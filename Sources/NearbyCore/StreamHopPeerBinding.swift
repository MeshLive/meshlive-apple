import Foundation

/// Security review SEC-B2 (Apple side): on every live-stream hop the authenticated end-to-end peer must be the
/// authenticated link peer, by full node ID. Otherwise a phone that dials a viewer's request (or answers a source's
/// offer) with its own key could pass the other side's end-to-end handshake through and own the hop-local controls
/// (heartbeats, link reports, route withdrawal, Wi-Fi capabilities) while the media stays end-to-end encrypted.
///
/// The rule covers both roles (the source or forwarder that dials, the viewer that answers), every offer version (2 and
/// 5) and every transport. A forwarded stream needs no exception: a forwarder runs its own end-to-end handshake with each
/// child and hands over the stream key (`ForwardedStreamGrant`). Apple has no stream relay harness, so there is no
/// exemption. Before this rule a version 2 hop compared the end-to-end peer with the selected 6-byte prefix only
/// (`MeshConnection`), which a middle could pass with a key ground to the victim's prefix.
public enum StreamHopPeerBinding {
    public enum Result: String { case bound, mismatch }

    /// Which side of the hop checks.
    public enum Role: String {
        /// The child: a viewer of a source or of a forwarder (the hop's responder).
        case viewer
        /// The source toward a viewer (the hop's initiator).
        case source
        /// A forwarder toward its child (the hop's initiator).
        case forwarder
    }

    /// DEBUG builds only (the app installs it at start): `stream_peer_binding: result=mismatch | role=<role> | version=<2|5>`.
    public static var debugLog: ((KeyValuePairs<String, String>) -> Void)?

    /// `.bound` only when the link peer authenticated and the end-to-end peer is the same node.
    public static func check(link: NodeId?, endpoint: NodeId) -> Result {
        guard let link, link == endpoint else { return .mismatch }
        return .bound
    }

    /// Fails the hop closed (`ProtocolError.authentication`) unless the end-to-end peer is the link peer.
    public static func require(role: Role, rotating: Bool, link: NodeId?, endpoint: NodeId) throws {
        guard check(link: link, endpoint: endpoint) == .mismatch else { return }
        debugLog?(["result": Result.mismatch.rawValue, "role": role.rawValue, "version": rotating ? "5" : "2"])
        throw ProtocolError.authentication
    }
}
