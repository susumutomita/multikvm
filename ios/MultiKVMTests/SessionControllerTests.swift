import MultiKVMCore
import XCTest

@testable import MultiKVM

final class DeviceProtocol: URLProtocol {
    static var onRequest: ((DeviceProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var responseWork: DispatchWorkItem?
    override func startLoading() { Self.onRequest?(self) }
    override func stopLoading() { responseWork?.cancel() }

    func respondAfterDelay(_ status: Int) {
        let work = DispatchWorkItem { [weak self] in self?.respond(status) }
        responseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    func respond(_ status: Int) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class SessionControllerTests: XCTestCase {
    @MainActor
    private func controller() -> SessionController {
        let defaults = UserDefaults(suiteName: "multikvm-tests-\(UUID())")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeviceProtocol.self]
        return SessionController(defaults: defaults, configuration: configuration)
    }

    @MainActor
    private func waitUntilSettled(_ session: SessionController) async throws {
        for _ in 0..<200 {
            if !session.isBusy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("connection did not settle")
    }

    override func tearDown() {
        DeviceProtocol.onRequest = nil
        super.tearDown()
    }

    @MainActor
    func testInvalidAddressCanBeCorrectedAndRetried() async throws {
        let session = controller()
        session.hostText = "ftp://invalid"
        session.connect()
        guard case .closed = session.phase else { return XCTFail("invalid address was accepted") }
        let requested = expectation(description: "retry requested device")
        DeviceProtocol.onRequest = { request in
            XCTAssertEqual(request.request.url?.path, "/device")
            request.respond(401)
            requested.fulfill()
        }
        session.hostText = "http://jetkvm.example.ts.net"
        session.connect()
        await fulfillment(of: [requested], timeout: 2)
        try await waitUntilSettled(session)
        XCTAssertEqual(session.phase, .closed(reason: "ローカルパスワードが必要です"))
        session.disconnect()
    }

    @MainActor
    func testDisconnectDuringDeviceRequestCannotReopenTransport() async throws {
        let session = controller()
        let requested = expectation(description: "device requested")
        DeviceProtocol.onRequest = { request in
            request.respondAfterDelay(200)
            requested.fulfill()
        }
        session.hostText = "jetkvm.example.ts.net"
        session.connect()
        await fulfillment(of: [requested], timeout: 2)
        session.disconnect()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(session.phase, .closed(reason: "切断しました"))
        XCTAssertFalse(session.isBusy)
    }

    @MainActor
    func testLoginFailureClearsPasswordAndAllowsRetry() async throws {
        let session = controller()
        let login = expectation(description: "login rejected")
        DeviceProtocol.onRequest = { request in
            if request.request.url?.path == "/device" {
                request.respond(401)
            } else {
                XCTAssertEqual(request.request.url?.path, "/auth/login-local")
                XCTAssertEqual(request.request.httpMethod, "POST")
                request.respond(429)
                login.fulfill()
            }
        }
        session.hostText = "jetkvm.example.ts.net"
        session.password = "test-only-password"
        session.connect()
        await fulfillment(of: [login], timeout: 2)
        try await waitUntilSettled(session)
        XCTAssertEqual(session.password, "")
        XCTAssertEqual(session.phase, .closed(reason: "パスワード試行が多すぎます"))
    }

    @MainActor
    func testMeasurementDoesNotFlashWithoutAnOpenHidChannel() {
        let session = controller()
        session.phase = .streaming
        session.sendMeasureFlash()
        XCTAssertFalse(session.measurementFlash)
        session.releaseKeys()
        XCTAssertFalse(session.measurementFlash)
    }
}
