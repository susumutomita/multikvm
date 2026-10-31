import Foundation

public enum SignalingMessage: Equatable {
    case deviceMetadata(version: String)
    case answer(type: String, sdp: String)
    case iceCandidate(IceCandidate)
    case otherSession
    case ping
    case serverError(String)
    case ignored
    case malformed(SignalingParseError)
}

public enum SignalingParseError: Equatable {
    case invalidJSON, missingType, invalidAnswer, invalidCandidate
}

public enum SignalingCodec {
    public static func parse(_ text: String) -> SignalingMessage {
        if text == "ping" {
            return .ping
        }
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .malformed(.invalidJSON)
        }
        if let error = object["error"] as? String, object["type"] == nil {
            return .serverError(error)
        }
        guard let type = object["type"] as? String else {
            return .malformed(.missingType)
        }
        switch type {
        case "device-metadata":
            let version = (object["data"] as? [String: Any])?["deviceVersion"] as? String ?? ""
            return .deviceMetadata(version: version)
        case "answer":
            guard let encoded = object["data"] as? String,
                let decoded = Data(base64Encoded: encoded),
                let json = String(data: decoded, encoding: .utf8),
                let payload = jsonObject(json),
                let sdp = payload["sdp"] as? String
            else {
                return .malformed(.invalidAnswer)
            }
            let sdpType = payload["type"] as? String ?? "answer"
            return .answer(type: sdpType, sdp: sdp)
        case "new-ice-candidate":
            guard let data = object["data"] as? [String: Any],
                let candidate = data["candidate"] as? String
            else {
                return .malformed(.invalidCandidate)
            }
            if candidate.isEmpty { return .ignored }  // End of candidates.
            let mid = data["sdpMid"] as? String
            let line = intValue(data["sdpMLineIndex"])
            return .iceCandidate(IceCandidate(sdp: candidate, sdpMid: mid, lineIndex: line))
        case "other-session-connected":
            return .otherSession
        default:
            return .ignored
        }
    }

    public static func offer(sessionDescriptionJSON: String) -> String {
        let encoded = Data(sessionDescriptionJSON.utf8).base64EncodedString()
        return """
            {"type":"offer","data":{"sd":"\(encoded)"}}
            """
    }

    public static func sessionDescriptionJSON(type: String, sdp: String) throws -> String {
        String(decoding: try JSONEncoder().encode(Description(type: type, sdp: sdp)), as: UTF8.self)
    }

    public static func iceCandidate(_ candidate: IceCandidate) throws -> String {
        let message = CandidateMessage(
            data: CandidateData(
                candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.lineIndex))
        return String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
    }

    private struct Description: Encodable {
        let type: String
        let sdp: String
    }
    private struct CandidateMessage: Encodable {
        let type = "new-ice-candidate"
        let data: CandidateData
    }
    private struct CandidateData: Encodable {
        let candidate: String
        let sdpMid: String?
        let sdpMLineIndex: Int?
    }

    public static let pong = "pong"

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}
