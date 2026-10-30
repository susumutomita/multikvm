import Foundation
import MultiKVMCore
import UIKit

struct OverlayModel: Equatable {
    var fps = 0.0
    var kbps = 0.0
    var rttMs: Double?
    var path = "未確定"
    var enqueueMs = 0.0
    var dropped = 0
    var clockMs = 0
}

enum PointerMode: String {
    case absolute
    case relative
}

@MainActor
final class SessionController: ObservableObject {
    @Published var hostText: String
    @Published var password = ""
    @Published var keyboardSide: KeyboardSide
    @Published var hostLayout: KeyboardSide
    @Published var pointerMode: PointerMode
    @Published var phase: LinkPhase = .idle
    @Published var statusLine = "未接続"
    @Published var overlay = OverlayModel()
    @Published var capsLock = false
    @Published var addressWarning: String?
    @Published var videoSize = PlaneSize(width: 0, height: 0)

    let renderer = VideoRenderer()
    private let defaults = UserDefaults.standard
    private let session: URLSession
    private var link: LinkState
    private var endpoint: JetKVMEndpoint?
    private var socket: URLSessionWebSocketTask?
    private var peer: PeerLink?
    private var keyboard = KeyboardModel()
    private var absolute = AbsolutePointer()
    private var rpcID = 0
    private var receiving = false
    private var clockTimer: Timer?
    private var recentHardwareKeys: [UInt8: TimeInterval] = [:]
    private var injectedShift = false

    var isBusy: Bool {
        switch phase {
        case .checkingAuth, .openingSignaling, .negotiating:
            return true
        case .idle, .confirmingDevice, .streaming, .closed:
            return false
        }
    }

    init() {
        let storedHost = UserDefaults.standard.string(forKey: Key.host) ?? ""
        hostText = storedHost
        keyboardSide = KeyboardSide(rawValue: UserDefaults.standard.string(forKey: Key.keyboard) ?? "") ?? .us
        hostLayout = KeyboardSide(rawValue: UserDefaults.standard.string(forKey: Key.hostLayout) ?? "") ?? .us
        pointerMode = PointerMode(rawValue: UserDefaults.standard.string(forKey: Key.pointer) ?? "") ?? .absolute
        link = LinkState(
            pairedHost: UserDefaults.standard.string(forKey: Key.paired),
            host: ""
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 12
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshClock()
            }
        }
        clockTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func connect() {
        if case .closed = phase {
            phase = .idle
            link = LinkState(pairedHost: defaults.string(forKey: Key.paired), host: "")
        }
        guard phase == .idle else { return }
        defaults.set(hostText, forKey: Key.host)
        defaults.set(keyboardSide.rawValue, forKey: Key.keyboard)
        defaults.set(hostLayout.rawValue, forKey: Key.hostLayout)
        let endpoint: JetKVMEndpoint
        do {
            endpoint = try JetKVMEndpoint.parse(hostText)
        } catch {
            fail("アドレスを読めません")
            return
        }
        self.endpoint = endpoint
        addressWarning = warning(for: endpoint.addressKind)
        link = LinkState(pairedHost: defaults.string(forKey: Key.paired), host: endpoint.pairedIdentity)
        link.apply(.begin)
        publishPhase("認証を確認しています")
        Task { await authenticate(endpoint) }
    }

    func confirmPairing() {
        link.apply(.confirm)
        if let host = link.pairedHost {
            defaults.set(host, forKey: Key.paired)
        }
        publishPhase("接続しています")
        startPeer()
    }

    func rejectPairing() {
        link.apply(.reject)
        publishPhase(closedReason)
        closeTransport()
    }

    func disconnect() {
        guard phase != .idle else { return }
        if case .closed = phase { return }
        releaseKeys()
        link.apply(.userClosed)
        publishPhase(closedReason)
        closeTransport()
    }

    func releaseKeys() {
        injectedShift = false
        let report = keyboard.clear()
        absolute = AbsolutePointer()
        peer?.sendHid(report)
    }

    func togglePointerMode() {
        pointerMode = pointerMode == .absolute ? .relative : .absolute
        defaults.set(pointerMode.rawValue, forKey: Key.pointer)
        absolute = AbsolutePointer()
    }

    func sendMeasureFlash() {
        hardwareKey(HidUsage.keyboardF12, character: nil, down: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            self.hardwareKey(HidUsage.keyboardF12, character: nil, down: false)
        }
    }

    func hardwareKey(_ usage: UInt8?, character: Character?, down: Bool) {
        let resolved = resolve(usage: usage, character: character)
        guard let resolved else { return }
        if down {
            recentHardwareKeys[resolved] = Date().timeIntervalSinceReferenceDate
            if shouldInjectShift(usage: usage, character: character) {
                _ = keyboard.keyDown(0xE1)
                injectedShift = true
            }
            _ = keyboard.keyDown(resolved)
        } else {
            _ = keyboard.keyUp(resolved)
            if injectedShift {
                _ = keyboard.keyUp(0xE1)
                injectedShift = false
            }
        }
        peer?.sendHid(keyboard.report())
    }

    func gameControllerKey(_ usage: UInt8, down: Bool) {
        if let seen = recentHardwareKeys[usage], Date().timeIntervalSinceReferenceDate - seen < 0.05 {
            return
        }
        hardwareKey(usage, character: nil, down: down)
    }

    func pointer(xUnit: Double, yUnit: Double, buttons: UInt8) {
        switch pointerMode {
        case .absolute:
            peer?.sendHid(absolute.event(xUnit: xUnit, yUnit: yUnit, buttons: buttons))
        case .relative:
            break
        }
    }

    func pointerRelative(dx: Int, dy: Int, buttons: UInt8) {
        guard pointerMode == .relative else { return }
        for report in RelativePointer.reports(dx: dx, dy: dy, buttons: buttons) {
            peer?.sendHid(report)
        }
    }

    func scroll(dx: Double, dy: Double) {
        guard let wheel = Wheel.hid(userDeltaX: dx, userDeltaY: dy) else { return }
        rpcID += 1
        peer?.sendRpc(Wheel.jsonRpc(id: rpcID, wheelX: wheel.wheelX, wheelY: wheel.wheelY))
    }

    private func resolve(usage: UInt8?, character: Character?) -> UInt8? {
        if let usage, usage != 0 {
            return KeyboardLayout.remap(usage: usage, keyboard: keyboardSide, host: hostLayout)
        }
        guard let character, let stroke = KeyboardLayout.stroke(for: character, host: hostLayout) else {
            return nil
        }
        return stroke.usage
    }

    private func shouldInjectShift(usage: UInt8?, character: Character?) -> Bool {
        if let usage, usage != 0 { return false }
        guard let character, let stroke = KeyboardLayout.stroke(for: character, host: hostLayout) else {
            return false
        }
        return stroke.modifier != 0
    }

    private func authenticate(_ endpoint: JetKVMEndpoint) async {
        let deviceStatus = await statusCode(for: endpoint.device, method: "GET", body: nil)
        if deviceStatus == 200 {
            link.apply(.authNotRequired)
            publishPhase("シグナリングを開いています")
            openSocket()
            return
        }
        guard deviceStatus == 401 else {
            fail("機器に到達できません (\(deviceStatus.map(String.init) ?? "タイムアウト"))")
            return
        }
        if password.isEmpty {
            fail("ローカルパスワードが必要です")
            return
        }
        let login = await statusCode(
            for: endpoint.login,
            method: "POST",
            body: try? JSONSerialization.data(withJSONObject: ["password": password])
        )
        password = ""
        guard login == 200 else {
            fail(login == 429 ? "パスワード試行が多すぎます" : "パスワードが違います")
            return
        }
        link.apply(.authOk)
        publishPhase("シグナリングを開いています")
        openSocket()
    }

    private func statusCode(for url: URL, method: String, body: Data?) async -> Int? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode
        } catch {
            return nil
        }
    }

    private func openSocket() {
        guard let endpoint else { return }
        var request = URLRequest(url: endpoint.signaling)
        request.timeoutInterval = 12
        let task = session.webSocketTask(with: request)
        socket = task
        receiving = true
        task.resume()
        receiveNext()
    }

    private func receiveNext() {
        socket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.receiving else { return }
                switch result {
                case .success(.string(let text)):
                    self.handleSignaling(text)
                    self.receiveNext()
                case .success(.data):
                    self.receiveNext()
                case .failure(let error):
                    if self.receiving {
                        self.fail("シグナリングが切れました: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func handleSignaling(_ text: String) {
        switch SignalingCodec.parse(text) {
        case .ping:
            socket?.send(.string(SignalingCodec.pong)) { _ in }
        case .deviceMetadata(let version):
            link.apply(.metadata(version))
            publishPhase(link.phase == .negotiating ? "映像を交渉しています" : "機器を確認してください")
            if link.phase == .negotiating {
                startPeer()
            }
        case .answer(let type, let sdp):
            peer?.acceptAnswer(type: type, sdp: sdp)
        case .iceCandidate(let candidate):
            peer?.addRemote(candidate)
        case .otherSession:
            fail("別のセッションがこの JetKVM を使っています")
        case .serverError(let message):
            fail(message)
        case .ignored:
            break
        }
    }

    private func startPeer() {
        let linkPeer = PeerLink()
        linkPeer.sendSignaling = { [weak self] text in
            Task { @MainActor in
                self?.socket?.send(.string(text)) { _ in }
            }
        }
        linkPeer.onVideo = { [weak self] data, width, height in
            self?.renderer.render(data, width: width, height: height)
            let shot = self?.renderer.snapshot()
            Task { @MainActor in
                guard let self, let shot else { return }
                self.videoSize = shot.videoSize
                self.overlay.fps = shot.framesPerSecond
                self.overlay.kbps = shot.bitsPerSecond / 1000
                self.overlay.dropped = shot.dropped
                self.overlay.enqueueMs = shot.lastEnqueueMs
            }
        }
        linkPeer.onIceConnected = { [weak self] in
            Task { @MainActor in
                self?.link.apply(.iceConnected)
                self?.publishPhase("表示中")
                self?.peer?.sendHid(self?.keyboard.report() ?? KeyboardModel().report())
                UIApplication.shared.isIdleTimerDisabled = true
            }
        }
        linkPeer.onFailed = { [weak self] message in
            Task { @MainActor in
                self?.fail(message)
            }
        }
        linkPeer.onHidMessage = { [weak self] data in
            Task { @MainActor in
                guard let inbound = InboundHid.parse(data) else { return }
                self?.capsLock = inbound.capsLock
                if case .handshake = inbound {
                    self?.peer?.sendHid(self?.keyboard.report() ?? KeyboardModel().clear())
                }
            }
        }
        linkPeer.onRoundTripSeconds = { [weak self] seconds in
            Task { @MainActor in
                self?.overlay.rttMs = seconds.map { $0 * 1000 }
            }
        }
        linkPeer.onPath = { [weak self] path in
            Task { @MainActor in
                self?.overlay.path = path
            }
        }
        peer = linkPeer
        linkPeer.start()
    }

    private func closeTransport() {
        receiving = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        peer?.stop()
        peer = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func fail(_ message: String) {
        link.apply(.failed(message))
        publishPhase(message)
        closeTransport()
    }

    private func publishPhase(_ status: String) {
        phase = link.phase
        statusLine = status
    }

    private var closedReason: String {
        if case .closed(let reason) = link.phase { return reason }
        return "切断しました"
    }

    private func refreshClock() {
        overlay.clockMs = Int(Date().timeIntervalSince1970 * 1000) % 1_000_000
        let shot = renderer.snapshot()
        overlay.fps = shot.framesPerSecond
        overlay.kbps = shot.bitsPerSecond / 1000
        overlay.dropped = shot.dropped
        overlay.enqueueMs = shot.lastEnqueueMs
        if videoSize != shot.videoSize {
            videoSize = shot.videoSize
        }
    }

    private func warning(for kind: LiteralAddressKind) -> String? {
        switch kind {
        case .tailnet:
            return nil
        case .hostname:
            return "ホスト名です。Tailscale の MagicDNS 名を想定しています。"
        case .otherIP:
            return "この IP は Tailscale の範囲ではありません。LAN の host 候補にフォールバックします。"
        }
    }

    private enum Key {
        static let host = "multikvm.host"
        static let paired = "multikvm.pairedHost"
        static let keyboard = "multikvm.keyboard"
        static let hostLayout = "multikvm.hostLayout"
        static let pointer = "multikvm.pointer"
    }
}
