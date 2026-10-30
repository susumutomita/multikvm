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

// A redirect must never move local authentication to a different host.
private final class LocalSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
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
    @Published var measurementFlash = false
    @Published var addressWarning: String?
    @Published var videoSize = PlaneSize(width: 0, height: 0)

    let renderer = VideoRenderer()
    private let defaults: UserDefaults
    private let session: URLSession
    private var link: LinkState
    private var endpoint: JetKVMEndpoint?
    private var socket: URLSessionWebSocketTask?
    private var peer: PeerLink?
    private var keyboard = KeyboardModel()
    private var absolute = AbsolutePointer()
    private var wheel = WheelAccumulator()
    private var lastAbsolutePoint = (x: 0.0, y: 0.0)
    private var rpcID = 0
    private var receiving = false
    private var clockTimer: Timer?
    private var keyboardEvents = KeyboardEventFilter()
    private var authenticationTask: Task<Void, Never>?
    private var measurementTask: Task<Void, Never>?
    private var connectionID = UUID()
    private var injectedShift = false

    var isBusy: Bool {
        switch phase {
        case .checkingAuth, .openingSignaling, .negotiating:
            return true
        case .idle, .confirmingDevice, .streaming, .closed:
            return false
        }
    }

    init(defaults: UserDefaults = .standard, configuration: URLSessionConfiguration = .ephemeral) {
        self.defaults = defaults
        let storedHost = defaults.string(forKey: Key.host) ?? ""
        hostText = storedHost
        keyboardSide = KeyboardSide(rawValue: defaults.string(forKey: Key.keyboard) ?? "") ?? .us
        hostLayout = KeyboardSide(rawValue: defaults.string(forKey: Key.hostLayout) ?? "") ?? .us
        pointerMode = PointerMode(rawValue: defaults.string(forKey: Key.pointer) ?? "") ?? .absolute
        link = LinkState(
            pairedHost: defaults.string(forKey: Key.paired),
            host: ""
        )
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 12
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: LocalSessionDelegate(), delegateQueue: nil)
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshClock()
            }
        }
        clockTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit {
        clockTimer?.invalidate()
        session.invalidateAndCancel()
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
        let id = connectionID
        authenticationTask = Task { await authenticate(endpoint, connectionID: id) }
    }

    func confirmPairing() {
        guard case .confirmingDevice = phase else { return }
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
        measurementTask?.cancel()
        measurementTask = nil
        measurementFlash = false
        keyboardEvents = KeyboardEventFilter()
        wheel = WheelAccumulator()
        injectedShift = false
        let report = keyboard.clear()
        absolute = AbsolutePointer()
        peer?.sendHid(report)
        if pointerMode == .absolute {
            peer?.sendHid(absolute.event(xUnit: lastAbsolutePoint.x, yUnit: lastAbsolutePoint.y, buttons: 0))
        } else {
            pointerRelative(dx: 0, dy: 0, buttons: 0)
        }
    }

    func togglePointerMode() {
        releaseKeys()
        pointerMode = pointerMode == .absolute ? .relative : .absolute
        defaults.set(pointerMode.rawValue, forKey: Key.pointer)
        absolute = AbsolutePointer()
    }

    func sendMeasureFlash() {
        guard phase == .streaming, !measurementFlash else { return }
        guard !keyboard.report().bytes.dropFirst(2).contains(HidUsage.keyboardF12) else { return }
        guard peer?.sendHid(keyboard.keyDown(HidUsage.keyboardF12)) == true else {
            _ = keyboard.keyUp(HidUsage.keyboardF12)
            return
        }
        measurementFlash = true
        let id = connectionID
        measurementTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 80_000_000) } catch { return }
            guard self.connectionID == id else { return }
            self.peer?.sendHid(self.keyboard.keyUp(HidUsage.keyboardF12))
            self.measurementFlash = false
        }
    }

    func hardwareKey(
        _ usage: UInt8?, character: Character?, down: Bool,
        source: KeyboardEventFilter.Source = .uiKit
    ) {
        guard phase == .streaming else { return }
        if let usage,
            !keyboardEvents.accepts(usage: usage, down: down, source: source, at: ProcessInfo.processInfo.systemUptime)
        {
            return
        }
        let resolved = resolve(usage: usage, character: character)
        guard let resolved else { return }
        if down {
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
        hardwareKey(usage, character: nil, down: down, source: .gameController)
    }

    func pointer(xUnit: Double, yUnit: Double, buttons: UInt8) {
        switch pointerMode {
        case .absolute:
            lastAbsolutePoint = (xUnit, yUnit)
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
        guard let report = wheel.event(dx: dx, dy: dy) else { return }
        rpcID += 1
        peer?.sendRpc(Wheel.jsonRpc(id: rpcID, wheelX: report.wheelX, wheelY: report.wheelY))
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

    private func authenticate(_ endpoint: JetKVMEndpoint, connectionID id: UUID) async {
        let deviceStatus = await statusCode(for: endpoint.device, method: "GET", body: nil)
        guard connectionID == id, !Task.isCancelled else { return }
        if deviceStatus == 200 {
            password = ""
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
        guard connectionID == id, !Task.isCancelled else { return }
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
        receiveNext(task, connectionID: connectionID)
    }

    private func receiveNext(_ task: URLSessionWebSocketTask, connectionID id: UUID) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.receiving, self.connectionID == id, self.socket === task else { return }
                switch result {
                case .success(.string(let text)):
                    self.handleSignaling(text)
                    self.receiveNext(task, connectionID: id)
                case .success(.data):
                    self.receiveNext(task, connectionID: id)
                case .success:
                    self.fail("未対応のシグナリング形式です")
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
        let id = connectionID
        let linkPeer = PeerLink()
        renderer.onNeedsKeyframe = { [weak linkPeer] in linkPeer?.requestKeyframe() }
        linkPeer.sendSignaling = { [weak self] text in
            guard let self, self.connectionID == id else { return }
            self.socket?.send(.string(text)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    guard let self, self.connectionID == id else { return }
                    self.fail("送信できません: \(error.localizedDescription)")
                }
            }
        }
        linkPeer.onVideo = { [weak self] data, width, height in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connectionID == id else { return }
                self.renderer.render(data, width: width, height: height)
                let shot = self.renderer.snapshot()
                self.videoSize = shot.videoSize
                self.overlay.fps = shot.framesPerSecond
                self.overlay.kbps = shot.bitsPerSecond / 1000
                self.overlay.dropped = shot.dropped
                self.overlay.enqueueMs = shot.lastEnqueueMs
            }
        }
        linkPeer.onIceConnected = { [weak self] in
            Task { @MainActor in
                guard let self, self.connectionID == id else { return }
                self.link.apply(.iceConnected)
                self.publishPhase("表示中")
                self.peer?.sendHid(self.keyboard.report())
                UIApplication.shared.isIdleTimerDisabled = true
            }
        }
        linkPeer.onFailed = { [weak self] message in
            Task { @MainActor in
                guard let self, self.connectionID == id else { return }
                self.fail(message)
            }
        }
        linkPeer.onHidMessage = { [weak self] data in
            Task { @MainActor in
                guard let self, self.connectionID == id, let inbound = InboundHid.parse(data) else { return }
                self.capsLock = inbound.capsLock
                if case .handshake = inbound {
                    self.peer?.sendHid(self.keyboard.report())
                }
            }
        }
        linkPeer.onRoundTripSeconds = { [weak self] seconds in
            Task { @MainActor in
                guard let self, self.connectionID == id else { return }
                self.overlay.rttMs = seconds.map { $0 * 1000 }
            }
        }
        linkPeer.onPath = { [weak self] path in
            Task { @MainActor in
                guard let self, self.connectionID == id else { return }
                self.overlay.path = path
            }
        }
        peer = linkPeer
        linkPeer.start()
    }

    private func closeTransport() {
        connectionID = UUID()
        authenticationTask?.cancel()
        authenticationTask = nil
        measurementTask?.cancel()
        measurementTask = nil
        measurementFlash = false
        password = ""
        receiving = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        peer?.stop()
        peer = nil
        renderer.reset()
        videoSize = PlaneSize(width: 0, height: 0)
        overlay = OverlayModel()
        capsLock = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func fail(_ message: String) {
        releaseKeys()
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
