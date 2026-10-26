import Foundation

// EXPERIMENTAL Design OR, caller side (Android RelaySeekSelectors, RelaySeekRings, RelaySeekCallerMemory; PROTOCOL OR
// caller rules 1-7). Pure: the app supplies the contact's window, the first hops and the clock, and dials what `next`
// returns.

public enum RelaySeekSelectors {
    public enum Kind: Equatable { case primary, neighbour }
    public struct Selector: Equatable { public let epoch: Int64; public let rdi: Data; public let kind: Kind }

    /// The contact's role-0 IDs the recognition policy holds (by epoch, only days whose key the lease has), the centre
    /// `myE + skew`, and whether the lease is older than 14 days (recognition widens; a search does not).
    public struct Window: Equatable {
        public let centreEpoch: Int64, stale: Bool, ids: [Int64: Data]
        public init(centreEpoch: Int64, stale: Bool, ids: [Int64: Data]) { self.centreEpoch = centreEpoch; self.stale = stale; self.ids = ids }
    }

    /// 120 s of a 900 s epoch.
    public static func boundaryWindowMs(epochSeconds: Int64) -> Int64 { epochSeconds * 1_000 * 120 / 900 }

    /// The primary selector (a direct recognition's epoch, else the centre), then the neighbour on the side of the nearer
    /// boundary, only inside the boundary window and never for a stale lease.
    public static func selectors(window: Window, directEpoch: Int64?, msUntilBoundary: Int64, msSinceBoundary: Int64,
                                 epochSeconds: Int64 = RotatingDiscoveryIds.epochSeconds) -> [Selector] {
        let primaryEpoch = directEpoch.flatMap { window.ids[$0] != nil ? $0 : nil } ?? window.centreEpoch
        guard let primary = window.ids[primaryEpoch] else { return [] }
        var out = [Selector(epoch: primaryEpoch, rdi: primary, kind: .primary)]
        if window.stale { return out }
        let limit = boundaryWindowMs(epochSeconds: epochSeconds)
        var neighbour: Int64?
        if msUntilBoundary <= msSinceBoundary && msUntilBoundary <= limit { neighbour = primaryEpoch + 1 }
        else if msSinceBoundary < msUntilBoundary && msSinceBoundary <= limit { neighbour = primaryEpoch - 1 }
        if let neighbour, let rdi = window.ids[neighbour] { out.append(Selector(epoch: neighbour, rdi: rdi, kind: .neighbour)) }
        return out
    }
}

/// One caller attempt's requests in expanding rings (PROTOCOL OR caller rule 4): ring 1 (budget 1, primary selector) to
/// each first hop, ring 1b (budget 1, neighbour selector) inside the boundary window, ring 2 (budget 2, primary, a skip
/// list of the first hops that answered FAIL 1 in ring 1) with a relay cap of 2. Stops at READY; caps `N(S + 1)`
/// requests and twice that many dials; a request is sent only while it fits its minimum allowance.
public final class RelaySeekRings {
    public enum Ring: Equatable { case one, oneB, two }
    public enum Outcome: Equatable { case ready, noRoute, busyOrRefused, bindingFailed, noSeek, ambiguous, timeout, stale, other }
    public struct Request: Equatable {
        public let hop: Data, ring: Ring, budget: Int, selector: RelaySeekSelectors.Selector, skip: [Data], remainingMs: Int
    }

    private let attemptEndMs: Int64
    private let selectors: [RelaySeekSelectors.Selector]
    private let firstHops: [Data]
    private let connectMs: Int64
    private let rings: [Ring]
    private var excluded = Set<Data>()
    private var ringOneMisses: [Data] = []
    private var ringIndex = 0, hopIndex = 0
    public private(set) var requests = 0, dials = 0
    public private(set) var done = false
    public let maxRequests: Int
    public var maxDials: Int { 2 * maxRequests }

    public init(attemptEndMs: Int64, selectors: [RelaySeekSelectors.Selector], firstHops: [Data], maxRelays: Int, require: Int = 0,
                connectMs: Int64 = Int64(RelaySeek.defaultConnectMs)) {
        self.attemptEndMs = attemptEndMs; self.selectors = selectors; self.firstHops = firstHops; self.connectMs = connectMs
        var r: [Ring] = []
        if require != 2 {
            r.append(.one)
            if selectors.contains(where: { $0.kind == .neighbour }) { r.append(.oneB) }
        }
        if min(maxRelays, RelaySeek.maxBudget) >= 2 && require != 1 { r.append(.two) }
        rings = r
        maxRequests = firstHops.count * r.count
    }

    /// Remaining time a request may carry now: `min(20 s, attempt end - now - 2 s)`.
    public func remainingNow(_ now: Int64) -> Int64 {
        min(Int64(RelayedCalls.setupDeadlineMs), attemptEndMs - now - Int64(RelayedCalls.setupReplyGraceMs))
    }

    public func next(now: Int64) -> Request? {
        if done || requests >= maxRequests || dials >= maxDials { return nil }
        while ringIndex < rings.count {
            let ring = rings[ringIndex]
            while hopIndex < firstHops.count {
                let hop = firstHops[hopIndex]; hopIndex += 1
                if excluded.contains(hop) { continue }
                let budget = ring == .two ? 2 : 1
                let remaining = remainingNow(now)
                let minimum = Int64(budget == 1 ? RelaySeek.minAllowanceBudget1Ms : RelaySeek.minAllowanceBudget2Ms)
                if remaining - connectMs < minimum {
                    // Time only shrinks: a budget-1 request that cannot fit means nothing else can either.
                    if budget == 1 { done = true; return nil }
                    break
                }
                let selector = ring == .oneB ? selectors.first { $0.kind == .neighbour }! : selectors[0]
                let skip = ring == .two ? Array(ringOneMisses.prefix(RelaySeek.maxSkip)).map { $0.prefix(RelaySeek.skipPrefixBytes).rebased } : []
                requests += 1
                return Request(hop: hop, ring: ring, budget: budget, selector: selector, skip: skip, remainingMs: Int(remaining))
            }
            ringIndex += 1; hopIndex = 0
        }
        done = true
        return nil
    }

    public func record(_ request: Request, outcome: Outcome, physicalDials: Int) {
        dials += physicalDials
        switch outcome {
        case .ready: done = true
        case .noRoute: if request.ring == .one, !ringOneMisses.contains(request.hop) { ringOneMisses.append(request.hop) }
        case .busyOrRefused, .bindingFailed, .noSeek, .ambiguous: excluded.insert(request.hop)
        case .timeout, .stale, .other: break
        }
    }

    public static func outcome(for reason: RelaySetupFailure?) -> Outcome {
        switch reason {
        case nil: return .other
        case .noRoute?: return .noRoute
        case .busy?, .refused?: return .busyOrRefused
        case .timeout?: return .timeout
        case .childAuthentication?, .loop?: return .other
        }
    }
}

/// The caller's memory: the helper that last reached a contact in this epoch, "helper X found no route for selector S"
/// for 60 s, and the per-contact backoff after "Can't find" (30 s doubling to 120 s; automatic retries only).
public final class RelaySeekCallerMemory {
    public static let noRouteMs: Int64 = 60_000, backoffFirstMs: Int64 = 30_000, backoffMaxMs: Int64 = 120_000
    private var reached: [String: (epoch: Int64, hop: Data)] = [:]
    private var noRoute: [String: Int64] = [:]
    private var backoff: [String: (until: Int64, step: Int64)] = [:]
    public init() {}
    public func rememberReached(contact: String, epoch: Int64, hop: Data) { reached[contact] = (epoch, hop) }
    public func reachedBy(contact: String, epoch: Int64) -> Data? { reached[contact].flatMap { $0.epoch == epoch ? $0.hop : nil } }
    private func key(_ hop: Data, _ selector: Data, _ budget: Int) -> String { "\(hop.hex)/\(selector.hex)/\(budget)" }
    public func rememberNoRoute(hop: Data, selector: Data, budget: Int, now: Int64) { noRoute[key(hop, selector, budget)] = now }
    public func recentlyNoRoute(hop: Data, selector: Data, budget: Int, now: Int64) -> Bool {
        noRoute = noRoute.filter { now - $0.value < Self.noRouteMs }
        return noRoute[key(hop, selector, budget)] != nil
    }
    public func failed(contact: String, now: Int64) {
        let previous = backoff[contact]?.step ?? 0
        let step = previous == 0 ? Self.backoffFirstMs : min(previous * 2, Self.backoffMaxMs)
        backoff[contact] = (now + step, step)
    }
    public func reset(contact: String) { backoff[contact] = nil }
    public func backoffMs(contact: String, now: Int64) -> Int64 { max(0, (backoff[contact]?.until ?? 0) - now) }
}

/// The first hops of a caller attempt (PROTOCOL OR caller rule 3): version 5 helper offers on the call's bearer heard in
/// the last 10 s, not the contact itself, the helper that last reached this contact first, then the stronger signal; 3.
public enum RelaySeekFirstHops {
    public static let freshMs: Int64 = 10_000
    public static func choose<P>(offers: [OfferSighting<P>], bearer: MeshTransport, now: Int64, isContact: (Data) -> Bool,
                                 reachedBy: Data?, limit: Int = 3) -> [Data] {
        var latest: [Data: OfferSighting<P>] = [:]
        for o in offers where now - o.seenMs <= freshMs && RelayedCalls.isRelayHelperOffer(o.announcement, rotating: true)
            && o.announcement.transport == bearer && !isContact(o.announcement.nodeIdPrefix) {
            if let existing = latest[o.announcement.nodeIdPrefix], existing.seenMs >= o.seenMs { continue }
            latest[o.announcement.nodeIdPrefix] = o
        }
        return latest.values.sorted { a, b in
            let ra = a.announcement.nodeIdPrefix == reachedBy, rb = b.announcement.nodeIdPrefix == reachedBy
            if ra != rb { return ra }
            return (a.rssi ?? -127) > (b.rssi ?? -127)
        }.prefix(limit).map(\.announcement.nodeIdPrefix)
    }
}
