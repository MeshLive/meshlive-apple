import Foundation
import CryptoKit

public struct EndToEndSession {
    public let peerNodeId: NodeId
    public let peerCapabilities: NodeCapabilities
    public let peerFingerprint: IdentityFingerprint
    public let sealer: EndToEndContentSealer
    public let opener: EndToEndContentOpener
    /// BMH3 only: the reveal exchange, present when either side presented a pseudonym.
    public var reveal: Bmh3RevealSession? = nil
    /// BMH3 only: the peer's key is a throwaway (no admission, no contact match, no node ID shown).
    public var peerPseudonymous = false
    /// The key this phone presented at the endpoint layer (a pseudonym signs labels in a stranger session).
    public var presentedIdentity: SigningIdentity? = nil
    public var usedBmh3 = false

    public init(peerNodeId: NodeId, peerCapabilities: NodeCapabilities, peerFingerprint: IdentityFingerprint,
                sealer: EndToEndContentSealer, opener: EndToEndContentOpener) {
        self.peerNodeId = peerNodeId; self.peerCapabilities = peerCapabilities; self.peerFingerprint = peerFingerprint
        self.sealer = sealer; self.opener = opener
    }
}

/// Optional gate run on every endpoint handshake before any content key is used (verified contacts).
public protocol PeerIdentityGate: AnyObject {
    /// Throw to refuse (for example a verified contact's prefix with another key).
    func admit(peer: NodeId, fingerprint: IdentityFingerprint) throws
    /// A forwarded stream's original source, known only by its 128-bit node ID from the BFG1 grant.
    func admitForwardedSource(_ source: NodeId) throws
}

public extension PeerIdentityGate {
    func admitForwardedSource(_ source: NodeId) throws {}
}

/// Endpoint handshake (separate signature/KDF domain) over an authenticated link: BMH2, or with `bmh3` settings the
/// experimental BMH3 (the initiator speaks it when its link did; a responder dispatches on the first record's magic).
public final class EndToEndHandshake {
    public let role: HandshakeRole
    private let identity: SigningIdentity
    private let capabilities: NodeCapabilities
    private var pending: PendingHandshake?
    private weak var gate: PeerIdentityGate?
    private let bmh3: Bmh3CallSettings?
    private let speakBmh3: Bool
    private var bmh3Initiator: Bmh3Initiator?
    private var bmh3Responder: Bmh3Responder?
    private var bmh3Fingerprint: IdentityFingerprint?

    public init(role: HandshakeRole, identity: SigningIdentity, capabilities: NodeCapabilities, gate: PeerIdentityGate? = nil,
                bmh3: Bmh3CallSettings? = nil, speakBmh3: Bool = false) {
        self.role = role; self.identity = identity; self.capabilities = capabilities; self.gate = gate
        self.bmh3 = bmh3; self.speakBmh3 = speakBmh3
    }

    private func strangerPresentation() throws -> Bmh3Presentation? {
        try bmh3?.stranger.map { try Bmh3Presentation(identity: $0, capabilities: capabilities, pseudonym: true) }
    }

    /// A throwaway key is not an authenticated person: it is neither admitted nor remembered (its reveal is).
    private func admit(_ peer: Bmh3Peer) throws {
        if !peer.pseudonymous { try gate?.admit(peer: peer.nodeId, fingerprint: peer.fingerprint) }
        bmh3Fingerprint = peer.fingerprint
    }

    /// Initiator: the BMS1 type-4 payload to send first (BMH2 hello or BMH3 msg1).
    public func initiatorHello(ephemeral: P256.KeyAgreement.PrivateKey = .init()) throws -> Data {
        precondition(role == .initiator)
        if speakBmh3, let bmh3 {
            let config = try Bmh3Config(purpose: .endToEnd, identity: identity, capabilities: capabilities, entropy: bmh3.entropy,
                                        stranger: try strangerPresentation())
            let tag = bmh3.contactTag
            let initiator = Bmh3Initiator(config: config, contactTag: tag, checkResponder: { [weak self] peer in
                if let expected = tag?.expectedPeer, peer.nodeId != expected { throw Bmh3Failure("not the expected contact") }
                // The verified-contact check runs before this phone reveals itself; the discovery binding follows.
                try self?.admit(peer)
                try bmh3.checkResponder(peer, .endToEnd)
            })
            bmh3Initiator = initiator
            return try initiator.message1()
        }
        let p = try MeshHandshake.start(identity: identity, role: .initiator, capabilities: capabilities, purpose: .endToEnd, ephemeral: ephemeral)
        pending = p
        return try p.hello.encoded()
    }

    private func bmh3Session(_ result: Bmh3Result, localRole: UInt8) throws -> EndToEndSession {
        guard let fingerprint = bmh3Fingerprint else { throw ProtocolError.state("Peer fingerprint missing") }
        var session = EndToEndSession(peerNodeId: result.peer.nodeId, peerCapabilities: result.peer.capabilities, peerFingerprint: fingerprint,
                                      sealer: EndToEndContentSealer(key: SymmetricKey(data: result.sendKey)),
                                      opener: EndToEndContentOpener(key: SymmetricKey(data: result.receiveKey)))
        if result.ownPseudonymous || result.peer.pseudonymous {
            var own = [identity.publicKeyEncoded, result.ownSpki]
            if let stranger = bmh3?.stranger { own.append(stranger.publicKeyEncoded) }
            session.reveal = Bmh3RevealSession(localRole: localRole, exporter: result.exporter, ownPseudonymSpki: result.ownSpki,
                                               peerPseudonymSpki: result.peer.spki, ownPseudonymous: result.ownPseudonymous,
                                               peerPseudonymous: result.peer.pseudonymous, ownSpkis: own)
        }
        session.peerPseudonymous = result.peer.pseudonymous
        session.presentedIdentity = result.ownPseudonymous ? bmh3?.stranger : identity
        session.usedBmh3 = true
        return session
    }

    /// Consumes the peer's type-4 payload; returns the session once complete and the reply to send, if any.
    /// BMH2: one call. BMH3: the initiator completes on msg2 (replying msg3); the responder replies msg2 to msg1 and
    /// completes on msg3.
    public func receive(_ payload: Data) throws -> (session: EndToEndSession?, reply: Data?) {
        if let initiator = bmh3Initiator {
            let message3 = try initiator.onMessage2(payload)
            return (try bmh3Session(try initiator.finalResult(), localRole: DiscoveryExchange.IdentityReveal.roleCaller), message3)
        }
        if let responder = bmh3Responder {
            guard try responder.onMessage3(payload) == nil else { throw ProtocolError.state("BMH3 I_FIRST is not supported") }
            return (try bmh3Session(try responder.finalResult(), localRole: DiscoveryExchange.IdentityReveal.roleCallee), nil)
        }
        if role == .responder, let bmh3, Bmh3Wire.isBmh3(payload) {
            let config = try Bmh3Config(purpose: .endToEnd, identity: identity, capabilities: capabilities, entropy: bmh3.entropy,
                                        stranger: try strangerPresentation())
            let budget = bmh3.budget
            let responder = Bmh3Responder(config: config, tagChecks: bmh3.tagChecks(), opening: bmh3.opening(), replayCache: bmh3.replayCache,
                                          beforeReply: { _ in try budget?.spend() },
                                          admitInitiator: { [weak self] peer, matched in
                                              guard !matched || bmh3.admitTagged(peer.nodeId) else { return false }
                                              try self?.admit(peer); return true })
            bmh3Responder = responder
            return (nil, try responder.onMessage1(payload))
        }
        if role == .responder, let bmh3, !bmh3.acceptBmh2 { throw Bmh3Failure("bmh2 refused") }
        let remote = try SignedHandshakeHello(decoding: payload)
        let keys: MeshSessionKeys
        var reply: Data?
        switch role {
        case .initiator:
            guard let pending else { throw ProtocolError.state("Endpoint handshake not started") }
            keys = try MeshHandshake.finish(pending, remote: remote)
        case .responder:
            guard remote.role == .initiator else { throw ProtocolError.state("Expected an end-to-end initiator") }
            let p = try MeshHandshake.start(identity: identity, role: .responder, capabilities: capabilities, purpose: .endToEnd)
            keys = try MeshHandshake.finish(p, remote: remote)
            reply = try p.hello.encoded()
        }
        pending = nil
        let fingerprint = IdentityFingerprint(publicKey: remote.identityPublicKey)
        try gate?.admit(peer: keys.peerNodeId, fingerprint: fingerprint)
        var session = EndToEndSession(peerNodeId: keys.peerNodeId, peerCapabilities: remote.capabilities, peerFingerprint: fingerprint,
                                      sealer: EndToEndContentSealer(key: keys.sendKey), opener: EndToEndContentOpener(key: keys.receiveKey))
        session.presentedIdentity = identity
        return (session, reply)
    }
}
