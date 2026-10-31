import Foundation
import MultiKVMCore

@MainActor
protocol LocalConnecting: AnyObject, Sendable {
    var onMessage: (@MainActor (SignalingMessage) -> Void)? { get set }
    var onFailure: (@MainActor (LocalConnectionError) -> Void)? { get set }
    func authenticate(at endpoint: JetKVMEndpoint, password: String) async throws
    func openSignaling(at endpoint: JetKVMEndpoint)
    func send(_ text: String)
    func close()
}

/// HTTP authentication and signaling share one ephemeral cookie store.
@MainActor
final class LocalConnection: LocalConnecting {
    var onMessage: (@MainActor (SignalingMessage) -> Void)?
    var onFailure: (@MainActor (LocalConnectionError) -> Void)?
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 12
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func authenticate(at endpoint: JetKVMEndpoint, password: String) async throws {
        try await DeviceAuthenticator(session: session).authenticate(at: endpoint, password: password)
    }

    func openSignaling(at endpoint: JetKVMEndpoint) {
        socket?.cancel(with: .goingAway, reason: nil)
        var request = URLRequest(url: endpoint.signaling)
        request.timeoutInterval = 12
        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        receive(on: task)
    }

    func send(_ text: String) {
        guard let task = socket else { return }
        task.send(.string(text)) { [weak self, weak task] error in
            guard let error else { return }
            DispatchQueue.main.async {
                guard let self, let task, self.socket === task else { return }
                self.onFailure?(.signaling(error.localizedDescription))
            }
        }
    }

    func close() {
        let old = socket
        socket = nil
        onMessage = nil
        onFailure = nil
        old?.cancel(with: .goingAway, reason: nil)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            DispatchQueue.main.async {
                guard let self, let task, self.socket === task else { return }
                switch result {
                case .success(.string(let text)):
                    let message = SignalingCodec.parse(text)
                    if message == .ping { self.send(SignalingCodec.pong) } else { self.onMessage?(message) }
                    if self.socket === task { self.receive(on: task) }
                case .success(.data):
                    self.receive(on: task)
                case .success:
                    self.onFailure?(.signaling("未対応のシグナリング形式です"))
                case .failure(let error):
                    self.onFailure?(.signaling(error.localizedDescription))
                }
            }
        }
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}
