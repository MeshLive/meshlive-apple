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
