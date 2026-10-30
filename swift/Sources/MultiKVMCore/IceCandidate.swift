import Foundation

public enum IceCandidateKind: Equatable, Sendable {
    case tailnetHost
    case otherHost
    case unwanted
}

public struct IceCandidate: Equatable, Sendable {
    public var sdp: String
    public var sdpMid: String?
    public var lineIndex: Int?
    public var address: String
    public var kind: IceCandidateKind

    public init(sdp: String, sdpMid: String?, lineIndex: Int?) {
        self.sdp = sdp
        self.sdpMid = sdpMid
        self.lineIndex = lineIndex
        let parsed = IceCandidate.classify(sdp)
        self.address = parsed.address
        self.kind = parsed.kind
    }

    public static func classify(_ sdp: String) -> (address: String, kind: IceCandidateKind) {
        let parts = sdp.split(separator: " ").map(String.init)
        guard let typ = parts.firstIndex(of: "typ"), typ >= 2 else {
            return ("", .unwanted)
        }
        let address = parts[typ - 2]
        let type = typ + 1 < parts.count ? parts[typ + 1] : ""
        if type != "host" {
            return (address, .unwanted)
        }
        if TailnetAddress.isTailnet(address) {
            return (address, .tailnetHost)
        }
        return (address, .otherHost)
    }
}

/// host 候補のうち Tailscale アドレスを優先する。relay / srflx は捨てる。
/// Tailscale 候補が一つでもあれば、それ以外の host 候補は出さない。
public struct HostCandidateGate {
    private var buffered: [IceCandidate] = []
    private var emitted: Set<String> = []
    private var sawTailnet = false
    private var fallbackActive = false

    public init() {}

    public mutating func receive(_ candidate: IceCandidate) -> [IceCandidate] {
        switch candidate.kind {
        case .unwanted:
            return []
        case .tailnetHost:
            sawTailnet = true
            buffered.append(candidate)
            return emit(where: { $0.kind == .tailnetHost })
        case .otherHost:
            buffered.append(candidate)
            return fallbackActive && !sawTailnet ? emit(where: { $0.kind == .otherHost }) : []
        }
    }

    /// 候補が出揃ったあとに呼ぶ。Tailscale 候補がなければ、残った host 候補を返す。
    public mutating func flush() -> [IceCandidate] {
        if sawTailnet {
            return emit(where: { $0.kind == .tailnetHost })
        }
        fallbackActive = true
        return emit(where: { $0.kind == .otherHost })
    }

    public var prefersTailnet: Bool { sawTailnet }

    private mutating func emit(where predicate: (IceCandidate) -> Bool) -> [IceCandidate] {
        var ready: [IceCandidate] = []
        for candidate in buffered where predicate(candidate) && !emitted.contains(candidate.sdp) {
            emitted.insert(candidate.sdp)
            ready.append(candidate)
        }
        return ready
    }
}
