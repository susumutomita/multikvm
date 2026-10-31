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

@MainActor
final class SessionController: ObservableObject {
    @Published var hostText: String
    @Published var password = ""
    @Published var keyboardSide: KeyboardSide
    @Published var hostLayout: KeyboardSide
    @Published private(set) var pointerMode: PointerMode
    @Published private(set) var overlay = OverlayModel()
    @Published private(set) var capsLock = false
    @Published private(set) var measurementFlash = false
    @Published private(set) var addressWarning: String?
    @Published private(set) var videoSize = PlaneSize(width: 0, height: 0)
    @Published private var state: LinkState

    let renderer = VideoRenderer()
    private let defaults: UserDefaults
    private let makeConnection: @MainActor () -> any LocalConnecting
    private let makePeer: @MainActor () -> any PeerSession
    private var attempt: Attempt?
    private var input = RemoteInput()
    private var clockTask: Task<Void, Never>?
    private var measurementTask: Task<Void, Never>?

    private struct Attempt: Sendable {
        let id: UUID
        let endpoint: JetKVMEndpoint
        let connection: any LocalConnecting
        var peer: (any PeerSession)?
        var authentication: Task<Void, Never>?
    }

    var phase: LinkPhase { state.phase }
    var connectionHost: String { state.host }
    var statusLine: String {
        switch phase {
        case .idle: return "未接続"
        case .checkingAuth: return "認証を確認しています"
        case .openingSignaling: return "シグナリングを開いています"
        case .confirmingDevice: return "機器を確認してください"
        case .negotiating: return "映像を交渉しています"
        case .streaming: return "表示中"
        case .closed(let reason): return reason
        }
    }
    var isBusy: Bool {
        switch phase {
        case .checkingAuth, .openingSignaling, .negotiating: return true
        default: return false
        }
    }

    init(
        defaults: UserDefaults = .standard, configuration: URLSessionConfiguration = .ephemeral,
        makeConnection: (@MainActor () -> any LocalConnecting)? = nil,
        makePeer: (@MainActor () -> any PeerSession)? = nil
    ) {
        self.defaults = defaults
        hostText = defaults.string(forKey: Key.host) ?? ""
        keyboardSide = KeyboardSide(rawValue: defaults.string(forKey: Key.keyboard) ?? "") ?? .us
        hostLayout = KeyboardSide(rawValue: defaults.string(forKey: Key.hostLayout) ?? "") ?? .us
        pointerMode = PointerMode(rawValue: defaults.string(forKey: Key.pointer) ?? "") ?? .absolute
        state = LinkState(pairedHost: defaults.string(forKey: Key.paired), host: "")
        if let makeConnection {
            self.makeConnection = makeConnection
        } else {
            let connection = LocalConnection(configuration: configuration)
            self.makeConnection = { connection }
        }
        self.makePeer = makePeer ?? { PeerLink() }
    }

    deinit {
        clockTask?.cancel()
        measurementTask?.cancel()
        let old = attempt
        old?.authentication?.cancel()
        Task { @MainActor in
            old?.connection.close()
            old?.peer?.stop()
            if old?.peer != nil { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    func connect() {
        switch phase {
        case .idle, .closed: break
        default: return
        }
        defaults.set(hostText, forKey: Key.host)
        defaults.set(keyboardSide.rawValue, forKey: Key.keyboard)
        defaults.set(hostLayout.rawValue, forKey: Key.hostLayout)
        let endpoint: JetKVMEndpoint
        do { endpoint = try JetKVMEndpoint.parse(hostText) } catch {
            fail("アドレスを読めません")
            return
        }
        addressWarning = warning(for: endpoint.addressKind)
        state = LinkState(pairedHost: defaults.string(forKey: Key.paired), host: endpoint.pairedIdentity)
        state.apply(.begin)
        let connection = makeConnection()
        let id = UUID()
        attempt = Attempt(id: id, endpoint: endpoint, connection: connection)
        connection.onMessage = { [weak self] message in
            guard let self, self.attempt?.id == id else { return }
            self.handleSignaling(message)
        }
        connection.onFailure = { [weak self] error in
            guard let self, self.attempt?.id == id else { return }
            self.fail(error.displayMessage)
        }
        let submittedPassword = password
        attempt?.authentication = Task { [weak self] in
            do {
                try await connection.authenticate(at: endpoint, password: submittedPassword)
                guard let self, self.attempt?.id == id, !Task.isCancelled else { return }
                self.password = ""
                self.attempt?.authentication = nil
                self.state.apply(.authenticated)
                connection.openSignaling(at: endpoint)
            } catch {
                guard let self, self.attempt?.id == id, !Task.isCancelled else { return }
                self.fail(
                    (error as? LocalConnectionError)?.displayMessage
                        ?? (error is CancellationError ? "接続を中止しました" : "接続処理に失敗しました: \(error.localizedDescription)"))
            }
        }
    }

    func confirmPairing() {
        guard case .confirmingDevice = phase else { return }
        state.apply(.confirm)
        if let host = state.pairedHost { defaults.set(host, forKey: Key.paired) }
        startPeer()
    }

    func rejectPairing() {
        guard case .confirmingDevice = phase else { return }
        state.apply(.reject)
        closeAttempt()
    }

    func disconnect() {
        switch phase {
        case .idle, .closed: return
        default: break
        }
        releaseKeys()
        state.apply(.userClosed)
        closeAttempt()
    }

    func releaseKeys() {
        measurementTask?.cancel()
        measurementTask = nil
        measurementFlash = false
        for report in input.release(mode: pointerMode) { attempt?.peer?.sendHid(report) }
    }

    func togglePointerMode() {
        releaseKeys()
        pointerMode = pointerMode == .absolute ? .relative : .absolute
        defaults.set(pointerMode.rawValue, forKey: Key.pointer)
    }

    func sendMeasureFlash() {
        guard phase == .streaming, !measurementFlash,
            let report = input.measurement(down: true)
        else { return }
        guard attempt?.peer?.sendHid(report) == true else {
            _ = input.measurement(down: false)
            return
        }
        measurementFlash = true
        let id = attempt?.id
        measurementTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 80_000_000) } catch { return }
            guard let self, self.attempt?.id == id else { return }
            if let release = self.input.measurement(down: false) { self.attempt?.peer?.sendHid(release) }
            self.measurementFlash = false
        }
    }

    func hardwareKey(
        _ usage: UInt8?, character: Character?, down: Bool,
        source: KeyboardEventFilter.Source = .uiKit
    ) {
        guard phase == .streaming else { return }
        if let report = input.key(
            usage: usage, character: character, down: down,
            source: source, at: ProcessInfo.processInfo.systemUptime, keyboardSide: keyboardSide, hostLayout: hostLayout
        ) {
            attempt?.peer?.sendHid(report)
        }
    }

    func gameControllerKey(_ usage: UInt8, down: Bool) {
        hardwareKey(usage, character: nil, down: down, source: .gameController)
    }

    func pointer(xUnit: Double, yUnit: Double, buttons: UInt8) {
        guard pointerMode == .absolute else { return }
        attempt?.peer?.sendHid(input.absolute(x: xUnit, y: yUnit, buttons: buttons))
    }

    func pointerRelative(dx: Int, dy: Int, buttons: UInt8) {
        guard pointerMode == .relative else { return }
        for report in RelativePointer.reports(dx: dx, dy: dy, buttons: buttons) { attempt?.peer?.sendHid(report) }
    }

    func scroll(dx: Double, dy: Double) {
        do { if let report = try input.scroll(dx: dx, dy: dy) { attempt?.peer?.sendRpc(report) } } catch {
            fail("スクロールを送信できません: \(error.localizedDescription)")
        }
    }

    private func handleSignaling(_ message: SignalingMessage) {
        switch message {
        case .deviceMetadata(let version):
            state.apply(.metadata(version))
            if case .closed(let reason) = phase { fail(reason) } else if phase == .negotiating { startPeer() }
        case .answer(let type, let sdp): attempt?.peer?.acceptAnswer(type: type, sdp: sdp)
        case .iceCandidate(let candidate): attempt?.peer?.addRemote(candidate)
        case .otherSession: fail("別のセッションがこの JetKVM を使っています")
        case .serverError(let message): fail(message)
        case .malformed(let error): fail(error.displayMessage)
        case .ping, .ignored: break
        }
    }

    private func startPeer() {
        guard let current = attempt, phase == .negotiating else { return }
        let peer = makePeer()
        attempt?.peer = peer
        renderer.onNeedsKeyframe = { [weak peer] in peer?.requestKeyframe() }
        peer.onEvent = { [weak self] event in
            guard let self, self.attempt?.id == current.id else { return }
            self.handlePeer(event)
        }
        startClock()
        peer.start()
    }

    private func handlePeer(_ event: PeerEvent) {
        switch event {
        case .signaling(let text): attempt?.connection.send(text)
        case .video(let data, let width, let height): renderer.render(data, width: width, height: height)
        case .connected:
            guard phase == .negotiating else { return }
            state.apply(.iceConnected)
            attempt?.peer?.sendHid(input.keyboardReport)
            UIApplication.shared.isIdleTimerDisabled = true
        case .failed(let message): fail(message)
        case .hid(let data):
            guard let inbound = InboundHid.parse(data) else { return }
            capsLock = inbound.capsLock
            if case .handshake = inbound { attempt?.peer?.sendHid(input.keyboardReport) }
        case .roundTrip(let seconds): overlay.rttMs = seconds.map { $0 * 1000 }
        case .path(let path): overlay.path = path
        }
    }

    private func closeAttempt() {
        let old = attempt
        attempt = nil  // Invalidate every callback before closing either transport.
        old?.authentication?.cancel()
        old?.connection.close()
        old?.peer?.stop()
        measurementTask?.cancel()
        measurementTask = nil
        measurementFlash = false
        password = ""
        clockTask?.cancel()
        clockTask = nil
        renderer.reset()
        videoSize = PlaneSize(width: 0, height: 0)
        overlay = OverlayModel()
        capsLock = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func fail(_ message: String) {
        releaseKeys()
        state.apply(.failed(message))
        closeAttempt()
    }

    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 33_333_333) } catch { return }
                self?.refreshOverlay()
            }
        }
    }

    private func refreshOverlay() {
        let shot = renderer.snapshot()
        overlay.clockMs = Int(Date().timeIntervalSince1970 * 1000) % 1_000_000
        overlay.fps = shot.framesPerSecond
        overlay.kbps = shot.bitsPerSecond / 1000
        overlay.dropped = shot.dropped
        overlay.enqueueMs = shot.lastEnqueueMs
        if videoSize != shot.videoSize { videoSize = shot.videoSize }
    }

    private func warning(for kind: LiteralAddressKind) -> String? {
        switch kind {
        case .tailnet: return nil
        case .hostname: return "ホスト名です。Tailscale の MagicDNS 名を想定しています。"
        case .otherIP: return "この IP は Tailscale の範囲ではありません。LAN の host 候補にフォールバックします。"
        }
    }

    private enum Key {
        static let host = "multikvm.host", paired = "multikvm.pairedHost", keyboard = "multikvm.keyboard"
        static let hostLayout = "multikvm.hostLayout", pointer = "multikvm.pointer"
    }
}
