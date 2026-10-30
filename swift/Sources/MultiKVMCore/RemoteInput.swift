import Foundation

public enum PointerMode: String { case absolute, relative }

/// Input state is independent of UIKit, transport, and wall clocks.
public struct RemoteInput {
    private var keyboard = KeyboardModel()
    private var keyEvents = KeyboardEventFilter()
    private var syntheticModifiers: [UInt8: UInt8] = [:]
    private var wheel = WheelAccumulator()
    private var lastPoint = (x: 0.0, y: 0.0)
    private var rpcID = 0

    public init() {}

    public var keyboardReport: OutgoingHid {
        var bytes = keyboard.report().bytes
        bytes[1] |= syntheticModifiers.values.reduce(0, |)
        return OutgoingHid(bytes: bytes)
    }

    public mutating func key(
        usage: UInt8?, character: Character?, down: Bool,
        source: KeyboardEventFilter.Source, at time: Double,
        keyboardSide: KeyboardSide, hostLayout: KeyboardSide
    ) -> OutgoingHid? {
        if let usage, !keyEvents.accepts(usage: usage, down: down, source: source, at: time) { return nil }
        let stroke: (usage: UInt8, modifier: UInt8)?
        if let usage, usage != 0 {
            stroke = KeyboardLayout.remap(usage: usage, keyboard: keyboardSide, host: hostLayout).map { ($0, 0) }
        } else {
            stroke = character.flatMap { KeyboardLayout.stroke(for: $0, host: hostLayout) }
        }
        guard let stroke else { return nil }
        if down {
            _ = keyboard.keyDown(stroke.usage)
            syntheticModifiers[stroke.usage] = stroke.modifier
        } else {
            _ = keyboard.keyUp(stroke.usage)
            syntheticModifiers.removeValue(forKey: stroke.usage)
        }
        return keyboardReport
    }

    public mutating func measurement(down: Bool) -> OutgoingHid? {
        if down {
            guard !keyboard.report().bytes.dropFirst(2).contains(HidUsage.keyboardF12) else { return nil }
            _ = keyboard.keyDown(HidUsage.keyboardF12)
        } else {
            _ = keyboard.keyUp(HidUsage.keyboardF12)
        }
        return keyboardReport
    }

    public mutating func absolute(x: Double, y: Double, buttons: UInt8) -> OutgoingHid {
        lastPoint = (x, y)
        return AbsolutePointer.report(xUnit: x, yUnit: y, buttons: buttons)
    }

    public mutating func scroll(dx: Double, dy: Double) throws -> String? {
        guard let delta = wheel.event(dx: dx, dy: dy) else { return nil }
        rpcID += 1
        return try Wheel.jsonRpc(id: rpcID, wheelX: delta.wheelX, wheelY: delta.wheelY)
    }

    public mutating func release(mode: PointerMode) -> [OutgoingHid] {
        _ = keyboard.clear()
        keyEvents = KeyboardEventFilter()
        syntheticModifiers = [:]
        wheel = WheelAccumulator()
        let pointer =
            mode == .absolute
            ? [AbsolutePointer.report(xUnit: lastPoint.x, yUnit: lastPoint.y, buttons: 0)]
            : RelativePointer.reports(dx: 0, dy: 0, buttons: 0)
        return [keyboardReport] + pointer
    }
}
