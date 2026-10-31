import MultiKVMCore
import XCTest

@testable import MultiKVM

@MainActor
private final class TestConnection: LocalConnecting {
    var onMessage: (@MainActor (SignalingMessage) -> Void)?
    var onFailure: (@MainActor (LocalConnectionError) -> Void)?
    var authenticationError: Error?
    var holdAuthentication = false
    var pending: CheckedContinuation<Void, Error>?
    var opened = false
    var closed = false
    var sent: [String] = []
    func authenticate(at endpoint: JetKVMEndpoint, password: String) async throws {
        if holdAuthentication { try await withCheckedThrowingContinuation { pending = $0 } }
        if let authenticationError { throw authenticationError }
    }
    func completeAuthentication() {
        pending?.resume()
        pending = nil
    }
    func openSignaling(at endpoint: JetKVMEndpoint) { opened = true }
    func send(_ text: String) { sent.append(text) }
    func close() {
        closed = true
        onMessage = nil
        onFailure = nil
    }
}

@MainActor
private final class TestPeer: PeerSession {
    var onEvent: (@MainActor (PeerEvent) -> Void)?
    var started = false
    var stopped = false
    var acceptsHid = true
    var reports: [OutgoingHid] = []
    var rpc: [String] = []
    func start() { started = true }
    func stop() {
        stopped = true
        onEvent = nil
    }
    func requestKeyframe() {}
    func acceptAnswer(type: String, sdp: String) {}
    func addRemote(_ candidate: IceCandidate) {}
    func sendHid(_ message: OutgoingHid) -> Bool {
        guard acceptsHid else { return false }
        reports.append(message)
        return true
    }
    func sendRpc(_ text: String) { rpc.append(text) }
}

private final class SessionReference {
    weak var value: SessionController?
    init(_ value: SessionController?) { self.value = value }
}

final class SessionControllerTests: XCTestCase {
    @MainActor
    private func controller(_ connections: [TestConnection], _ peers: [TestPeer]) -> SessionController {
        let defaults = UserDefaults(suiteName: "multikvm-tests-\(UUID())")!
        var connections = connections
        var peers = peers
        return SessionController(
            defaults: defaults,
            makeConnection: { connections.removeFirst() }, makePeer: { peers.removeFirst() })
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("connection did not settle")
    }

    @MainActor
    private func establish(_ session: SessionController, _ connection: TestConnection, _ peer: TestPeer) async throws {
        session.connect()
        try await waitUntil { connection.opened }
        connection.onMessage?(.deviceMetadata(version: "test-version"))
        if case .confirmingDevice = session.phase { session.confirmPairing() }
        XCTAssertEqual(session.phase, .negotiating)
        XCTAssertTrue(peer.started)
        peer.onEvent?(.connected)
        XCTAssertEqual(session.phase, .streaming)
    }

    @MainActor
    func testInvalidAddressCanBeCorrectedAndRetried() async throws {
        let connection = TestConnection()
        let peer = TestPeer()
        let session = controller([connection], [peer])
        session.hostText = "ftp://invalid"
        session.connect()
        XCTAssertEqual(session.phase, .closed(reason: "アドレスを読めません"))
        session.hostText = "jetkvm.example.ts.net"
        try await establish(session, connection, peer)
        session.disconnect()
        XCTAssertTrue(connection.closed)
        XCTAssertTrue(peer.stopped)
        XCTAssertEqual(session.phase, .closed(reason: "切断しました"))
    }

    @MainActor
    func testCanceledAuthenticationCannotOverwriteReconnect() async throws {
        let old = TestConnection()
        let next = TestConnection()
        old.holdAuthentication = true
        let session = controller([old, next], [TestPeer()])
        session.hostText = "first.example.ts.net"
        session.connect()
        try await waitUntil { old.pending != nil }
        let staleFailure = old.onFailure
        session.disconnect()
        session.hostText = "second.example.ts.net"
        session.connect()
        try await waitUntil { next.opened }
        next.onMessage?(.deviceMetadata(version: "second"))
        old.completeAuthentication()
        staleFailure?(.network(.timedOut))
        await Task.yield()
        XCTAssertFalse(old.opened)
        XCTAssertEqual(session.phase, .confirmingDevice(version: "second"))
        session.disconnect()
    }

    @MainActor
    func testOldPeerEventsCannotAlterTheNextAttempt() async throws {
        let c1 = TestConnection()
        let c2 = TestConnection()
        let p1 = TestPeer()
        let p2 = TestPeer()
        let session = controller([c1, c2], [p1, p2])
        session.hostText = "jetkvm.example.ts.net"
        try await establish(session, c1, p1)
        let stale = p1.onEvent
        session.disconnect()
        session.connect()
        try await waitUntil { c2.opened }
        c2.onMessage?(.deviceMetadata(version: "second"))
        XCTAssertEqual(session.phase, .negotiating)  // Saved pairing skips confirmation.
        stale?(.connected)
        stale?(.failed("old failure"))
        stale?(.path("old path"))
        stale?(.signaling("old offer"))
        stale?(.video(Data([0]), width: 1, height: 1))
        XCTAssertEqual(session.phase, .negotiating)
        XCTAssertTrue(c2.sent.isEmpty)
        XCTAssertEqual(session.overlay.path, "未確定")
        p2.onEvent?(.connected)
        XCTAssertEqual(session.phase, .streaming)
        session.disconnect()
    }

    @MainActor
    func testAuthenticationErrorsKeepTheirMeaningAndClearPassword() async throws {
        for error in [LocalConnectionError.authenticationRejected, .rateLimited, .httpStatus(503), .network(.timedOut)]
        {
            let connection = TestConnection()
            connection.authenticationError = error
            let session = controller([connection], [])
            session.hostText = "jetkvm.example.ts.net"
            session.password = "test-only-password"
            session.connect()
            try await waitUntil { !session.isBusy }
            XCTAssertEqual(session.phase, .closed(reason: error.displayMessage))
            XCTAssertEqual(session.password, "")
            XCTAssertTrue(connection.closed)
        }
    }

    @MainActor
    func testTransportFailureReleasesInputsAndAllowsRetry() async throws {
        let c1 = TestConnection()
        let c2 = TestConnection()
        let p1 = TestPeer()
        let p2 = TestPeer()
        let session = controller([c1, c2], [p1, p2])
        session.hostText = "jetkvm.example.ts.net"
        try await establish(session, c1, p1)
        session.hardwareKey(HidUsage.keyboardA, character: nil, down: true)
        c1.onFailure?(.network(.networkConnectionLost))
        XCTAssertTrue(p1.stopped)
        XCTAssertTrue(p1.reports.suffix(2).contains { $0.bytes == KeyboardModel().report().bytes })
        try await establish(session, c2, p2)
        session.disconnect()
    }

    @MainActor
    func testMeasurementRequiresHidAcceptanceAndReleasesItsKey() async throws {
        let c = TestConnection()
        let p = TestPeer()
        let session = controller([c], [p])
        session.hostText = "jetkvm.example.ts.net"
        try await establish(session, c, p)
        p.acceptsHid = false
        session.sendMeasureFlash()
        XCTAssertFalse(session.measurementFlash)
        p.acceptsHid = true
        session.sendMeasureFlash()
        XCTAssertTrue(session.measurementFlash)
        XCTAssertTrue(p.reports.last!.bytes.contains(HidUsage.keyboardF12))
        try await waitUntil { !session.measurementFlash }
        XCTAssertFalse(p.reports.last!.bytes.contains(HidUsage.keyboardF12))
        session.disconnect()
    }
    @MainActor
    func testOutOfOrderMetadataClosesTheAttemptAndDoesNotLeaveTransportRunning() async throws {
        let c = TestConnection()
        let p = TestPeer()
        let session = controller([c], [p])
        session.hostText = "jetkvm.example.ts.net"
        try await establish(session, c, p)
        c.onMessage?(.deviceMetadata(version: "duplicate"))
        guard case .closed = session.phase else { return XCTFail("protocol violation was accepted") }
        XCTAssertTrue(c.closed)
        XCTAssertTrue(p.stopped)
    }

    @MainActor
    func testRendererReportsMalformedFormatSeparatelyFromIntentionalDrops() {
        let renderer = VideoRenderer()
        renderer.render(Data([0, 0, 0, 1, 0x67, 0, 0, 0, 1, 0x68, 0, 0, 0, 1, 0x65]), width: 2, height: 2)
        XCTAssertGreaterThan(renderer.snapshot().processingFailures, 0)
        XCTAssertEqual(renderer.snapshot().lastFailure?.operation, .format)
        renderer.reset()
        XCTAssertNil(renderer.snapshot().lastFailure)
        XCTAssertEqual(renderer.snapshot().processingFailures, 0)
    }

    @MainActor
    func testPairingShowsTheDialedHostEvenWhenTheNextInputIsEdited() async throws {
        let c = TestConnection()
        c.holdAuthentication = true
        let session = controller([c], [])
        session.hostText = "first.example.ts.net"
        session.connect()
        try await waitUntil { c.pending != nil }
        session.hostText = "next.example.ts.net"
        c.completeAuthentication()
        try await waitUntil { c.opened }
        c.onMessage?(.deviceMetadata(version: "first"))
        XCTAssertEqual(session.connectionHost, "http://first.example.ts.net")
        XCTAssertEqual(session.hostText, "next.example.ts.net")
        session.rejectPairing()
    }

    @MainActor
    func testReleasingControllerClosesItsActiveAttempt() async throws {
        let c = TestConnection()
        let p = TestPeer()
        var session: SessionController? = controller([c], [p])
        session!.hostText = "jetkvm.example.ts.net"
        try await establish(session!, c, p)
        let released = SessionReference(session)
        session = nil
        XCTAssertNil(released.value)
        try await waitUntil { c.closed && p.stopped }
    }

}
