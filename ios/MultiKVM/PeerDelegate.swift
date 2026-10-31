import Foundation
import MultiKVMCore
import WebRTC

enum RTCEvent: Sendable {
    case connection(Int)
    case gatheringComplete
    case candidate(IceCandidate)
    case channelState(ObjectIdentifier, Int)
    case message(ObjectIdentifier, Data, isBinary: Bool)
}

/// WebRTC calls this adapter on its own threads. Mutable session state stays on MainActor.
final class PeerDelegate: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    private weak var owner: PeerLink?

    @MainActor
    init(owner: PeerLink) { self.owner = owner }

    private func forward(_ event: RTCEvent, from peer: RTCPeerConnection? = nil) {
        let target = owner
        let identity = peer.map(ObjectIdentifier.init)
        DispatchQueue.main.async { [weak target] in target?.receive(event, from: identity) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        forward(.connection(newState.rawValue), from: peerConnection)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { forward(.gatheringComplete, from: peerConnection) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        forward(
            .candidate(
                IceCandidate(sdp: candidate.sdp, sdpMid: candidate.sdpMid, lineIndex: Int(candidate.sdpMLineIndex))),
            from: peerConnection)
    }
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        forward(.channelState(ObjectIdentifier(dataChannel), dataChannel.readyState.rawValue))
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        forward(.message(ObjectIdentifier(dataChannel), buffer.data, isBinary: buffer.isBinary))
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {}
}
