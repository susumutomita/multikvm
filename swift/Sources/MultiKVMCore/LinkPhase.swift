public enum LinkPhase: Equatable {
    case idle
    case checkingAuth
    case openingSignaling
    case confirmingDevice(version: String)
    case negotiating
    case streaming
    case closed(reason: String)
}

public enum LinkEvent: Equatable {
    case begin
    case authenticated
    case metadata(String)
    case confirm
    case reject
    case iceConnected
    case failed(String)
    case userClosed
}

public struct LinkState: Equatable {
    public private(set) var phase: LinkPhase
    public private(set) var pairedHost: String?
    public let host: String

    public init(pairedHost: String?, host: String) {
        self.phase = .idle
        self.pairedHost = pairedHost
        self.host = host
    }

    public mutating func apply(_ event: LinkEvent) {
        switch event {
        case .begin:
            phase = phase == .idle ? .checkingAuth : .closed(reason: "すでに開始しています")
        case .authenticated:
            phase = phase == .checkingAuth ? .openingSignaling : .closed(reason: "認証の順序が崩れました")
        case .metadata(let version):
            guard phase == .openingSignaling else {
                phase = .closed(reason: "デバイス情報の順序が崩れました")
                return
            }
            if pairedHost == host {
                phase = .negotiating
            } else {
                phase = .confirmingDevice(version: version)
            }
        case .confirm:
            guard case .confirmingDevice = phase else {
                phase = .closed(reason: "ペアリングの順序が崩れました")
                return
            }
            pairedHost = host
            phase = .negotiating
        case .reject:
            phase = .closed(reason: "ペアリングを取り消しました")
        case .iceConnected:
            if phase == .negotiating {
                phase = .streaming
            }
        case .failed(let reason):
            phase = .closed(reason: reason)
        case .userClosed:
            phase = .closed(reason: "切断しました")
        }
    }
}
