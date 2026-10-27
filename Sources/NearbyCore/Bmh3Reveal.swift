import Foundation

// EXPERIMENTAL rotating discovery IDs (phase 1b) and BMH3 pseudonyms (phase 2): the endpoint container BDX1 (BME1
// content type 11, calls only, sent only when both endpoint hellos carry bit 3) and the identity reveal of a
// pseudonymous session (Android PresenceLeases.kt DiscoveryExchange, Bmh3Reveal.kt; Android protocol reference "BDX1 formats" and
// "Phase 2: pseudonymous stranger identities").

/// `"BDX1" | kind | body`: 1 OPENING, 2 RECOGNITION_OFFER, 3 PRESENCE_LEASE, 4 IDENTITY_REVEAL. Strict decode.
public enum DiscoveryExchange {
    public static let magic = Data("BDX1".utf8)
    public static let kindOpening: UInt8 = 1, kindRecognitionOffer: UInt8 = 2, kindPresenceLease: UInt8 = 3, kindIdentityReveal: UInt8 = 4
    public static let leaseBytes = 32, maxLeases = 28

    public struct IdentityReveal: Equatable {
        public static let roleCaller: UInt8 = 1, roleCallee: UInt8 = 2
        public let role: UInt8
        public let spki: Data
        public let entries: [OpeningEntry]
        public let signature: Data
        public init(role: UInt8, spki: Data, entries: [OpeningEntry], signature: Data) throws {
            guard role == Self.roleCaller || role == Self.roleCallee else { throw ProtocolError.malformed("Invalid reveal role") }
            guard spki.count == Bmh3Wire.spkiBytes, signature.count == Bmh3Wire.signatureBytes else { throw ProtocolError.malformed("Invalid reveal lengths") }
            guard entries.count <= DiscoveryOpeningCodec.maxEntries else { throw ProtocolError.malformed("At most two opening entries") }
            guard role == Self.roleCallee || entries.isEmpty else { throw ProtocolError.malformed("Only the callee opens a rotating ID") }
            self.role = role; self.spki = spki.rebased; self.entries = entries; self.signature = signature.rebased
        }
    }

    public struct PresenceLease: Equatable {
        public let generation: UInt32, senderEpoch: UInt32, firstDay: UInt32
        public let leases: [Data]
    }

    public enum Record: Equatable {
        case opening([OpeningEntry])
        case recognitionOffer
        case presenceLease(PresenceLease)
        case identityReveal(IdentityReveal)
    }

    /// The BDO1 body after its version byte: `count | entries`.
    static func openingBody(_ entries: [OpeningEntry]) throws -> Data {
        try DiscoveryOpeningCodec.encode(entries).suffix(from: DiscoveryOpeningCodec.magic.count + 1).rebased
    }

    static func entries(fromBody body: Data) throws -> [OpeningEntry] {
        try DiscoveryOpeningCodec.decode(DiscoveryOpeningCodec.magic + Data([DiscoveryOpeningCodec.version]) + body)
    }

    public static func encode(_ record: Record) throws -> Data {
        var w = BinaryWriter(); w.bytes(magic)
        switch record {
        case .opening(let entries): w.byte(kindOpening); w.bytes(try openingBody(entries))
        case .recognitionOffer: w.byte(kindRecognitionOffer); w.byte(0)
        case .presenceLease(let lease):
            w.byte(kindPresenceLease); w.u32(lease.generation); w.u32(lease.senderEpoch); w.u32(lease.firstDay)
            w.byte(UInt8(lease.leases.count)); for key in lease.leases { w.bytes(key) }
        case .identityReveal(let reveal):
            w.byte(kindIdentityReveal); w.byte(reveal.role); w.u16(UInt16(Bmh3Wire.spkiBytes)); w.bytes(reveal.spki)
            w.bytes(try openingBody(reveal.entries)); w.bytes(reveal.signature)
        }
        return w.data
    }

    public static func decode(_ raw: Data) throws -> Record {
        let bytes = raw.rebased
        guard bytes.count >= magic.count + 2, bytes.prefix(4).rebased == magic else { throw ProtocolError.malformed("Not a BDX1 record") }
        let kind = bytes[4]
        let body = bytes.suffix(from: 5).rebased
        switch kind {
        case kindOpening: return .opening(try entries(fromBody: body))
        case kindRecognitionOffer:
            guard body == Data([0]) else { throw ProtocolError.malformed("Invalid recognition offer") }
            return .recognitionOffer
        case kindPresenceLease:
            var r = BinaryReader(body)
            let generation = try r.u32(), senderEpoch = try r.u32(), firstDay = try r.u32()
            let count = Int(try r.byte())
            guard generation >= 1 else { throw ProtocolError.malformed("Presence lease generation must be at least 1") }
            guard (1...maxLeases).contains(count), r.remaining == count * leaseBytes else { throw ProtocolError.malformed("Invalid presence lease length") }
            return .presenceLease(PresenceLease(generation: generation, senderEpoch: senderEpoch, firstDay: firstDay,
                                                leases: try (0..<count).map { _ in try r.bytes(leaseBytes) }))
        case kindIdentityReveal:
            let fixed = magic.count + 1 + 1 + 2 + Bmh3Wire.spkiBytes + 1
            guard bytes.count >= fixed + Bmh3Wire.signatureBytes else { throw ProtocolError.malformed("Reveal too short") }
            let role = bytes[5]
            guard Int(bytes[6]) << 8 | Int(bytes[7]) == Bmh3Wire.spkiBytes else { throw ProtocolError.malformed("Invalid reveal identity length") }
            let spki = bytes.subdata(in: 8..<(8 + Bmh3Wire.spkiBytes))
            let count = Int(bytes[8 + Bmh3Wire.spkiBytes])
            guard count <= DiscoveryOpeningCodec.maxEntries else { throw ProtocolError.malformed("Too many opening entries") }
            guard bytes.count == fixed + count * OpeningEntry.bytes + Bmh3Wire.signatureBytes else { throw ProtocolError.malformed("Invalid reveal length") }
            let entries = try entries(fromBody: bytes.subdata(in: (8 + Bmh3Wire.spkiBytes)..<(fixed + count * OpeningEntry.bytes)))
            return .identityReveal(try IdentityReveal(role: role, spki: spki, entries: entries, signature: bytes.suffix(Bmh3Wire.signatureBytes).rebased))
        default:
            throw ProtocolError.malformed("Unknown BDX1 kind \(kind)")
        }
    }
}

/// The identity reveal (BDX1 kind 4): message construction, signature input and verification.
public enum Bmh3Reveal {
    public static let domain = Data("BluetoothVideoMesh/BMH3/Reveal/1".utf8)
    static let keyInfo = Data("BluetoothVideoMesh/BMH3/Reveal/1 key".utf8)

    /// A reveal that passed the signature check; the caller still runs the identity gate and the discovery binding.
    public struct Verified: Equatable {
        public let spki: Data
        public let nodeId: NodeId
        public let entries: [OpeningEntry]
        public var fingerprint: IdentityFingerprint { IdentityFingerprint(publicKey: spki) }
    }

    static func roleName(_ role: UInt8) -> String { role == DiscoveryExchange.IdentityReveal.roleCaller ? "Caller" : "Callee" }

    /// `D "/" Role " signature" 0x00 TH_R`, with `TH_R = SHA-256(D | 0x00 | role | K | SHA-256(own pseudonym SPKI) |
    /// SHA-256(peer pseudonym SPKI) | SPKI | prior | opening body)` and `K = HKDF-Expand(EXP, "... key")`.
    public static func signingInput(role: UInt8, exporter: Data, ownPseudonymSpki: Data, peerPseudonymSpki: Data,
                                    realSpki: Data, entries: [OpeningEntry], prior: Data) throws -> Data {
        guard exporter.count == 32, realSpki.count == Bmh3Wire.spkiBytes, prior.isEmpty || prior.count == 32 else {
            throw Bmh3Failure("reveal input lengths")
        }
        let key = Bmh3Crypto.expand(exporter, keyInfo)
        let th = Bmh3Crypto.sha256(domain + Data([0, role]) + key + Bmh3Crypto.sha256(ownPseudonymSpki) + Bmh3Crypto.sha256(peerPseudonymSpki)
                                   + realSpki + prior + (try DiscoveryExchange.openingBody(entries)))
        return domain + Data("/\(roleName(role)) signature".utf8) + Data([0]) + th
    }

    /// This phone's reveal, signed with its real identity. `entries` are the callee's pinned opening entries.
    public static func build(role: UInt8, real: SigningIdentity, exporter: Data, ownPseudonymSpki: Data, peerPseudonymSpki: Data,
                             entries: [OpeningEntry], prior: Data) throws -> DiscoveryExchange.IdentityReveal {
        guard Bmh3Crypto.isCanonicalSpki(real.publicKeyEncoded) else { throw Bmh3Failure("identity key is not the canonical P-256 SPKI") }
        let input = try signingInput(role: role, exporter: exporter, ownPseudonymSpki: ownPseudonymSpki, peerPseudonymSpki: peerPseudonymSpki,
                                     realSpki: real.publicKeyEncoded, entries: entries, prior: prior)
        return try DiscoveryExchange.IdentityReveal(role: role, spki: real.publicKeyEncoded, entries: entries,
                                                    signature: try Bmh3Crypto.derToRaw(try real.sign(input)))
    }

    /// Verifies `reveal` as the peer's: role, canonical SPKI, signature over this session's exporter and the peer's own
    /// pseudonym, and that the real key is neither the pseudonym nor one of this phone's keys.
    public static func verify(_ reveal: DiscoveryExchange.IdentityReveal, expectedRole: UInt8, exporter: Data, peerPseudonymSpki: Data,
                              ownPseudonymSpki: Data, ownSpkis: [Data], prior: Data) throws -> Verified {
        guard reveal.role == expectedRole else { throw Bmh3Failure("reveal role") }
        guard Bmh3Crypto.isCanonicalSpki(reveal.spki) else { throw Bmh3Failure("reveal identity key invalid") }
        guard reveal.spki != peerPseudonymSpki else { throw Bmh3Failure("reveal names the pseudonym") }
        guard !ownSpkis.contains(reveal.spki) else { throw Bmh3Failure("reveal names this phone") }
        let input = try signingInput(role: expectedRole, exporter: exporter, ownPseudonymSpki: peerPseudonymSpki, peerPseudonymSpki: ownPseudonymSpki,
                                     realSpki: reveal.spki, entries: reveal.entries, prior: prior)
        guard try Bmh3Crypto.verify(spki: reveal.spki, message: input, raw: reveal.signature) else { throw Bmh3Failure("reveal signature") }
        return Verified(spki: reveal.spki, nodeId: NodeId.fromPublicKey(reveal.spki), entries: reveal.entries)
    }
}

/// The reveal exchange of one end-to-end session (Android Bmh3RevealSession). A phone reveals only to a peer that declared
/// a pseudonym itself, the callee only after its user accepted, the caller only after it verified the callee's reveal and
/// its binding. At most one reveal per direction.
public final class Bmh3RevealSession {
    public let localRole: UInt8
    public let ownPseudonymous: Bool
    public let peerPseudonymous: Bool
    private let exporter: Data
    private let ownPseudonymSpki: Data
    private let peerPseudonymSpki: Data
    private let ownSpkis: [Data]
    public private(set) var ownRevealSent = false
    public private(set) var revealed: Bmh3Reveal.Verified?
    private var failed = false
    /// SHA-256 of the callee's reveal record: the caller's reveal binds it.
    private var calleeRecordHash: Data?

    public init(localRole: UInt8, exporter: Data, ownPseudonymSpki: Data, peerPseudonymSpki: Data,
                ownPseudonymous: Bool, peerPseudonymous: Bool, ownSpkis: [Data]? = nil) {
        precondition(localRole == DiscoveryExchange.IdentityReveal.roleCaller || localRole == DiscoveryExchange.IdentityReveal.roleCallee)
        self.localRole = localRole; self.exporter = exporter.rebased
        self.ownPseudonymSpki = ownPseudonymSpki.rebased; self.peerPseudonymSpki = peerPseudonymSpki.rebased
        self.ownPseudonymous = ownPseudonymous; self.peerPseudonymous = peerPseudonymous
        self.ownSpkis = ownSpkis ?? [ownPseudonymSpki]
    }

    private var isCaller: Bool { localRole == DiscoveryExchange.IdentityReveal.roleCaller }
    private var peerRole: UInt8 { isCaller ? DiscoveryExchange.IdentityReveal.roleCallee : DiscoveryExchange.IdentityReveal.roleCaller }

    /// True when the peer declared a pseudonym: a reveal from it is expected and one to it is understood.
    public var active: Bool { peerPseudonymous }

    /// The caller may reveal itself only after the callee's reveal was verified (and the caller ran the binding).
    public var callerMayReveal: Bool { isCaller && ownPseudonymous && peerPseudonymous && revealed != nil && !ownRevealSent && !failed }

    /// True while a reveal from the peer is required before the call may proceed: the callee's, seen by a caller, and
    /// the caller's, seen by a callee that is itself pseudonymous. Such a caller always reveals right after it verified
    /// the callee's reveal, ahead of its stream header in the same ordered queue; without this rule a caller could stay
    /// a throwaway for a whole answered call.
    public var peerRevealRequired: Bool { peerPseudonymous && revealed == nil && (isCaller || ownPseudonymous) }

    /// Builds this phone's encoded reveal record; throws when the rules do not allow it or it was already sent.
    public func sendOwn(real: SigningIdentity, entries: [OpeningEntry]) throws -> Data {
        guard ownPseudonymous, peerPseudonymous else { throw Bmh3Failure("no reveal to a peer that did not declare a pseudonym") }
        guard !ownRevealSent else { throw Bmh3Failure("reveal already sent") }
        guard !failed else { throw Bmh3Failure("reveal exchange failed") }
        if isCaller && revealed == nil { throw Bmh3Failure("caller reveals only after the callee") }
        if isCaller && !entries.isEmpty { throw Bmh3Failure("only the callee opens a rotating ID") }
        let prior = isCaller ? (calleeRecordHash ?? Data()) : Data()
        let record = try Bmh3Reveal.build(role: localRole, real: real, exporter: exporter, ownPseudonymSpki: ownPseudonymSpki,
                                          peerPseudonymSpki: peerPseudonymSpki, entries: entries, prior: prior)
        let encoded = try DiscoveryExchange.encode(.identityReveal(record))
        if !isCaller { calleeRecordHash = Bmh3Crypto.sha256(encoded) }
        ownRevealSent = true
        return encoded
    }

    /// Processes the peer's reveal record; throws (the call ends) for a reveal from a peer that did not declare a pseudonym,
    /// a second one, a wrong role or signature, or a caller reveal before this callee sent its own.
    public func onPeerReveal(_ record: DiscoveryExchange.IdentityReveal) throws -> Bmh3Reveal.Verified {
        do {
            guard peerPseudonymous else { throw Bmh3Failure("reveal from a peer that did not declare a pseudonym") }
            guard revealed == nil else { throw Bmh3Failure("second reveal") }
            if !isCaller && !ownRevealSent { throw Bmh3Failure("caller reveal before the callee's") }
            let prior = isCaller ? Data() : (calleeRecordHash ?? Data())
            let verified = try Bmh3Reveal.verify(record, expectedRole: peerRole, exporter: exporter, peerPseudonymSpki: peerPseudonymSpki,
                                                 ownPseudonymSpki: ownPseudonymSpki, ownSpkis: ownSpkis, prior: prior)
            if isCaller { calleeRecordHash = Bmh3Crypto.sha256(try DiscoveryExchange.encode(.identityReveal(record))) }
            revealed = verified
            return verified
        } catch {
            failed = true
            throw error
        }
    }
}

/// The callee of a pseudonym-pseudonym call requires the caller's reveal: it reveals itself at Accept, holds its own
/// camera and microphone and refuses the caller's media until the caller's reveal verified (media before it ends the
/// call), and hangs up when the reveal has not arrived `deadline` after Accept.
public enum CallerRevealGate {
    /// One ECDSA verification and one signature plus a round trip on the caller's side; the same 10 s bound as the
    /// hop handshake deadline, not a measured limit.
    public static let deadline: TimeInterval = 10
    public static let message = "The caller did not confirm its identity. The call was ended."

    /// True when the call must end now: the reveal is still pending `deadline` after `acceptedAt`.
    public static func expired(revealPending: Bool, acceptedAt: TimeInterval, now: TimeInterval) -> Bool {
        revealPending && now - acceptedAt >= deadline
    }
}
