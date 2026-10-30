import XCTest
@testable import MultiKVMCore

final class EndpointTests: XCTestCase {
    func testTailnetLiteral() throws {
        let endpoint = try JetKVMEndpoint.parse("100.64.1.2")
        XCTAssertEqual(endpoint.signaling.scheme, "ws")
        XCTAssertEqual(endpoint.signaling.path, "/webrtc/signaling/client")
        XCTAssertEqual(endpoint.login.path, "/auth/login-local")
        XCTAssertEqual(endpoint.addressKind, .tailnet)
        XCTAssertEqual(endpoint.pairedIdentity, "http://100.64.1.2")
    }

    func testHttpsMagicDNS() throws {
        let endpoint = try JetKVMEndpoint.parse("https://JetKVM.tail.ts.net/")
        XCTAssertEqual(endpoint.signaling.scheme, "wss")
        XCTAssertEqual(endpoint.addressKind, .hostname)
        XCTAssertEqual(endpoint.pairedIdentity, "https://jetkvm.tail.ts.net")
    }

    func testRejectsUserInfoAndOddScheme() {
        XCTAssertThrowsError(try JetKVMEndpoint.parse("http://user:secret@100.64.0.1")) { error in
            XCTAssertEqual(error as? EndpointError, .userInfo)
        }
        XCTAssertThrowsError(try JetKVMEndpoint.parse("ftp://100.64.0.1")) { error in
            XCTAssertEqual(error as? EndpointError, .unsupportedScheme)
        }
    }

    func testTailnetBoundaries() {
        XCTAssertTrue(TailnetAddress.isTailnet("100.64.0.0"))
        XCTAssertTrue(TailnetAddress.isTailnet("100.127.255.255"))
        XCTAssertFalse(TailnetAddress.isTailnet("100.63.255.255"))
        XCTAssertFalse(TailnetAddress.isTailnet("100.128.0.1"))
        XCTAssertFalse(TailnetAddress.isTailnet("192.168.1.20"))
        XCTAssertTrue(TailnetAddress.isTailnet("fd7a:115c:a1e0::1"))
        XCTAssertEqual(TailnetAddress.kind(of: "10.1.1.1"), .otherIP)
    }
}

final class IceGateTests: XCTestCase {
    func testTailnetDropsLanAndRelay() {
        var gate = HostCandidateGate()
        let lan = IceCandidate(sdp: "candidate:1 1 UDP 1 192.168.1.20 9 typ host", sdpMid: "0", lineIndex: 0)
        let relay = IceCandidate(sdp: "candidate:2 1 UDP 1 1.2.3.4 3478 typ relay", sdpMid: "0", lineIndex: 0)
        let tail = IceCandidate(sdp: "candidate:3 1 UDP 1 100.65.1.2 9 typ host", sdpMid: "0", lineIndex: 0)
        XCTAssertEqual(lan.kind, .otherHost)
        XCTAssertEqual(relay.kind, .unwanted)
        XCTAssertEqual(tail.kind, .tailnetHost)
        XCTAssertTrue(gate.receive(lan).isEmpty)
        XCTAssertTrue(gate.receive(relay).isEmpty)
        XCTAssertEqual(gate.receive(tail).map(\.address), ["100.65.1.2"])
        XCTAssertTrue(gate.flush().isEmpty)
    }

    func testLanFallbackWhenNoTailnet() {
        var gate = HostCandidateGate()
        let lan = IceCandidate(sdp: "candidate:1 1 UDP 1 192.168.1.20 9 typ host", sdpMid: nil, lineIndex: 0)
        XCTAssertTrue(gate.receive(lan).isEmpty)
        XCTAssertEqual(gate.flush().map(\.address), ["192.168.1.20"])
    }
}

final class SignalingTests: XCTestCase {
    func testAnswerAndOfferEnvelope() throws {
        let description = SignalingCodec.sessionDescriptionJSON(type: "answer", sdp: "v=0\r\n")
        let encoded = Data(description.utf8).base64EncodedString()
        let wire = #"{"type":"answer","data":"\#(encoded)"}"#
        guard case .answer(let type, let sdp) = SignalingCodec.parse(wire) else {
            return XCTFail("answer")
        }
        XCTAssertEqual(type, "answer")
        XCTAssertEqual(sdp, "v=0\r\n")

        let offer = SignalingCodec.offer(sessionDescriptionJSON: description)
        let object = try JSONSerialization.jsonObject(with: Data(offer.utf8)) as? [String: Any]
        let data = object?["data"] as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "offer")
        XCTAssertEqual(data?["sd"] as? String, encoded)
    }

    func testMetadataPingAndCandidate() {
        XCTAssertEqual(
            SignalingCodec.parse(#"{"type":"device-metadata","data":{"deviceVersion":"0.4.9"}}"#),
            .deviceMetadata(version: "0.4.9")
        )
        XCTAssertEqual(SignalingCodec.parse("ping"), .ping)
        XCTAssertEqual(SignalingCodec.pong, "pong")
        guard case .iceCandidate(let candidate) = SignalingCodec.parse(
            #"{"type":"new-ice-candidate","data":{"candidate":"candidate:1 1 UDP 1 100.64.0.2 9 typ host","sdpMid":"0","sdpMLineIndex":0}}"#
        ) else {
            return XCTFail("candidate")
        }
        XCTAssertEqual(candidate.kind, .tailnetHost)
        XCTAssertEqual(candidate.lineIndex, 0)
    }

    func testLinkRequiresPairingBeforeVideo() {
        var state = LinkState(pairedHost: nil, host: "http://100.64.0.2")
        state.apply(.begin)
        state.apply(.authNotRequired)
        state.apply(.metadata("1.0.0"))
        XCTAssertEqual(state.phase, .confirmingDevice(version: "1.0.0"))
        state.apply(.iceConnected)
        XCTAssertEqual(state.phase, .confirmingDevice(version: "1.0.0"))
        state.apply(.confirm)
        XCTAssertEqual(state.phase, .negotiating)
        XCTAssertEqual(state.pairedHost, "http://100.64.0.2")
        state.apply(.iceConnected)
        XCTAssertEqual(state.phase, .streaming)
    }

    func testKnownHostSkipsConfirm() {
        var state = LinkState(pairedHost: "http://100.64.0.2", host: "http://100.64.0.2")
        state.apply(.begin)
        state.apply(.authOk)
        state.apply(.metadata("1.0.0"))
        XCTAssertEqual(state.phase, .negotiating)
    }
}
