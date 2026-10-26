import Foundation
import CryptoKit

/// Sans-I/O link (Android SecureBluetoothLink.kt): BMH2 (u32-length-prefixed signed hellos) or, with `bmh3` settings,
/// the experimental BMH3 handshake (u32-length-prefixed msg1..msg3), then BMS1 records in both directions. The initiator
/// (central/caller/stream source) writes first; a BMH3-enabled responder dispatches on the first frame's magic.
public final class SecureLink {
    public enum Output: Equatable {
        case send(Data)
        case established
        case record(SecureRecord)
    }
    public static let maxHelloBytes = 2_048
    public let role: HandshakeRole
    private let identity: SigningIdentity
    private let capabilities: NodeCapabilities
    /// Experimental BMH3 (calls only); nil = BMH2 exactly as before.
    public let bmh3: Bmh3CallSettings?
    private var pending: PendingHandshake?
    private var bmh3Initiator: Bmh3Initiator?
    private var bmh3Responder: Bmh3Responder?
    private var helloBuffer = Data()
    private var sealer: SecureRecordSealer?
    private var opener: SecureRecordOpener?
    public private(set) var peerHello: SignedHandshakeHello?
    public private(set) var peerNodeId: NodeId?
    /// The peer's signed capabilities, with the build-tag bit 7 removed (it is never a capability).
    public private(set) var peerCapabilities: NodeCapabilities?
    /// The capabilities this phone presented (a pseudonymous BMH3 responder clears link bit 3).
    public private(set) var presentedCapabilities: NodeCapabilities
    /// BMH3 only: the peer's block declared a throwaway key / this phone presented one.
    public private(set) var peerPseudonymous = false
    public private(set) var ownPseudonymous = false
    public private(set) var usedBmh3 = false
    /// BMH3 only: the authenticated peer of the link handshake.
    public private(set) var bmh3Peer: Bmh3Peer?
    /// A stream reader tightens this before the header and raises it only after a verified audio-only header.
    public var maxIncomingCiphertextBytes = SecureRecordProtocol.maxPlaintextBytes + MeshAead.tagBytes {
        didSet { opener?.maxCiphertextBytes = maxIncomingCiphertextBytes }
    }
    public var isEstablished: Bool { sealer != nil }
    public var acceptDiscoveryOpening = false
    public var acceptStoreForward: Bool {
        get { opener?.acceptStoreForward ?? false }
        set { opener?.acceptStoreForward = newValue }
    }

    public init(role: HandshakeRole, identity: SigningIdentity, capabilities: NodeCapabilities, bmh3: Bmh3CallSettings? = nil) {
        self.role = role; self.identity = identity; self.capabilities = capabilities; self.bmh3 = bmh3
        presentedCapabilities = capabilities
    }

    static func frame(_ hello: SignedHandshakeHello) throws -> Data { try frame(bytes: try hello.encoded()) }

    static func frame(bytes: Data) throws -> Data {
        guard (1...maxHelloBytes).contains(bytes.count) else { throw ProtocolError.limit("Handshake message is too large") }
        var w = BinaryWriter(); w.u32(UInt32(bytes.count)); w.bytes(bytes); return w.data
    }

    /// Initiator: returns its framed hello (or BMH3 msg1). Responder: returns nil and waits.
    public func start(ephemeral: P256.KeyAgreement.PrivateKey = .init()) throws -> Data? {
        guard role == .initiator else { return nil }
        if let bmh3, bmh3.speak {
            // Toward a relay (route cost above 0) a throwaway key replaces the real one; a stranger presentation is for
            // the advert's owner only.
            let declared = bmh3.declareLinkOverride ? bmh3.linkIdentityOverride : nil
            let linkIdentity = declared == nil ? (bmh3.linkIdentityOverride ?? identity) : identity
            // Without a tag the initiator presents its stranger presentation, never `identity` (rule P).
            let stranger = declared ?? (bmh3.linkIdentityOverride == nil ? bmh3.stranger : nil)
            let config = try Bmh3Config(purpose: .link, identity: linkIdentity, capabilities: capabilities, entropy: bmh3.entropy,
                                        stranger: try stranger.map { try Bmh3Presentation(identity: $0, capabilities: capabilities, pseudonym: true) })
            let tag = bmh3.linkTag && bmh3.linkIdentityOverride == nil ? bmh3.contactTag : nil
            let initiator = Bmh3Initiator(config: config, contactTag: tag, checkResponder: { peer in
                // A recognised contact: the answerer must be that contact (its full node ID), not any key whose RDI matches.
                if let expected = tag?.expectedPeer, peer.nodeId != expected { throw Bmh3Failure("not the expected contact") }
                try bmh3.checkResponder(peer, .link)
            })
            bmh3Initiator = initiator
            return try SecureLink.frame(bytes: try initiator.message1())
        }
        let p = try MeshHandshake.start(identity: identity, role: .initiator, capabilities: capabilities, purpose: .link, ephemeral: ephemeral)
        pending = p
        return try SecureLink.frame(p.hello)
    }

    /// The next whole `u32 length | message` frame of the handshake, or nil when more bytes are needed.
    private func nextFrame() throws -> Data? {
        guard helloBuffer.count >= 4 else { return nil }
        var r = BinaryReader(helloBuffer.prefix(4).rebased)
        let size = Int(try r.i32())
        guard (1...SecureLink.maxHelloBytes).contains(size) else { throw ProtocolError.malformed("Invalid handshake message size") }
        guard helloBuffer.count >= 4 + size else { return nil }
        let frame = helloBuffer.subdata(in: helloBuffer.startIndex + 4 ..< helloBuffer.startIndex + 4 + size)
        helloBuffer = helloBuffer.dropFirst(4 + size).rebased
        return frame
    }

    public func receive(_ data: Data, recordLimit: Int = Int.max) throws -> [Output] {
        if let opener { return try opener.feed(data, maxRecords: recordLimit).map { .record($0) } }
        helloBuffer.append(data)
        var outputs: [Output] = []
        while sealer == nil, let frame = try nextFrame() {
            if let keys = try handleFrame(frame, &outputs) {
                install(keys)
                outputs.append(.established)
                let rest = helloBuffer; helloBuffer = Data()
                if !rest.isEmpty, let opener { outputs += try opener.feed(rest, maxRecords: recordLimit).map { .record($0) } }
            }
        }
        return outputs
    }

    private func install(_ keys: MeshSessionKeys) {
        pending = nil; bmh3Initiator = nil; bmh3Responder = nil
        sealer = SecureRecordSealer(key: keys.sendKey)
        let opener = SecureRecordOpener(key: keys.receiveKey)
        opener.acceptDiscoveryOpening = acceptDiscoveryOpening && presentedCapabilities.transportMask & NodeCapabilities.transportDiscoveryOpening != 0
        opener.maxCiphertextBytes = maxIncomingCiphertextBytes
        self.opener = opener
    }

    /// One handshake frame; returns the session keys once the handshake is complete.
    private func handleFrame(_ frame: Data, _ outputs: inout [Output]) throws -> MeshSessionKeys? {
        if let initiator = bmh3Initiator {
            let message3 = try initiator.onMessage2(frame)
            outputs.append(.send(try SecureLink.frame(bytes: message3)))
            let result = try initiator.finalResult()
            if !result.peer.pseudonymous { bmh3?.onRealResponder(result.peer) }
            return try finishBmh3(result)
        }
        if let responder = bmh3Responder {
            guard try responder.onMessage3(frame) == nil else { throw ProtocolError.state("BMH3 I_FIRST is not supported") }
            return try finishBmh3(try responder.finalResult())
        }
        if role == .responder, let bmh3, Bmh3Wire.isBmh3(frame) {
            // A pseudonymous LINK block clears link-hello bit 3: no BDO1 follows, so the salt of a rotating ID stays here.
            var strangerCaps = capabilities
            strangerCaps.transportMask &= ~NodeCapabilities.transportDiscoveryOpening
            let config = try Bmh3Config(purpose: .link, identity: identity, capabilities: capabilities, entropy: bmh3.entropy,
                                        stranger: try bmh3.stranger.map { try Bmh3Presentation(identity: $0, capabilities: strangerCaps, pseudonym: true) })
            let budget = bmh3.budget
            let responder = Bmh3Responder(config: config, tagChecks: bmh3.tagChecks(), opening: bmh3.opening(), replayCache: bmh3.replayCache,
                                          beforeReply: { _ in try budget?.spend() },
                                          admitInitiator: { peer, matched in !matched || bmh3.admitTagged(peer.nodeId) })
            bmh3Responder = responder
            outputs.append(.send(try SecureLink.frame(bytes: try responder.onMessage1(frame))))
            return nil
        }
        if role == .responder, let bmh3, !bmh3.acceptBmh2 { throw Bmh3Failure("bmh2 refused") }
        let remote = try SignedHandshakeHello(decoding: frame)
        let keys: MeshSessionKeys
        switch role {
        case .initiator:
            guard let pending else { throw ProtocolError.state("Link handshake not started") }
            keys = try MeshHandshake.finish(pending, remote: remote)
        case .responder:
            guard remote.role == .initiator else { throw ProtocolError.state("Expected an initiator handshake") }
            let p = try MeshHandshake.start(identity: identity, role: .responder, capabilities: capabilities, purpose: .link)
            keys = try MeshHandshake.finish(p, remote: remote)
            outputs.append(.send(try SecureLink.frame(p.hello)))
        }
        peerHello = remote
        peerNodeId = remote.nodeId
        var caps = remote.capabilities
        caps.transportMask &= ~NodeCapabilities.transportBuildTag
        peerCapabilities = caps
        return keys
    }

    private func finishBmh3(_ result: Bmh3Result) throws -> MeshSessionKeys {
        usedBmh3 = true
        bmh3Peer = result.peer
        peerNodeId = result.peer.nodeId
        var caps = result.peer.capabilities
        caps.transportMask &= ~NodeCapabilities.transportBuildTag
        peerCapabilities = caps
        peerPseudonymous = result.peer.pseudonymous
        ownPseudonymous = result.ownPseudonymous
        if result.ownPseudonymous && role == .responder { presentedCapabilities.transportMask &= ~NodeCapabilities.transportDiscoveryOpening }
        return MeshSessionKeys(peerNodeId: result.peer.nodeId, sendKey: SymmetricKey(data: result.sendKey), receiveKey: SymmetricKey(data: result.receiveKey))
    }

    public func seal(_ type: SecureRecordType, _ payload: Data) throws -> Data {
        guard let sealer else { throw ProtocolError.state("Link is not authenticated") }
        return try sealer.seal(type, payload)
    }
    public var sentRecords: UInt64 { sealer?.nextSequence ?? 0 }
    public var receivedRecords: UInt64 { opener?.nextSequence ?? 0 }
}
