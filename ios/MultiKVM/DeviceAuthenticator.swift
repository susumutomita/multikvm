import Foundation
import MultiKVMCore

enum LocalConnectionError: Error, Equatable {
    case passwordRequired
    case authenticationRejected
    case rateLimited
    case httpStatus(Int)
    case nonHTTPResponse
    case network(URLError.Code)
    case unexpected(String)
    case signaling(String)

    static func transport(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? CancellationError() : Self.network(urlError.code)
        }
        return Self.unexpected(error.localizedDescription)
    }
}

struct DeviceAuthenticator {
    let session: URLSession

    func authenticate(at endpoint: JetKVMEndpoint, password: String) async throws {
        switch try await status(for: URLRequest(url: endpoint.device)) {
        case 200: return
        case 401: break
        case 429: throw LocalConnectionError.rateLimited
        case let status: throw LocalConnectionError.httpStatus(status)
        }
        guard !password.isEmpty else { throw LocalConnectionError.passwordRequired }
        var request = URLRequest(url: endpoint.login)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Login(password: password))
        switch try await status(for: request) {
        case 200: return
        case 401, 403: throw LocalConnectionError.authenticationRejected
        case 429: throw LocalConnectionError.rateLimited
        case let status: throw LocalConnectionError.httpStatus(status)
        }
    }

    private func status(for request: URLRequest) async throws -> Int {
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw LocalConnectionError.transport(error)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw LocalConnectionError.nonHTTPResponse }
        return http.statusCode
    }

    private struct Login: Encodable { let password: String }
}
