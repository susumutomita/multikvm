import Foundation
import MultiKVMCore

extension LocalConnectionError {
    var displayMessage: String {
        switch self {
        case .passwordRequired: return "ローカルパスワードが必要です"
        case .authenticationRejected: return "パスワードが違います"
        case .rateLimited: return "パスワード試行が多すぎます"
        case .httpStatus(let status): return "機器がエラーを返しました (HTTP \(status))"
        case .nonHTTPResponse: return "機器の HTTP 応答を確認できません"
        case .network(.timedOut): return "機器への接続がタイムアウトしました"
        case .network(let code): return "機器への通信に失敗しました (\(code.rawValue))"
        case .unexpected(let detail): return "接続処理に失敗しました: \(detail)"
        case .signaling(let detail): return "シグナリングに失敗しました: \(detail)"
        }
    }
}

extension SignalingParseError {
    var displayMessage: String {
        switch self {
        case .invalidJSON: return "シグナリングの JSON を読めません"
        case .missingType: return "シグナリングの message type がありません"
        case .invalidAnswer: return "answer を読めません"
        case .invalidCandidate: return "ICE candidate を読めません"
        }
    }
}
