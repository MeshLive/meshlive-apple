import Foundation
import CryptoKit

// EXPERIMENTAL rotating discovery IDs, phase 1 (off by default; Android "Experimental rotating discovery IDs",
// reviewed design RV1-RV19). Call-ready presence advertises compact UUID v2 whose 6 ID bytes are a 15-minute
// rotating ID (RDI) instead of the fixed node prefix. A caller that selected a v2 advert requires the link
// opening BDO1 (hop type 13, link hello bit 3) and recomputes it from the authenticated node ID (RV15).
// Streams, viewer requests, forwarders and relay chains keep the fixed prefix in this phase.

public enum RotatingDiscoveryIds {
    public static let epochSeconds: Int64 = 900
    public static let idBytes = 6, saltBytes = 32, presenceKeyBytes = 32
    public static let roleCallOffer: UInt8 = 0, roleStreamOffer: UInt8 = 1, roleViewerRequest: UInt8 = 2
    public static let saltDomain = Data("BluetoothVideoMesh/Discovery/Salt/1".utf8) + Data([0])
    public static let idDomain = Data("BluetoothVideoMesh/Discovery/Id/1".utf8) + Data([0])
    public static let leaseDomain = Data("BluetoothVideoMesh/Discovery/Lease/1".utf8) + Data([0])

    public static func wallEpoch(unixSeconds: Int64) -> Int64 { Int64((Double(unixSeconds) / Double(epochSeconds)).rounded(.down)) }
    /// This phone's wall-clock epoch now (the verifier's reference for RD4).
    public static func currentWallEpoch() -> Int64 { wallEpoch(unixSeconds: Int64(Date().timeIntervalSince1970)) }
    /// Lease week of an epoch (672 epochs = 7 days).
    public static func week(of epoch: Int64) -> Int64 { Int64((Double(epoch) / 672).rounded(.down)) }

    static func u32(_ v: Int64) -> Data { var w = BinaryWriter(); w.u32(UInt32(truncatingIfNeeded: v)); return w.data }
    static func hmac(_ key: Data, _ message: Data) -> Data { Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))) }

    /// L_w = HMAC-SHA256(P, lease domain || u32 w) (RV11: the owner's salts are keyed by the week's lease).
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

/// RV15: the check follows the advert the caller selected, never the peer's hello.
public enum DiscoverySelectionCheck {
    public enum Result: Equatable { case pass, prefixMismatch, openingMissing, openingMismatch, openingStale }
    /// RD4: an opening entry counts only within two epochs of the verifier's wall-clock epoch, so a forger cannot
    /// build one 2^48 table for a fixed epoch and invert any victim ID of any epoch.
    public static let epochTolerance: Int64 = 2
    /// - Parameter verifierWallEpoch: this phone's wall epoch (nil skips the RD4 window; only tests of the ID itself do).
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

/// RV4 monotonic epoch (Android DiscoveryEpochClock): a tick only when the wall epoch changes or 960 s of
/// monotonic time passed; E = max(wall, last + 1) at a tick; reused otherwise; after a reboot reused only
/// while the wall agrees; a forward offset above 96 epochs lasting 1 h of consistent wall time starts a new
/// presence generation.
public struct EpochClockState: Equatable, Codable {
    public var lastEpoch: Int64 = -1, tickWallEpoch: Int64 = -1, tickElapsedMs: Int64 = 0
    public var bootId = "", generation: Int64 = 1
    public init(lastEpoch: Int64 = -1, tickWallEpoch: Int64 = -1, tickElapsedMs: Int64 = 0, bootId: String = "", generation: Int64 = 1) {
        self.lastEpoch = lastEpoch; self.tickWallEpoch = tickWallEpoch; self.tickElapsedMs = tickElapsedMs; self.bootId = bootId; self.generation = generation
    }
}

public final class DiscoveryEpochClock {
    public static let elapsedTickMs: Int64 = (RotatingDiscoveryIds.epochSeconds + 60) * 1000
    public static let maxAheadEpochs: Int64 = 2  // RH4 (Android 2026-10-14; was 96)
    public static let aheadRecoveryMs: Int64 = 3_600_000
    public static let consistentWallToleranceMs: Int64 = 120_000
    public struct Reading: Equatable { public let epoch: Int64; public let ticked: Bool; public let newGeneration: Bool }

    public private(set) var state: EpochClockState
    private let bootId: String
    private let persist: (EpochClockState) -> Void
    private var aheadSince: Int64?
    private var aheadWallOffset: Int64 = 0

    public init(state: EpochClockState, bootId: String, persist: @escaping (EpochClockState) -> Void) {
        self.state = state; self.bootId = bootId; self.persist = persist
    }

    public func read(wallMs: Int64, elapsedMs: Int64) -> Reading {
        let wall = RotatingDiscoveryIds.wallEpoch(unixSeconds: Int64((Double(wallMs) / 1000).rounded(.down)))
        var current = state
        if current.lastEpoch >= 0 && current.lastEpoch - wall > Self.maxAheadEpochs {
            let offset = wallMs - elapsedMs
            if let since = aheadSince, abs(offset - aheadWallOffset) <= Self.consistentWallToleranceMs {
                if elapsedMs - since >= Self.aheadRecoveryMs {
                    current = EpochClockState(lastEpoch: wall, tickWallEpoch: wall, tickElapsedMs: elapsedMs, bootId: bootId, generation: current.generation + 1)
                    state = current; persist(current); aheadSince = nil
                    return Reading(epoch: wall, ticked: true, newGeneration: true)
                }
            } else {
                aheadSince = elapsedMs; aheadWallOffset = offset
            }
        } else {
            aheadSince = nil
        }
        let tick: Bool
        if current.lastEpoch < 0 { tick = true }
        else if current.bootId != bootId { tick = wall != current.tickWallEpoch }
        else { tick = wall != current.tickWallEpoch || elapsedMs - current.tickElapsedMs >= Self.elapsedTickMs }
        guard tick else {
            if current.bootId != bootId {
                current.tickElapsedMs = elapsedMs; current.bootId = bootId
                state = current; persist(current)
            }
            return Reading(epoch: current.lastEpoch, ticked: false, newGeneration: false)
        }
        let epoch = max(wall, current.lastEpoch + 1)
        current.lastEpoch = epoch; current.tickWallEpoch = wall; current.tickElapsedMs = elapsedMs; current.bootId = bootId
        state = current; persist(current)
        return Reading(epoch: epoch, ticked: true, newGeneration: false)
    }
}

/// Pin rule: open only the role-0 ID that is on air, or that left the air less than 60 s ago.
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
    public static let maxMs: Int64 = (minSeconds + RotatingDiscoveryIds.epochSeconds) * 1000
    public static func endEpoch(startUnixSeconds: Int64) -> Int64 {
        Int64((Double(startUnixSeconds + minSeconds + RotatingDiscoveryIds.epochSeconds - 1) / Double(RotatingDiscoveryIds.epochSeconds)).rounded(.down))
    }
    public static func isActive(endEpoch: Int64, nowUnixSeconds: Int64) -> Bool {
        endEpoch >= 0 && RotatingDiscoveryIds.wallEpoch(unixSeconds: nowUnixSeconds) < endEpoch
    }
}

/// RV8 tarpit: the responder delays its hello by 2^(n-6) s (capped at 30 s) for the n-th stranger handshake
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

/// Rotating discovery IDs phase 1b for streams (rotating viewer requests and forwarder offers, PROTOCOL Phase 1b items
/// 1-7) is not built on Apple platforms: this phone's viewer request and forwarder offer always carry its fixed prefix
/// (compact v1). While this phone runs rotating IDs it therefore neither joins nor forwards a stream whose offer
/// rotates (announcement version 5): Android mirrors such an offer with a rotating request, and a fixed-prefix one
/// would broadcast exactly the ID the setting hides. With the setting off the fixed prefix is public anyway, so a Mac
/// with Android compatibility still joins (and may forward) a rotating stream with its fixed identity.
public enum RotatingStreamPolicy {
    public static let joinRefusal = "This stream uses private discovery. This app cannot join it yet without showing your phone's fixed ID, so it is not joined while Rotating discovery IDs is on."

    /// Why this phone does not join `offer`, or nil when it may.
    public static func joinRefusal(offer: DiscoveryAnnouncement, rotatingIds: Bool) -> String? {
        offer.rotating && rotatingIds ? joinRefusal : nil
    }

    /// Whether this phone may advertise a (fixed-prefix) forwarder offer for a stream it joined through `offer`.
    public static func mayForward(offer: DiscoveryAnnouncement, rotatingIds: Bool) -> Bool { !(offer.rotating && rotatingIds) }
}

/// A call listener's rotating presence (role 0) as the app runs it: one ID per epoch, break-before-make at each
/// boundary (stop, a uniform 1-8 s silence, then the new ID, RV12), and the entries a connection accepted now may open
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
