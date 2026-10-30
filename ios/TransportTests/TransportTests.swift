import MultiKVMCore
import WebRTC
import XCTest

@testable import MultiKVMTransport

final class TransportTests: XCTestCase {
    @MainActor
    func testRealWebRTCOfferContainsOnlyH264AndNoAudio() async {
        let offered = expectation(description: "native offer")
        let peer = PeerLink()
        var messages: [String] = []
        peer.onFailed = { message in
            XCTFail(message)
            offered.fulfill()
        }
        peer.sendSignaling = { text in
            messages.append(text)
            guard let data = text.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["type"] as? String == "offer",
                let payload = object["data"] as? [String: String],
                let encoded = payload["sd"], let decoded = Data(base64Encoded: encoded),
                let description = try? JSONSerialization.jsonObject(with: decoded) as? [String: String],
                let sdp = description["sdp"]
            else { return }
            XCTAssertTrue(OfferSdp.problems(in: sdp).isEmpty, sdp)
            XCTAssertTrue(sdp.contains("packetization-mode=1"), sdp)
            XCTAssertTrue(sdp.contains("profile-level-id=64"), sdp)
            XCTAssertFalse(sdp.contains("VP8"), sdp)
            XCTAssertFalse(sdp.contains("VP9"), sdp)
            XCTAssertFalse(sdp.contains("AV1"), sdp)
            XCTAssertTrue(messages.first?.contains("\"type\":\"offer\"") == true)
            offered.fulfill()
        }
        peer.start()
        await fulfillment(of: [offered], timeout: 10)
        peer.stop()
    }

    func testDecoderAcknowledgesOriginalRtpTimestamp() {
        let decoder = PassthroughH264Decoder()
        let image = RTCEncodedImage()
        // Annex-B SPS + IDR is enough to exercise the passthrough accounting path.
        image.buffer = Data([0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x65, 1])
        image.timeStamp = 0xF123_4567
        var received: UInt32?
        decoder.setCallback { received = UInt32(bitPattern: $0.timeStamp) }
        XCTAssertEqual(decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), 0)
        XCTAssertEqual(received, image.timeStamp)
        XCTAssertEqual(decoder.release(), 0)
    }
}
