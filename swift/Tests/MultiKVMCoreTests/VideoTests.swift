import XCTest
@testable import MultiKVMCore

final class VideoTests: XCTestCase {
    func testAnnexBAndAVCC() {
        let annex = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x00, 0x00, 0x01, 0x68, 0xCE, 0x00, 0x00, 0x00, 0x01, 0x65, 0x88])
        let unit = H264AccessUnit.parseBitstream(annex)
        XCTAssertEqual(unit.nalUnits.map { [UInt8]($0) }, [[0x67, 0x42], [0x68, 0xCE], [0x65, 0x88]])
        XCTAssertEqual(unit.sps, Data([0x67, 0x42]))
        XCTAssertEqual(unit.pps, Data([0x68, 0xCE]))
        XCTAssertEqual(unit.sliceUnits, [Data([0x65, 0x88])])

        let avcc = Data([0x00, 0x00, 0x00, 0x02, 0x65, 0x11])
        XCTAssertEqual(H264AccessUnit.parseBitstream(avcc).nalUnits, [Data([0x65, 0x11])])
        let prefixed = H264AccessUnit(nalUnits: [Data([0x65, 0x11])]).lengthPrefixed()
        XCTAssertEqual(prefixed, avcc)
    }

    func testFUAAndSTAP() {
        let depacketizer = H264Depacketizer()
        let start = depacketizer.push(RtpH264Packet(payload: Data([0x7C, 0x85, 0x11, 0x22]), marker: false, timestamp: 90))
        XCTAssertNil(start)
        let end = depacketizer.push(RtpH264Packet(payload: Data([0x7C, 0x45, 0x33, 0x44]), marker: true, timestamp: 90))
        XCTAssertEqual(end?.nalUnits, [Data([0x65, 0x11, 0x22, 0x33, 0x44])])

        let stap = depacketizer.push(RtpH264Packet(
            payload: Data([0x78, 0x00, 0x03, 0x67, 0x42, 0x00, 0x00, 0x02, 0x68, 0x01]),
            marker: true,
            timestamp: 180
        ))
        XCTAssertEqual(stap?.nalUnits, [Data([0x67, 0x42, 0x00]), Data([0x68, 0x01])])

        let single = depacketizer.push(RtpH264Packet(payload: Data([0x65, 0x88]), marker: true, timestamp: 270))
        XCTAssertEqual(single?.nalUnits, [Data([0x65, 0x88])])
        _ = depacketizer.push(RtpH264Packet(payload: Data([0x7C]), marker: false, timestamp: 1))
        XCTAssertEqual(depacketizer.droppedPackets, 1)
    }

    func testOfferMungeAndProblems() {
        let sdp = "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=rtpmap:96 H264/90000\r\na=extmap:1 urn:ietf:params:rtp-hdrext:sdes:mid\r\n"
        let munged = OfferSdp.insertingPlayoutDelay(sdp)
        XCTAssertTrue(munged.contains("a=extmap:2 \(OfferSdp.playoutDelayURI)"))
        XCTAssertTrue(OfferSdp.problems(in: munged).isEmpty)
        XCTAssertFalse(OfferSdp.problems(in: sdp + "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n").isEmpty)
        XCTAssertFalse(OfferSdp.problems(in: sdp.replacingOccurrences(of: "H264", with: "H265")).isEmpty)
    }

    func testStatsAndBarcode() {
        var stats = StreamStats()
        stats.record(byteCount: 1000, at: 0)
        stats.record(byteCount: 1000, at: 1)
        XCTAssertEqual(stats.framesPerSecond, 2, accuracy: 0.001)
        XCTAssertEqual(stats.bitsPerSecond, 16_000, accuracy: 0.001)

        let zero = LatencyBarcode.cells(unixMilliseconds: 0)
        XCTAssertEqual(zero.count, 24)
        XCTAssertEqual(LatencyBarcode.decode(luminances: zero.map { $0 ? 0 : 255 }), 0)
        let one = LatencyBarcode.cells(unixMilliseconds: 1)
        XCTAssertEqual(LatencyBarcode.decode(luminances: one.map { $0 ? 10 : 200 }), 1)
        var broken = one.map { $0 ? UInt8(0) : 255 }
        broken[22] = broken[22] == 0 ? 255 : 0
        XCTAssertNil(LatencyBarcode.decode(luminances: broken))
    }

    func testLedParse() {
        XCTAssertEqual(InboundHid.parse(Data([0x01, 0x01])), .handshake(version: 1))
        XCTAssertTrue(InboundHid.parse(Data([0x32, 0x02]))?.capsLock == true)
        XCTAssertFalse(InboundHid.parse(Data([0x32, 0x00]))?.capsLock == true)
    }
}
