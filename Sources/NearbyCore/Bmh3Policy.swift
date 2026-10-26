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

/// Where BMH3 pins are kept (the app: a small file outside backups, deleted by the emergency wipe).
public protocol Bmh3PinStorage: AnyObject {
    /// nil when nothing is stored; throws when something is stored but cannot be read (it is then never overwritten).
    func read() throws -> String?
    func write(_ value: String)
}

/// Node prefixes (6 bytes) that completed a BMH3 handshake with this phone (Android Bmh3Pins), newest last, at most
/// `capacity`, each valid for 30 days after its last success: a later version 2 offer with a pinned prefix is
/// contacted with BMH3 even when its hint was stripped (a downgrade). Stored as Android does, one `hex ms` line per
/// pin, so an app restart keeps them; without storage they live in memory only.
public final class Bmh3Pins {
    public static let ttl: TimeInterval = 30 * 24 * 3600
    /// A pin dated more than this far in the future (a clock moved back) is dropped.
    static let clockSlack: TimeInterval = 24 * 3600
    private var entries: [(key: String, atMs: Int64)] = []
    private let capacity: Int
    private let storage: Bmh3PinStorage?
    private var loaded = false
    private let lock = NSLock()
    public init(capacity: Int = 256, storage: Bmh3PinStorage? = nil) { self.capacity = capacity; self.storage = storage }

    public func isPinned(_ prefix: Data, now: Date = Date()) -> Bool {
        guard let key = Self.key(prefix) else { return false }
        lock.lock(); defer { lock.unlock() }
        load(now); expire(now)
        return entries.contains { $0.key == key }
    }
    public func pin(_ prefix: Data, now: Date = Date()) {
        guard let key = Self.key(prefix) else { return }
        lock.lock(); defer { lock.unlock() }
        load(now)
        entries.removeAll { $0.key == key }
        entries.append((key, Int64(now.timeIntervalSince1970 * 1000)))
        expire(now)
        save()
    }
    public func clear() { lock.lock(); load(Date()); entries.removeAll(); save(); lock.unlock() }

    private static func key(_ prefix: Data) -> String? { prefix.count >= 6 ? prefix.prefix(6).rebased.hex : nil }

    private func load(_ now: Date) {
        guard !loaded else { return }
        let text: String
        do { text = try storage?.read() ?? "" }
        catch {
            // Unreadable is not empty (review 2026-10-27): keep this session's pins in memory, never save over the
            // stored ones (30-day downgrade protection), and try reading again next time.
            return
        }
        loaded = true
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, parts[0].count == 12, Data(hex: String(parts[0])) != nil, String(parts[0]) == parts[0].lowercased(),
                  let at = Int64(parts[1]) else { continue }
            entries.removeAll { $0.key == String(parts[0]) }
            entries.append((String(parts[0]), at))
        }
        expire(now)
    }

    private func expire(_ now: Date) {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let before = entries.count
        entries.removeAll { nowMs - $0.atMs > Int64(Self.ttl * 1000) || $0.atMs > nowMs + Int64(Self.clockSlack * 1000) }
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        if entries.count != before { save() }
    }

    private func save() {
        guard loaded else { return }
        storage?.write(entries.map { "\($0.key) \($0.atMs)" }.joined(separator: "\n"))
    }
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

    /// The process-wide replay cache and signing budget of call responders that present their real key.
    public static let sharedReplayCache = Bmh3ReplayCache()
    public static let sharedBudget = Bmh3SigningBudget()
    /// Per-epoch replay caches and budgets of pseudonym-mode responders (Android `Bmh3Policy.epochGuards`).
    public static let epochGuards = Bmh3EpochGuards()
}

/// The replay cache and the signing budget of stranger-facing (pseudonym-mode) responders, one pair per discovery
/// epoch, dropped two epochs later (Android Bmh3EpochGuards, review PR3). A process-wide cache would let a prober
/// replay one msg1 across an epoch boundary and read "same phone" from the silent close, linking two rotating IDs;
/// a drained process-wide budget carries over the boundary the same way.
public final class Bmh3EpochGuards {
    public final class Guards {
        public let replayCache: Bmh3ReplayCache
        public let budget: Bmh3SigningBudget
        init(replayCache: Bmh3ReplayCache, budget: Bmh3SigningBudget) { self.replayCache = replayCache; self.budget = budget }
    }
    private var byEpoch: [Int64: Guards] = [:]
    private let newBudget: () -> Bmh3SigningBudget
    private let lock = NSLock()
    public init(newBudget: @escaping () -> Bmh3SigningBudget = { Bmh3SigningBudget() }) { self.newBudget = newBudget }

    /// The guards of `epoch`; those of epochs before `epoch - 1` are dropped.
    public func forEpoch(_ epoch: Int64) -> Guards {
        lock.lock(); defer { lock.unlock() }
        byEpoch = byEpoch.filter { $0.key >= epoch - 1 }
        if let existing = byEpoch[epoch] { return existing }
        let created = Guards(replayCache: Bmh3ReplayCache(), budget: newBudget())
        byEpoch[epoch] = created
        return created
    }
    var epochs: [Int64] { lock.lock(); defer { lock.unlock() }; return byEpoch.keys.sorted() }
}
