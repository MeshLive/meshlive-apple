import Foundation
import CryptoKit

// EXPERIMENTAL rotating discovery IDs, phase 1 (off by default; Android "Experimental rotating discovery IDs"). Call-ready presence advertises compact UUID v2 whose 6 ID bytes are a 15-minute
// rotating ID (RDI) instead of the fixed node prefix. A caller that selected a v2 advert requires the link
// opening BDO1 (hop type 13, link hello bit 3) and recomputes it from the authenticated node ID.
// Streams, viewer requests, forwarders and relay chains keep the fixed prefix in this phase.

public enum RotatingDiscoveryIds {
    /// The epoch length of every release and every non-benchmark launch (PROTOCOL "Keys and epochs").
    public static let defaultEpochSeconds: Int64 = 900
    /// The epoch length in force: `defaultEpochSeconds` unless a DEBUG launch gave `-NearbyRotidEpochS <60...900>` before
    /// rotating discovery started (`DiscoveryEpochLength`, harness only, as Android `test_rotid_epoch_s`). The wire format
    /// does not carry it, so both phones of a test must use the same value.
    public fileprivate(set) static var epochSeconds: Int64 = defaultEpochSeconds
    public static let idBytes = 6, saltBytes = 32, presenceKeyBytes = 32
    public static let roleCallOffer: UInt8 = 0, roleStreamOffer: UInt8 = 1, roleViewerRequest: UInt8 = 2
    public static let saltDomain = Data("BluetoothVideoMesh/Discovery/Salt/1".utf8) + Data([0])
    public static let idDomain = Data("BluetoothVideoMesh/Discovery/Id/1".utf8) + Data([0])
    public static let leaseDomain = Data("BluetoothVideoMesh/Discovery/Lease/1".utf8) + Data([0])

    public static func wallEpoch(unixSeconds: Int64) -> Int64 { Int64((Double(unixSeconds) / Double(epochSeconds)).rounded(.down)) }
    /// This phone's wall-clock epoch now (the verifier's reference for the opening window).
    public static func currentWallEpoch() -> Int64 { wallEpoch(unixSeconds: Int64(Date().timeIntervalSince1970)) }
    /// Lease week of an epoch (672 epochs = 7 days).
    public static func week(of epoch: Int64) -> Int64 { Int64((Double(epoch) / 672).rounded(.down)) }

    static func u32(_ v: Int64) -> Data { var w = BinaryWriter(); w.u32(UInt32(truncatingIfNeeded: v)); return w.data }
    static func hmac(_ key: Data, _ message: Data) -> Data { Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))) }

    /// L_w = HMAC-SHA256(P, lease domain || u32 w) (the owner's salts are keyed by the week's lease).
    public static func leaseKey(presenceKey: Data, week: Int64) -> Data { hmac(presenceKey, leaseDomain + u32(week)) }

    public static func salt(key: Data, epoch: Int64, role: UInt8) -> Data { hmac(key, saltDomain + u32(epoch) + Data([role])) }

    public static func rdi(nodeId: Data, epoch: Int64, role: UInt8, salt: Data) -> Data {
        Data(SHA256.hash(data: idDomain + nodeId + u32(epoch) + Data([role]) + salt)).prefix(idBytes)
    }

    /// The opening entry with `saltKey` as the salt key (a lease key, or a vector's P).
    public static func entry(saltKey: Data, nodeId: Data, epoch: Int64, role: UInt8) -> OpeningEntry {
        let s = salt(key: saltKey, epoch: epoch, role: role)
        return OpeningEntry(rdi: rdi(nodeId: nodeId, epoch: epoch, role: role, salt: s), epoch: epoch, role: role, salt: s)
    }

    /// The entry this phone publishes: salts keyed by L_w(e) derived from the presence key.
    public static func ownEntry(presenceKey: Data, nodeId: Data, epoch: Int64, role: UInt8) -> OpeningEntry {
        entry(saltKey: leaseKey(presenceKey: presenceKey, week: week(of: epoch)), nodeId: nodeId, epoch: epoch, role: role)
    }
}

/// AB4: DEBUG harness `-NearbyRotidEpochS <60...900>` (Android `test_rotid_epoch_s`, `DiscoveryEpochLength`): a shorter
/// epoch so a phone test sees a boundary in minutes. Gates: a DEBUG build, a value in 60...900, and rotating discovery not
/// yet started (the length is set once, before the epoch clock loads its stored state). Nothing else changes: the wire
/// format, real-time lease days (`PresenceLeases.dayOf`) and every check. Both phones of a test must use the same value:
/// an opening counts only within two epochs of the verifier's own wall epoch, so unequal lengths fail as stale, by design.
public enum DiscoveryEpochLength {
    public static let minSeconds: Int64 = 60
    public static let maxSeconds: Int64 = 900

    /// Applies `seconds`; true when it is in force afterwards because of this call (or already was, unchanged).
    @discardableResult
    public static func set(_ seconds: Int64, debugBuild: Bool, started: Bool) -> Bool {
        guard debugBuild, (minSeconds...maxSeconds).contains(seconds) else { return false }
        if started { return seconds == RotatingDiscoveryIds.epochSeconds }
        RotatingDiscoveryIds.epochSeconds = seconds
        return true
    }

    /// Tests only: back to the release length.
    public static func resetForTests() { RotatingDiscoveryIds.epochSeconds = RotatingDiscoveryIds.defaultEpochSeconds }
}

/// `RDI (6) | epoch u32 | role u8 | salt (32)`.
public struct OpeningEntry: Equatable {
    public static let bytes = 43
    public let rdi: Data, epoch: Int64, role: UInt8, salt: Data
    public init(rdi: Data, epoch: Int64, role: UInt8, salt: Data) { self.rdi = rdi.rebased; self.epoch = epoch; self.role = role; self.salt = salt.rebased }

    /// True when this entry opens `selected` for `nodeId` (recomputed, never trusted).
    public func opens(selected: Data, nodeId: Data, expectedRole: UInt8) -> Bool {
        role == expectedRole && rdi == selected && RotatingDiscoveryIds.rdi(nodeId: nodeId, epoch: epoch, role: role, salt: salt) == selected
    }
}

/// Link opening `"BDO1" | version 1 | count (0..2) | count x entry` (strict).
public enum DiscoveryOpeningCodec {
    public static let magic = Data("BDO1".utf8)
    public static let version: UInt8 = 1
    public static let maxEntries = 2

    public static func encode(_ entries: [OpeningEntry]) throws -> Data {
        guard entries.count <= maxEntries else { throw ProtocolError.malformed("At most two opening entries") }
        var w = BinaryWriter(); w.bytes(magic); w.byte(version); w.byte(UInt8(entries.count))
        for e in entries { w.bytes(e.rdi); w.u32(UInt32(truncatingIfNeeded: e.epoch)); w.byte(e.role); w.bytes(e.salt) }
        return w.data
    }

    public static func decode(_ data: Data) throws -> [OpeningEntry] {
        let d = data.rebased
        guard d.count >= 6 else { throw ProtocolError.malformed("Opening too short") }
        guard d.prefix(4) == magic else { throw ProtocolError.malformed("Not a BDO1 opening") }
        guard d[4] == version else { throw ProtocolError.malformed("Unsupported opening version") }
        let count = Int(d[5])
        guard count <= maxEntries else { throw ProtocolError.malformed("Too many opening entries") }
        guard d.count == 6 + count * OpeningEntry.bytes else { throw ProtocolError.malformed("Invalid opening length") }
        var r = BinaryReader(d.dropFirst(6).rebased)
        return try (0..<count).map { _ in
            OpeningEntry(rdi: try r.bytes(6), epoch: Int64(try r.u32()), role: try r.byte(), salt: try r.bytes(32))
        }
    }
}

/// the check follows the advert the caller selected, never the peer's hello.
public enum DiscoverySelectionCheck {
    public enum Result: Equatable { case pass, prefixMismatch, openingMissing, openingMismatch, openingStale }
    /// an opening entry counts only within two epochs of the verifier's wall-clock epoch, so a forger cannot
    /// build one 2^48 table for a fixed epoch and invert any victim ID of any epoch.
    public static let epochTolerance: Int64 = 2
    /// - Parameter verifierWallEpoch: this phone's wall epoch (nil skips the opening window; only tests of the ID itself do).
    public static func check(selected: DiscoveryAnnouncement, expectedRole: UInt8, peerNodeId: Data, openingEntries: [OpeningEntry]?,
                             verifierWallEpoch: Int64? = nil) -> Result {
        guard selected.rotating else { return peerNodeId.prefix(6) == selected.nodeIdPrefix ? .pass : .prefixMismatch }
        guard let entries = openingEntries else { return .openingMissing }
        guard let opening = entries.first(where: { $0.opens(selected: selected.nodeIdPrefix, nodeId: peerNodeId, expectedRole: expectedRole) }) else {
            return .openingMismatch
        }
        if let wall = verifierWallEpoch, abs(opening.epoch - wall) > epochTolerance { return .openingStale }
        return .pass
    }
}

/// Monotonic epoch (Android DiscoveryEpochClock): a tick only when the wall epoch changes or 960 s of
/// monotonic time passed; E = max(wall, last + 1) at a tick; reused otherwise; after a reboot reused only
/// while the wall agrees; a forward offset above 96 epochs lasting 1 h of consistent wall time starts a new
/// presence generation.
public struct EpochClockState: Equatable, Codable {
    public var lastEpoch: Int64 = -1, tickWallEpoch: Int64 = -1, tickElapsedMs: Int64 = 0
    public var bootId = "", generation: Int64 = 1
    /// AB4: the epoch length `lastEpoch` was counted in (nil: the release 900 s, also for states stored by older builds).
    /// Another length makes the stored counter meaningless, so the clock restarts it and keeps the generation (Android).
    public var epochSeconds: Int64?
    public init(lastEpoch: Int64 = -1, tickWallEpoch: Int64 = -1, tickElapsedMs: Int64 = 0, bootId: String = "", generation: Int64 = 1,
                epochSeconds: Int64? = nil) {
        self.lastEpoch = lastEpoch; self.tickWallEpoch = tickWallEpoch; self.tickElapsedMs = tickElapsedMs; self.bootId = bootId; self.generation = generation
        self.epochSeconds = epochSeconds
    }
    /// The length in force as a state stores it (nil while it is the release length).
    static var currentLength: Int64? {
        RotatingDiscoveryIds.epochSeconds == RotatingDiscoveryIds.defaultEpochSeconds ? nil : RotatingDiscoveryIds.epochSeconds
    }
}

public final class DiscoveryEpochClock {
    public static var elapsedTickMs: Int64 { (RotatingDiscoveryIds.epochSeconds + 60) * 1000 }
    public static let maxAheadEpochs: Int64 = 2  // as Android (2026-10-14; was 96)
    public static let aheadRecoveryMs: Int64 = 3_600_000
    public static let consistentWallToleranceMs: Int64 = 120_000
    public struct Reading: Equatable { public let epoch: Int64; public let ticked: Bool; public let newGeneration: Bool }

    public private(set) var state: EpochClockState
    private let bootId: String
    private let persist: (EpochClockState) -> Void
    private var aheadSince: Int64?
    private var aheadWallOffset: Int64 = 0

    public init(state: EpochClockState, bootId: String, persist: @escaping (EpochClockState) -> Void) {
        self.bootId = bootId; self.persist = persist
        if state.epochSeconds != EpochClockState.currentLength {
            // A DEBUG short epoch (`DiscoveryEpochLength`) and later normal launches share one store: never carry E across lengths.
            self.state = EpochClockState(generation: state.generation, epochSeconds: EpochClockState.currentLength)
            persist(self.state)
        } else {
            self.state = state
        }
    }

    public func read(wallMs: Int64, elapsedMs: Int64) -> Reading {
        let wall = RotatingDiscoveryIds.wallEpoch(unixSeconds: Int64((Double(wallMs) / 1000).rounded(.down)))
        var current = state
        let tick: Bool
        if current.lastEpoch < 0 { tick = true }
        else if current.bootId != bootId { tick = wall != current.tickWallEpoch }
        else { tick = wall != current.tickWallEpoch || elapsedMs - current.tickElapsedMs >= Self.elapsedTickMs }
        // AB4F (finding 1, as Android RotatingDiscovery.kt:316-318): the lead over the wall is the epoch this read will
        // advertise, not the old stored one. After a backward wall step the tick advances the epoch again, so measuring
        // the old value cleared `aheadSince` at every boundary and the hour of lead never accumulated.
        let advertised = tick ? max(wall, current.lastEpoch + 1) : current.lastEpoch
        if advertised >= 0 && advertised - wall > Self.maxAheadEpochs {
            let offset = wallMs - elapsedMs
            if let since = aheadSince, abs(offset - aheadWallOffset) <= Self.consistentWallToleranceMs {
                if elapsedMs - since >= Self.aheadRecoveryMs {
                    current = EpochClockState(lastEpoch: wall, tickWallEpoch: wall, tickElapsedMs: elapsedMs, bootId: bootId, generation: current.generation + 1,
                                              epochSeconds: current.epochSeconds)
                    state = current; persist(current); aheadSince = nil
                    return Reading(epoch: wall, ticked: true, newGeneration: true)
                }
            } else {
                aheadSince = elapsedMs; aheadWallOffset = offset
            }
        } else {
            aheadSince = nil
        }
        guard tick else {
            if current.bootId != bootId {
                current.tickElapsedMs = elapsedMs; current.bootId = bootId
                state = current; persist(current)
            }
            return Reading(epoch: current.lastEpoch, ticked: false, newGeneration: false)
        }
        current.lastEpoch = advertised; current.tickWallEpoch = wall; current.tickElapsedMs = elapsedMs; current.bootId = bootId
        state = current; persist(current)
        return Reading(epoch: advertised, ticked: true, newGeneration: false)
    }
}

/// Pin rule: open only the role's ID that is on air, or that left the air less than 60 s ago (one instance per role:
/// the call listener's role 0, a waiting viewer's role 2).
public final class OpeningPins {
    public static let previousGraceMs: Int64 = 60_000
    private var current: OpeningEntry?
    private var currentOffAirMs: Int64?
    private var previous: OpeningEntry?
    private var previousOffAirMs: Int64 = Int64.min / 2
    public init() {}

    public func onAdvertised(_ entry: OpeningEntry, elapsedMs: Int64) {
        if current == entry { currentOffAirMs = nil; return }
        if let old = current { previous = old; previousOffAirMs = currentOffAirMs ?? elapsedMs }
        current = entry; currentOffAirMs = nil
    }
    public func offAir(elapsedMs: Int64) { if current != nil && currentOffAirMs == nil { currentOffAirMs = elapsedMs } }
    public func pinned(elapsedMs: Int64) -> [OpeningEntry] {
        var out: [OpeningEntry] = []
        if let current, currentOffAirMs.map({ elapsedMs - $0 < Self.previousGraceMs }) ?? true { out.append(current) }
        if let previous, elapsedMs - previousOffAirMs < Self.previousGraceMs { out.append(previous) }
        return out
    }
}

/// Visible-by-handle window: the fixed prefix (compact v1) until the first boundary at least 10 min later.
public enum VisibleByHandleWindow {
    public static let minSeconds: Int64 = 600
    public static var maxMs: Int64 { (minSeconds + RotatingDiscoveryIds.epochSeconds) * 1000 }
    public static func endEpoch(startUnixSeconds: Int64) -> Int64 {
        Int64((Double(startUnixSeconds + minSeconds + RotatingDiscoveryIds.epochSeconds - 1) / Double(RotatingDiscoveryIds.epochSeconds)).rounded(.down))
    }
    public static func isActive(endEpoch: Int64, nowUnixSeconds: Int64) -> Bool {
        endEpoch >= 0 && RotatingDiscoveryIds.wallEpoch(unixSeconds: nowUnixSeconds) < endEpoch
    }
}

/// Stranger tarpit: the responder delays its hello by 2^(n-6) s (capped at 30 s) for the n-th stranger handshake
/// in the epoch that has not led to a user-visible action; verified contacts are never delayed.
public final class StrangerTarpit {
    public static let capMs: Int64 = 30_000
    private var epoch: Int64 = -1, probes = 0
    public init() {}
    public static func delayMs(_ n: Int) -> Int64 {
        guard n > 0 else { return 0 }
        let exponent = n - 6
        if exponent >= 15 { return capMs }
        let ms: Int64 = exponent >= 0 ? 1000 << Int64(exponent) : 1000 >> Int64(-exponent)
        return min(ms, capMs)
    }
    public func nextDelayMs(epoch e: Int64) -> Int64 {
        if e != epoch { epoch = e; probes = 0 }
        probes += 1
        return Self.delayMs(probes)
    }
    public func forgive(epoch e: Int64) { if e == epoch && probes > 0 { probes -= 1 } }
}

/// Rotating discovery IDs phase 1b for streams on Apple platforms (Android protocol reference, phase 1b items 1-9).
/// The viewer side is built: a viewer request **mirrors the selected offer's version** (item 2), so a rotating
/// (version 5 / compact v2) offer is joined with a compact v2 request carrying this phone's role-2 RDI, never with the
/// fixed prefix. There is no downgrade: with the private viewer switched off (`-rotatingViewer NO`, a DEBUG control
/// arm) a rotating offer is refused instead. Forwarder offers do not rotate here yet (this device's own live offer
/// rotates with the Experimental source arm, `RotatingStreamOffer`), so a rotating stream is still not forwarded. Only a
/// DEBUG run that turns rotating IDs off altogether (the fixed prefix is then
/// public anyway, as call presence) joins, and may forward, a rotating stream with its fixed identity.
public enum RotatingStreamPolicy {
    public static let joinRefusal = "This stream uses private discovery. This app cannot join it yet without showing your phone's fixed ID."
    /// Android `AndroidVideoReceiver.viewerAnnouncement`: joining a version 2 offer shows the fixed prefix while waiting.
    public static let fixedIdNotice = "This source does not support private discovery. Your phone's fixed ID is visible while you join."

    /// The request this phone advertises to join an offer.
    public enum ViewerRequest: Equatable {
        /// Compact v1 with the fixed node prefix (a version 2 offer, or rotating IDs off).
        case fixedPrefix
        /// Compact v2 with this phone's role-2 RDI (a rotating offer).
        case rotating
        /// Not joined: a rotating offer while the private viewer is off (never a fixed-prefix request instead).
        case refused
    }

    public static func viewerRequest(offer: DiscoveryAnnouncement, rotatingIds: Bool, privateViewer: Bool) -> ViewerRequest {
        guard offer.rotating, rotatingIds else { return .fixedPrefix }
        return privateViewer ? .rotating : .refused
    }

    /// Why this phone does not join `offer`, or nil when it may.
    public static func joinRefusal(offer: DiscoveryAnnouncement, rotatingIds: Bool, privateViewer: Bool) -> String? {
        viewerRequest(offer: offer, rotatingIds: rotatingIds, privateViewer: privateViewer) == .refused ? joinRefusal : nil
    }

    /// Android `rotid_downgrade`: a join that puts the fixed prefix on air although rotating IDs hide it elsewhere.
    public static func showsFixedId(offer: DiscoveryAnnouncement, rotatingIds: Bool) -> Bool { rotatingIds && !offer.rotating }

    /// Whether an automatic route change (viewer recovery, the join auto-retry) may move a join of `original` to
    /// `candidate`: never from a rotating offer to a version 2 one while rotating IDs are on, because that request
    /// would put the fixed prefix on air without a tap (a decoy version 2 offer can carry any stream's logical token).
    /// Only the user's own tap joins a version 2 route, with the fixed-ID notice.
    public static func mayRouteAutomatically(from original: DiscoveryAnnouncement, to candidate: DiscoveryAnnouncement, rotatingIds: Bool) -> Bool {
        !(rotatingIds && original.rotating && !candidate.rotating)
    }

    /// Whether this phone may advertise a (fixed-prefix) forwarder offer for a stream it joined through `offer`.
    public static func mayForward(offer: DiscoveryAnnouncement, rotatingIds: Bool) -> Bool { !(offer.rotating && rotatingIds) }
}

/// A waiting viewer's rotating request (phase 1b items 2, 6 and 7): the compact v2 viewer request for a selected
/// rotating offer, one role-2 RDI per epoch, break-before-make at each boundary (stop, a uniform 1-8 s silence, then
/// the new epoch's ID) and the role-2 pins (`OpeningPins`, separate from the call role's). Restarts inside an epoch
/// reuse the epoch's ID (RV4).
public final class RotatingViewerRequest {
    public enum Decision: Equatable {
        case advertise(OpeningEntry)
        /// Nothing on air until `untilMs` (the boundary silence).
        case silent(untilMs: Int64)
    }

    /// The role-2 announcement for `entry`, mirroring the selected rotating `offer`: version 5 (compact v2), the offer's
    /// route token (copied before the wait, item 3), route cost and bitrate, and the transport flag of `transport`.
    /// No codec summary (Android `RotatingAdvertFields.forViewerRequest`: the link hello carries the decode mask) and no
    /// recovery hint (a compact v2 request has no field for one).
    public static func announcement(entry: OpeningEntry, offer: DiscoveryAnnouncement, transport: MeshTransport) throws -> DiscoveryAnnouncement {
        guard entry.role == RotatingDiscoveryIds.roleViewerRequest, entry.rdi.count == RotatingDiscoveryIds.idBytes else {
            throw ProtocolError.malformed("A viewer request uses the role-2 RDI")
        }
        guard offer.rotating, offer.isStreamOffer, offer.streamToken & 0x8000_0000 != 0 else {
            throw ProtocolError.malformed("A rotating viewer request answers a rotating stream offer")
        }
        var request = DiscoveryAnnouncement(nodeIdPrefix: entry.rdi,
                                            flags: DiscoveryAnnouncement.flagAcceptingConnections | (transport == .gatt ? DiscoveryAnnouncement.flagGattTransport : 0),
                                            capabilitySummary: 0, streamToken: offer.streamToken, routeCost: offer.routeCost,
                                            streamBitrateKbps: offer.streamBitrateKbps)
        request.rotating = true
        return request
    }

    public private(set) var pins = OpeningPins()
    private var onAir: OpeningEntry?
    private var silentUntilMs: Int64?
    /// The epoch of the last request that was on air and when it left, so a re-advertisement in a later epoch (a link
    /// that dropped after the boundary, a quick re-join) also follows the boundary silence instead of a gap that the
    /// connecting party chose.
    private var lastEpoch: Int64?
    private var lastOffAirMs: Int64 = Int64.min / 2
    public init() {}

    /// What the waiting viewer advertises now. `entryFor` gives this phone's role-2 entry of an epoch.
    public func decide(epoch: Int64, elapsedMs: Int64, entryFor: (Int64) -> OpeningEntry,
                       silenceMs: () -> Int64 = { Int64.random(in: 1_000...8_000) }) -> Decision {
        if let until = silentUntilMs {
            guard elapsedMs >= until else { return .silent(untilMs: until) }
            silentUntilMs = nil
        } else if let current = onAir, current.epoch != epoch {
            // Boundary: the old request leaves the air before the new one starts.
            pins.offAir(elapsedMs: elapsedMs)
            onAir = nil
            lastEpoch = nil
            let until = elapsedMs + min(8_000, max(1_000, silenceMs()))
            silentUntilMs = until
            return .silent(untilMs: until)
        } else if onAir == nil, let last = lastEpoch, last != epoch {
            // Off air since an earlier epoch: the new ID starts at least the uniform 1-8 s silence after the old one left.
            lastEpoch = nil
            let until = lastOffAirMs + min(8_000, max(1_000, silenceMs()))
            if elapsedMs < until { silentUntilMs = until; return .silent(untilMs: until) }
        }
        let entry: OpeningEntry
        if let current = onAir, current.epoch == epoch { entry = current } else { entry = entryFor(epoch) }
        onAir = entry
        pins.onAdvertised(entry, elapsedMs: elapsedMs)
        return .advertise(entry)
    }

    /// The request left the air (a parent connected, the join ended, or this phone advertises another role).
    public func offAir(elapsedMs: Int64) {
        pins.offAir(elapsedMs: elapsedMs)
        if let current = onAir { lastEpoch = current.epoch; lastOffAirMs = elapsedMs }
        onAir = nil
    }

    /// A join of a new stream starts: earlier requests (made for another stream's token) are never opened to its
    /// source. A boundary silence still running, and the last epoch on air, are kept (break-before-make holds).
    public func startJoin(elapsedMs: Int64) {
        offAir(elapsedMs: elapsedMs)
        pins = OpeningPins()
    }

    /// The role-2 entries a connection accepted at `elapsedMs` may open: on air, or off air for less than 60 s. Only
    /// role-2 entries: a sender opens only IDs of the role it advertised.
    public func acceptedEntries(elapsedMs: Int64) -> [OpeningEntry] {
        pins.pinned(elapsedMs: elapsedMs).filter { $0.role == RotatingDiscoveryIds.roleViewerRequest }
    }
}

/// A call listener's rotating presence (role 0) as the app runs it: one ID per epoch, break-before-make at each
/// boundary (stop, a uniform 1-8 s silence, then the new ID), and the entries a connection accepted now may open
/// (on air, or off air for less than 60 s: `OpeningPins`, evaluated at accept). Used by the MeshPeer test tool.
public final class RotatingCallPresence {
    public enum Step: Equatable { case none, stop, advertise(OpeningEntry) }
    private let entryFor: (Int64) -> OpeningEntry
    private let pins = OpeningPins()
    private var onAir: OpeningEntry?
    private var silentUntilMs: Int64?
    public init(entryFor: @escaping (Int64) -> OpeningEntry) { self.entryFor = entryFor }

    /// What the advertiser does now: advertise the first ID, stop at a boundary, or advertise the new ID once the
    /// silence is over.
    public func step(epoch: Int64, elapsedMs: Int64, silenceMs: () -> Int64 = { Int64.random(in: 1_000...8_000) }) -> Step {
        if let until = silentUntilMs {
            guard elapsedMs >= until else { return .none }
            silentUntilMs = nil
            return advertise(epoch, elapsedMs)
        }
        guard let current = onAir else { return advertise(epoch, elapsedMs) }
        guard current.epoch != epoch else { return .none }
        pins.offAir(elapsedMs: elapsedMs)
        onAir = nil
        silentUntilMs = elapsedMs + silenceMs()
        return .stop
    }

    private func advertise(_ epoch: Int64, _ elapsedMs: Int64) -> Step {
        let entry = entryFor(epoch)
        onAir = entry
        pins.onAdvertised(entry, elapsedMs: elapsedMs)
        return .advertise(entry)
    }

    /// The entries a connection accepted at `elapsedMs` may open.
    public func acceptedEntries(elapsedMs: Int64) -> [OpeningEntry] { pins.pinned(elapsedMs: elapsedMs) }
}

/// AB4, rotating discovery IDs phase 1b, source side (PROTOCOL phase 1b item 3; Android `RouteTokenWindow`). The route
/// tokens a source accepts in a viewer request: the current one, and each one it replaced less than 60 s earlier (at
/// most two), so a request that copied the offer's token just before a boundary still matches. `advance` keeps the grace
/// only for the same logical stream; a new logical token, or `clear`, drops every old token. A constant token (a
/// fixed-prefix offer) is exactly the old single-token test.
public final class RouteTokenWindow {
    public static let graceMs: Int64 = 60_000
    public static let maxRetired = 2
    private var logical: UInt32 = 0
    public private(set) var current: UInt32 = 0
    private var retired: [(token: UInt32, retiredAtMs: Int64)] = []
    public init() {}

    /// A new stream (or the first token): only `token` is accepted.
    public func reset(logical: UInt32, token: UInt32) {
        self.logical = logical
        current = token
        retired.removeAll()
    }

    /// The same stream's token changed (a boundary, a Visible-by-handle window): the old one gets the grace.
    public func advance(logical: UInt32, token: UInt32, nowMs: Int64) {
        guard current != 0, logical == self.logical else { reset(logical: logical, token: token); return }
        guard token != current else { return }
        retired.insert((current, nowMs), at: 0)
        if retired.count > Self.maxRetired { retired.removeLast(retired.count - Self.maxRetired) }
        retired.removeAll { $0.token == token }
        current = token
    }

    public func clear() {
        logical = 0
        current = 0
        retired.removeAll()
    }

    public func accepts(_ token: UInt32, nowMs: Int64) -> Bool {
        guard token != 0, current != 0 else { return false }
        if token == current { return true }
        return retired.contains { $0.token == token && nowMs - $0.retiredAtMs < Self.graceMs }
    }
}

/// AB4 (Experimental, `-rotatingSource`): this device's own rotating stream offer (phase 1b items 1, 6 and 7; Android
/// `RotatingStreamAnnouncements.streamOffer`, `RotatingAdvertFields.forStreamOffer`, `rotateStreamPresenceForBoundary`).
/// The offer carries the role-1 RDI in place of the prefix (version 5 / compact v2), the route token
/// `logical XOR mask(RDI)` and the bitrate rounded to the compact unit. One role-1 ID per epoch, break-before-make at each
/// boundary (stop, a uniform 1-8 s silence, then the new epoch's ID), its own role-1 pins (separate from the call role's
/// and the viewer role's), evaluated when a viewer link sends BDO1; restarts inside an epoch reuse the epoch's ID (RV4).
public final class RotatingStreamOffer {
    public enum Decision: Equatable {
        case advertise(OpeningEntry)
        /// Nothing on air until `untilMs` (the boundary silence).
        case silent(untilMs: Int64)
    }

    /// The unit of the compact UUID's bitrate field (Android `RotatingAdvertFields.BITRATE_UNIT_KBPS`).
    public static let bitrateUnitKbps = 25

    /// Android `RotatingAdvertFields.roundedBitrate`: the nearest 25 kbps, never 0 for a non-zero rate.
    public static func roundedBitrate(_ kbps: UInt16) -> UInt16 {
        guard kbps > 0 else { return 0 }
        let rounded = (Int(kbps) + bitrateUnitKbps / 2) / bitrateUnitKbps * bitrateUnitKbps
        return UInt16(min(max(rounded, bitrateUnitKbps), Int(UInt16.max)))
    }

    /// The rotating form of `base` (this source's fixed-prefix offer; every other field is kept).
    public static func announcement(base: DiscoveryAnnouncement, entry: OpeningEntry, logicalToken: UInt32) throws -> DiscoveryAnnouncement {
        guard entry.role == RotatingDiscoveryIds.roleStreamOffer, entry.rdi.count == RotatingDiscoveryIds.idBytes else {
            throw ProtocolError.malformed("A stream offer uses the role-1 RDI")
        }
        guard base.isStreamOffer, !base.usesClassic, base.recoveryFromNodeIdPrefix == nil else {
            throw ProtocolError.malformed("A rotating stream offer is an LE stream offer")
        }
        var offer = base
        offer.nodeIdPrefix = entry.rdi
        offer.streamToken = try StreamRouteToken.forAdvertiser(logical: logicalToken, prefix: entry.rdi)
        offer.streamBitrateKbps = roundedBitrate(base.streamBitrateKbps)
        offer.rotating = true
        return offer
    }

    private var pins = OpeningPins()
    private var onAir: OpeningEntry?
    /// The presence key generation the on-air entry was built from (AB4F: a revocation rebuilds it at once).
    private var onAirGeneration: Int64?
    private var silentUntilMs: Int64?
    /// The epoch of the last offer that was on air and when it left, so a re-advertisement in a later epoch also follows
    /// the boundary silence.
    private var lastEpoch: Int64?
    private var lastOffAirMs: Int64 = Int64.min / 2
    public init() {}

    /// What the live source advertises now. `entryFor` gives this device's role-1 entry of an epoch; `generation` is the
    /// presence key generation (or a revision of it): a new generation rebuilds the entry and its pins at once, even inside
    /// the same epoch, so a revoked lease does not stay on air until the boundary. A same-generation refresh reuses it.
    public func decide(epoch: Int64, elapsedMs: Int64, generation: Int64 = 0,
                       entryFor: (Int64) -> OpeningEntry,
                       silenceMs: () -> Int64 = { Int64.random(in: 1_000...8_000) }) -> Decision {
        if let until = silentUntilMs {
            guard elapsedMs >= until else { return .silent(untilMs: until) }
            silentUntilMs = nil
        } else if let current = onAir, current.epoch != epoch {
            // Boundary: the old offer leaves the air before the new one starts.
            pins.offAir(elapsedMs: elapsedMs)
            onAir = nil
            lastEpoch = nil
            let until = elapsedMs + min(8_000, max(1_000, silenceMs()))
            silentUntilMs = until
            return .silent(untilMs: until)
        } else if onAir == nil, let last = lastEpoch, last != epoch {
            // Off air since an earlier epoch: the new ID starts at least the uniform 1-8 s silence after the old one left.
            lastEpoch = nil
            let until = lastOffAirMs + min(8_000, max(1_000, silenceMs()))
            if elapsedMs < until { silentUntilMs = until; return .silent(untilMs: until) }
        }
        let entry: OpeningEntry
        if let current = onAir, current.epoch == epoch, onAirGeneration == generation {
            entry = current
        } else {
            // A new key generation: the old entry must not stay advertised or openable (its pins go too).
            if onAirGeneration != nil, onAirGeneration != generation { pins = OpeningPins() }
            entry = entryFor(epoch)
            onAirGeneration = generation
        }
        onAir = entry
        pins.onAdvertised(entry, elapsedMs: elapsedMs)
        return .advertise(entry)
    }

    /// The rotating offer left the air (the live ended, another role took the radio, or the fixed offer of a
    /// Visible-by-handle window is on air).
    public func offAir(elapsedMs: Int64) {
        pins.offAir(elapsedMs: elapsedMs)
        if let current = onAir { lastEpoch = current.epoch; lastOffAirMs = elapsedMs }
        onAir = nil
    }

    /// The offer changes form back to rotating (a Visible-by-handle window ended): nothing on air for a uniform 1-8 s,
    /// then the current epoch's ID, as at a boundary (PROTOCOL: the window starts and ends on a new advertising set).
    public func restart(elapsedMs: Int64, silenceMs: () -> Int64 = { Int64.random(in: 1_000...8_000) }) {
        offAir(elapsedMs: elapsedMs)
        lastEpoch = nil
        silentUntilMs = elapsedMs + min(8_000, max(1_000, silenceMs()))
    }

    /// The role-1 entries a viewer link may open when it sends BDO1: on air, or off air for less than 60 s. Only role-1
    /// entries: a sender opens only IDs of the role it advertised.
    public func acceptedEntries(elapsedMs: Int64) -> [OpeningEntry] {
        pins.pinned(elapsedMs: elapsedMs).filter { $0.role == RotatingDiscoveryIds.roleStreamOffer }
    }
}

/// AB4 (Experimental, `-rotatingSource`): which viewer requests this device's live source answers, and the rules of
/// phase 1b item 5 that depend on a request being rotating. Pure; `LiveController` applies them.
public enum RotatingSourcePolicy {
    /// A viewer request this source dials: the accepting flag, a route token in the window, this source's transport
    /// (Android's source filter), and a rotating request only while this source's rotating arm is on. With the arm off
    /// and a constant token this is exactly the old rule (fixed-prefix requests with the one token).
    public static func selects(_ request: DiscoveryAnnouncement, tokens: RouteTokenWindow, transport: MeshTransport,
                               rotatingArm: Bool, nowMs: Int64) -> Bool {
        guard request.flags & DiscoveryAnnouncement.flagAcceptingConnections != 0,
              request.transport == transport, tokens.accepts(request.streamToken, nowMs: nowMs) else { return false }
        return !request.rotating || rotatingArm
    }

    /// The child a request names for route recovery (tried first and not counted, `ViewerAdmissionGate.isRecovery`): a
    /// version 2 request's recovery prefix. A version 5 request's six spare bytes are an RV18 hint, never a prefix; this
    /// source does not match hints, so such a request is an ordinary one (Android: no match = ordinary admission).
    public static func namedChild(_ request: DiscoveryAnnouncement) -> Data? {
        request.rotating ? nil : request.recoveryFromNodeIdPrefix
    }

    /// Item 5: one authenticated link per node. When a rotating request's link authenticates as `node`, every other
    /// session already authenticated as that node is replaced (its request rotated while the older link was dying).
    /// A fixed-prefix request replaces nothing (Android `replaceSameNode` runs for version 5 requests only).
    public static func replacedSessions<Key: Hashable>(newKey: Key, node: NodeId, rotating: Bool, authenticated: [Key: NodeId]) -> [Key] {
        guard rotating else { return [] }
        return authenticated.filter { $0.key != newKey && $0.value == node }.map { $0.key }
    }
}

extension DiscoverySelectionCheck.Result {
    /// Android's name of the result in `rotid_open` log lines.
    public var logName: String {
        switch self {
        case .pass: return "PASS"
        case .prefixMismatch: return "PREFIX_MISMATCH"
        case .openingMissing: return "OPENING_MISSING"
        case .openingMismatch: return "OPENING_MISMATCH"
        case .openingStale: return "OPENING_STALE"
        }
    }
}
