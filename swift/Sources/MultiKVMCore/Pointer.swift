import Foundation

public enum AbsoluteAxis {
    public static let maximum = 32_767

    public static func hid(_ unit: Double) -> Int {
        if unit.isNaN || unit.isInfinite {
            return 0
        }
        let clamped = min(1, max(0, unit))
        return Int((clamped * Double(maximum)).rounded())
    }
}

public struct AbsolutePointer {
    private var lastButtons: UInt8?

    public init() {}

    public mutating func event(xUnit: Double, yUnit: Double, buttons: UInt8) -> OutgoingHid {
        let x = AbsoluteAxis.hid(xUnit)
        let y = AbsoluteAxis.hid(yUnit)
        let buttonsChanged = lastButtons != buttons
        lastButtons = buttons
        return OutgoingHid(
            channel: buttonsChanged ? .reliable : .unreliableOrdered,
            bytes: HidMessage.pointer(x: x, y: y, buttons: buttons)
        )
    }
}

public enum RelativePointer {
    public static func reports(dx: Int, dy: Int, buttons: UInt8) -> [OutgoingHid] {
        var xs = chunks(dx)
        var ys = chunks(dy)
        if xs.isEmpty && ys.isEmpty {
            xs = [0]
            ys = [0]
        }
        let count = max(xs.count, ys.count)
        return (0 ..< count).map { index in
            let x = index < xs.count ? xs[index] : 0
            let y = index < ys.count ? ys[index] : 0
            return OutgoingHid(
                channel: .reliable,
                bytes: HidMessage.mouse(dx: x, dy: y, buttons: buttons)
            )
        }
    }

    private static func chunks(_ delta: Int) -> [Int8] {
        var rest = delta
        var parts: [Int8] = []
        while rest != 0 {
            let step = max(-127, min(127, rest))
            parts.append(Int8(step))
            rest -= step
        }
        return parts
    }
}

public enum Wheel {
    /// 正の userDeltaY は下方向のスクロール。HID のホイールは上が正なので符号を反転する。
    public static func hid(userDeltaX: Double, userDeltaY: Double, notchPoints: Double = 40) -> (wheelX: Int, wheelY: Int)? {
        let x = ticks(userDeltaX, notchPoints: notchPoints)
        let y = -ticks(userDeltaY, notchPoints: notchPoints)
        if x == 0 && y == 0 {
            return nil
        }
        return (x, y)
    }

    public static func jsonRpc(id: Int, wheelX: Int, wheelY: Int) -> String {
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "wheelReport",
            "params": ["wheelY": wheelY, "wheelX": wheelX],
            "id": id,
        ]
        let data = try? JSONSerialization.data(withJSONObject: object)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private static func ticks(_ points: Double, notchPoints: Double) -> Int {
        if points == 0 || notchPoints == 0 {
            return 0
        }
        let scaled = (points / notchPoints).rounded()
        var value = Int(scaled)
        if value == 0 && abs(points) >= 8 {
            value = points > 0 ? 1 : -1
        }
        return max(-127, min(127, value))
    }
}

public struct PlaneSize: Equatable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct PlaneRect: Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct PlanePoint: Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum VideoViewport {
    public static func contentRect(view: PlaneSize, video: PlaneSize) -> PlaneRect {
        if view.width <= 0 || view.height <= 0 || video.width <= 0 || video.height <= 0 {
            return PlaneRect(x: 0, y: 0, width: max(0, view.width), height: max(0, view.height))
        }
        let viewAspect = view.width / view.height
        let videoAspect = video.width / video.height
        if videoAspect > viewAspect {
            let height = view.width / videoAspect
            return PlaneRect(x: 0, y: (view.height - height) / 2, width: view.width, height: height)
        }
        let width = view.height * videoAspect
        return PlaneRect(x: (view.width - width) / 2, y: 0, width: width, height: view.height)
    }

    public static func unit(location: PlanePoint, content: PlaneRect) -> (Double, Double) {
        if content.width <= 0 || content.height <= 0 {
            return (0, 0)
        }
        let x = min(1, max(0, (location.x - content.x) / content.width))
        let y = min(1, max(0, (location.y - content.y) / content.height))
        return (x, y)
    }
}
