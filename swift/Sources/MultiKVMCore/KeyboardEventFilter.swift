/// UIKit と GCKeyboard が同じ遷移を届ける場合だけ重複を除く。
/// 同じ入力元の短いタップや、押下直後の解放は必ず通す。
public struct KeyboardEventFilter {
    public enum Source: Equatable { case uiKit, gameController }
    private struct Event {
        var source: Source
        var time: Double
    }
    private var downs: [UInt8: Event] = [:]
    private var ups: [UInt8: Event] = [:]

    public init() {}

    public mutating func accepts(usage: UInt8, down: Bool, source: Source, at time: Double) -> Bool {
        let previous = down ? downs[usage] : ups[usage]
        if let previous, previous.source != source, (0...0.05).contains(time - previous.time) {
            return false
        }
        let event = Event(source: source, time: time)
        if down { downs[usage] = event } else { ups[usage] = event }
        return true
    }
}
