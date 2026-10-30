import Foundation
import MultiKVMCore
import XCTest

@testable import MultiKVMTransport

private final class HTTPStub: URLProtocol {
    private static let lock = NSLock()
    private static var handlers: [String: (HTTPStub) -> Void] = [:]
    static func register(_ host: String, handler: @escaping (HTTPStub) -> Void) {
        lock.withLock { handlers[host] = handler }
    }
    static func remove(_ host: String) { _ = lock.withLock { handlers.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool {
        lock.withLock { handlers[request.url?.host ?? ""] != nil }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.lock.withLock { Self.handlers[request.url?.host ?? ""] }
        handler?(self)
    }
    override func stopLoading() {}
    func respond(status: Int) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    func fail(_ code: URLError.Code) { client?.urlProtocol(self, didFailWithError: URLError(code)) }
    func nonHTTP() {
        client?.urlProtocol(
            self,
            didReceive: URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil),
            cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private struct AuthFixture {
    let host = "auth-\(UUID().uuidString.lowercased()).invalid"
    let session: URLSession
    init(handler: @escaping (HTTPStub) -> Void) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStub.self]
        session = URLSession(configuration: config)
        HTTPStub.register(host, handler: handler)
    }
    var endpoint: JetKVMEndpoint { get throws { try JetKVMEndpoint.parse(host) } }
    func authenticate(password: String = "test-only-password") async throws {
        try await DeviceAuthenticator(session: session).authenticate(at: endpoint, password: password)
    }
    func close() {
        session.invalidateAndCancel()
        HTTPStub.remove(host)
    }
}

final class AuthenticatorTests: XCTestCase {
    func testDeviceWithoutPasswordNeverPostsLogin() async throws {
        let f = AuthFixture { stub in
            XCTAssertEqual(stub.request.url?.path, "/device")
            stub.respond(status: 200)
        }
        defer { f.close() }
        try await f.authenticate(password: "")
    }

    func testRequiredPasswordDoesNotSendEmptyLogin() async throws {
        let f = AuthFixture { stub in
            XCTAssertEqual(stub.request.url?.path, "/device")
            stub.respond(status: 401)
        }
        defer { f.close() }
        do {
            try await f.authenticate(password: "")
            XCTFail("empty password accepted")
        } catch { XCTAssertEqual(error as? LocalConnectionError, .passwordRequired) }
    }

    func testSuccessfulLocalLoginUsesPostToLoginEndpoint() async throws {
        let f = AuthFixture { stub in
            if stub.request.url?.path == "/device" {
                stub.respond(status: 401)
            } else {
                XCTAssertEqual(stub.request.url?.path, "/auth/login-local")
                XCTAssertEqual(stub.request.httpMethod, "POST")
                XCTAssertEqual(stub.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                stub.respond(status: 200)
            }
        }
        defer { f.close() }
        try await f.authenticate()
    }

    func testLoginRejectionsAreDistinctFromServerErrors() async throws {
        for (status, expected) in [
            (401, LocalConnectionError.authenticationRejected), (403, .authenticationRejected), (429, .rateLimited),
            (503, .httpStatus(503)),
        ] {
            let f = AuthFixture { stub in stub.respond(status: stub.request.url?.path == "/device" ? 401 : status) }
            defer { f.close() }
            do {
                try await f.authenticate()
                XCTFail("HTTP \(status) accepted")
            } catch { XCTAssertEqual(error as? LocalConnectionError, expected) }
        }
    }

    func testDeviceServerFailureAndRateLimitArePreserved() async throws {
        for (status, expected) in [(429, LocalConnectionError.rateLimited), (502, .httpStatus(502))] {
            let f = AuthFixture { $0.respond(status: status) }
            defer { f.close() }
            do {
                try await f.authenticate()
                XCTFail("HTTP \(status) accepted")
            } catch { XCTAssertEqual(error as? LocalConnectionError, expected) }
        }
    }

    func testNetworkFailuresDuringEitherRequestKeepTheirCode() async throws {
        for code in [URLError.Code.timedOut, .notConnectedToInternet, .serverCertificateUntrusted] {
            for duringLogin in [false, true] {
                let f = AuthFixture { stub in
                    if duringLogin && stub.request.url?.path == "/device" {
                        stub.respond(status: 401)
                    } else {
                        stub.fail(code)
                    }
                }
                defer { f.close() }
                do {
                    try await f.authenticate()
                    XCTFail("network failure accepted")
                } catch { XCTAssertEqual(error as? LocalConnectionError, .network(code)) }
            }
        }
    }

    func testCancellationIsNotReportedAsBadPassword() async throws {
        let f = AuthFixture { $0.fail(.cancelled) }
        defer { f.close() }
        do {
            try await f.authenticate()
            XCTFail("cancellation accepted")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testNonHttpResponseIsDiagnosable() async throws {
        let f = AuthFixture { $0.nonHTTP() }
        defer { f.close() }
        do {
            try await f.authenticate()
            XCTFail("non HTTP response accepted")
        } catch { XCTAssertEqual(error as? LocalConnectionError, .nonHTTPResponse) }
    }

    @MainActor
    func testStoppedPeerCannotStartAnotherAttempt() {
        let peer = PeerLink()
        peer.stop()
        var failure: String?
        peer.onEvent = { if case .failed(let message) = $0 { failure = message } }
        peer.start()
        XCTAssertNotNil(failure)
    }
}
