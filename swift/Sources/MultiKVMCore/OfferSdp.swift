import Foundation

public enum OfferSdp {
    public static let playoutDelayURI = "http://www.webrtc.org/experiments/rtp-hdrext/playout-delay"

    public static func insertingPlayoutDelay(_ sdp: String) -> String {
        if sdp.contains(playoutDelayURI) {
            return sdp
        }
        let newline = sdp.contains("\r\n") ? "\r\n" : "\n"
        var lines = sdp.components(separatedBy: newline)
        let used = extmapIDs(in: lines)
        guard let id = (1 ... 14).first(where: { !used.contains($0) }) else {
            return sdp
        }
        guard let video = lines.firstIndex(where: { $0.hasPrefix("m=video") }) else {
            return sdp
        }
        lines.insert("a=extmap:\(id) \(playoutDelayURI)", at: video + 1)
        return lines.joined(separator: newline)
    }

    public static func problems(in sdp: String) -> [String] {
        var found: [String] = []
        let upper = sdp.uppercased()
        if sdp.contains("m=audio") {
            found.append("音声の m-line があります。映像の再生遅延が音声に引っ張られるので、音声は載せません")
        }
        if upper.contains("H265") || upper.contains("HEVC") {
            found.append("H.265 が含まれています。エンコーダは H.264 High を使うので、H.264 だけを提示します")
        }
        if !upper.contains("H264") {
            found.append("H.264 が SDP にありません")
        }
        if !sdp.contains(playoutDelayURI) {
            found.append("playout-delay 拡張がありません。ジッタバッファを 0 に固定できません")
        }
        return found
    }

    private static func extmapIDs(in lines: [String]) -> Set<Int> {
        var ids: Set<Int> = []
        for line in lines where line.hasPrefix("a=extmap:") {
            let rest = line.dropFirst("a=extmap:".count)
            let token = rest.split(separator: " ").first.map(String.init) ?? ""
            let idText = token.split(separator: "/").first.map(String.init) ?? ""
            if let id = Int(idText) {
                ids.insert(id)
            }
        }
        return ids
    }
}

public struct StreamStats: Equatable {
    public private(set) var framesPerSecond: Double = 0
    public private(set) var bitsPerSecond: Double = 0
    public private(set) var framesInWindow = 0
    private var windowStart: Double = 0
    private var bytesInWindow = 0
    private var started = false

    public init() {}

    public mutating func record(byteCount: Int, at time: Double) {
        if !started {
            windowStart = time
            started = true
        }
        framesInWindow += 1
        bytesInWindow += byteCount
        let elapsed = time - windowStart
        if elapsed >= 1 {
            framesPerSecond = Double(framesInWindow) / elapsed
            bitsPerSecond = Double(bytesInWindow * 8) / elapsed
            framesInWindow = 0
            bytesInWindow = 0
            windowStart = time
        }
    }
}

public enum LatencyBarcode {
    public static let cellCount = 24
    public static let dataBits = 20

    public static func cells(unixMilliseconds: UInt64) -> [Bool] {
        let value = unixMilliseconds & 0xF_FFFF
        var bits: [Bool] = []
        for shift in stride(from: dataBits - 1, through: 0, by: -1) {
            bits.append((value >> shift) & 1 == 1)
        }
        let parity = bits.reduce(false) { $0 != $1 }
        return [true, false] + bits + [parity, false]
    }

    public static func decode(luminances: [UInt8], threshold: UInt8 = 128) -> UInt64? {
        guard luminances.count == cellCount else { return nil }
        let black = luminances.map { $0 < threshold }
        guard black[0], !black[1], !black[cellCount - 1] else { return nil }
        let bits = Array(black[2 ..< 2 + dataBits])
        let parity = bits.reduce(false) { $0 != $1 }
        guard parity == black[2 + dataBits] else { return nil }
        var value: UInt64 = 0
        for bit in bits {
            value = (value << 1) | (bit ? 1 : 0)
        }
        return value
    }
}
