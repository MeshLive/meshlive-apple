import Foundation

/// What a discovery row stands for: one advertised role of one node, independent of the radio address.
/// Android restarts advertising under a new random address (for example when its Call screen reopens), and
/// Core Bluetooth reports each address as a new peripheral; keying rows by peripheral produced duplicate,
/// stale rows. Rows are therefore keyed by node prefix + kind + route token, and the peripheral is just the
/// most recent way to reach that row.
public struct DiscoveryKey: Hashable, CustomStringConvertible {
    public enum Kind: UInt8 { case call = 1, stream = 2, viewerRequest = 3, other = 4 }
    public let prefix: Data
    public let kind: Kind
    /// Stream route token for stream offers and viewer requests; 0 for call offers.
    public let token: UInt32

    public init(_ announcement: DiscoveryAnnouncement) {
        prefix = announcement.nodeIdPrefix
        if announcement.isPrivateCallOffer { kind = .call; token = 0 }
        else if announcement.isStreamOffer { kind = .stream; token = announcement.streamToken }
        else if announcement.flags & DiscoveryAnnouncement.flagAcceptingConnections != 0 { kind = .viewerRequest; token = announcement.streamToken }
        else { kind = .other; token = announcement.streamToken }
    }

    /// Stable row identity (survives address rotation, so lists do not jump).
    public var rowId: UUID {
        var w = BinaryWriter()
        w.bytes(prefix.prefix(6) + Data(repeating: 0, count: max(0, 6 - prefix.count)))
        w.byte(kind.rawValue); w.u32(token)
        w.bytes(Data([0xD1, 0x5C, 0x0E, 0x7A, 0x00]))
        return UUID(rawBytes: w.data)
    }

    public var description: String { "\(prefix.hex)/\(kind)/\(String(format: "%08x", token))" }
}

public struct DiscoveryEntry: Equatable {
    public let key: DiscoveryKey
    public var rowId: UUID { key.rowId }
    /// The radio handle (Core Bluetooth peripheral identifier) that advertised most recently.
    public var handle: UUID
    public var announcement: DiscoveryAnnouncement
    public var rssi: Int
    public var isIPhone: Bool
    public var firstSeen: TimeInterval
    public var lastSeen: TimeInterval
}

/// Sans-I/O discovery bookkeeping (main queue in the app): dedup by `DiscoveryKey`, replace the handle on
/// a new address, expire rows not re-seen within `window` seconds.
public final class DiscoveryTable {
    public struct Change: Equatable {
        public var isNew = false
        public var announcementChanged = false
        public var handleReplaced = false
        public var removedRows: [UUID] = []
        public var listChanged: Bool { isNew || announcementChanged || !removedRows.isEmpty }
    }

    /// Rows disappear when not re-seen within this many seconds (Android advertises continuously while its
    /// Call/Live screen is open; foreground duplicate scanning reports it several times per second).
    public var window: TimeInterval
    private(set) public var entries: [DiscoveryKey: DiscoveryEntry] = [:]
    /// The one key each radio handle currently advertises (an address carries one advertisement set).
    private var keyByHandle: [UUID: DiscoveryKey] = [:]

    public init(window: TimeInterval = 8) { self.window = window }

    @discardableResult
    public func observe(handle: UUID, announcement: DiscoveryAnnouncement, rssi: Int, isIPhone: Bool, now: TimeInterval) -> Change {
        var change = Change()
        let key = DiscoveryKey(announcement)
        // The same address now advertises something else: its previous row is gone unless another address took it over.
        if let previous = keyByHandle[handle], previous != key, entries[previous]?.handle == handle {
            entries[previous] = nil
            change.removedRows.append(previous.rowId)
        }
        keyByHandle[handle] = key
        if var entry = entries[key] {
            if entry.handle != handle {
                change.handleReplaced = true
                keyByHandle[entry.handle] = nil
                entry.handle = handle
            }
            if entry.announcement != announcement { change.announcementChanged = true; entry.announcement = announcement }
            entry.rssi = rssi; entry.isIPhone = isIPhone; entry.lastSeen = now
            entries[key] = entry
        } else {
            entries[key] = DiscoveryEntry(key: key, handle: handle, announcement: announcement, rssi: rssi, isIPhone: isIPhone, firstSeen: now, lastSeen: now)
            change.isNew = true
        }
        return change
    }

    /// Removes rows not re-seen within `window`; returns their row IDs.
    @discardableResult
    public func expire(now: TimeInterval) -> [UUID] {
        let stale = entries.filter { now - $0.value.lastSeen > window }
        for (key, entry) in stale {
            entries[key] = nil
            if keyByHandle[entry.handle] == key { keyByHandle[entry.handle] = nil }
        }
        return stale.map { $0.key.rowId }
    }

    public func entry(rowId: UUID) -> DiscoveryEntry? { entries.values.first { $0.rowId == rowId } }

    /// Handles still referenced by a row (the radio may release other peripherals).
    public var liveHandles: Set<UUID> { Set(entries.values.map(\.handle)) }

    public func removeAll() { entries.removeAll(); keyByHandle.removeAll() }
}

// MARK: - Copied-ID warning (Android CopiedIdTracker, Design G)

/// Android's copied-ID warning (Design G, review F4) on Apple's discovery. Keys are the rotating discovery ID plus the
/// route cost. For one key, a coincidence is a sighting while another radio address (a Core Bluetooth peripheral
/// identifier: one per advertising address) of the same key was heard within `simultaneousMs` and, with the overlap
/// rule, was heard again after this address first appeared: the two interleave, so two senders are on the air at once.
/// A handover (the old address stops, a new one starts, as an advertising restart) never interleaves; a relay's mirror
/// at route cost + 1 is another key. Coincidences closer than `simultaneousMs` count once; `repeats` of them warn.
///
/// PC twin: a Windows PC sends one compact call offer from two advertising sets at once. Android exempts exactly two
/// recent addresses, one legacy and one extended, whose Flags and UUID lists (with 0x180A) are byte-identical. Core
/// Bluetooth reports neither the legacy/extended kind nor the Flags, so Apple exempts exactly two recent addresses whose
/// service UUID lists are identical and carry 0x180A (`twinForm`). An address replaced by a newer one of the same form
/// (`superseded`) is left out of the twin test only.
///
/// It disables nothing and sends nothing: the row says so and a call asks once more. Main queue only (`MeshRadio`).
public final class CopiedIdTracker {
    /// What the PC twin test compares: the advert's service UUIDs as received, nil unless 0x180A is among them.
    public struct TwinForm: Equatable {
        public let compared: String
    }

    public static let simultaneousMs: Int64 = 2_000
    public static let repeats = 2
    public static let staleMs: Int64 = 20 * 60_000
    public static let maxKeys = 512

    /// Android `test_copied_id_overlap` control arm: false counts any two addresses heard within 2 s (the old rule).
    public var requireOverlap = true
    /// Android `test_copied_id_pc_pair` control arm: false warns for a PC's twin sets too.
    public var pcPairExempt = true

    private final class Seen {
        let address: UUID
        let firstMs: Int64
        var lastMs: Int64
        var form: TwinForm?
        init(address: UUID, firstMs: Int64, form: TwinForm?) { self.address = address; self.firstMs = firstMs; lastMs = firstMs; self.form = form }
    }

    private var perKey: [String: [Seen]] = [:]
    private var touched: [String: Int64] = [:]
    private var coincidences: [String: Int] = [:]
    private var lastCoincidenceMs: [String: Int64] = [:]

    public init() {}

    /// The twin form of an advert from its service UUID strings (`CBUUID.uuidString`, "180A" for 0x180A).
    public static func twinForm(serviceUUIDs: [String]) -> TwinForm? {
        let upper = serviceUUIDs.map { $0.uppercased() }
        guard upper.contains("180A") else { return nil }
        return TwinForm(compared: upper.joined(separator: ","))
    }

    private static func key(_ id: Data, _ routeCost: UInt8) -> String { "\(id.hex)/\(routeCost)" }

    /// Records one rotating call offer. True when the warning is now due for this ID at this route cost.
    @discardableResult
    public func observe(id: Data, address: UUID, routeCost: UInt8, nowMs: Int64, form: TwinForm? = nil) -> Bool {
        let key = Self.key(id, routeCost)
        touched[key] = nowMs
        if touched.count > Self.maxKeys { prune(nowMs: nowMs) }
        var list = perKey[key] ?? []
        let own: Seen
        if let existing = list.first(where: { $0.address == address }) {
            existing.lastMs = nowMs
            // A sighting without a form never erases the form the address already showed.
            if let form { existing.form = form }
            own = existing
        } else {
            own = Seen(address: address, firstMs: nowMs, form: form)
            list.append(own)
        }
        perKey[key] = list
        let recent = list.filter { nowMs - $0.lastMs <= Self.simultaneousMs }
        // Superseded addresses leave only the twin test; the overlap scan below still sees every address.
        let exempt = pcPairExempt && Self.pcTwin(recent.filter { !Self.superseded($0, in: list) })
        let other = !exempt && list.contains {
            $0.address != address && nowMs - $0.lastMs <= Self.simultaneousMs
                // The other address was heard after this one appeared: both on the air, not one replacing the other.
                && (!requireOverlap || $0.lastMs > own.firstMs)
        }
        if other, lastCoincidenceMs[key].map({ nowMs - $0 > Self.simultaneousMs }) ?? true {
            coincidences[key, default: 0] += 1
            lastCoincidenceMs[key] = nowMs
        }
        return (coincidences[key] ?? 0) >= Self.repeats
    }

    /// Exactly two recent addresses with the same non-nil form are one PC (Apple form of Android's twin rule).
    private static func pcTwin(_ recent: [Seen]) -> Bool {
        guard recent.count == 2, let a = recent[0].form, let b = recent[1].form else { return false }
        return a == b
    }

    /// `old` was replaced, not joined: another address with the same non-nil form was first heard strictly after `old`
    /// was last heard. If `old` is heard again after that, the two interleave and `old` counts again.
    private static func superseded(_ old: Seen, in all: [Seen]) -> Bool {
        guard let form = old.form else { return false }
        return all.contains { $0 !== old && $0.form == form && $0.firstMs > old.lastMs }
    }

    /// True while the warning is due for this ID at any route cost.
    public func warned(_ id: Data) -> Bool {
        let prefix = id.hex + "/"
        return coincidences.contains { $0.key.hasPrefix(prefix) && $0.value >= Self.repeats }
    }

    /// Drops every key not heard for `staleMs` (an ID that left the air at an epoch change is never needed again).
    public func prune(nowMs: Int64) {
        for (key, at) in touched where nowMs - at > Self.staleMs {
            touched[key] = nil; perKey[key] = nil; coincidences[key] = nil; lastCoincidenceMs[key] = nil
        }
    }
}
