import Foundation
import MultiKVMCore
import WebRTC

/// WebRTC 156 (stasel/WebRTC) の Objective-C API に合わせている。
/// Linux ではビルドしない。実機の JetKVM と iPhone での接続は未検証。
final class PassthroughH264Decoder: NSObject, RTCVideoDecoder {
    var onAccessUnit: ((Data, Int32, Int32) -> Void)?
    private var callback: RTCVideoDecoderCallback?
    private var sawParameterSet = false
    private var sawIDR = false
    private let recovery: H264RecoveryGate

    init(recovery: H264RecoveryGate = H264RecoveryGate()) {
        self.recovery = recovery
        super.init()
    }

    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) {
        self.callback = callback
    }

    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int {
        0
    }

    func release() -> Int {
        callback = nil
        return 0
    }

    func decode(
        _ encodedImage: RTCEncodedImage,
        missingFrames: Bool,
        codecSpecificInfo info: (any RTCCodecSpecificInfo)?,
        renderTimeMs: Int64
    ) -> Int {
        let data = encodedImage.buffer
        let unit = H264AccessUnit.parseBitstream(data)
        if unit.sps != nil { sawParameterSet = true }
        if unit.nalUnits.contains(where: { H264AccessUnit.nalType($0) == 5 }) {
            sawIDR = true
        }
        guard recovery.accepts(unit) else {
            // Parameter sets may arrive separately from the replacement IDR.
            if unit.sliceUnits.isEmpty {
                onAccessUnit?(data, encodedImage.encodedWidth, encodedImage.encodedHeight)
            }
            return 4
        }
        onAccessUnit?(data, encodedImage.encodedWidth, encodedImage.encodedHeight)
        // コールバックを呼ばないと受信側がフレームを未完了のまま抱える実装がある。
        // 表示は AVSampleBufferDisplayLayer が行う。ここは 2x2 の空フレームで会計だけ返す。
        // webrtc video_error_codes.h の WEBRTC_VIDEO_CODEC_OK_REQUEST_KEYFRAME は 4。
        if sawParameterSet && sawIDR {
            acknowledgeDecode(encodedImage)
            return 0
        }
        return 4
    }

    func implementationName() -> String { "MultiKVM" }

    private func acknowledgeDecode(_ encodedImage: RTCEncodedImage) {
        guard let callback else { return }
        let buffer = RTCI420Buffer(width: 2, height: 2)
        let timestamp = Int64(encodedImage.timeStamp) * 1_000_000 / 90
        let frame = RTCVideoFrame(buffer: buffer, rotation: RTCVideoRotation._0, timeStampNs: timestamp)
        frame.timeStamp = Int32(bitPattern: encodedImage.timeStamp)
        callback(frame)
    }
}

final class PassthroughDecoderFactory: NSObject, RTCVideoDecoderFactory {
    var onAccessUnit: ((Data, Int32, Int32) -> Void)?
    let recovery = H264RecoveryGate()

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        RTCDefaultVideoDecoderFactory().supportedCodecs().filter {
            $0.name.caseInsensitiveCompare("H264") == .orderedSame
        }
    }

    func createDecoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoDecoder)? {
        let decoder = PassthroughH264Decoder(recovery: recovery)
        decoder.onAccessUnit = { [weak self] data, width, height in
            self?.onAccessUnit?(data, width, height)
        }
        return decoder
    }
}

@MainActor
final class PeerLink: PeerSession {
    var onEvent: (@MainActor (PeerEvent) -> Void)?
    private enum Lifecycle { case idle, running, stopped }
    private var lifecycle = Lifecycle.idle
    private let decoderFactory = PassthroughDecoderFactory()
    private lazy var delegateBridge = PeerDelegate(owner: self)
    private var factory: RTCPeerConnectionFactory?
    private var peer: RTCPeerConnection?
    private var rpc: RTCDataChannel?
    private var hid: RTCDataChannel?
    private var localGate = HostCandidateGate()
    private var remoteGate = HostCandidateGate()
    private var remoteReady = false
    private var pendingRemote: [IceCandidate] = []
    private var notifiedConnected = false
    private var hidReady = false
    private var statsTimer: Timer?
    private var remoteFlush: DispatchWorkItem?
    private var offerSent = false
    private var pendingSignals: [String] = []

    func requestKeyframe() { decoderFactory.recovery.requestKeyframe() }

    func start() {
        guard lifecycle == .idle else {
            onEvent?(.failed("PeerSession は接続ごとに新しく作ってください"))
            return
        }
        lifecycle = .running
        WebRTCBoot.prepare()
        decoderFactory.onAccessUnit = { [weak self] data, width, height in
            // FIFO is required: compressed interframes depend on the preceding frame.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lifecycle == .running else { return }
                self.onEvent?(.video(data, width: width, height: height))
            }
        }
        let peerFactory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: decoderFactory)
        factory = peerFactory
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = []
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherOnce
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = peerFactory.peerConnection(with: config, constraints: constraints, delegate: delegateBridge)
        else {
            onEvent?(.failed("PeerConnection を作れません"))
            return
        }
        self.peer = peer
        let receiver = RTCRtpTransceiverInit()
        receiver.direction = .recvOnly
        guard let transceiver = peer.addTransceiver(of: .video, init: receiver) else {
            onEvent?(.failed("映像の受信経路を作れません"))
            return
        }
        let h264 = peerFactory.rtpReceiverCapabilities(forKind: "video").codecs.filter {
            $0.name.caseInsensitiveCompare("H264") == .orderedSame
        }
        guard !h264.isEmpty else {
            onEvent?(.failed("H.264 の受信コーデックがありません"))
            return
        }
        do { try transceiver.setCodecPreferences(h264, error: ()) } catch {
            onEvent?(.failed("H.264 を設定できません: \(error.localizedDescription)"))
            return
        }
        rpc = makeChannel(on: peer, label: "rpc")
        hid = makeChannel(on: peer, label: "hidrpc")
        let identity = ObjectIdentifier(peer)
        peer.offer(for: constraints) { [weak self] description, error in
            let sdp = description?.sdp
            let failure = error?.localizedDescription
            DispatchQueue.main.async {
                guard let self, let current = self.peer, ObjectIdentifier(current) == identity else { return }
                if let failure {
                    self.onEvent?(.failed("offer を作れません: \(failure)"))
                    return
                }
                guard let sdp else {
                    self.onEvent?(.failed("offer が空です"))
                    return
                }
                self.setOffer(sdp, on: current)
            }
        }
    }

    private func setOffer(_ rawSdp: String, on peer: RTCPeerConnection) {
        let sdp = OfferSdp.insertingPlayoutDelay(rawSdp)
        let identity = ObjectIdentifier(peer)
        let problems = OfferSdp.problems(in: sdp)
        guard problems.isEmpty else {
            onEvent?(.failed(problems.joined(separator: "\n")))
            return
        }
        peer.setLocalDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.peer.map(ObjectIdentifier.init) == identity else { return }
                if let error {
                    self.onEvent?(.failed("local description を設定できません: \(error.localizedDescription)"))
                    return
                }
                do {
                    let json = try SignalingCodec.sessionDescriptionJSON(type: "offer", sdp: sdp)
                    self.emit(SignalingCodec.offer(sessionDescriptionJSON: json), offer: true)
                } catch { self.onEvent?(.failed("offer をエンコードできません: \(error.localizedDescription)")) }
            }
        }
    }

    func stop() {
        lifecycle = .stopped
        statsTimer?.invalidate()
        statsTimer = nil
        remoteFlush?.cancel()
        remoteFlush = nil
        onEvent = nil
        let old = peer
        peer = nil
        old?.close()
        rpc = nil
        hid = nil
        factory = nil
    }

    func addRemote(_ candidate: IceCandidate) {
        guard lifecycle == .running else { return }
        let ready = remoteGate.receive(candidate)
        publishPath()
        if remoteGate.prefersTailnet {
            remoteFlush?.cancel()
        } else if remoteFlush == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.lifecycle == .running else { return }
                self.enqueueRemote(self.remoteGate.flush())
                self.publishPath()
            }
            remoteFlush = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
        enqueueRemote(ready)
    }

    @discardableResult
    func sendHid(_ message: OutgoingHid) -> Bool {
        guard let hid, hid.readyState == .open, hidReady else { return false }
        return hid.sendData(RTCDataBuffer(data: message.bytes, isBinary: true))
    }

    func sendRpc(_ text: String) {
        guard let rpc, rpc.readyState == .open else { return }
        rpc.sendData(RTCDataBuffer(data: Data(text.utf8), isBinary: false))
    }

    private func makeChannel(on peer: RTCPeerConnection, label: String) -> RTCDataChannel? {
        let config = RTCDataChannelConfiguration()
        config.isOrdered = true
        let channel = peer.dataChannel(forLabel: label, configuration: config)
        channel?.delegate = delegateBridge
        return channel
    }

    private func enqueueRemote(_ candidates: [IceCandidate]) {
        guard remoteReady else {
            pendingRemote.append(contentsOf: candidates)
            return
        }
        for candidate in candidates { addNow(candidate) }
    }

    private func addNow(_ candidate: IceCandidate) {
        let ice = RTCIceCandidate(
            sdp: candidate.sdp, sdpMLineIndex: Int32(candidate.lineIndex ?? 0), sdpMid: candidate.sdpMid)
        peer?.add(ice) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                guard let self, self.lifecycle == .running else { return }
                self.onEvent?(.failed("ICE 候補を追加できません: \(error.localizedDescription)"))
            }
        }
    }

    private func publishPath() {
        onEvent?(.path(remoteGate.prefersTailnet || localGate.prefersTailnet ? "候補: Tailscale host" : "候補: LAN host"))
    }

    private func emitCandidate(_ candidate: IceCandidate) {
        do { emit(try SignalingCodec.iceCandidate(candidate), offer: false) } catch {
            onEvent?(.failed("ICE 候補をエンコードできません: \(error.localizedDescription)"))
        }
    }

    private func emit(_ text: String, offer: Bool) {
        guard lifecycle == .running else { return }
        if offer {
            onEvent?(.signaling(text))
            offerSent = true
            let queued = pendingSignals
            pendingSignals = []
            for item in queued { onEvent?(.signaling(item)) }
        } else if offerSent {
            onEvent?(.signaling(text))
        } else {
            pendingSignals.append(text)
        }
    }

    func receive(_ event: RTCEvent, from source: ObjectIdentifier?) {
        guard lifecycle == .running, source == nil || source == peer.map(ObjectIdentifier.init) else { return }
        switch event {
        case .connection(let rawState):
            guard let state = RTCIceConnectionState(rawValue: rawState) else { return }
            switch state {
            case .connected, .completed:
                if !notifiedConnected {
                    notifiedConnected = true
                    onEvent?(.connected)
                    if lifecycle == .running { startStats() }
                }
            case .failed, .disconnected:
                onEvent?(.failed("ICE が \(state == .failed ? "失敗" : "切断") しました。Tailscale が直接つながっているか確認してください"))
            default: break
            }
        case .gatheringComplete:
            for candidate in localGate.flush() { emitCandidate(candidate) }
            publishPath()
        case .candidate(let candidate):
            for item in localGate.receive(candidate) { emitCandidate(item) }
            publishPath()
        case .channelState(let identity, let rawState):
            if let hid, ObjectIdentifier(hid) == identity, rawState == RTCDataChannelState.open.rawValue {
                hid.sendData(RTCDataBuffer(data: HidMessage.handshake(), isBinary: true))
            }
        case .message(let identity, let data, let isBinary):
            guard let hid, ObjectIdentifier(hid) == identity, isBinary else { return }
            if case .handshake = InboundHid.parse(data) { hidReady = true }
            onEvent?(.hid(data))
        }
    }

    func acceptAnswer(type: String, sdp: String) {
        guard let peer else { return }
        let identity = ObjectIdentifier(peer)
        peer.setRemoteDescription(RTCSessionDescription(type: type == "offer" ? .offer : .answer, sdp: sdp)) {
            [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.peer.map(ObjectIdentifier.init) == identity else { return }
                if let error {
                    self.onEvent?(.failed("answer を設定できません: \(error.localizedDescription)"))
                    return
                }
                self.remoteReady = true
                let queued = self.pendingRemote
                self.pendingRemote = []
                for candidate in queued { self.addNow(candidate) }
            }
        }
    }

    private func startStats() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.collectStats() }
        }
        statsTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func collectStats() {
        guard let peer else { return }
        let identity = ObjectIdentifier(peer)
        peer.statistics { [weak self] report in
            let values = Self.readStats(report)
            DispatchQueue.main.async {
                guard let self, self.peer.map(ObjectIdentifier.init) == identity else { return }
                self.onEvent?(.roundTrip(values.rtt))
                if let path = values.path { self.onEvent?(.path(path)) }
            }
        }
    }

    nonisolated private static func readStats(_ report: RTCStatisticsReport) -> (rtt: Double?, path: String?) {
        let selectedID = report.statistics.values.compactMap {
            $0.type == "transport" ? $0.values["selectedCandidatePairId"] as? String : nil
        }.first
        let pair =
            selectedID.flatMap { report.statistics[$0] }
            ?? report.statistics.values.first {
                $0.type == "candidate-pair" && $0.values["state"] as? String == "succeeded"
                    && ($0.values["nominated"] as? NSNumber)?.boolValue == true
            }
        let rtt = (pair?.values["currentRoundTripTime"] as? NSNumber)?.doubleValue
        guard let localID = pair?.values["localCandidateId"] as? String,
            let remoteID = pair?.values["remoteCandidateId"] as? String,
            let local = report.statistics[localID]?.values["address"] as? String,
            let remote = report.statistics[remoteID]?.values["address"] as? String
        else { return (rtt, nil) }
        return (
            rtt, TailnetAddress.isTailnet(local) || TailnetAddress.isTailnet(remote) ? "Tailscale host" : "LAN host"
        )
    }

}

@MainActor
private enum WebRTCBoot {
    static var didPrepare = false
    static func prepare() {
        guard !didPrepare else { return }
        didPrepare = true
        RTCInitializeSSL()
        RTCInitFieldTrialDictionary(["WebRTC-ForcePlayoutDelay": "min_ms:0,max_ms:0"])
    }
}
