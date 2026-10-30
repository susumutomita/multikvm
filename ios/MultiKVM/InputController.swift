import GameController
import MultiKVMCore
import SwiftUI
import UIKit

struct InputHost: UIViewControllerRepresentable {
    @ObservedObject var session: SessionController

    func makeUIViewController(context: Context) -> InputViewController {
        let controller = InputViewController()
        controller.session = session
        return controller
    }

    func updateUIViewController(_ controller: InputViewController, context: Context) {
        controller.session = session
    }
}

final class InputViewController: UIViewController, UIGestureRecognizerDelegate {
    var session: SessionController?
    private var lastPoint: CGPoint?
    private var buttons: UInt8 = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let session else { return }
        view = session.renderer.view
        view.backgroundColor = .black
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.delegate = self
        view.addGestureRecognizer(scroll)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:)))
        view.addGestureRecognizer(hover)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(gameControllerKeyboard),
            name: NSNotification.Name.GCKeyboardDidConnect,
            object: nil
        )
        installGameController()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var canBecomeFirstResponder: Bool { true }

    override var inputView: UIView? {
        UIView(frame: .zero)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        deliver(presses, down: true)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        deliver(presses, down: false)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        deliver(presses, down: false)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        apply(touches, event: event, ended: false)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        apply(touches, event: event, ended: false)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        apply(touches, event: event, ended: true)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        apply(touches, event: event, ended: true)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc private func onScroll(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        gesture.setTranslation(.zero, in: view)
        session?.scroll(dx: translation.x, dy: translation.y)
    }

    @objc private func onHover(_ gesture: UIHoverGestureRecognizer) {
        guard session?.pointerMode == .absolute else { return }
        let point = gesture.location(in: view)
        sendAbsolute(point, buttons: buttons)
    }

    @objc private func gameControllerKeyboard() {
        installGameController()
    }

    private func installGameController() {
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            let usage = UInt8(truncatingIfNeeded: keyCode)
            Task { @MainActor in
                self?.session?.gameControllerKey(usage, down: pressed)
            }
        }
    }

    private func deliver(_ presses: Set<UIPress>, down: Bool) {
        for press in presses {
            let raw = press.key?.keyCode.rawValue ?? 0
            let usage = (raw > 0 && raw <= 255) ? UInt8(raw) : nil
            let character = press.key?.characters.first
            session?.hardwareKey(usage, character: character, down: down)
        }
    }

    private func apply(_ touches: Set<UITouch>, event: UIEvent?, ended: Bool) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: view)
        if ended, touches.count == event.map({ $0.allTouches?.count ?? touches.count }) ?? touches.count {
            buttons = 0
            lastPoint = nil
            sendAbsolute(point, buttons: 0)
            return
        }
        buttons = hidButtons(event: event, touch: touch)
        if session?.pointerMode == .relative, let lastPoint {
            let dx = Int((point.x - lastPoint.x).rounded())
            let dy = Int((point.y - lastPoint.y).rounded())
            session?.pointerRelative(dx: dx, dy: dy, buttons: buttons)
        } else {
            sendAbsolute(point, buttons: buttons)
        }
        lastPoint = point
    }

    private func sendAbsolute(_ point: CGPoint, buttons: UInt8) {
        guard let session else { return }
        let rect = VideoViewport.contentRect(
            view: PlaneSize(width: Double(view.bounds.width), height: Double(view.bounds.height)),
            video: session.videoSize
        )
        let unit = VideoViewport.unit(
            location: PlanePoint(x: Double(point.x), y: Double(point.y)),
            content: rect
        )
        session.pointer(xUnit: unit.0, yUnit: unit.1, buttons: buttons)
    }

    private func hidButtons(event: UIEvent?, touch: UITouch) -> UInt8 {
        guard touch.type == .indirectPointer, let mask = event?.buttonMask else {
            return 0x01
        }
        var value: UInt8 = 0
        if mask.contains(.primary) { value |= 0x01 }
        if mask.contains(.secondary) { value |= 0x02 }
        return value == 0 ? buttons : value
    }
}
