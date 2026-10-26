import Foundation

// The reach table of Design C (Android ReachTable.kt): targets this phone learned only from adverts it scanned
// itself, a distance vector with an age and no sequence numbers. Never persisted; node prefixes only. All times are
// monotonic milliseconds from `clock`; `P` is the dialable peer (the app's row ID, a plain value in tests).
//
// Cost bookkeeping: an observation's `rawCost` is what was heard (0 for a target's own offer, the page cost for a
// relay's page). A helper's own cost is `rawCost + 1`; a caller's route costs `rawCost` relays through that relay.

public struct ReachConfig {
    public var maxRelays = RelayedCalls.defaultMaxRelays
    public var maxEntries = 32
    public var maxRoutesPerTarget = 3
    public var perRelayTargets = 4
    public var newTargetsPerWindow = 8
    public var intakeWindowMs: Int64 = 30_000
    public var minSightingGapMs: Int64 = 2_000
    public var pendingWindowMs: Int64 = 30_000
    public var maxPending = 96
    public var staleMs: Int64 = 30_000
    public var maxAgeMs: Int64 = 62_000
    public var protectedAfterMs: Int64 = 20_000
    public var holdDownMs: Int64 = 10_000
    public var advertiseAfterMs: Int64 = 5_000
    public var failSkipMs: Int64 = 30_000
    public var noRouteSkipMs: Int64 = 300_000
    public var offerFreshMs: Int64 = RelayedCalls.offerFreshMs
    public var maxOffers = 64
    public var advertisedEntries = 4
    public init() {}
}

/// The latest connectable cost-0 call offer heard from one node prefix.
public struct OfferSighting<P> {
    public let peer: P
    public let announcement: DiscoveryAnnouncement
    public let seenMs: Int64
    public let address: String
    public let rssi: Int?
}

/// A usable way to reach `target`: directly (`nextHop` nil) or through the first relay `nextHop`.
public struct ReachRoute<P> {
    public let target: Data
    public let nextHop: Data?
    /// Relays between the caller and the target: 0 direct, else the cost on the first relay's page.
    public let relays: Int
    public let ageMs: Int64
    /// The connectable offer to dial: the target's own (direct) or the first relay's.
    public let hop: OfferSighting<P>
}

public struct AdvertisedReach: Equatable {
    public let entry: ReachPageEntry
    public let relay: Bool
}

public final class ReachTable<P> {
    private let ownPrefix: Data
    private let config: ReachConfig
    private let clock: () -> Int64
    private var random: () -> Int
    /// Rotating IDs: version 5 targets and version 6 pages only; flushed by the owner at every boundary.
    public let rotating: Bool
    private let ownIds: () -> [Data]
    /// DEBUG lab mask: false behaves as if no target were in direct radio range.
    private let directSightings: () -> Bool

    private final class Observation {
        let target: Data, targetKey: String, relay: Data?, relayKey: String?
        var rawCost: Int, ageAtObservationMs: Int64, observedMs: Int64
        let firstSeenMs: Int64
        var lastRefreshMs: Int64
        var used = false
        init(target: Data, relay: Data?, rawCost: Int, ageMs: Int64, now: Int64) {
            self.target = target; targetKey = target.hex; self.relay = relay; relayKey = relay?.hex
            self.rawCost = rawCost; ageAtObservationMs = ageMs; observedMs = now; firstSeenMs = now; lastRefreshMs = now
        }
        var routeKey: String { "\(targetKey)|\(relayKey ?? "-")" }
        func ageMs(_ now: Int64) -> Int64 { ageAtObservationMs + (now - observedMs) }
    }

    private var observations: [String: Observation] = [:]
    private var observationOrder: [String] = []
    private var pending: [(key: String, firstMs: Int64)] = []
    private var offers: [(key: String, sighting: OfferSighting<P>)] = []
    private var skipUntil: [String: Int64] = [:]
    private var intake: [Int64] = []
    private var holdDown: [String: (lostCost: Int, until: Int64)] = [:]

    public init(ownPrefix: Data, config: ReachConfig = ReachConfig(), clock: @escaping () -> Int64,
                random: @escaping () -> Int = { Int.random(in: Int.min...Int.max) }, rotating: Bool = false,
                ownIds: (() -> [Data])? = nil, directSightings: @escaping () -> Bool = { true }) {
        self.ownPrefix = ownPrefix.rebased; self.config = config; self.clock = clock; self.random = random
        self.rotating = rotating; self.directSightings = directSightings
        let own = ownPrefix.rebased
        self.ownIds = ownIds ?? { [own] }
    }

    public var size: Int { observations.count }

    private func isOwn(_ bytes: Data) -> Bool { ownIds().contains(bytes) }
    private func isOwnVia(_ via: Data) -> Bool { ownIds().contains { $0.prefix(ReachPageCodec.viaBytes) == via } }

    // MARK: Sightings

    /// A scanned call offer: remembered for dialling and, with the consent bit, a direct observation.
    public func observeOffer(peer: P, announcement: DiscoveryAnnouncement, address: String, rssi: Int? = nil) {
        guard announcement.isPrivateCallOffer, announcement.rotating == rotating, announcement.routeCost == 0, !announcement.usesClassic,
              announcement.flags & DiscoveryAnnouncement.flagAcceptingConnections != 0 else { return }
        let now = clock()
        let key = announcement.nodeIdPrefix.hex
        guard !isOwn(announcement.nodeIdPrefix) else { return }
        offers.removeAll { $0.key == key }
        offers.append((key, OfferSighting(peer: peer, announcement: announcement, seenMs: now, address: address, rssi: rssi)))
        while offers.count > config.maxOffers { offers.removeFirst() }
        if directSightings() && RelayedCalls.consents(announcement, rotating: rotating) {
            observe(target: announcement.nodeIdPrefix, relay: nil, rawCost: 0, ageMs: 0, address: address, now: now)
        }
    }

    /// A scanned reach page from the advertiser at `address`.
    public func observePage(_ page: ReachPage, address: String) {
        let now = clock()
        guard page.rotating == rotating, !isOwn(page.relayPrefix) else { return }
        for entry in page.entries {
            if isOwn(entry.target) || isOwnVia(entry.via) || entry.cost > config.maxRelays { continue }
            observe(target: entry.target, relay: page.relayPrefix, rawCost: entry.cost, ageMs: entry.ageMs, address: address, now: now)
        }
    }

    private func observe(target: Data, relay: Data?, rawCost: Int, ageMs: Int64, address: String, now: Int64) {
        prune(now)
        let targetKey = target.hex, relayKey = relay?.hex
        let routeKey = "\(targetKey)|\(relayKey ?? "-")"
        if let existing = observations[routeKey] {
            // Ages only grow along a path: a refresh keeps the smaller age; the relay's cost may change.
            existing.ageAtObservationMs = min(existing.ageMs(now), ageMs)
            existing.observedMs = now; existing.lastRefreshMs = now; existing.rawCost = rawCost
            return
        }
        if (skipUntil[routeKey] ?? 0) > now { return }
        if let hold = holdDown[targetKey], hold.until > now, rawCost + 1 > hold.lostCost { return }
        let pendingKey = "\(routeKey)@\(address)"
        guard let first = pending.first(where: { $0.key == pendingKey }), now - first.firstMs <= config.pendingWindowMs else {
            pending.removeAll { $0.key == pendingKey }
            pending.append((pendingKey, now))
            while pending.count > config.maxPending { pending.removeFirst() }
            return
        }
        if now - first.firstMs < config.minSightingGapMs { return }
        intake.removeAll { now - $0 >= config.intakeWindowMs }
        if intake.count >= config.newTargetsPerWindow { return }
        if let relayKey, observations.values.filter({ $0.relayKey == relayKey }).count >= config.perRelayTargets { return }
        if observations.values.filter({ $0.targetKey == targetKey }).count >= config.maxRoutesPerTarget { return }
        if observations.count >= config.maxEntries && !evictWorse(than: rawCost, now: now) { return }
        observations[routeKey] = Observation(target: target.rebased, relay: relay?.rebased, rawCost: rawCost, ageMs: ageMs, now: now)
        observationOrder.append(routeKey)
        intake.append(now)
        pending.removeAll { $0.key == pendingKey }
    }

    private func isProtected(_ o: Observation, _ now: Int64) -> Bool { o.used || now - o.firstSeenMs >= config.protectedAfterMs }

    private func evictWorse(than rawCost: Int, now: Int64) -> Bool {
        let victim = observations.values.filter { !isProtected($0, now) }
            .max { a, b in a.rawCost != b.rawCost ? a.rawCost < b.rawCost : a.lastRefreshMs > b.lastRefreshMs }
        guard let victim, victim.rawCost >= rawCost else { return false }
        remove(victim.routeKey)
        return true
    }

    private func remove(_ key: String) { observations[key] = nil; observationOrder.removeAll { $0 == key } }

    private func prune(_ now: Int64) {
        var lost: [Observation] = []
        for key in observationOrder {
            guard let o = observations[key] else { continue }
            if o.ageMs(now) > config.maxAgeMs || now - o.lastRefreshMs > config.staleMs { lost.append(o); remove(key) }
        }
        for gone in lost where !observations.values.contains(where: { $0.targetKey == gone.targetKey }) {
            // After the best route to a target is lost, worse routes are ignored briefly (damps loops).
            holdDown[gone.targetKey] = (gone.rawCost + 1, now + config.holdDownMs)
        }
        holdDown = holdDown.filter { $0.value.until > now }
        skipUntil = skipUntil.filter { $0.value > now }
        pending.removeAll { now - $0.firstMs > config.pendingWindowMs }
        offers.removeAll { now - $0.sighting.seenMs > config.offerFreshMs * 2 }
    }

    // MARK: Outcomes

    /// A setup through `relay` (nil: direct) to `target` failed: skip the pair briefly (5 min and drop for no route).
    public func markFailed(relay: Data?, target: Data, noRoute: Bool) {
        let now = clock()
        let key = "\(target.hex)|\(relay?.hex ?? "-")"
        skipUntil[key] = now + (noRoute ? config.noRouteSkipMs : config.failSkipMs)
        if noRoute { remove(key) }
    }

    /// A setup through `relay` to `target` reached READY: the entry survives eviction.
    public func markUsed(relay: Data?, target: Data) { observations["\(target.hex)|\(relay?.hex ?? "-")"]?.used = true }

    // MARK: Queries

    public func directOffer(_ target: Data, maxAgeMs: Int64? = nil) -> OfferSighting<P>? {
        guard directSightings() else { return nil }
        let now = clock()
        guard let s = offers.first(where: { $0.key == target.hex })?.sighting, now - s.seenMs <= (maxAgeMs ?? config.offerFreshMs) else { return nil }
        return s
    }

    public func offer(_ prefix: Data) -> OfferSighting<P>? { offers.first { $0.key == prefix.hex }?.sighting }

    /// Every offer heard within `withinMs` (Design OR: a search first uses what scans heard anyway).
    public func recentOffers(withinMs: Int64) -> [OfferSighting<P>] {
        let now = clock()
        return offers.map(\.sighting).filter { now - $0.seenMs <= withinMs }
    }

    /// The fresh connectable helper offer (FLAG_RELAY_CAPABLE) of relay `prefix`.
    public func helperOffer(_ prefix: Data, accept: (DiscoveryAnnouncement) -> Bool = { _ in true }) -> OfferSighting<P>? {
        let now = clock()
        guard let s = offers.first(where: { $0.key == prefix.hex })?.sighting, now - s.seenMs <= config.offerFreshMs,
              RelayedCalls.isRelayHelperOffer(s.announcement, rotating: rotating), accept(s.announcement) else { return nil }
        return s
    }

    /// Routes a caller can try for `target`, best first: direct, then fewest relays, then age under 20 s, then the
    /// stronger first hop (15 dB bands), then the freshest. Failed pairs are excluded.
    public func callerRoutes(_ target: Data, accept: (DiscoveryAnnouncement) -> Bool = { _ in true }, requireRelays: Int = 0) -> [ReachRoute<P>] {
        let now = clock()
        prune(now)
        let targetKey = target.hex
        var routes: [ReachRoute<P>] = []
        if requireRelays == 0, let hop = directOffer(target), accept(hop.announcement) {
            routes.append(ReachRoute(target: target.rebased, nextHop: nil, relays: 0, ageMs: 0, hop: hop))
        }
        for key in observationOrder {
            guard let o = observations[key], o.targetKey == targetKey, let relay = o.relay else { continue }
            if requireRelays != 0 && o.rawCost != requireRelays { continue }
            if (skipUntil[o.routeKey] ?? 0) > now { continue }
            guard let hop = helperOffer(relay, accept: accept) else { continue }
            routes.append(ReachRoute(target: target.rebased, nextHop: relay, relays: o.rawCost, ageMs: o.ageMs(now), hop: hop))
        }
        func band(_ r: ReachRoute<P>) -> Int { -(r.hop.rssi ?? -127) / 15 }
        return routes.enumerated().sorted { x, y in
            let a = x.element, b = y.element
            if a.relays != b.relays { return a.relays < b.relays }
            let fa = a.ageMs < 20_000 ? 0 : 1, fb = b.ageMs < 20_000 ? 0 : 1
            if fa != fb { return fa < fb }
            if band(a) != band(b) { return band(a) < band(b) }
            if a.ageMs != b.ageMs { return a.ageMs < b.ageMs }
            return x.offset < y.offset
        }.map(\.element)
    }

    /// Targets with a relayed route and no fresh direct offer: the extra rows of the people list.
    public func relayedTargets(accept: (DiscoveryAnnouncement) -> Bool = { _ in true }, includeDirect: Bool = false) -> [Data] {
        prune(clock())
        var seen = Set<String>(), out: [Data] = []
        for key in observationOrder {
            guard let o = observations[key], o.relay != nil, !seen.contains(o.targetKey) else { continue }
            seen.insert(o.targetKey)
            if !includeDirect && directOffer(o.target) != nil { continue }
            if callerRoutes(o.target, accept: accept).contains(where: { $0.nextHop != nil }) { out.append(o.target) }
        }
        return out
    }

    /// A helper's route for a SETUP with `budget`: the target's own fresh, consenting offer whatever the budget, else
    /// the cheapest page-learned route that fits the budget left for the next hop.
    public func setupRoute(_ target: Data, budget: Int, accept: (DiscoveryAnnouncement) -> Bool = { _ in true }) -> ReachRoute<P>? {
        guard budget >= 1 else { return nil }
        if let hop = directOffer(target), accept(hop.announcement), RelayedCalls.consents(hop.announcement, rotating: rotating) {
            return ReachRoute(target: target.rebased, nextHop: nil, relays: 0, ageMs: 0, hop: hop)
        }
        guard budget > 1 else { return nil }
        return callerRoutes(target, accept: accept).first { $0.nextHop != nil && $0.relays <= budget - 1 }
    }

    /// What this helper advertises, best first, at most `advertisedEntries`: its own cost `rawCost + 1` within the cap;
    /// a page-learned entry only after `advertiseAfterMs` and while its relay's helper offer is fresh.
    public func advertisable() -> [AdvertisedReach] {
        let now = clock()
        prune(now)
        var best: [String: (o: Observation, cost: Int, units: Int)] = [:]
        for key in observationOrder {
            guard let o = observations[key] else { continue }
            let ownCost = o.rawCost + 1
            guard ownCost <= config.maxRelays, let units = ReachPageCodec.ageUnits(for: o.ageMs(now)) else { continue }
            if let relay = o.relay {
                if now - o.firstSeenMs < config.advertiseAfterMs || helperOffer(relay) == nil { continue }
            } else if directOffer(o.target) == nil { continue }
            if let current = best[o.targetKey], !(ownCost < current.cost || (ownCost == current.cost && units < current.units)) { continue }
            best[o.targetKey] = (o, ownCost, units)
        }
        return best.values.map { ($0, random()) }
            .sorted { a, b in
                if a.0.cost != b.0.cost { return a.0.cost < b.0.cost }
                if a.0.units != b.0.units { return a.0.units < b.0.units }
                return a.1 < b.1
            }
            .prefix(config.advertisedEntries)
            .compactMap { item in
                let via = (item.0.o.relay ?? item.0.o.target).prefix(ReachPageCodec.viaBytes).rebased
                guard let entry = try? ReachPageEntry(target: item.0.o.target, cost: item.0.cost, ageUnits: item.0.units, via: via) else { return nil }
                return AdvertisedReach(entry: entry, relay: item.0.o.relay != nil)
            }
    }

    /// Entries by cost heard (`c0` own offers, `cN` pages naming N relays) for the debug table line.
    public func costSummary() -> String {
        let counts = Dictionary(grouping: observations.values, by: \.rawCost).mapValues(\.count)
        return counts.isEmpty ? "none" : counts.keys.sorted().map { "c\($0)=\(counts[$0]!)" }.joined(separator: ",")
    }

    public func clear() {
        observations.removeAll(); observationOrder.removeAll(); pending.removeAll(); offers.removeAll()
        skipUntil.removeAll(); intake.removeAll(); holdDown.removeAll()
    }
}
