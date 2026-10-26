import Foundation

// EXPERIMENTAL relayed private calls and multi-hop discovery (Android RelayedCalls.kt / RelaySetup.kt; PROTOCOL
// "Experimental relayed calls and multi-hop discovery", DECISIONS "Design C"). Off: no consent bit, no relay flag,
// no link-hello bit, and hop type 12 is rejected as unknown, exactly as before.

/// Why a hop refused or could not finish a relay setup (`FAIL` reason byte).
public enum RelaySetupFailure: UInt8, CaseIterable {
    case noRoute = 1, busy = 2, childAuthentication = 3, timeout = 4, refused = 5, loop = 6

    public var label: String {
        switch self {
        case .noRoute: return "no route"
        case .busy: return "busy"
        case .childAuthentication: return "child authentication failed"
        case .timeout: return "timeout"
        case .refused: return "refused"
        case .loop: return "loop"
        }
    }

    /// The plain sentence shown to the caller.
    public var userText: String {
        switch self {
        case .noRoute: return "A phone on the way could not reach them any more"
        case .busy: return "A phone on the way is busy with something else"
        case .childAuthentication: return "A phone on the way could not verify the next phone"
        case .timeout: return "Connecting through other phones took too long"
        case .refused: return "A phone on the way is not helping right now"
        case .loop: return "The route loops back on itself"
        }
    }
}

/// `BRS1` relay setup messages (hop type 12). Regenerated per hop; the setup ID is random per hop.
public enum RelaySetupMessage: Equatable {
    /// `rotating`: message 4 (`SETUP_RDI`), the target is a role-0 RDI of the current epoch.
    case setup(target: Data, budget: Int, remainingMs: Int, setupId: Data, rotating: Bool)
    case ready(setupId: Data, relays: Int)
    case fail(setupId: Data, reason: RelaySetupFailure)
    /// Design OR message 5: a search for one target ID blinded as `token` under `nonce`, with up to 3 two-byte RDI
    /// prefixes to skip. Regenerated per hop like SETUP; nonce, token and skip list travel unchanged.
    case seek(budget: Int, remainingMs: Int, setupId: Data, nonce: Data, token: Data, skip: [Data])

    public var setupId: Data {
        switch self {
        case .setup(_, _, _, let id, _), .ready(let id, _), .fail(let id, _), .seek(_, _, let id, _, _, _): return id
        }
    }
}

public enum RelaySetupCodec {
    public static let magic = Data("BRS1".utf8)
    public static let setupBytes = 24
    public static let replyBytes = 14
    public static let idBytes = 8
    public static let setup: UInt8 = 1, ready: UInt8 = 2, fail: UInt8 = 3, setupRdi: UInt8 = 4, seek: UInt8 = 5
    public static let seekBaseBytes = 33

    public static func encode(_ message: RelaySetupMessage) throws -> Data {
        var w = BinaryWriter()
        w.bytes(magic)
        switch message {
        case let .setup(target, budget, remainingMs, setupId, rotating):
            guard target.count == 6, target.contains(where: { $0 != 0 }) else { throw ProtocolError.malformed("Setup target") }
            guard (1...CallRelayChain.maxRelays).contains(budget) else { throw ProtocolError.malformed("Setup budget") }
            guard (RelayedCalls.minRemainingMs...RelayedCalls.setupDeadlineMs).contains(remainingMs) else { throw ProtocolError.malformed("Setup deadline") }
            guard setupId.count == idBytes else { throw ProtocolError.malformed("Setup ID") }
            w.byte(rotating ? setupRdi : setup); w.bytes(target); w.byte(UInt8(budget)); w.u32(UInt32(remainingMs)); w.bytes(setupId)
        case let .ready(setupId, relays):
            guard setupId.count == idBytes, (1...CallRelayChain.maxRelays).contains(relays) else { throw ProtocolError.malformed("Ready") }
            w.byte(ready); w.bytes(setupId); w.byte(UInt8(relays))
        case let .fail(setupId, reason):
            guard setupId.count == idBytes else { throw ProtocolError.malformed("Setup ID") }
            w.byte(fail); w.bytes(setupId); w.byte(reason.rawValue)
        case let .seek(budget, remainingMs, setupId, nonce, token, skip):
            try validateSeek(budget: budget, remainingMs: remainingMs, setupId: setupId, nonce: nonce, token: token, skip: skip)
            w.byte(seek); w.byte(UInt8(budget)); w.u32(UInt32(remainingMs)); w.bytes(setupId); w.bytes(nonce); w.bytes(token)
            w.byte(UInt8(skip.count)); skip.forEach { w.bytes($0) }
        }
        return w.data
    }

    static func validateSeek(budget: Int, remainingMs: Int, setupId: Data, nonce: Data, token: Data, skip: [Data]) throws {
        guard (1...RelaySeek.maxBudget).contains(budget) else { throw ProtocolError.malformed("Seek budget") }
        guard (RelayedCalls.minRemainingMs...RelayedCalls.setupDeadlineMs).contains(remainingMs) else { throw ProtocolError.malformed("Seek deadline") }
        guard setupId.count == idBytes else { throw ProtocolError.malformed("Setup ID") }
        guard nonce.count == RelaySeek.nonceBytes, nonce.contains(where: { $0 != 0 }) else { throw ProtocolError.malformed("Seek nonce") }
        guard token.count == RelaySeek.tokenBytes else { throw ProtocolError.malformed("Seek token") }
        guard skip.count <= RelaySeek.maxSkip, skip.allSatisfy({ $0.count == RelaySeek.skipPrefixBytes }) else { throw ProtocolError.malformed("Seek skip list") }
        guard Set(skip).count == skip.count else { throw ProtocolError.malformed("Seek skip list duplicates") }
    }

    /// Exactly one valid message. `acceptRdi` only with rotating IDs and relayed calls both on (message 4); `acceptSeek`
    /// only on a link where this listener signed `RELAY_SEEK` (message 5).
    public static func decode(_ data: Data, acceptRdi: Bool = false, acceptSeek: Bool = false) throws -> RelaySetupMessage {
        let bytes = data.rebased
        guard bytes.count >= 5, bytes.prefix(4) == magic else { throw ProtocolError.malformed("Relay setup magic") }
        var r = BinaryReader(bytes.suffix(from: 4).rebased)
        let type = try r.byte()
        switch type {
        case setup, setupRdi:
            guard type == setup || acceptRdi else { throw ProtocolError.malformed("Relay setup message \(type)") }
            guard bytes.count == setupBytes else { throw ProtocolError.malformed("Relay setup length") }
            let target = try r.bytes(6)
            let budget = Int(try r.byte())
            let remaining = Int(try r.u32())
            let id = try r.bytes(idBytes)
            guard target.contains(where: { $0 != 0 }) else { throw ProtocolError.malformed("Setup target is the zero prefix") }
            guard (1...CallRelayChain.maxRelays).contains(budget) else { throw ProtocolError.malformed("Setup budget") }
            guard (RelayedCalls.minRemainingMs...RelayedCalls.setupDeadlineMs).contains(remaining) else { throw ProtocolError.malformed("Setup deadline") }
            return .setup(target: target, budget: budget, remainingMs: remaining, setupId: id, rotating: type == setupRdi)
        case ready:
            guard bytes.count == replyBytes else { throw ProtocolError.malformed("Relay ready length") }
            let id = try r.bytes(idBytes)
            let relays = Int(try r.byte())
            guard (1...CallRelayChain.maxRelays).contains(relays) else { throw ProtocolError.malformed("Ready relays") }
            return .ready(setupId: id, relays: relays)
        case fail:
            guard bytes.count == replyBytes else { throw ProtocolError.malformed("Relay fail length") }
            let id = try r.bytes(idBytes)
            guard let reason = RelaySetupFailure(rawValue: try r.byte()) else { throw ProtocolError.malformed("Relay fail reason") }
            return .fail(setupId: id, reason: reason)
        case seek:
            guard acceptSeek else { throw ProtocolError.malformed("Relay setup message \(type)") }
            guard bytes.count >= seekBaseBytes else { throw ProtocolError.malformed("Relay seek length") }
            let budget = Int(try r.byte())
            let remaining = Int(try r.u32())
            let id = try r.bytes(idBytes)
            let nonce = try r.bytes(RelaySeek.nonceBytes)
            let token = try r.bytes(RelaySeek.tokenBytes)
            let count = Int(try r.byte())
            guard count <= RelaySeek.maxSkip, bytes.count == seekBaseBytes + RelaySeek.skipPrefixBytes * count else {
                throw ProtocolError.malformed("Relay seek length")
            }
            let skip = try (0..<count).map { _ in try r.bytes(RelaySeek.skipPrefixBytes) }
            try validateSeek(budget: budget, remainingMs: remaining, setupId: id, nonce: nonce, token: token, skip: skip)
            return .seek(budget: budget, remainingMs: remaining, setupId: id, nonce: nonce, token: token, skip: skip)
        default:
            throw ProtocolError.malformed("Relay setup message \(type)")
        }
    }

    public static func newSetupId() -> Data {
        var id = Data(count: idBytes)
        _ = id.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, idBytes, $0.baseAddress!) }
        return id
    }
}

/// The route a caller asked for: `relays` helpers between it and `target`, the first being the helper whose own offer
/// has the prefix `helperPrefix`. `rotating`: target and helper are role-0 RDIs (SETUP message 4, link openings).
public struct RelayRoute: Equatable {
    public let target: Data
    public let helperPrefix: Data
    public let relays: Int
    public let rotating: Bool
    public init(target: Data, helperPrefix: Data, relays: Int, rotating: Bool = false) {
        self.target = target; self.helperPrefix = helperPrefix; self.relays = relays; self.rotating = rotating
    }
}

public enum RelayedCalls {
    public static let defaultMaxRelays = 2
    /// Call-offer `capabilitySummary` bit 4: the target may be found and called through other phones.
    public static let consentBit: UInt8 = 1 << 4
    /// Link-hello transport-mask bit 4: "understands RELAY_SETUP (hop type 12)".
    public static let linkHelloSetupBit: UInt8 = 1 << 4
    public static let setupDeadlineMs = 20_000
    public static let minRemainingMs = 2_000
    public static let perHopReserveMs = 1_000
    /// Reply grace after the setup deadline: cleanup time for the last hop, not extra setup time.
    public static let setupReplyGraceMs = 2_000
    /// A helper closes an accepted link that has not finished the handshake and delivered its first record by then.
    public static let preSetupWaitMs = 20_000
    /// A connectable offer older than this is not dialled (it may have a new address).
    public static let offerFreshMs: Int64 = 30_000
    public static let maxCandidates = 3
    public static let candidateWindowMs: Int64 = 60_000

    /// Consent as seen in a call offer; `rotating` selects the population (version 5 vs version 2).
    public static func consents(_ offer: DiscoveryAnnouncement, rotating: Bool = false) -> Bool {
        offer.isPrivateCallOffer && offer.rotating == rotating && offer.routeCost == 0 && offer.capabilitySummary & consentBit != 0
    }

    /// A connectable idle helper offer: callers may open its listener and send SETUP.
    public static func isRelayHelperOffer(_ offer: DiscoveryAnnouncement, rotating: Bool = false) -> Bool {
        offer.isPrivateCallOffer && offer.rotating == rotating && offer.routeCost == 0 &&
            offer.flags & DiscoveryAnnouncement.flagRelayCapable != 0 && offer.flags & DiscoveryAnnouncement.flagAcceptingConnections != 0
    }

    /// The own cost-0 call offer with this phone's relayed-call bits (unchanged when both are off).
    public static func offerFor(_ base: DiscoveryAnnouncement, consentOn: Bool, helperActive: Bool, rotatingCompat: Bool = false) -> DiscoveryAnnouncement {
        if (base.rotating && !rotatingCompat) || base.routeCost != 0 || !base.isPrivateCallOffer { return base }
        var offer = base
        if consentOn { offer.capabilitySummary |= consentBit }
        if helperActive { offer.flags |= DiscoveryAnnouncement.flagRelayCapable }
        return offer
    }

    /// The link hello this phone signs: bit 4 with the feature on; an active helper also signs bit 6 and capacity 1.
    public static func linkCapabilities(_ base: NodeCapabilities, featureOn: Bool, helperActive: Bool) -> NodeCapabilities {
        guard featureOn else { return base }
        var caps = base
        caps.transportMask |= linkHelloSetupBit
        if helperActive { caps.transportMask |= NodeCapabilities.transportCallRelay; caps.maxChildren = max(caps.maxChildren, 1) }
        return caps
    }

    /// The helper-only link-hello evidence a caller requires before it sends SETUP.
    public static func linkAcceptsSetup(_ peer: NodeCapabilities) -> Bool {
        peer.transportMask & linkHelloSetupBit != 0 && peer.transportMask & NodeCapabilities.transportCallRelay != 0 && peer.maxChildren >= 1
    }

    /// The caller's own hello must show bit 4 before a helper reads SETUP.
    public static func linkUnderstandsSetup(_ peer: NodeCapabilities) -> Bool { peer.transportMask & linkHelloSetupBit != 0 }

    /// Remaining time passed to the next hop; nil when too little is left to try.
    public static func nextHopRemainingMs(remainingMs: Int, elapsedMs: Int) -> Int? {
        let left = remainingMs - elapsedMs - perHopReserveMs
        return left >= minRemainingMs ? left : nil
    }

    /// A minimal helper offer carrying `prefix` (version 5 for a rotating route): what a hop answering with a real key
    /// is checked against.
    public static func helperOfferFor(_ prefix: Data, rotating: Bool) -> DiscoveryAnnouncement {
        var offer = DiscoveryAnnouncement(nodeIdPrefix: prefix.prefix(6).rebased,
                                          flags: DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable |
                                              DiscoveryAnnouncement.flagRelayCapable,
                                          capabilitySummary: 0, streamToken: 0, routeCost: 0)
        offer.rotating = rotating
        return offer
    }

    /// The announcement a caller uses for a relayed route: the target at the route cost, the first hop's bearer flags.
    public static func routedAnnouncement(target: Data, cost: Int, hop: DiscoveryAnnouncement) -> DiscoveryAnnouncement {
        var offer = DiscoveryAnnouncement(
            nodeIdPrefix: target.prefix(6).rebased,
            flags: DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable |
                (cost > 0 ? DiscoveryAnnouncement.flagRelayCapable : 0) |
                (hop.flags & (DiscoveryAnnouncement.flagGattTransport | DiscoveryAnnouncement.flagClassicTransport)),
            // The target's codecs are not advertised along a route; the end-to-end hello decides.
            capabilitySummary: NodeCapabilities.codecVP9 | NodeCapabilities.codecAV1,
            streamToken: 0, routeCost: UInt8(cost))
        offer.rotating = hop.rotating
        return offer
    }
}

/// Why a helper refused a SETUP before touching the radio, in PROTOCOL's order.
public struct RelaySetupInputs {
    public var featureOn = true, helperAllowed = true, paused = false, busy = false, rateLimited = false
    public var parentIsSelf = false, parentIsTarget = false, targetIsSelf = false
    public var budget = 1, maxRelays = RelayedCalls.defaultMaxRelays, routeAvailable = true
    public init() {}
}

public enum RelaySetupAdmission {
    /// Nil accepts; otherwise the FAIL reason. A SETUP for this phone's own ID answers like a missing entry (review CP-1).
    public static func refusal(_ i: RelaySetupInputs) -> RelaySetupFailure? {
        if !i.featureOn || !i.helperAllowed || i.paused { return .refused }
        if i.busy { return .busy }
        if i.rateLimited { return .refused }
        if i.targetIsSelf { return .noRoute }
        if i.parentIsSelf || i.parentIsTarget { return .loop }
        if i.budget < 1 || i.budget > i.maxRelays { return .refused }
        if !i.routeAvailable { return .noRoute }
        return nil
    }
}

/// SETUP rate limits: `perParent` per parent key per minute, `overall` per minute (identities are free, so the overall
/// cap and one relay at a time are the bounds that hold). A pseudonymous parent is keyed by its link address.
public final class RelaySetupRateLimiter {
    public static let unknownAddressBucket = "addr:unknown"
    private let perParent: Int, overall: Int, windowMs: Int64
    private var byParent: [String: [Int64]] = [:]
    private var all: [Int64] = []
    private static let maxTrackedParents = 64
    public init(perParent: Int = 3, overall: Int = 10, windowMs: Int64 = 60_000) {
        self.perParent = perParent; self.overall = overall; self.windowMs = windowMs
    }
    public var trackedParents: Int { byParent.count }

    /// The limiter key: a real parent's prefix, or the link address of a pseudonymous one (unknown: one shared bucket).
    public static func key(parentPrefixHex: String, pseudonymous: Bool, remoteAddress: String?) -> String {
        guard pseudonymous else { return parentPrefixHex }
        guard let remoteAddress, !remoteAddress.isEmpty else { return unknownAddressBucket }
        return "addr:" + remoteAddress.uppercased()
    }

    public func tryAdmit(_ parent: String, nowMs: Int64) -> Bool {
        all.removeAll { nowMs - $0 >= windowMs }
        var own = (byParent[parent] ?? []).filter { nowMs - $0 < windowMs }
        if byParent.count > Self.maxTrackedParents {
            for (k, v) in byParent { let kept = v.filter { nowMs - $0 < windowMs }; if kept.isEmpty && k != parent { byParent[k] = nil } else { byParent[k] = kept } }
            while byParent.count > Self.maxTrackedParents,
                  let oldest = byParent.filter({ $0.key != parent }).min(by: { ($0.value.last ?? 0) < ($1.value.last ?? 0) })?.key {
                byParent[oldest] = nil
            }
        }
        guard all.count < overall, own.count < perParent else { byParent[parent] = own; return false }
        all.append(nowMs); own.append(nowMs); byParent[parent] = own
        return true
    }
}
