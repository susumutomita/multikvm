import XCTest

@testable import MultiKVMCore

final class KeyboardTests: XCTestCase {
    func testGameControllerShortTapKeepsRelease() {
        var events = KeyboardEventFilter()
        XCTAssertTrue(events.accepts(usage: 4, down: true, source: .gameController, at: 0))
        XCTAssertTrue(events.accepts(usage: 4, down: false, source: .gameController, at: 0.01))
        XCTAssertTrue(events.accepts(usage: 4, down: true, source: .gameController, at: 0.02))
        XCTAssertTrue(events.accepts(usage: 4, down: false, source: .gameController, at: 0.03))
    }

    func testDuplicateKeyboardSourcesKeepBothTransitionsInEitherOrder() {
        for first in [KeyboardEventFilter.Source.uiKit, .gameController] {
            let second: KeyboardEventFilter.Source = first == .uiKit ? .gameController : .uiKit
            var events = KeyboardEventFilter()
            XCTAssertTrue(events.accepts(usage: 4, down: true, source: first, at: 1))
            XCTAssertFalse(events.accepts(usage: 4, down: true, source: second, at: 1.001))
            XCTAssertTrue(events.accepts(usage: 4, down: false, source: first, at: 1.01))
            XCTAssertFalse(events.accepts(usage: 4, down: false, source: second, at: 1.011))
        }
    }

    func testModifiersAndRollover() {
        var keyboard = KeyboardModel()
        let down = keyboard.keyDown(0xE0)
        XCTAssertEqual(down.bytes, Data([0x02, HidModifier.leftControl, 0, 0, 0, 0, 0, 0]))

        let letter = keyboard.keyDown(HidUsage.keyboardA)
        XCTAssertEqual(letter.bytes[1], HidModifier.leftControl)
        XCTAssertEqual(letter.bytes[2], HidUsage.keyboardA)

        _ = keyboard.keyUp(0xE0)
        XCTAssertEqual(keyboard.report().bytes[1], 0)

        for usage in UInt8(0x04)...UInt8(0x09) {
            _ = keyboard.keyDown(usage)
        }
        let extra = keyboard.keyDown(0x0A)
        XCTAssertEqual(Array(extra.bytes.dropFirst(2)), Array(repeating: HidMessage.rollover, count: 6))
        let released = keyboard.keyUp(0x04)
        XCTAssertFalse(released.bytes.dropFirst(2).contains(HidMessage.rollover))
        XCTAssertEqual(keyboard.clear().bytes, Data([0x02, 0, 0, 0, 0, 0, 0, 0]))
    }

    func testLayoutRemapAndCharacters() {
        XCTAssertEqual(
            KeyboardLayout.remap(usage: HidUsage.keyboardInternational3, keyboard: .jis, host: .us),
            HidUsage.keyboardBackslash
        )
        XCTAssertNil(KeyboardLayout.remap(usage: HidUsage.keyboardInternational4, keyboard: .jis, host: .us))
        XCTAssertEqual(
            KeyboardLayout.remap(usage: HidUsage.keyboardBackslash, keyboard: .us, host: .jis),
            HidUsage.keyboardInternational3
        )
        XCTAssertEqual(
            KeyboardLayout.remap(usage: HidUsage.keyboardA, keyboard: .jis, host: .jis),
            HidUsage.keyboardA
        )
        XCTAssertEqual(KeyboardLayout.stroke(for: "@", host: .us)?.usage, HidUsage.keyboard2)
        XCTAssertEqual(KeyboardLayout.stroke(for: "@", host: .us)?.modifier, HidModifier.leftShift)
        XCTAssertEqual(KeyboardLayout.stroke(for: "@", host: .jis)?.usage, HidUsage.keyboardLeftBracket)
        XCTAssertEqual(KeyboardLayout.stroke(for: "@", host: .jis)?.modifier, 0)
        XCTAssertEqual(KeyboardLayout.stroke(for: "¥", host: .jis)?.usage, HidUsage.keyboardInternational3)
        XCTAssertEqual(KeyboardLayout.stroke(for: "A", host: .us)?.modifier, HidModifier.leftShift)
        XCTAssertEqual(KeyboardLayout.stroke(for: "a", host: .jis)?.usage, HidUsage.keyboardA)
        XCTAssertNil(KeyboardLayout.stroke(for: "あ", host: .jis))
    }

    func testRepeatIsIdempotent() {
        var keyboard = KeyboardModel()
        _ = keyboard.keyDown(HidUsage.keyboardA)
        let again = keyboard.keyDown(HidUsage.keyboardA)
        XCTAssertEqual(again.bytes.filter { $0 == HidUsage.keyboardA }.count, 1)
    }
}

final class PointerTests: XCTestCase {
    func testSlowScrollPreservesMovementAcrossCallbacksAndDirectionChanges() {
        var wheel = WheelAccumulator()
        var total = 0
        for _ in 0..<20 { total += wheel.event(dx: 0, dy: 4)?.wheelY ?? 0 }
        XCTAssertEqual(total, -2)
        XCTAssertNil(wheel.event(dx: 12, dy: -12))
        XCTAssertNil(wheel.event(dx: -12, dy: 12))
        XCTAssertNil(wheel.event(dx: 0, dy: 39))
        XCTAssertEqual(wheel.event(dx: 40, dy: 1)?.wheelY, -1)
        XCTAssertEqual(wheel.event(dx: -40, dy: -40)?.wheelX, -1)
        XCTAssertNil(wheel.event(dx: .nan, dy: .infinity))
    }

    func testAbsoluteCoordinatesAndButtonTransitions() {
        let first = AbsolutePointer.report(xUnit: 0, yUnit: 1, buttons: 0)
        XCTAssertEqual(first.bytes.count, 10)
        XCTAssertEqual(first.bytes[0], 0x03)
        let move = AbsolutePointer.report(xUnit: 0.5, yUnit: 0, buttons: 0)
        XCTAssertEqual(move.bytes, Data([3, 0, 0, 64, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(AbsoluteAxis.hid(0.5), 16_384)
        XCTAssertEqual(AbsoluteAxis.hid(1), 32_767)
        XCTAssertEqual(AbsoluteAxis.hid(-1), 0)
        XCTAssertEqual(AbsoluteAxis.hid(.nan), 0)
        let click = AbsolutePointer.report(xUnit: 0.5, yUnit: 0, buttons: 0x01)
        XCTAssertEqual(click.bytes.last, 0x01)
        let drag = AbsolutePointer.report(xUnit: 0.6, yUnit: 0.1, buttons: 0x01)
        let release = AbsolutePointer.report(xUnit: 0.6, yUnit: 0.1, buttons: 0)
        XCTAssertEqual(release.bytes.last, 0)
        XCTAssertEqual(drag.bytes.last, 1)
        XCTAssertEqual(Array(drag.bytes.dropLast()), Array(release.bytes.dropLast()))
    }

    func testStationaryRelativeClickAndReleasePreserveButtonState() {
        let press = RelativePointer.reports(dx: 0, dy: 0, buttons: 1)
        let release = RelativePointer.reports(dx: 0, dy: 0, buttons: 0)
        XCTAssertEqual(press.map(\.bytes), [Data([0x06, 0, 0, 1])])
        XCTAssertEqual(release.map(\.bytes), [Data([0x06, 0, 0, 0])])
    }

    func testRelativeSplitAndWheel() throws {
        let reports = RelativePointer.reports(dx: 300, dy: -200, buttons: 0x01)
        XCTAssertEqual(reports.count, 3)
        XCTAssertTrue(reports.allSatisfy { $0.bytes[3] == 1 })
        XCTAssertEqual(reports.map(\.bytes[1]), [127, 127, 46])
        XCTAssertEqual(Int8(bitPattern: reports[0].bytes[2]), -127)
        XCTAssertEqual(Int8(bitPattern: reports[1].bytes[2]), -73)
        XCTAssertEqual(reports[2].bytes[2], 0)

        var wheel = WheelAccumulator()
        let down = wheel.event(dx: 0, dy: 40)
        XCTAssertEqual(down?.wheelY, -1)
        XCTAssertEqual(down?.wheelX, 0)
        let up = wheel.event(dx: 80, dy: -40)
        XCTAssertEqual(up?.wheelX, 2)
        XCTAssertEqual(up?.wheelY, 1)
        XCTAssertNil(wheel.event(dx: 0, dy: 0))
        let json = try Wheel.jsonRpc(id: 7, wheelX: 0, wheelY: -1)
        XCTAssertTrue(json.contains(#""method":"wheelReport""#))
        XCTAssertTrue(json.contains(#""wheelY":-1"#))
    }

    func testLetterbox() {
        let rect = VideoViewport.contentRect(
            view: PlaneSize(width: 1000, height: 1000),
            video: PlaneSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(rect.x, 0, accuracy: 0.01)
        XCTAssertGreaterThan(rect.y, 0)
        let unit = VideoViewport.unit(
            location: PlanePoint(x: rect.x + rect.width, y: rect.y),
            content: rect
        )
        XCTAssertEqual(unit.0, 1, accuracy: 0.001)
        XCTAssertEqual(unit.1, 0, accuracy: 0.001)
        let outside = VideoViewport.unit(location: PlanePoint(x: -20, y: 5000), content: rect)
        XCTAssertEqual(outside.0, 0)
        XCTAssertEqual(outside.1, 1)
    }
}

final class RemoteInputTests: XCTestCase {
    func testSyntheticShiftDoesNotReleaseOtherShiftedKeysOrPhysicalShift() {
        var input = RemoteInput()
        func key(_ usage: UInt8?, _ character: Character?, _ down: Bool, _ time: Double) -> OutgoingHid? {
            input.key(
                usage: usage, character: character, down: down, source: .uiKit,
                at: time, keyboardSide: .us, hostLayout: .us)
        }
        _ = key(0xE1, nil, true, 0)
        _ = key(nil, "A", true, 1)
        _ = key(nil, "B", true, 2)
        XCTAssertEqual(key(nil, "A", false, 3)?.bytes[1], HidModifier.leftShift)
        XCTAssertEqual(key(nil, "B", false, 4)?.bytes[1], HidModifier.leftShift)
        XCTAssertEqual(key(0xE1, nil, false, 5)?.bytes[1], 0)
    }

    func testReleaseKeepsPointerPositionAndClearsWheelAndKeyboard() throws {
        var input = RemoteInput()
        _ = input.absolute(x: 0.6, y: 0.7, buttons: 1)
        _ = input.key(
            usage: HidUsage.keyboardA, character: nil, down: true,
            source: .gameController, at: 0, keyboardSide: .us, hostLayout: .us)
        XCTAssertNil(try input.scroll(dx: 0, dy: 39))
        let releases = input.release(mode: .absolute)
        XCTAssertEqual(releases[0], KeyboardModel().report())
        XCTAssertEqual(releases[1], AbsolutePointer.report(xUnit: 0.6, yUnit: 0.7, buttons: 0))
        XCTAssertNil(try input.scroll(dx: 0, dy: 1))
    }

    func testGameControllerFallbackTapReleasesAndMeasurementDoesNotStealHeldF12() {
        var input = RemoteInput()
        let down = input.key(
            usage: HidUsage.keyboardF12, character: nil, down: true,
            source: .gameController, at: 0, keyboardSide: .us, hostLayout: .us)
        XCTAssertTrue(down!.bytes.contains(HidUsage.keyboardF12))
        XCTAssertNil(input.measurement(down: true))
        let up = input.key(
            usage: HidUsage.keyboardF12, character: nil, down: false,
            source: .gameController, at: 0.001, keyboardSide: .us, hostLayout: .us)
        XCTAssertEqual(up, KeyboardModel().report())
        XCTAssertNotNil(input.measurement(down: true))
        XCTAssertEqual(input.measurement(down: false), KeyboardModel().report())
    }
}
