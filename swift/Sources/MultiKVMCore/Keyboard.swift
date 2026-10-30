import Foundation

/// A validated HID report; transport always uses its reliable ordered channel.
public struct OutgoingHid: Equatable {
    public let bytes: Data
    public init(bytes: Data) { self.bytes = bytes }
}

public enum HidMessage {
    public static let handshakeType: UInt8 = 0x01
    public static let keyboardType: UInt8 = 0x02
    public static let pointerType: UInt8 = 0x03
    public static let mouseType: UInt8 = 0x06
    public static let version: UInt8 = 0x01
    public static let rollover: UInt8 = 0x01
    public static let keySlots = 6

    public static func handshake() -> Data {
        Data([handshakeType, version])
    }

    public static func keyboard(modifier: UInt8, keys: [UInt8]) -> Data {
        var body = keys
        if body.count > keySlots {
            body = Array(repeating: rollover, count: keySlots)
        } else if body.count < keySlots {
            body.append(contentsOf: Array(repeating: 0, count: keySlots - body.count))
        }
        return Data([keyboardType, modifier] + body)
    }

    public static func pointer(x: Int, y: Int, buttons: UInt8) -> Data {
        var data = Data([pointerType])
        data.append(contentsOf: bigEndian(Int32(x)))
        data.append(contentsOf: bigEndian(Int32(y)))
        data.append(buttons)
        return data
    }

    public static func mouse(dx: Int8, dy: Int8, buttons: UInt8) -> Data {
        Data([mouseType, UInt8(bitPattern: dx), UInt8(bitPattern: dy), buttons])
    }

    public static func bigEndian(_ value: Int32) -> [UInt8] {
        let raw = UInt32(bitPattern: value)
        return [
            UInt8((raw >> 24) & 0xFF),
            UInt8((raw >> 16) & 0xFF),
            UInt8((raw >> 8) & 0xFF),
            UInt8(raw & 0xFF),
        ]
    }
}

public enum InboundHid: Equatable {
    case handshake(version: UInt8)
    case keyboardLed(raw: UInt8)
    case other(type: UInt8)

    public static func parse(_ data: Data) -> InboundHid? {
        guard let type = data.first else { return nil }
        switch type {
        case HidMessage.handshakeType:
            return .handshake(version: data.count > 1 ? data[1] : 0)
        case 0x32:
            return .keyboardLed(raw: data.count > 1 ? data[1] : 0)
        default:
            return .other(type: type)
        }
    }

    public var capsLock: Bool {
        if case .keyboardLed(let raw) = self {
            return raw & 0x02 != 0
        }
        return false
    }
}

public enum HidModifier {
    public static let leftControl: UInt8 = 0x01
    public static let leftShift: UInt8 = 0x02
    public static let leftAlt: UInt8 = 0x04
    public static let leftGUI: UInt8 = 0x08
    public static let rightControl: UInt8 = 0x10
    public static let rightShift: UInt8 = 0x20
    public static let rightAlt: UInt8 = 0x40
    public static let rightGUI: UInt8 = 0x80

    public static func mask(forUsage usage: UInt8) -> UInt8? {
        switch usage {
        case 0xE0: return leftControl
        case 0xE1: return leftShift
        case 0xE2: return leftAlt
        case 0xE3: return leftGUI
        case 0xE4: return rightControl
        case 0xE5: return rightShift
        case 0xE6: return rightAlt
        case 0xE7: return rightGUI
        default: return nil
        }
    }
}

public enum HidUsage {
    public static let keyboardA: UInt8 = 0x04
    public static let keyboard1: UInt8 = 0x1E
    public static let keyboard2: UInt8 = 0x1F
    public static let keyboardMinus: UInt8 = 0x2D
    public static let keyboardEqual: UInt8 = 0x2E
    public static let keyboardLeftBracket: UInt8 = 0x2F
    public static let keyboardRightBracket: UInt8 = 0x30
    public static let keyboardBackslash: UInt8 = 0x31
    public static let keyboardSemicolon: UInt8 = 0x33
    public static let keyboardQuote: UInt8 = 0x34
    public static let keyboardGrave: UInt8 = 0x35
    public static let keyboardF12: UInt8 = 0x45
    public static let keyboardNonUSBackslash: UInt8 = 0x64
    public static let keyboardInternational1: UInt8 = 0x87
    public static let keyboardInternational3: UInt8 = 0x89
    public static let keyboardInternational4: UInt8 = 0x8A
    public static let keyboardInternational5: UInt8 = 0x8B
}

public struct KeyboardModel {
    private var modifiers: UInt8 = 0
    private var pressed: [UInt8] = []

    public init() {}

    public var isEmpty: Bool { modifiers == 0 && pressed.isEmpty }

    public mutating func keyDown(_ usage: UInt8) -> OutgoingHid {
        if let mask = HidModifier.mask(forUsage: usage) {
            modifiers |= mask
        } else if !pressed.contains(usage) {
            pressed.append(usage)
        }
        return report()
    }

    public mutating func keyUp(_ usage: UInt8) -> OutgoingHid {
        if let mask = HidModifier.mask(forUsage: usage) {
            modifiers &= ~mask
        } else {
            pressed.removeAll { $0 == usage }
        }
        return report()
    }

    public mutating func clear() -> OutgoingHid {
        modifiers = 0
        pressed.removeAll()
        return report()
    }

    public func report() -> OutgoingHid {
        let keys: [UInt8]
        if pressed.count > HidMessage.keySlots {
            keys = Array(repeating: HidMessage.rollover, count: HidMessage.keySlots)
        } else {
            keys = pressed
        }
        return OutgoingHid(
            bytes: HidMessage.keyboard(modifier: modifiers, keys: keys)
        )
    }
}

public enum KeyboardSide: String, Equatable {
    case us
    case jis
}

public enum KeyboardLayout {
    /// 物理キーボードの HID usage を、Windows 側の配列へ合わせる。
    /// 同じ配列ならそのまま通す。変換・無変換は US 側に対応するキーがないので捨てる。
    public static func remap(usage: UInt8, keyboard: KeyboardSide, host: KeyboardSide) -> UInt8? {
        if keyboard == host {
            return usage
        }
        switch (keyboard, host, usage) {
        case (.jis, .us, HidUsage.keyboardInternational3):
            return HidUsage.keyboardBackslash
        case (.jis, .us, HidUsage.keyboardInternational1):
            return HidUsage.keyboardNonUSBackslash
        case (.jis, .us, HidUsage.keyboardInternational4),
            (.jis, .us, HidUsage.keyboardInternational5):
            return nil
        case (.us, .jis, HidUsage.keyboardBackslash):
            return HidUsage.keyboardInternational3
        case (.us, .jis, HidUsage.keyboardNonUSBackslash):
            return HidUsage.keyboardInternational1
        default:
            return usage
        }
    }

    /// 文字しか取れないときのフォールバック。ハードウェアキーボードは usage を優先する。
    public static func stroke(for character: Character, host: KeyboardSide) -> (usage: UInt8, modifier: UInt8)? {
        switch host {
        case .us:
            return usStroke(character)
        case .jis:
            return jisStroke(character) ?? usStroke(character)
        }
    }

    private static func usStroke(_ character: Character) -> (usage: UInt8, modifier: UInt8)? {
        if let usage = letter(character) {
            let modifier: UInt8 = character.isUppercase ? HidModifier.leftShift : 0
            return (usage, modifier)
        }
        let shift = HidModifier.leftShift
        switch character {
        case "@": return (HidUsage.keyboard2, shift)
        case "\\": return (HidUsage.keyboardBackslash, 0)
        case "[": return (HidUsage.keyboardLeftBracket, 0)
        case "]": return (HidUsage.keyboardRightBracket, 0)
        case "-": return (HidUsage.keyboardMinus, 0)
        case "=": return (HidUsage.keyboardEqual, 0)
        case ";": return (HidUsage.keyboardSemicolon, 0)
        case "'": return (HidUsage.keyboardQuote, 0)
        case "`": return (HidUsage.keyboardGrave, 0)
        case " ": return (0x2C, 0)
        default: return nil
        }
    }

    private static func jisStroke(_ character: Character) -> (usage: UInt8, modifier: UInt8)? {
        let shift = HidModifier.leftShift
        switch character {
        case "@": return (HidUsage.keyboardLeftBracket, 0)
        case "`": return (HidUsage.keyboardLeftBracket, shift)
        case "[": return (HidUsage.keyboardRightBracket, 0)
        case "{": return (HidUsage.keyboardRightBracket, shift)
        case "]": return (HidUsage.keyboardBackslash, 0)
        case "}": return (HidUsage.keyboardBackslash, shift)
        case "\\", "¥": return (HidUsage.keyboardInternational3, 0)
        case "|": return (HidUsage.keyboardInternational3, shift)
        case "^": return (HidUsage.keyboardEqual, 0)
        case "~": return (HidUsage.keyboardEqual, shift)
        case ":": return (HidUsage.keyboardQuote, 0)
        case "*": return (HidUsage.keyboardQuote, shift)
        case "_": return (HidUsage.keyboardInternational1, shift)
        default: return nil
        }
    }

    private static func letter(_ character: Character) -> UInt8? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return nil
        }
        let value = scalar.value
        if (97...122).contains(value) {
            return HidUsage.keyboardA + UInt8(value - 97)
        }
        if (65...90).contains(value) {
            return HidUsage.keyboardA + UInt8(value - 65)
        }
        if (49...57).contains(value) {
            return HidUsage.keyboard1 + UInt8(value - 49)
        }
        if value == 48 {
            return 0x27
        }
        return nil
    }
}
