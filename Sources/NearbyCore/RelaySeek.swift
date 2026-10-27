import Foundation
import CryptoKit

// EXPERIMENTAL route search (on-demand relayed route search; Android RelaySeek.kt): a caller asks a
// helper over the link with SEEK (hop type 12 message 5) and the helper looks for the target on demand, so no reach
// page is needed. Effective only with relayed calls on and its own launch-argument switch.

public enum RelaySeek {
    public static let maxBudget = 2
    public static let nonceBytes = 8
    public static let tokenBytes = 6
    public static let maxSkip = 3
    public static let skipPrefixBytes = 2
    /// `RELAY_SEEK` bit 0: SEEK version 1. Bits 1 and 2 are reserved (OR-T proof, OR-C probe).
    public static let featureSeekV1: UInt8 = 1

    /// Minimum allowance a request needs (budget 1 / budget 2), and the onward minimum for the target link.
    public static let minAllowanceBudget1Ms = 9_000
    public static let minAllowanceBudget2Ms = 14_000
    public static let onwardTargetMs = 6_000
    /// A search with less time than this left answers FAIL 4 without radio work.
    public static let minSearchMs = 3_000
    public static let defaultScanMs = 3_000
    public static let collectAfterMatchMs = 1_000
    public static let maxTargetAddresses = 3
    public static let dialsPerRequest = 3
    public static let opportunisticCacheMs: Int64 = 5_000
    public static let defaultFanout = 2
    public static let defaultConnectMs = 4_000

    static let tokenDomain = Data("BluetoothVideoMesh/RelaySeek/Token/1".utf8) + Data([0])

    /// `token = SHA-256(domain || 0x00 || nonce || RDI)[0:6]`: a lookup hint, never proof of identity.
    public static func token(nonce: Data, rdi: Data) -> Data {
        Data(SHA256.hash(data: tokenDomain + nonce + rdi)).prefix(tokenBytes).rebased
    }

    public static func newNonce() -> Data {
        var n = Data(count: nonceBytes)
        repeat { _ = n.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, nonceBytes, $0.baseAddress!) } } while !n.contains { $0 != 0 }
        return n
    }

    /// Whether a scanned offer is the sought target: a version 5 cost-0 consenting call offer on the link's bearer whose
    /// role-0 RDI gives the request's token; this device's own RDIs never match.
    public static func matches(_ offer: DiscoveryAnnouncement, nonce: Data, token: Data, bearer: MeshTransport, ownRdis: [Data]) -> Bool {
        RelayedCalls.consents(offer, rotating: true) && offer.transport == bearer && !ownRdis.contains(offer.nodeIdPrefix)
            && Self.token(nonce: nonce, rdi: offer.nodeIdPrefix) == token
    }
}

/// What a helper tries for one search (route-search helper rule), from offers it heard itself: up to 3 target
/// sightings whose RDI gives the token (strongest first), and up to `fanout` version 5 helper offers on the same bearer
/// whose RDI does not start with a skip prefix (budget 2 only). Peers are the app's dialable row IDs.
public struct RelaySeekPlan<P> {
    public let targets: [(peer: P, rdi: Data)]
    public let helpers: [(peer: P, rdi: Data)]

    public init(offers allOffers: [OfferSighting<P>], nonce: Data, token: Data, skip: [Data], budget: Int, bearer: MeshTransport, ownRdis: [Data],
                fanout: Int = RelaySeek.defaultFanout, badAddresses: Set<String> = [], plainId: Data? = nil) {
        let offers = allOffers.filter { !badAddresses.contains($0.address) }
        // Heard twice first, then the stronger signal (route-search helper rule).
        let strongest = offers.sorted { a, b in
            let ta = a.count >= 2, tb = b.count >= 2
            if ta != tb { return ta }
            return (a.rssi ?? -127) > (b.rssi ?? -127)
        }
        targets = Array(strongest.filter { o in
            // A plain SETUP handled as a search compares the ID directly (no token).
            if let plainId { return RelayedCalls.consents(o.announcement, rotating: true) && o.announcement.transport == bearer
                && !ownRdis.contains(o.announcement.nodeIdPrefix) && o.announcement.nodeIdPrefix == plainId }
            return RelaySeek.matches(o.announcement, nonce: nonce, token: token, bearer: bearer, ownRdis: ownRdis)
        }
            .prefix(RelaySeek.maxTargetAddresses).map { ($0.peer, $0.announcement.nodeIdPrefix) })
        if budget >= 2 {
            let targetRdis = Set(targets.map(\.rdi))
            helpers = Array(strongest.filter { o in
                let rdi = o.announcement.nodeIdPrefix
                return RelayedCalls.isRelayHelperOffer(o.announcement, rotating: true) && o.announcement.transport == bearer
                    && !ownRdis.contains(rdi) && !targetRdis.contains(rdi) && !skip.contains(rdi.prefix(RelaySeek.skipPrefixBytes).rebased)
            }.prefix(fanout).map { ($0.peer, $0.announcement.nodeIdPrefix) })
        } else { helpers = [] }
    }
}

/// Advertiser addresses whose link failed the opening of the sought ID: not dialled again by this helper in that epoch
/// (Android RelaySeekBadAddresses; a copied advert costs one dial per epoch).
public final class RelaySeekBadAddresses {
    private var epoch: Int64 = .min
    private var addresses = Set<String>()
    public init() {}
    public func record(_ address: String, epoch: Int64) { if epoch != self.epoch { self.epoch = epoch; addresses = [] }; addresses.insert(address) }
    public func current(epoch: Int64) -> Set<String> { epoch == self.epoch ? addresses : [] }
}

/// A helper's search budgets over a rolling 10 minutes (Android RelaySeekBudgets): duty at most 60 s, on-demand scanning
/// 30 s, 12 outgoing dials and 12 handshakes, 10 s between searches. Only work done is charged; a search that ends in
/// READY gets its duty and scan time back.
public final class RelaySeekBudgets {
    public static let windowMs: Int64 = 600_000
    public let dutyMs: Int64, scanMs: Int64, dials: Int, handshakes: Int, gapMs: Int64
    private var dutyLog: [(at: Int64, ms: Int64)] = []
    private var scanLog: [(at: Int64, ms: Int64)] = []
    private var dialLog: [Int64] = []
    private var handshakeLog: [Int64] = []
    private var lastEnd: Int64?
    public init(scale: Double = 1) {
        dutyMs = Int64(60_000 * scale); scanMs = Int64(30_000 * scale); dials = Int(12 * scale); handshakes = Int(12 * scale); gapMs = 10_000
    }
    private func trim(_ now: Int64) {
        dutyLog.removeAll { now - $0.at >= Self.windowMs }; scanLog.removeAll { now - $0.at >= Self.windowMs }
        dialLog.removeAll { now - $0 >= Self.windowMs }; handshakeLog.removeAll { now - $0 >= Self.windowMs }
    }
    public func remainingDutyMs(now: Int64) -> Int64 { trim(now); return max(0, dutyMs - dutyLog.reduce(0) { $0 + $1.ms }) }
    public func remainingScanMs(now: Int64) -> Int64 { trim(now); return max(0, scanMs - scanLog.reduce(0) { $0 + $1.ms }) }
    public func exhausted(now: Int64) -> Bool {
        trim(now)
        return remainingDutyMs(now: now) <= 0 || remainingScanMs(now: now) <= 0 || dialLog.count >= dials || handshakeLog.count >= handshakes
    }
    /// Nil admits; otherwise the reason a request is refused (FAIL 5) before any radio work.
    public func refusal(budget: Int, now: Int64) -> String? {
        trim(now)
        if let lastEnd, now - lastEnd < gapMs { return "gap" }
        let minimum = Int64(budget == 1 ? RelaySeek.minAllowanceBudget1Ms : RelaySeek.minAllowanceBudget2Ms)
        if remainingDutyMs(now: now) < minimum { return "duty" }
        if dialLog.count >= dials { return "dials" }
        if handshakeLog.count >= handshakes { return "handshakes" }
        return nil
    }
    /// When the budgets first ran out (helpers withdraw their flag after 60 s of exhaustion), or nil.
    public private(set) var exhaustedSince: Int64?
    /// The listener signs RELAY_SEEK only while a budget-1 search still fits (9 s of duty left) and nothing ran out.
    public func signing(now: Int64) -> Bool {
        let ok = !exhausted(now: now) && remainingDutyMs(now: now) >= Int64(RelaySeek.minAllowanceBudget1Ms)
        if ok { exhaustedSince = nil } else if exhaustedSince == nil { exhaustedSince = now }
        return ok
    }
    /// After 60 s of exhaustion the helper flag is withdrawn until recovery.
    public func withdrawHelperFlag(now: Int64) -> Bool { !signing(now: now) && now - (exhaustedSince ?? now) >= 60_000 }
    public func chargeDial(now: Int64) { dialLog.append(now) }
    public func chargeHandshake(now: Int64) { handshakeLog.append(now) }
    /// The search ended: charge its duty and scan time unless it reached READY.
    public func finish(startedAt: Int64, scanMs: Int64, ready: Bool, now: Int64) {
        lastEnd = now
        guard !ready else { return }
        dutyLog.append((now, max(0, now - startedAt))); if scanMs > 0 { scanLog.append((now, scanMs)) }
    }
}

/// FAILs re-sent without work for the same nonce, token, budget and skip list within 60 s (64 entries). READY never.
public final class RelaySeekFailCache {
    private var entries: [(key: String, at: Int64, reason: RelaySetupFailure)] = []
    public init() {}
    static func key(budget: Int, nonce: Data, token: Data, skip: [Data]) -> String {
        "\(budget)|\(nonce.hex)|\(token.hex)|\(skip.map(\.hex).joined(separator: ","))"
    }
    public func lookup(budget: Int, nonce: Data, token: Data, skip: [Data], now: Int64) -> RelaySetupFailure? {
        entries.removeAll { now - $0.at >= 60_000 }
        let k = Self.key(budget: budget, nonce: nonce, token: token, skip: skip)
        return entries.first { $0.key == k }?.reason
    }
    public func store(budget: Int, nonce: Data, token: Data, skip: [Data], reason: RelaySetupFailure, now: Int64) {
        entries.append((Self.key(budget: budget, nonce: nonce, token: token, skip: skip), now, reason))
        while entries.count > 64 { entries.removeFirst() }
    }
}
