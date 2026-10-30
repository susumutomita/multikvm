import Foundation

public enum EndpointError: Error, Equatable {
    case empty
    case unsupportedScheme
    case userInfo
    case missingHost
}

public enum LiteralAddressKind: Equatable {
    case tailnet
    case otherIP
    case hostname
}

public struct JetKVMEndpoint: Equatable {
    public var origin: URL
    public var signaling: URL
    public var login: URL
    public var device: URL
    public var addressKind: LiteralAddressKind
    /// ペアリングの照合に使う。スキーム、ホスト、ポートだけを小文字で持つ。
    public var pairedIdentity: String

    public static func parse(_ raw: String) throws -> JetKVMEndpoint {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw EndpointError.empty
        }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: withScheme) else {
            throw EndpointError.missingHost
        }
        let scheme = components.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            throw EndpointError.unsupportedScheme
        }
        if components.user != nil || components.password != nil {
            throw EndpointError.userInfo
        }
        guard let host = components.host, !host.isEmpty else {
            throw EndpointError.missingHost
        }
        components.scheme = scheme
        components.host = host.lowercased()
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let origin = components.url else {
            throw EndpointError.missingHost
        }

        var signalingParts = components
        signalingParts.scheme = scheme == "https" ? "wss" : "ws"
        signalingParts.path = "/webrtc/signaling/client"
        var loginParts = components
        loginParts.path = "/auth/login-local"
        var deviceParts = components
        deviceParts.path = "/device"
        guard
            let signaling = signalingParts.url,
            let login = loginParts.url,
            let device = deviceParts.url
        else {
            throw EndpointError.missingHost
        }

        let kind = TailnetAddress.kind(of: host)
        let port = components.port
        let identity: String
        if let port {
            identity = "\(scheme)://\(host.lowercased()):\(port)"
        } else {
            identity = "\(scheme)://\(host.lowercased())"
        }
        return JetKVMEndpoint(
            origin: origin,
            signaling: signaling,
            login: login,
            device: device,
            addressKind: kind,
            pairedIdentity: identity
        )
    }
}

public enum TailnetAddress {
    /// Tailscale の IPv4 CGNAT (100.64.0.0/10) か、IPv6 ULA (fd7a:115c:a1e0::/48)。
    public static func isTailnet(_ host: String) -> Bool {
        kind(of: host) == .tailnet
    }

    public static func kind(of host: String) -> LiteralAddressKind {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if isTailnetIPv4(bare) || isTailnetIPv6(bare) {
            return .tailnet
        }
        if isIPv4(bare) || bare.contains(":") {
            return .otherIP
        }
        return .hostname
    }

    public static func isTailnetIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else {
            return false
        }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (64 ... 127).contains(octets[1])
    }

    public static func isTailnetIPv6(_ host: String) -> Bool {
        host.lowercased().hasPrefix("fd7a:115c:a1e0:")
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}
