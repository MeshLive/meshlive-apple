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
    /// Route search: the `RELAY_SEEK` bits the BMH3 responder signed (0 for BMH2 or none).
    public private(set) var peerRelaySeek: UInt8 = 0
    public private(set) var ownPseudonymous = false
    public private(set) var usedBmh3 = false
    /// AW1: this initiator wrote the WIFI marker in its link msg3 / the link peer did.
    public private(set) var sentWifiMarker = false
    public private(set) var peerWifiMarker = false
    /// BMH3 responder only: msg1's tag matched the live verification code (BVMID2).
    public private(set) var qrTagMatched = false
    /// BMH3 only: the authenticated peer of the link handshake.
    public private(set) var bmh3Peer: Bmh3Peer?
    /// A stream reader tightens this before the header and raises it only after a verified audio-only header.
    public var maxIncomingCiphertextBytes = SecureRecordProtocol.maxPlaintextBytes + MeshAead.tagBytes {
        didSet { opener?.maxCiphertextBytes = maxIncomingCiphertextBytes }
    }
    public var acceptDiscoveryOpening = false
    /// Experimental relayed calls: hop type 12 parses while true (a helper's first record, a caller's single reply).
    public var acceptRelaySetup = false { didSet { opener?.acceptRelaySetup = acceptRelaySetup } }
    /// AW1: hop type 16 parses while true (a direct call's Wi-Fi agent opted in).
    public var acceptWifi = false { didSet { opener?.acceptWifi = acceptWifi } }
    /// AW2: the build tag this side asks to sign in its BMH2 link hello (Android raises it on stream hops while a Wi-Fi
    /// switch is on). nil = no tag, every byte as before. Set it before `start` (initiator) or the peer's hello (responder).
    public var ownBuildTag: BuildTag?
    /// AW2: the tag this side's BMH2 link hello actually carried.
    public private(set) var sentBuildTag: BuildTag?
    /// AW2: the tag of the peer's verified BMH2 link hello (Android BuildTag.readFrom); nil without one.
    public private(set) var peerBuildTag: BuildTag?
    /// AW2: derive this BMH2 link's hop key `UW` from its two directional BMS1 keys when they are installed.
    public var deriveHopWifiKey = false
    private var hopWifiKey: Data?
    /// AW2 (Android WifiHopGate.bmh2TagsAllow): both BMH2 link hellos carried a build tag of at least
    /// `WifiWire.firstRelease`. Never true on a BMH3 link.
    public var wifiBuildTagGate: Bool {
        !usedBmh3 && (sentBuildTag?.release ?? 0) >= WifiWire.firstRelease && (peerBuildTag?.release ?? 0) >= WifiWire.firstRelease
    }
    /// AW2: the hop key, handed over once (the link keeps no copy afterwards); nil when it was not derived.
    public func takeHopWifiKey() -> Data? {
        defer { hopWifiKey = nil }
        return hopWifiKey
    }
    public var acceptStoreForward: Bool {
        get { opener?.acceptStoreForward ?? false }
        set { opener?.acceptStoreForward = newValue }
    }

    public init(role: HandshakeRole, identity: SigningIdentity, capabilities: NodeCapabilities, bmh3: Bmh3CallSettings? = nil) {
        self.role = role; self.identity = identity; self.capabilities = capabilities; self.bmh3 = bmh3
        presentedCapabilities = capabilities
    }

    /// EXPERIMENTAL in-call link renewal (Design SR): the renewed hop link of a direct call. No handshake runs on it: the
    /// renewal opening proved the old link's peer and gave these keys. Each direction starts at sequence 0; the peer's
    /// authenticated identity and capabilities are the old link's; nothing else of the old link's BMS1 state carries over
    /// (the AW1 opt-in for hop type 16 is the reader's own and is kept).
    public init(renewing old: SecureLink, sendKey: Data, receiveKey: Data) {
        role = old.role; identity = old.identity; capabilities = old.capabilities; bmh3 = old.bmh3
        presentedCapabilities = old.presentedCapabilities
        peerHello = old.peerHello; peerNodeId = old.peerNodeId; peerCapabilities = old.peerCapabilities
        peerPseudonymous = old.peerPseudonymous; peerRelaySeek = old.peerRelaySeek; ownPseudonymous = old.ownPseudonymous
        usedBmh3 = old.usedBmh3; bmh3Peer = old.bmh3Peer
        sentBuildTag = old.sentBuildTag; peerBuildTag = old.peerBuildTag
        maxIncomingCiphertextBytes = old.maxIncomingCiphertextBytes
        acceptWifi = old.acceptWifi
        sealer = SecureRecordSealer(key: SymmetricKey(data: sendKey))
        let opener = SecureRecordOpener(key: SymmetricKey(data: receiveKey))
        opener.maxCiphertextBytes = maxIncomingCiphertextBytes
        opener.acceptWifi = acceptWifi
        self.opener = opener
    }

    static func frame(_ hello: SignedHandshakeHello) throws -> Data { try frame(bytes: try hello.encoded()) }

    /// AW2 (Android BuildTag.readFrom): the tag of a BMH2 link hello (bit 7 set, nonce bytes 0-1); nil without one.
    static func buildTag(of hello: SignedHandshakeHello) -> BuildTag? {
        guard hello.capabilities.transportMask & NodeCapabilities.transportBuildTag != 0, hello.nonce.count >= 2 else { return nil }
        let nonce = hello.nonce.rebased
        return BuildTag(encoded: UInt16(nonce[0]) << 8 | UInt16(nonce[1]))
    }

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
                                        stranger: try stranger.map { try Bmh3Presentation(identity: $0, capabilities: capabilities, pseudonym: true) },
                                        wifiMarker: bmh3.wifiMarker)
            let tag = bmh3.linkTag && bmh3.linkIdentityOverride == nil ? bmh3.contactTag : nil
            let initiator = Bmh3Initiator(config: config, contactTag: tag, checkResponder: { peer in
                // A recognised contact: the answerer must be that contact (its full node ID), not any key whose RDI matches.
                if let expected = tag?.expectedPeer, peer.nodeId != expected { throw Bmh3Failure("not the expected contact") }
                try bmh3.checkResponder(peer, .link)
            })
            bmh3Initiator = initiator
            return try SecureLink.frame(bytes: try initiator.message1())
        }
        let p = try MeshHandshake.start(identity: identity, role: .initiator, capabilities: capabilities, purpose: .link, ephemeral: ephemeral,
                                        buildTag: ownBuildTag)
        pending = p
        sentBuildTag = SecureLink.buildTag(of: p.hello)
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
        opener.acceptRelaySetup = acceptRelaySetup
        opener.acceptWifi = acceptWifi
        self.opener = opener
        // AW2: a BMH2 hop's UW, derived while its two directional keys exist (BMH3 call hops use the call's UW).
        if deriveHopWifiKey, !usedBmh3 {
            hopWifiKey = try? WifiKeys.uwHop(keyA: keys.sendKey.withUnsafeBytes { Data($0) },
                                             keyB: keys.receiveKey.withUnsafeBytes { Data($0) })
        }
    }

    /// One handshake frame; returns the session keys once the handshake is complete.
    private func handleFrame(_ frame: Data, _ outputs: inout [Output]) throws -> MeshSessionKeys? {
        if let initiator = bmh3Initiator {
            let message3 = try initiator.onMessage2(frame)
            outputs.append(.send(try SecureLink.frame(bytes: message3)))
            let result = try initiator.finalResult()
            sentWifiMarker = bmh3?.wifiMarker ?? false
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
                                        stranger: try bmh3.stranger.map { try Bmh3Presentation(identity: $0, capabilities: strangerCaps, pseudonym: true) },
                                        relaySeek: bmh3.relaySeek)
            let responder = Bmh3Responder(config: config, tagChecks: bmh3.responderTagChecks(), opening: bmh3.opening(), replayCache: bmh3.replayCache,
                                          beforeReply: { matched in try bmh3.beforeReply(tagMatched: matched) },
                                          admitInitiator: { peer, matched in bmh3.admitInitiator(peer.nodeId, tagMatched: matched) })
            bmh3Responder = responder
            outputs.append(.send(try SecureLink.frame(bytes: try responder.onMessage1(frame))))
            return nil
        }
        if role == .responder, let bmh3, bmh3.refusesBmh2 { throw Bmh3Failure("bmh2 refused") }
        let remote = try SignedHandshakeHello(decoding: frame)
        let keys: MeshSessionKeys
        switch role {
        case .initiator:
            guard let pending else { throw ProtocolError.state("Link handshake not started") }
            keys = try MeshHandshake.finish(pending, remote: remote)
        case .responder:
            guard remote.role == .initiator else { throw ProtocolError.state("Expected an initiator handshake") }
            let p = try MeshHandshake.start(identity: identity, role: .responder, capabilities: capabilities, purpose: .link,
                                            buildTag: ownBuildTag)
            sentBuildTag = SecureLink.buildTag(of: p.hello)
            keys = try MeshHandshake.finish(p, remote: remote)
            outputs.append(.send(try SecureLink.frame(p.hello)))
        }
        peerHello = remote
        peerNodeId = remote.nodeId
        peerBuildTag = SecureLink.buildTag(of: remote)
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
        peerRelaySeek = result.peer.relaySeek
        peerWifiMarker = result.peer.extensions.wifiMarker
        ownPseudonymous = result.ownPseudonymous
        qrTagMatched = result.qrTagMatched
        if result.ownPseudonymous && role == .responder { presentedCapabilities.transportMask &= ~NodeCapabilities.transportDiscoveryOpening }
        return MeshSessionKeys(peerNodeId: result.peer.nodeId, sendKey: SymmetricKey(data: result.sendKey), receiveKey: SymmetricKey(data: result.receiveKey))
    }

    public func seal(_ type: SecureRecordType, _ payload: Data) throws -> Data {
        guard let sealer else { throw ProtocolError.state("Link is not authenticated") }
        return try sealer.seal(type, payload)
    }
    public var receivedRecords: UInt64 { opener?.nextSequence ?? 0 }
    /// Bytes of an incomplete record waiting in the opener; nil before the handshake installed it.
    public var bufferedRecordBytes: Int? { opener?.bufferedBytes }
}
