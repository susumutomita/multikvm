import Foundation
import MultiKVMCore

enum PeerEvent: Sendable {
    case signaling(String)
    case video(Data, width: Int32, height: Int32)
    case connected
    case failed(String)
    case hid(Data)
    case roundTrip(Double?)
    case path(String)
}

/// One instance belongs to one connection attempt; start is allowed once.
@MainActor
protocol PeerSession: AnyObject, Sendable {
    var onEvent: (@MainActor (PeerEvent) -> Void)? { get set }
    func start()
    func stop()
    func requestKeyframe()
    func acceptAnswer(type: String, sdp: String)
    func addRemote(_ candidate: IceCandidate)
    @discardableResult func sendHid(_ message: OutgoingHid) -> Bool
    func sendRpc(_ text: String)
}
