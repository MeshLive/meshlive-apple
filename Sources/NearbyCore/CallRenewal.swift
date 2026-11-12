import Foundation
import CryptoKit

// EXPERIMENTAL in-call link renewal (Design SR; Android protocol reference "Experimental in-call link renewal"; Apple
// switch `appleLinkRenewal`, off). The pure parts: the `RENEW` record codec, `K_renew`, the advert UUID, the opening
// frames and MACs, the new link's hop keys, the scope check, the stall verdict and the two state machines. No radio
// and no clock of their own: every time is the caller's `now` (seconds, the transport driver's monotonic clock).

/// End-to-end hello bit 4 and BME1 content type 12 `RENEW` (exact lengths; anything else fails closed).
public enum CallRenewalWire {
    /// End-to-end hello transport-mask bit 4: "sends and accepts content type 12 and the renewal opening".
    public static let capabilityBit: UInt8 = 1 << 4

    public enum Op: UInt8 { case offer = 1, armed = 2, refused = 3, bind = 4 }

    public enum Reason: UInt8, CaseIterable {
        case notDirect = 1, limit = 2, serverRegistration = 3, advertising = 4, collision = 5, disabled = 6
        /// Sent by the offerer: it kept the old link (the peer was heard again); the armed phone disarms.
        case abandoned = 7
        /// The log word (Android's enum name in lower case).
        public var label: String {
            switch self {
            case .notDirect: return "not_direct"
            case .limit: return "limit"
            case .serverRegistration: return "server_registration"
            case .advertising: return "advertising"
            case .collision: return "collision"
            case .disabled: return "disabled"
            case .abandoned: return "abandoned"
            }
        }
    }

    public enum Message: Equatable {
        /// `role` 0 = end-to-end initiator (caller), 1 = responder.
        case offer(ticket: UInt64, role: UInt8)
        case armed(ticket: UInt64)
        case refused(ticket: UInt64, reason: Reason)
        /// `nextSequence` = the `BME1` sequence of this BIND record plus one.
        case bind(ticket: UInt64, nextSequence: UInt64)

        public var ticket: UInt64 {
            switch self {
            case .offer(let t, _), .armed(let t), .refused(let t, _), .bind(let t, _): return t
            }
        }
    }

    public static func advertise(_ caps: NodeCapabilities, enabled: Bool) -> NodeCapabilities {
        var c = caps
        if enabled { c.transportMask |= capabilityBit }
        return c
    }

    public static func negotiated(enabled: Bool, peer: NodeCapabilities) -> Bool { enabled && peer.transportMask & capabilityBit != 0 }

    /// Both end-to-end hellos signed bit 4: only then does a session derive `K_renew`.
    public static func bothSigned(local: NodeCapabilities, peer: NodeCapabilities) -> Bool {
        local.transportMask & capabilityBit != 0 && peer.transportMask & capabilityBit != 0
    }

    public static func encode(_ message: Message) throws -> Data {
        guard message.ticket != 0 else { throw ProtocolError.malformed("A renewal ticket is never zero") }
        var w = BinaryWriter(capacity: 17)
        switch message {
        case .offer(let ticket, let role):
            guard role <= 1 else { throw ProtocolError.malformed("Invalid renewal role") }
            w.byte(Op.offer.rawValue); w.u64(ticket); w.byte(role)
        case .armed(let ticket):
            w.byte(Op.armed.rawValue); w.u64(ticket)
        case .refused(let ticket, let reason):
            w.byte(Op.refused.rawValue); w.u64(ticket); w.byte(reason.rawValue)
        case .bind(let ticket, let next):
            guard next > 0, next <= UInt64(Int64.max) else { throw ProtocolError.malformed("Invalid renewal sequence") }
            w.byte(Op.bind.rawValue); w.u64(ticket); w.u64(next)
        }
        return w.data
    }

    /// Exact lengths; an unknown op, another length, a zero ticket, a role above 1, a reason outside 1..7 or a BIND
    /// sequence of 0 (or above the signed 64-bit range Android reads) is malformed.
    public static func decode(_ payload: Data) throws -> Message {
        let p = payload.rebased
        guard let first = p.first else { throw ProtocolError.malformed("Empty renewal record") }
        guard let op = Op(rawValue: first) else { throw ProtocolError.malformed("Unknown renewal op \(first)") }
        let expected: Int
        switch op {
        case .offer, .refused: expected = 10
        case .armed: expected = 9
        case .bind: expected = 17
        }
        guard p.count == expected else { throw ProtocolError.malformed("Invalid renewal record length \(p.count) for op \(first)") }
        var r = BinaryReader(p.dropFirst().rebased)
        let ticket = try r.u64()
        guard ticket != 0 else { throw ProtocolError.malformed("Zero renewal ticket") }
        switch op {
        case .offer:
            let role = try r.byte()
            guard role <= 1 else { throw ProtocolError.malformed("Invalid renewal role \(role)") }
            return .offer(ticket: ticket, role: role)
        case .armed:
            return .armed(ticket: ticket)
        case .refused:
            let value = try r.byte()
            guard let reason = Reason(rawValue: value) else { throw ProtocolError.malformed("Invalid renewal reason \(value)") }
            return .refused(ticket: ticket, reason: reason)
        case .bind:
            let next = try r.u64()
            guard next > 0, next <= UInt64(Int64.max) else { throw ProtocolError.malformed("Invalid renewal sequence") }
            return .bind(ticket: ticket, nextSequence: next)
        }
    }
}

/// `K_renew`, held only in memory with its call's end-to-end session and zeroed when the session closes.
public final class CallRenewalKey {
    private var bytes: [UInt8]
    public private(set) var zeroed = false
    init(_ data: Data) { bytes = [UInt8](data) }
    deinit { zero() }
    /// A copy for one computation (the caller drops it at once).
    var data: Data { Data(bytes) }
    public func zero() {
        for i in bytes.indices { bytes[i] = 0 }
        zeroed = true
    }
}

/// `K_renew`, the advert UUID, the opening MACs and the new link's hop keys (protocol reference "Renewal key", "Advert",
/// "Renewal opening"). HKDF is RFC 5869 with SHA-256; tickets and sequences are big-endian.
public enum CallRenewalCrypto {
    static let salt = Data("BluetoothVideoMesh/SR1".utf8)
    static let keyInfo = Data("renew-key".utf8)
    static let srv = Data("SR1 srv".utf8)
    static let offerLabel = Data("SR1 offer".utf8)
    static let armedLabel = Data("SR1 armed".utf8)
    static let hopLabel = Data("SR1 hop".utf8)
    public static let keyBytes = 32
    public static let macBytes = 32
    public static let randomBytesCount = 16

    /// Both endpoints get the same key from their two directional content keys, without knowing their role.
    public static func renewalKey(_ k1: Data, _ k2: Data) throws -> Data {
        guard k1.count == keyBytes, k2.count == keyBytes else { throw ProtocolError.state("Renewal key input must be two 32-byte keys") }
        let (low, high) = keyPrecedes(k2, k1) ? (k2, k1) : (k1, k2)
        return hkdf(low + high, salt: salt, info: keyInfo, count: keyBytes)
    }

    public static func advertUuid(key: Data, callId: UUID, ticket: UInt64) -> UUID {
        var bytes = [UInt8](hmac(key, srv, uuidBytes(callId), ticketBytes(ticket)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    public static func offerMac(key: Data, callId: UUID, ticket: UInt64, challenge: Data, nonce: Data) -> Data {
        hmac(key, offerLabel, uuidBytes(callId), ticketBytes(ticket), challenge, nonce)
    }

    public static func armedMac(key: Data, callId: UUID, ticket: UInt64, challenge: Data, nonce: Data) -> Data {
        hmac(key, armedLabel, uuidBytes(callId), ticketBytes(ticket), challenge, nonce)
    }

    /// `toArmed`: the offerer -> armed direction (bytes 0-31); `toOfferer`: armed -> offerer (bytes 32-63).
    public static func hopKeys(key: Data, callId: UUID, ticket: UInt64, challenge: Data, nonce: Data) -> (toArmed: Data, toOfferer: Data) {
        let material = hkdf(key, salt: challenge + nonce, info: hopLabel + uuidBytes(callId) + ticketBytes(ticket), count: keyBytes * 2)
        return (material.prefix(keyBytes).rebased, material.suffix(keyBytes).rebased)
    }

    static func hkdf(_ ikm: Data, salt: Data, info: Data, count: Int) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: count)
            .withUnsafeBytes { Data($0) }
    }

    static func hmac(_ key: Data, _ parts: Data...) -> Data {
        var mac = HMAC<SHA256>(key: SymmetricKey(data: key))
        for part in parts { mac.update(data: part) }
        return Data(mac.finalize())
    }

    static func uuidBytes(_ id: UUID) -> Data { withUnsafeBytes(of: id.uuid) { Data($0) } }

    static func ticketBytes(_ ticket: UInt64) -> Data { var w = BinaryWriter(capacity: 8); w.u64(ticket); return w.data }

    /// Unsigned byte order of two equal-length keys.
    private static func keyPrecedes(_ a: Data, _ b: Data) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x < y }
        return false
    }

    /// A fresh non-zero ticket.
    public static func newTicket() -> UInt64 {
        while true {
            let value = randomBytes(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            if value != 0 { return value }
        }
    }
}

/// The three fixed-length frames of the renewal opening, before any `BMS1` byte on the new link.
public enum CallRenewalFrames {
    static let challengeMagic = Data("SR1C".utf8)
    static let proofMagic = Data("SR1P".utf8)
    static let confirmMagic = Data("SR1A".utf8)
    public static let challengeBytes = 4 + CallRenewalCrypto.randomBytesCount
    public static let proofBytes = 4 + 8 + CallRenewalCrypto.randomBytesCount + CallRenewalCrypto.macBytes
    public static let confirmBytes = 4 + CallRenewalCrypto.macBytes

    public struct Proof: Equatable { public let ticket: UInt64; public let nonce: Data; public let mac: Data }

    public static func challenge(_ challenge: Data) -> Data {
        precondition(challenge.count == CallRenewalCrypto.randomBytesCount)
        return challengeMagic + challenge
    }

    public static func parseChallenge(_ frame: Data) throws -> Data {
        let f = frame.rebased
        guard f.count == challengeBytes, f.prefix(4) == challengeMagic else { throw ProtocolError.malformed("Invalid renewal challenge") }
        return f.suffix(CallRenewalCrypto.randomBytesCount).rebased
    }

    public static func proof(ticket: UInt64, nonce: Data, mac: Data) -> Data {
        precondition(nonce.count == CallRenewalCrypto.randomBytesCount && mac.count == CallRenewalCrypto.macBytes)
        return proofMagic + CallRenewalCrypto.ticketBytes(ticket) + nonce + mac
    }

    public static func parseProof(_ frame: Data) throws -> Proof {
        let f = frame.rebased
        guard f.count == proofBytes, f.prefix(4) == proofMagic else { throw ProtocolError.malformed("Invalid renewal proof") }
        var r = BinaryReader(f.dropFirst(4).rebased)
        let ticket = try r.u64()
        guard ticket != 0 else { throw ProtocolError.malformed("Zero renewal ticket") }
        let nonce = try r.bytes(CallRenewalCrypto.randomBytesCount)
        let mac = try r.bytes(CallRenewalCrypto.macBytes)
        return Proof(ticket: ticket, nonce: nonce, mac: mac)
    }

    public static func confirm(_ mac: Data) -> Data {
        precondition(mac.count == CallRenewalCrypto.macBytes)
        return confirmMagic + mac
    }

    public static func parseConfirm(_ frame: Data) throws -> Data {
        let f = frame.rebased
        guard f.count == confirmBytes, f.prefix(4) == confirmMagic else { throw ProtocolError.malformed("Invalid renewal confirmation") }
        return f.suffix(CallRenewalCrypto.macBytes).rebased
    }
}

/// Which calls may renew (protocol reference "Scope (checked, not assumed)") and the per-call limits.
public enum CallRenewalScope {
    public static let minActive: TimeInterval = 10
    public static let maxAttempts = 2
    public static let minInterval: TimeInterval = 60

    public struct Facts: Equatable {
        public var gattOnBothEnds: Bool
        public var relayHops: Int
        public var relayedRoute: Bool
        public var linkPeerIsEndpointPeer: Bool
        public var verificationSession: Bool
        public init(gattOnBothEnds: Bool, relayHops: Int, relayedRoute: Bool, linkPeerIsEndpointPeer: Bool, verificationSession: Bool) {
            self.gattOnBothEnds = gattOnBothEnds; self.relayHops = relayHops; self.relayedRoute = relayedRoute
            self.linkPeerIsEndpointPeer = linkPeerIsEndpointPeer; self.verificationSession = verificationSession
        }
    }

    /// A direct call: the hop peer is the end-to-end peer, over GATT, not a verification session.
    public static func direct(_ facts: Facts) -> Bool {
        facts.gattOnBothEnds && facts.relayHops == 0 && !facts.relayedRoute && facts.linkPeerIsEndpointPeer && !facts.verificationSession
    }

    /// Nil: the renewal may run now. Otherwise the reason an armed phone answers (or an offerer does not offer).
    public static func refusal(enabled: Bool, negotiated: Bool, facts: Facts, phaseActive: Bool, activeFor: TimeInterval,
                               attempts: Int, sinceLastAttempt: TimeInterval?) -> CallRenewalWire.Reason? {
        if !enabled || !negotiated { return .disabled }
        if !direct(facts) { return .notDirect }
        if !phaseActive || activeFor < minActive || attempts >= maxAttempts { return .limit }
        if let since = sinceLastAttempt, since < minInterval { return .limit }
        return nil
    }
}

/// Android's call stall tolerance, used while a renewal is possible: "Poor" after 3 s of silence (the renewal's soft
/// state), the 8 s close kept up to 14 s while this phone's own writes still complete (one finished within 2 s).
public enum RenewalStall {
    public static let silenceLimit: TimeInterval = 8
    public static let poorAfter: TimeInterval = 3
    public static let tolerance: TimeInterval = 14
    public static let sendFresh: TimeInterval = 2

    public enum Verdict: Equatable { case ok, poor, end }

    public static func verdict(enabled: Bool, now: TimeInterval, lastReceived: TimeInterval, lastSendProgress: TimeInterval) -> Verdict {
        let silent = now - lastReceived
        if !enabled { return silent >= silenceLimit ? .end : .ok }
        if silent < poorAfter { return .ok }
        if silent < silenceLimit { return .poor }
        let sending = now - lastSendProgress < sendFresh
        return sending && silent < tolerance ? .poor : .end
    }

    /// The offerer's soft state: no record for 3 s while this phone's own writes still complete.
    public static func soft(now: TimeInterval, lastReceived: TimeInterval, lastSendProgress: TimeInterval) -> Bool {
        verdict(enabled: true, now: now, lastReceived: lastReceived, lastSendProgress: lastSendProgress) == .poor
            && now - lastSendProgress < sendFresh
    }
}

/// The offerer: the phone that stopped hearing its peer while its own writes complete. It keeps the old link until it
/// sees the armed advert, and every path ends within `hardBound` of the OFFER.
public final class RenewalOfferer {
    public enum Phase: Equatable { case idle, scanning, waitingOldLink, connecting, bound, abandoned, failed }
    public enum Tick: Equatable { case none, stopScan, endCall }

    /// Offer after 1 s of the soft state (4 s of silence): a false trigger costs a scan, not the call.
    public static let softHold: TimeInterval = 1
    public static let scanWindow: TimeInterval = 6
    /// No connect starts after OFFER + 11 s (Android `LAST_CONNECT_MS`).
    public static let lastConnect: TimeInterval = 11
    public static let hardBound: TimeInterval = 12

    public private(set) var phase: Phase = .idle
    public private(set) var ticket: UInt64 = 0
    public private(set) var offeredAt: TimeInterval = 0

    public init() {}

    /// The soft state has lasted long enough to offer.
    public func shouldTrigger(softSince: TimeInterval?, now: TimeInterval) -> Bool {
        guard phase == .idle, let softSince else { return false }
        return now - softSince >= Self.softHold
    }

    public func offer(ticket: UInt64, now: TimeInterval) {
        precondition(phase == .idle && ticket != 0)
        self.ticket = ticket; offeredAt = now; phase = .scanning
    }

    /// The renewal owns the call's liveness while it scans, connects or has just bound (until the switch reset the
    /// timers); once the scan ended without a sighting (or the peer refused) the normal rules apply again.
    public var ownsLiveness: Bool { phase == .scanning || phase == .connecting || phase == .bound }

    /// A record other than `RENEW` arrived on the old link: true when the renewal is abandoned (old link kept).
    public func onPeerHeard() -> Bool {
        guard phase == .scanning || phase == .waitingOldLink else { return false }
        phase = .abandoned
        return true
    }

    /// The armed advert was seen: true means break the old link now and connect (only inside the scan window).
    public func onAdvertFound(now: TimeInterval) -> Bool {
        guard phase == .scanning, now - offeredAt < Self.scanWindow else { return false }
        phase = .connecting
        return true
    }

    /// Another connect attempt is still allowed (a failure before CONFIRM, a squatter, a copied advert).
    public func mayRetry(now: TimeInterval) -> Bool { phase == .connecting && now - offeredAt < Self.lastConnect }

    /// What a connect attempt (GATT open plus opening) may still take: up to `lastConnect` after the OFFER, never past it.
    public func connectBudget(now: TimeInterval) -> TimeInterval {
        phase == .connecting ? max(0, offeredAt + Self.lastConnect - now) : 0
    }

    /// A collision counts only while this phone's own offer still scans.
    public var ownOfferPending: Bool { phase == .scanning }

    /// The opening proved the armed phone: true when BIND may go now (checked before it is sent).
    public func onBound(now: TimeInterval) -> Bool {
        guard phase == .connecting, now - offeredAt < Self.hardBound else { return false }
        phase = .bound
        return true
    }

    /// The peer refused: the renewal is over and the old link stays.
    public func onRefused() -> Bool {
        guard phase == .scanning || phase == .waitingOldLink else { return false }
        phase = .waitingOldLink
        return true
    }

    /// Collision: this phone (the callee) yields its own offer and arms for the caller's.
    public func yieldToPeer() -> Bool {
        guard phase == .scanning else { return false }
        phase = .abandoned
        return true
    }

    public func tick(now: TimeInterval) -> Tick {
        let elapsed = now - offeredAt
        if (phase == .scanning || phase == .connecting) && elapsed >= Self.hardBound { phase = .failed; return .endCall }
        if phase == .scanning && elapsed >= Self.scanWindow { phase = .waitingOldLink; return .stopScan }
        return .none
    }

    /// A finished renewal (bound, abandoned or refused) lets the next one start, within the call's limits.
    public func reset() {
        if phase == .bound || phase == .abandoned || phase == .waitingOldLink { phase = .idle }
    }
}

/// Collision: both phones offered. The caller (role 0) keeps its offer; the callee yields and arms.
public enum RenewalCollision {
    public static func keepOwn(ownRole: UInt8) -> Bool { ownRole == 0 }
}

/// The armed phone: it still hears its peer but its own sending stalled. One attempt per OFFER: an advert, a challenge
/// per connection, one consumed ticket, one BIND on the proved connection.
public final class RenewalArmed {
    public enum Phase: Equatable { case idle, arming, armed, bound, disarmed, failed }
    public enum Tick: Equatable { case none, refuseRegistration, stopAdvert, disarm, endCall }
    public enum Admission: Equatable { case challenge(Int), drop }
    public enum ProofResult: Equatable { case confirm, drop }
    public enum BindResult: Equatable { case accept, ignore }

    public static let registration: TimeInterval = 3
    public static let proofWindow: TimeInterval = 1
    public static let advertWindow: TimeInterval = 7
    public static let hardBound: TimeInterval = 12
    public static let maxConnections = 8

    public private(set) var phase: Phase = .idle
    public private(set) var ticket: UInt64 = 0
    public private(set) var receivedAt: TimeInterval = 0
    public private(set) var advertising = false
    private var connections = 0
    private var challengedAt: [Int: TimeInterval] = [:]
    public private(set) var provedConnection: Int?
    private var ticketUsed = false

    public init() {}

    /// OFFER arrived; `refusal` is the scope answer. True: arm (advertise and listen).
    public func onOffer(ticket: UInt64, refusal: CallRenewalWire.Reason?, now: TimeInterval) -> Bool {
        guard refusal == nil, phase != .arming, phase != .armed else { return false }
        self.ticket = ticket; receivedAt = now; phase = .arming; advertising = false
        connections = 0; challengedAt = [:]; provedConnection = nil; ticketUsed = false
        return true
    }

    /// The listener and the advert are up. False: too late (refused already) or not arming; close what was opened.
    public func onServerReady(now: TimeInterval) -> Bool {
        guard phase == .arming, now - receivedAt < Self.registration else { return false }
        phase = .armed; advertising = true
        return true
    }

    public func onServerFailed() { if phase == .arming { phase = .disarmed } }

    /// The liveness hang-up and old-link failures are part of the renewal while this holds.
    public var suspendsLiveness: Bool { phase == .arming || phase == .armed || phase == .bound }

    public func onConnection(_ id: Int, now: TimeInterval) -> Admission {
        guard phase == .armed, provedConnection == nil, connections < Self.maxConnections else { return .drop }
        connections += 1
        challengedAt[id] = now
        return .challenge(id)
    }

    /// True when `id` has had its challenge for `proofWindow` without a valid proof: drop it (squatter).
    public func proofOverdue(_ id: Int, now: TimeInterval) -> Bool {
        guard let at = challengedAt[id] else { return false }
        return provedConnection != id && now - at >= Self.proofWindow
    }

    public func onProof(_ id: Int, ticket: UInt64, valid: Bool, now: TimeInterval) -> ProofResult {
        guard let at = challengedAt[id] else { return .drop }
        guard valid, ticket == self.ticket, !ticketUsed, phase == .armed, now - at < Self.proofWindow else {
            challengedAt[id] = nil
            return .drop
        }
        ticketUsed = true
        provedConnection = id
        return .confirm
    }

    public func onConnectionClosed(_ id: Int) { challengedAt[id] = nil }

    /// BIND only as the first record of the proved connection, with the current ticket, once.
    public func onBind(connection: Int?, ticket: UInt64, firstRecord: Bool) -> BindResult {
        guard phase == .armed, let connection, connection == provedConnection, firstRecord, ticket == self.ticket else { return .ignore }
        phase = .bound; advertising = false
        return .accept
    }

    /// The offerer abandoned (REFUSED abandoned): stop advertising, resume liveness.
    public func onAbandoned(ticket: UInt64) -> Bool {
        guard ticket == self.ticket, suspendsLiveness, phase != .bound else { return false }
        phase = .disarmed; advertising = false
        return true
    }

    /// `oldLinkAlive`: the old link still carries records; then the bound disarms instead of ending the call.
    public func tick(oldLinkAlive: Bool, now: TimeInterval) -> Tick {
        let elapsed = now - receivedAt
        if phase == .arming && elapsed >= Self.registration { phase = .disarmed; return .refuseRegistration }
        if phase == .armed && elapsed >= Self.hardBound {
            advertising = false
            if oldLinkAlive { phase = .disarmed; return .disarm }
            phase = .failed
            return .endCall
        }
        if phase == .armed && advertising && elapsed >= Self.advertWindow { advertising = false; return .stopAdvert }
        return .none
    }

    public func reset() { if phase == .bound || phase == .disarmed { phase = .idle } }
}

/// Per-call attempt limits shared by both roles.
public struct RenewalAttempts {
    public private(set) var count = 0
    private var lastAt: TimeInterval?
    public init() {}
    public func sinceLast(now: TimeInterval) -> TimeInterval? { lastAt.map { now - $0 } }
    public mutating func record(now: TimeInterval) { count += 1; lastAt = now }
}

/// One side of the renewal opening on a new link's byte stream (sans-I/O): the armed phone sends CHALLENGE, reads PROOF
/// and answers CONFIRM; the offerer reads CHALLENGE, answers PROOF and reads CONFIRM. Bytes after the last frame are
/// the new link's first BMS1 bytes (`takeLeftover`). A malformed frame throws: the caller drops the connection.
public final class RenewalOpening {
    public enum Role: Equatable { case offerer, armed }
    public enum State: Equatable { case waiting, proved, refused }

    public let role: Role
    public let ticket: UInt64
    public private(set) var state: State = .waiting
    /// The call's `K_renew` owner (never a copy): once the call ends and zeroes it, every operation of this opening
    /// fails. Raw bytes exist only for the duration of one computation.
    private let keyOwner: CallRenewalKey
    /// The key for one computation, or a failure once the owner was zeroed or the opening decided.
    private func key() throws -> Data {
        guard !keyOwner.zeroed, state == .waiting else { throw ProtocolError.state("The renewal key was erased") }
        return keyOwner.data
    }
    private let callId: UUID
    private var challenge: Data?
    private var nonce: Data?
    private var buffer = Data()
    private var leftover = Data()
    private let admit: ((UInt64, Bool) -> Bool)?
    private var send: [UInt8]?
    private var receive: [UInt8]?
    /// This side's send and receive BMS1 keys once proved (until `wipe`).
    public var sendKey: Data? { send.map { Data($0) } }
    public var receiveKey: Data? { receive.map { Data($0) } }
    /// The connection the armed phone challenged (its state machine's ID).
    public let connection: Int

    /// Armed: `admit(proofTicket, valid)` is the state machine's decision on the proof; false drops the connection.
    public init(armed key: CallRenewalKey, callId: UUID, ticket: UInt64, connection: Int, challenge: Data = randomBytes(CallRenewalCrypto.randomBytesCount),
                admit: @escaping (UInt64, Bool) -> Bool) {
        role = .armed; keyOwner = key; self.callId = callId; self.ticket = ticket; self.connection = connection
        self.challenge = challenge; self.admit = admit
    }

    public init(offerer key: CallRenewalKey, callId: UUID, ticket: UInt64, nonce: Data = randomBytes(CallRenewalCrypto.randomBytesCount)) {
        role = .offerer; keyOwner = key; self.callId = callId; self.ticket = ticket; self.connection = 0
        self.nonce = nonce; admit = nil
    }

    deinit { wipe() }

    /// Zeroes the hop keys this opening holds (once the renewed link was built from them, or on any close).
    public func wipe() {
        if send != nil { Self.zero(&send!) }
        if receive != nil { Self.zero(&receive!) }
        send = nil; receive = nil
    }

    private static func zero(_ bytes: inout [UInt8]) { for i in bytes.indices { bytes[i] = 0 } }

    /// Armed: the CHALLENGE, sent as soon as the client's subscribe is accepted. The offerer sends nothing first.
    public func start() -> Data? {
        guard role == .armed, let challenge, !keyOwner.zeroed else { return nil }
        return CallRenewalFrames.challenge(challenge)
    }

    /// The frame this side expects next starts with these 4 bytes; anything else is dropped at once.
    private var expectedMagic: Data {
        role == .armed ? CallRenewalFrames.proofMagic : (challenge == nil ? CallRenewalFrames.challengeMagic : CallRenewalFrames.confirmMagic)
    }

    /// Bytes from the new link. Returns the frame to send in answer (PROOF or CONFIRM), if any. A connection whose first
    /// bytes are not the expected frame's magic throws at once (a central that is not running the opening).
    public func receive(_ data: Data) throws -> Data? {
        guard state == .waiting else { leftover.append(data); return nil }
        buffer.append(data)
        let head = buffer.prefix(4)
        guard head == expectedMagic.prefix(head.count) else { throw ProtocolError.malformed("Not a renewal opening frame") }
        switch role {
        case .armed:
            guard buffer.count >= CallRenewalFrames.proofBytes, let challenge else { return nil }
            let proof = try CallRenewalFrames.parseProof(buffer.prefix(CallRenewalFrames.proofBytes).rebased)
            leftover = buffer.dropFirst(CallRenewalFrames.proofBytes).rebased; buffer = Data()
            let k = try key()
            let valid = proof.ticket == ticket
                && constantTimeEqual(proof.mac, CallRenewalCrypto.offerMac(key: k, callId: callId, ticket: ticket, challenge: challenge, nonce: proof.nonce))
            guard admit?(proof.ticket, valid) == true else { state = .refused; return nil }
            let keys = CallRenewalCrypto.hopKeys(key: k, callId: callId, ticket: ticket, challenge: challenge, nonce: proof.nonce)
            let confirm = CallRenewalFrames.confirm(CallRenewalCrypto.armedMac(key: k, callId: callId, ticket: ticket, challenge: challenge, nonce: proof.nonce))
            send = [UInt8](keys.toOfferer); receive = [UInt8](keys.toArmed)
            state = .proved
            return confirm
        case .offerer:
            guard let nonce else { return nil }
            if challenge == nil {
                guard buffer.count >= CallRenewalFrames.challengeBytes else { return nil }
                let received = try CallRenewalFrames.parseChallenge(buffer.prefix(CallRenewalFrames.challengeBytes).rebased)
                challenge = received
                buffer = buffer.dropFirst(CallRenewalFrames.challengeBytes).rebased
                let proof = CallRenewalFrames.proof(ticket: ticket, nonce: nonce,
                                                    mac: CallRenewalCrypto.offerMac(key: try key(), callId: callId, ticket: ticket, challenge: received, nonce: nonce))
                if !buffer.isEmpty {
                    let rest = buffer.prefix(4)
                    guard rest == CallRenewalFrames.confirmMagic.prefix(rest.count) else { throw ProtocolError.malformed("Not a renewal opening frame") }
                }
                if buffer.count >= CallRenewalFrames.confirmBytes { _ = try finishOfferer() }
                return proof
            }
            return try finishOfferer()
        }
    }

    /// The offerer's CONFIRM check; a wrong one (an advert copied from the air) is refused.
    private func finishOfferer() throws -> Data? {
        guard let challenge, let nonce, buffer.count >= CallRenewalFrames.confirmBytes else { return nil }
        let confirm = try CallRenewalFrames.parseConfirm(buffer.prefix(CallRenewalFrames.confirmBytes).rebased)
        leftover = buffer.dropFirst(CallRenewalFrames.confirmBytes).rebased; buffer = Data()
        let k = try key()
        guard constantTimeEqual(confirm, CallRenewalCrypto.armedMac(key: k, callId: callId, ticket: ticket, challenge: challenge, nonce: nonce)) else {
            state = .refused; return nil
        }
        let keys = CallRenewalCrypto.hopKeys(key: k, callId: callId, ticket: ticket, challenge: challenge, nonce: nonce)
        send = [UInt8](keys.toArmed); receive = [UInt8](keys.toOfferer)
        state = .proved
        return nil
    }

    /// The bytes that followed the last opening frame (the new link's first BMS1 bytes).
    public func takeLeftover() -> Data { defer { leftover = Data() }; return leftover }
}
