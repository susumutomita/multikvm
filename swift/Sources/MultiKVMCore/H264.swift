import Foundation

/// After a compressed reference frame is lost, resume only at an IDR.
/// The renderer and decoder use separate gates because display callbacks are queued.
public final class H264RecoveryGate {
    private let lock = NSLock()
    private var waiting: Bool

    public init(waitingForKeyframe: Bool = false) { waiting = waitingForKeyframe }

    public func requestKeyframe() { lock.withLock { waiting = true } }

    public func accepts(_ unit: H264AccessUnit) -> Bool {
        lock.withLock {
            if unit.nalUnits.contains(where: { H264AccessUnit.nalType($0) == 5 }) {
                waiting = false
            }
            return !waiting
        }
    }
}

public struct H264AccessUnit: Equatable {
    public var nalUnits: [Data]

    public init(nalUnits: [Data]) {
        self.nalUnits = nalUnits
    }

    public var sps: Data? { nalUnits.first { H264AccessUnit.nalType($0) == 7 } }
    public var pps: Data? { nalUnits.first { H264AccessUnit.nalType($0) == 8 } }

    public var sliceUnits: [Data] {
        nalUnits.filter {
            let type = H264AccessUnit.nalType($0)
            return type == 1 || type == 5 || type == 6
        }
    }

    public func lengthPrefixed(units: [Data]? = nil) -> Data {
        var output = Data()
        for unit in units ?? nalUnits {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(unit)
        }
        return output
    }

    public static func nalType(_ nal: Data) -> UInt8 {
        guard let first = nal.first else { return 0 }
        return first & 0x1F
    }

    public static func parseBitstream(_ buffer: Data) -> H264AccessUnit {
        if buffer.starts(with: [0x00, 0x00, 0x00, 0x01]) || buffer.starts(with: [0x00, 0x00, 0x01]) {
            return H264AccessUnit(nalUnits: splitAnnexB(buffer))
        }
        if let avcc = splitAVCC(buffer), !avcc.isEmpty {
            return H264AccessUnit(nalUnits: avcc)
        }
        return H264AccessUnit(nalUnits: buffer.isEmpty ? [] : [buffer])
    }

    private static func splitAnnexB(_ buffer: Data) -> [Data] {
        let bytes = [UInt8](buffer)
        var starts: [Int] = []
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    starts.append(index + 3)
                    index += 3
                    continue
                }
                if index + 3 < bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    starts.append(index + 4)
                    index += 4
                    continue
                }
            }
            index += 1
        }
        var units: [Data] = []
        for (offset, start) in starts.enumerated() {
            let end = offset + 1 < starts.count ? startCodeStart(bytes, before: starts[offset + 1]) : bytes.count
            if start < end {
                units.append(Data(bytes[start..<end]))
            }
        }
        return units
    }

    private static func startCodeStart(_ bytes: [UInt8], before nalStart: Int) -> Int {
        if nalStart >= 4, bytes[nalStart - 4] == 0, bytes[nalStart - 3] == 0, bytes[nalStart - 2] == 0,
            bytes[nalStart - 1] == 1
        {
            return nalStart - 4
        }
        if nalStart >= 3, bytes[nalStart - 3] == 0, bytes[nalStart - 2] == 0, bytes[nalStart - 1] == 1 {
            return nalStart - 3
        }
        return nalStart
    }

    private static func splitAVCC(_ buffer: Data) -> [Data]? {
        var units: [Data] = []
        var offset = 0
        let bytes = [UInt8](buffer)
        while offset + 4 <= bytes.count {
            let length =
                Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8
                | Int(bytes[offset + 3])
            let start = offset + 4
            if length <= 0 || start + length > bytes.count {
                return units.isEmpty ? nil : units
            }
            let nal = Data(bytes[start..<start + length])
            if nal.first.map({ $0 & 0x80 }) == 0x80 {
                return units.isEmpty ? nil : units
            }
            units.append(nal)
            offset = start + length
        }
        return units.isEmpty ? nil : units
    }
}

public struct RtpH264Packet {
    public var payload: Data
    public var marker: Bool
    public var timestamp: UInt32

    public init(payload: Data, marker: Bool, timestamp: UInt32) {
        self.payload = payload
        self.marker = marker
        self.timestamp = timestamp
    }
}

public final class H264Depacketizer {
    public private(set) var droppedPackets = 0
    private var fu: [UInt8] = []
    private var fuTimestamp: UInt32 = 0
    private var fuOpen = false

    public init() {}

    public func push(_ packet: RtpH264Packet) -> H264AccessUnit? {
        let payload = [UInt8](packet.payload)
        guard let first = payload.first else {
            droppedPackets += 1
            return nil
        }
        let type = first & 0x1F
        if type >= 1 && type <= 23 {
            fuOpen = false
            fu.removeAll()
            return H264AccessUnit(nalUnits: [packet.payload])
        }
        if type == 24 {
            return stap(payload)
        }
        if type == 28 {
            return fuA(payload, timestamp: packet.timestamp)
        }
        droppedPackets += 1
        return nil
    }

    private func stap(_ payload: [UInt8]) -> H264AccessUnit? {
        var units: [Data] = []
        var offset = 1
        while offset + 2 <= payload.count {
            let size = Int(payload[offset]) << 8 | Int(payload[offset + 1])
            let start = offset + 2
            if size <= 0 || start + size > payload.count {
                droppedPackets += 1
                return nil
            }
            units.append(Data(payload[start..<start + size]))
            offset = start + size
        }
        return units.isEmpty ? nil : H264AccessUnit(nalUnits: units)
    }

    private func fuA(_ payload: [UInt8], timestamp: UInt32) -> H264AccessUnit? {
        guard payload.count >= 2 else {
            droppedPackets += 1
            return nil
        }
        let indicator = payload[0]
        let header = payload[1]
        let start = header & 0x80 != 0
        let end = header & 0x40 != 0
        let nalHeader = (indicator & 0xE0) | (header & 0x1F)
        if start {
            fu = [nalHeader]
            fu.append(contentsOf: payload.dropFirst(2))
            fuTimestamp = timestamp
            fuOpen = true
        } else if fuOpen && fuTimestamp == timestamp {
            fu.append(contentsOf: payload.dropFirst(2))
        } else {
            droppedPackets += 1
            fuOpen = false
            fu.removeAll()
            return nil
        }
        if end && fuOpen {
            let unit = Data(fu)
            fuOpen = false
            fu.removeAll()
            return H264AccessUnit(nalUnits: [unit])
        }
        return nil
    }
}
