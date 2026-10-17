import Foundation

// EXPERIMENTAL BMH3 for private calls (Android Bmh3Policy.kt / Bmh3Link.kt): which handshake an initiator speaks, the
// responder's dispatch and cost guards, and the per-connection settings that SecureLink (link layer) and
// EndToEndHandshake (end-to-end layer) read. With `Bmh3CallSettings` nil every byte is exactly BMH2 as before.

/// Which handshake an initiator speaks, decided once before the first byte and never revisited (PROTOCOL "Negotiation").
public enum Bmh3Choice {
    public enum Reason: String { case off, rotating, only, hint, pin, none }
    /// Android `capabilitySummary` bit 5 of a version 2 private-call offer: "this identity accepts BMH3 handshakes".
    public static let hintBit: UInt8 = 1 << 5

    public static func hasHint(_ offer: DiscoveryAnnouncement) -> Bool {
        offer.isPrivateCallOffer && !offer.rotating && offer.capabilitySummary & hintBit != 0
    }

    /// A version 5 offer is always BMH3; a version 2 offer is BMH3 with the hint, a pin or `only`, otherwise BMH2.
    public static func decide(enabled: Bool, only: Bool, offer: DiscoveryAnnouncement?, pinned: Bool) -> (bmh3: Bool, reason: Reason) {
        if !enabled { return (false, .off) }
        if let offer, offer.rotating { return (true, .rotating) }
        if only { return (true, .only) }
        if let offer, hasHint(offer) { return (true, .hint) }
        if pinned { return (true, .pin) }
        return (false, .none)
    }
}

/// Node prefixes that completed a BMH3 handshake with this phone (Android Bmh3Pins): a later version 2 offer with a
/// pinned prefix is contacted with BMH3 even when its hint was stripped. In memory here (an app restart forgets them).
public final class Bmh3Pins {
    public static let ttl: TimeInterval = 30 * 24 * 3600
    private var entries: [Data: Date] = [:]
    private let capacity: Int
    private let lock = NSLock()
    public init(capacity: Int = 256) { self.capacity = capacity }
    public func isPinned(_ prefix: Data, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let at = entries[prefix.prefix(6).rebased] else { return false }
        return now.timeIntervalSince(at) <= Self.ttl
    }
    public func pin(_ prefix: Data, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        entries[prefix.prefix(6).rebased] = now
        if entries.count > capacity, let oldest = entries.min(by: { $0.value < $1.value })?.key { entries.removeValue(forKey: oldest) }
    }
    public func clear() { lock.lock(); entries.removeAll(); lock.unlock() }
}

/// The signing budget of a stranger-facing R_FIRST responder (Android Bmh3SigningBudget): 8 signatures in a burst, one
/// more every 4 s. The sans-I/O core cannot wait, so an empty bucket closes the connection silently.
public final class Bmh3SigningBudget {
    private let capacity: Double, refill: TimeInterval
    private var tokens: Double
    private var last: TimeInterval
    private let clock: () -> TimeInterval
    private let lock = NSLock()
    public init(capacity: Int = 8, refill: TimeInterval = 4, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.capacity = Double(capacity); self.refill = refill; self.clock = clock
        tokens = Double(capacity); last = clock()
    }
    public func spend() throws {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        tokens = min(capacity, tokens + max(0, now - last) / refill); last = now
        guard tokens >= 1 else { throw Bmh3Failure("budget") }
        tokens -= 1
    }
}

/// The BMH3 settings of one call connection (both layers). Nil on a connection means BMH2 only, exactly as before.
public final class Bmh3CallSettings {
    /// Initiator: speak BMH3 (decided by `Bmh3Choice`). Responder: ignored (it dispatches on the first frame's magic).
    public let speak: Bool
    /// Responder: accept a BMH2 first message. False in pseudonym mode (a BMH2 hello is answered with the real key).
    public let acceptBmh2: Bool
    /// The throwaway this phone presents to a stranger (rule P): per attempt for a caller, per connection for a callee;
    /// the same key at the link and the end-to-end layer. Nil: the real identity to everyone (BMH3 Phase 1).
    public let stranger: SigningIdentity?
    /// Initiator: the link-layer identity toward a first hop that is a relay (route cost above 0).
    public let linkIdentityOverride: SigningIdentity?
    /// Responder: the OPENING value (`count | entries`) of the entries pinned when the connection was accepted.
    public var opening: () -> Data?
    /// Initiator: runs after the responder's block verified and before this phone reveals itself; throws to abort.
    public var checkResponder: (Bmh3Peer, Bmh3Purpose) throws -> Void
    /// Initiator: a peer that proved a real identity (pins).
    public var onRealResponder: (Bmh3Peer) -> Void = { _ in }
    public let replayCache: Bmh3ReplayCache?
    public let budget: Bmh3SigningBudget?
    public let entropy: Bmh3Entropy
    /// Initiator (phase 2): the contact tag toward a recognised contact's advert (its lease key bound to the advert).
    /// With a tag this phone presents its real key, and only to that contact's full node ID; R_FIRST only.
    public var contactTag: Bmh3ContactTag?
    /// Initiator: the tag applies at the link layer only toward the advert's owner (route cost 0), never a relay.
    public var linkTag: Bool = true
    /// Responder (phase 2): `K_tag` checks of this phone's own day keys against the adverts it has on air or just left.
    public var tagChecks: () -> [Bmh3ContactTag] = { [] }
    /// Responder: a matched tag must come from a contact this phone delivered its current lease to (else a lease leaked).
    public var admitTagged: (NodeId) -> Bool = { _ in false }

    public init(speak: Bool, acceptBmh2: Bool = true, stranger: SigningIdentity? = nil, linkIdentityOverride: SigningIdentity? = nil,
                opening: @escaping () -> Data? = { nil }, checkResponder: @escaping (Bmh3Peer, Bmh3Purpose) throws -> Void = { _, _ in },
                replayCache: Bmh3ReplayCache? = nil, budget: Bmh3SigningBudget? = nil, entropy: Bmh3Entropy = SecureBmh3Entropy()) {
        self.speak = speak; self.acceptBmh2 = acceptBmh2; self.stranger = stranger; self.linkIdentityOverride = linkIdentityOverride
        self.opening = opening; self.checkResponder = checkResponder; self.replayCache = replayCache; self.budget = budget; self.entropy = entropy
    }

    /// The `OPENING` extension value for entries, or nil when there are none.
    public static func openingValue(_ entries: [OpeningEntry]) -> Data? {
        guard !entries.isEmpty, let bdo1 = try? DiscoveryOpeningCodec.encode(entries) else { return nil }
        return bdo1.suffix(from: DiscoveryOpeningCodec.magic.count + 1).rebased
    }

    /// The caller's check before it reveals itself: the peer must open the selected advert (link layer: route cost 0
    /// only, above it the link peer is a relay; end-to-end: always). A pseudonymous answerer is judged at its reveal.
    public static func selectionCheck(_ selected: DiscoveryAnnouncement, wallEpoch: @escaping () -> Int64 = RotatingDiscoveryIds.currentWallEpoch) -> (Bmh3Peer, Bmh3Purpose) throws -> Void {
        return { peer, purpose in
            if peer.pseudonymous { return }
            if purpose == .link && selected.routeCost > 0 { return }
            let result = DiscoverySelectionCheck.check(selected: selected, expectedRole: RotatingDiscoveryIds.roleCallOffer,
                                                       peerNodeId: peer.nodeId.bytes, openingEntries: try peer.openingEntries(),
                                                       verifierWallEpoch: wallEpoch())
            guard result == .pass else { throw ProtocolError.authentication }
        }
    }

    /// The process-wide replay cache and signing budget of call responders.
    public static let sharedReplayCache = Bmh3ReplayCache()
    public static let sharedBudget = Bmh3SigningBudget()
}
