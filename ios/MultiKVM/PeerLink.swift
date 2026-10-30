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

    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) {
        self.callback = callback
    }

    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int {
        0
    }

    func releaseDecoder() -> Int {
        callback = nil
        0
    }

    func decode(
        _ encodedImage: RTCEncodedImage,
        missingFrames: Bool,
        codecSpecificInfo info: (any RTCCodecSpecificInfo)?,
        renderTimeMs: Int64
    ) -> Int {
        let data = encodedImage.buffer
        onAccessUnit?(data, encodedImage.encodedWidth, encodedImage.encodedHeight)
        let unit = H264AccessUnit.parseBitstream(data)
        if unit.sps != nil { sawParameterSet = true }
        if unit.nalUnits.contains(where: { H264AccessUnit.nalType($0) == 5 }) {
            sawIDR = true
        }
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
        callback(frame)
    }
}

final class PassthroughDecoderFactory: NSObject, RTCVideoDecoderFactory {
    var onAccessUnit: ((Data, Int32, Int32) -> Void)?

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        [RTCVideoCodecInfo(name: "H264")]
    }

    func createDecoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoDecoder)? {
        let decoder = PassthroughH264Decoder()
        decoder.onAccessUnit = { [weak self] data, width, height in
            self?.onAccessUnit?(data, width, height)
        }
        return decoder
    }
}

final class PeerLink: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    var sendSignaling: ((String) -> Void)?
    var onVideo: ((Data, Int32, Int32) -> Void)?
    var onIceConnected: (() -> Void)?
    var onFailed: ((String) -> Void)?
    var onHidMessage: ((Data) -> Void)?
    var onRoundTripSeconds: ((Double?) -> Void)?
    var onPath: ((String) -> Void)?

    private let decoderFactory = PassthroughDecoderFactory()
    private var factory: RTCPeerConnectionFactory?
    private var peer: RTCPeerConnection?
    private var rpc: RTCDataChannel?
    private var hidReliable: RTCDataChannel?
    private var hidOrdered: RTCDataChannel?
    private var hidUnordered: RTCDataChannel?
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
    private let signalLock = NSLock()

    func start() {
        WebRTCBoot.prepare()
        decoderFactory.onAccessUnit = { [weak self] data, width, height in
            self?.onVideo?(data, width, height)
        }
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let peerFactory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        factory = peerFactory
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = []
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherOnce
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = peerFactory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            onFailed?("PeerConnection を作れません")
            return
        }
        self.peer = peer
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .recvOnly
        let transceiver = peer.addTransceiver(of: .video, init: transceiverInit)
        let capabilities = RTCRtpReceiver.rtpReceiverCapabilities(forKind: "video")
        let h264 = capabilities.codecs.filter { $0.name.caseInsensitiveCompare("H264") == .orderedSame }
        if h264.isEmpty {
            onFailed?("H.264 の受信コーデックがありません")
            return
        }
        transceiver.setCodecPreferences(h264)

        rpc = makeChannel(on: peer, label: "rpc", ordered: true, reliable: true)
        hidReliable = makeChannel(on: peer, label: "hidrpc", ordered: true, reliable: true)
        hidOrdered = makeChannel(on: peer, label: "hidrpc-unreliable-ordered", ordered: true, reliable: false)
        hidUnordered = makeChannel(on: peer, label: "hidrpc-unreliable-nonordered", ordered: false, reliable: false)

        peer.offer(for: constraints) { [weak self] description, error in
            guard let self else { return }
            if let error {
                self.onFailed?("offer を作れません: \(error.localizedDescription)")
                return
            }
            guard let description else {
                self.onFailed?("offer が空です")
                return
            }
            let munged = OfferSdp.insertingPlayoutDelay(description.sdp)
            let problems = OfferSdp.problems(in: munged)
            if !problems.isEmpty {
                self.onFailed?(problems.joined(separator: "\n"))
                return
            }
            let offer = RTCSessionDescription(type: .offer, sdp: munged)
            peer.setLocalDescription(offer) { error in
                if let error {
                    self.onFailed?("local description を設定できません: \(error.localizedDescription)")
                    return
                }
                let json = SignalingCodec.sessionDescriptionJSON(type: "offer", sdp: munged)
                self.emit(SignalingCodec.offer(sessionDescriptionJSON: json), offer: true)
            }
        }
    }

    func stop() {
        statsTimer?.invalidate()
        remoteFlush?.cancel()
        hidReady = false
        peer?.close()
        peer = nil
        factory = nil
    }

    func addRemote(_ candidate: IceCandidate) {
        let ready = remoteGate.receive(candidate)
        publishPath()
        if remoteGate.prefersTailnet {
            remoteFlush?.cancel()
        } else if remoteFlush == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.enqueueRemote(self.remoteGate.flush())
                self.publishPath()
            }
            remoteFlush = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
        enqueueRemote(ready)
    }

    func sendHid(_ message: OutgoingHid) {
        let channel: RTCDataChannel?
        switch message.channel {
        case .reliable:
            channel = hidReliable
        case .unreliableOrdered:
            channel = (hidOrdered?.readyState == .open) ? hidOrdered : hidReliable
        }
        guard let channel, channel.readyState == .open else { return }
        if !hidReady, message.bytes.first != HidMessage.handshakeType {
            return
        }
        channel.sendData(RTCDataBuffer(data: message.bytes, isBinary: true))
    }

    func sendRpc(_ text: String) {
        guard let rpc, rpc.readyState == .open else { return }
        rpc.sendData(RTCDataBuffer(data: Data(text.utf8), isBinary: false))
    }

    private func makeChannel(
        on peer: RTCPeerConnection,
        label: String,
        ordered: Bool,
        reliable: Bool
    ) -> RTCDataChannel? {
        let config = RTCDataChannelConfiguration()
        config.isOrdered = ordered
        if !reliable {
            config.maxRetransmits = 0
        }
        let channel = peer.dataChannel(forLabel: label, configuration: config)
        channel?.delegate = self
        return channel
    }

    private func enqueueRemote(_ candidates: [IceCandidate]) {
        guard remoteReady else {
            pendingRemote.append(contentsOf: candidates)
            return
        }
        for candidate in candidates {
            addNow(candidate)
        }
    }

    private func addNow(_ candidate: IceCandidate) {
        let ice = RTCIceCandidate(
            sdp: candidate.sdp,
            sdpMLineIndex: Int32(candidate.lineIndex ?? 0),
            sdpMid: candidate.sdpMid
        )
        peer?.add(ice)
    }

    private func publishPath() {
        onPath?(remoteGate.prefersTailnet || localGate.prefersTailnet ? "Tailscale host" : "LAN host")
    }

    private func emit(_ text: String, offer: Bool) {
        signalLock.lock()
        if offer {
            offerSent = true
        }
        if offerSent {
            let queued = pendingSignals
            pendingSignals = []
            signalLock.unlock()
            if offer {
                sendSignaling?(text)
                for item in queued {
                    sendSignaling?(item)
                }
            } else {
                for item in queued {
                    sendSignaling?(item)
                }
                sendSignaling?(text)
            }
        } else {
            pendingSignals.append(text)
            signalLock.unlock()
        }
    }

    private func handshake() {
        hidReliable?.sendData(RTCDataBuffer(data: HidMessage.handshake(), isBinary: true))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        switch newState {
        case .connected, .completed:
            if !notifiedConnected {
                notifiedConnected = true
                onIceConnected?()
                startStats()
            }
        case .failed, .disconnected:
            let failed = newState == .failed
            onFailed?("ICE が \(failed ? "失敗" : "切断") しました。Tailscale が直接つながっているか確認してください")
        case .new, .checking, .closed:
            break
        @unknown default:
            break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        let ready = localGate.flush()
        publishPath()
        for candidate in ready {
            emit(SignalingCodec.iceCandidate(candidate), offer: false)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let parsed = IceCandidate(sdp: candidate.sdp, sdpMid: candidate.sdpMid, lineIndex: Int(candidate.sdpMLineIndex))
        for item in localGate.receive(parsed) {
            emit(SignalingCodec.iceCandidate(item), offer: false)
        }
        publishPath()
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {}

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.label == "hidrpc", dataChannel.readyState == .open {
            handshake()
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard buffer.isBinary else { return }
        if dataChannel.label == "hidrpc" {
            if case .handshake = InboundHid.parse(buffer.data) {
                hidReady = true
            }
            onHidMessage?(buffer.data)
        }
    }

    func acceptAnswer(type: String, sdp: String) {
        let answer = RTCSessionDescription(type: type == "offer" ? .offer : .answer, sdp: sdp)
        peer?.setRemoteDescription(answer) { [weak self] error in
            guard let self else { return }
            if let error {
                self.onFailed?("answer を設定できません: \(error.localizedDescription)")
                return
            }
            self.remoteReady = true
            let queued = self.pendingRemote
            self.pendingRemote = []
            for candidate in queued {
                self.addNow(candidate)
            }
        }
    }

    private func startStats() {
        statsTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.peer?.statistics { report in
                var rtt: Double?
                for stat in report.statistics.values where stat.type == "candidate-pair" {
                    let state = stat.values["state"] as? String
                    if state == "succeeded", let value = stat.values["currentRoundTripTime"] as? NSNumber {
                        rtt = value.doubleValue
                    }
                }
                self?.onRoundTripSeconds?(rtt)
            }
        }
        statsTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

private enum WebRTCBoot {
    static var didPrepare = false

    static func prepare() {
        if didPrepare { return }
        didPrepare = true
        RTCInitializeSSL()
        RTCInitFieldTrialDictionary([
            "WebRTC-ForcePlayoutDelay": "min_ms:0,max_ms:0",
        ])
    }
}
