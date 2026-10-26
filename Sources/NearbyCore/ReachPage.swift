import Foundation

// Reach pages (Android ReachPage.kt; PROTOCOL "Reach page"): the manufacturer 0xFFFF scan response of a relay's legacy,
// non-connectable set. `version 4 | relay prefix (6) | relay flags | page (index << 4 | count) | entries (1..2) x
// (target (6) | cost << 5 | age units | via (2))`, 18 or 27 bytes. Version 6 is the same layout with role-0 RDIs.

public struct ReachPageEntry: Equatable {
    public let target: Data
    /// Relays between the connecting phone and the target, the advertising relay included (1...4).
    public let cost: Int
    /// Age in 2-second units (0...31).
    public let ageUnits: Int
    /// First two bytes of the next hop (the target itself for cost 1): poison reverse.
    public let via: Data
    public init(target: Data, cost: Int, ageUnits: Int, via: Data) throws {
        guard target.count == 6 else { throw ProtocolError.malformed("Reach target prefix") }
        guard (1...ReachPageCodec.maxCost).contains(cost) else { throw ProtocolError.malformed("Reach cost") }
        guard (0...ReachPageCodec.maxAgeUnits).contains(ageUnits) else { throw ProtocolError.malformed("Reach age") }
        guard via.count == ReachPageCodec.viaBytes else { throw ProtocolError.malformed("Reach via") }
        self.target = target.rebased; self.cost = cost; self.ageUnits = ageUnits; self.via = via.rebased
    }
    public var ageMs: Int64 { Int64(ageUnits) * ReachPageCodec.ageUnitMs }
}

public struct ReachPage: Equatable {
    public let relayPrefix: Data
    /// Bit 0 LE CoC, bit 1 GATT, bit 3 idle.
    public let relayFlags: UInt8
    public let index: Int
    public let count: Int
    public let entries: [ReachPageEntry]
    /// Version 6: relay, targets and via are role-0 RDIs of the current epoch.
    public let rotating: Bool
    public init(relayPrefix: Data, relayFlags: UInt8, index: Int, count: Int, entries: [ReachPageEntry], rotating: Bool = false) {
        self.relayPrefix = relayPrefix.rebased; self.relayFlags = relayFlags; self.index = index; self.count = count
        self.entries = entries; self.rotating = rotating
    }
}

public enum ReachPageCodec {
    public static let version: UInt8 = 4
    public static let versionRdi: UInt8 = 6
    public static let headerBytes = 9, entryBytes = 9, maxEntriesPerPage = 2, maxPages = 4
    public static let maxCost = 4, maxAgeUnits = 31, viaBytes = 2
    public static let ageUnitMs: Int64 = 2_000
    public static let flagCoc: UInt8 = 1, flagGatt: UInt8 = 1 << 1, flagIdle: UInt8 = 1 << 3
    static let knownFlags: UInt8 = flagCoc | flagGatt | flagIdle

    public static func isReachPage(_ bytes: Data?) -> Bool {
        guard let first = bytes?.first else { return false }
        return first == version || first == versionRdi
    }

    /// Age in ms rounded up to 2-second units; nil when past the field maximum.
    public static func ageUnits(for ageMs: Int64) -> Int? {
        if ageMs < 0 { return 0 }
        let units = (ageMs + ageUnitMs - 1) / ageUnitMs
        return units > Int64(maxAgeUnits) ? nil : Int(units)
    }

    public static func flags(for transport: MeshTransport, idle: Bool) -> UInt8 {
        (transport == .l2cap ? flagCoc : flagGatt) | (idle ? flagIdle : 0)
    }

    public static func encode(_ page: ReachPage) throws -> Data {
        guard page.relayPrefix.count == 6 else { throw ProtocolError.malformed("Relay prefix") }
        guard page.relayFlags & ~knownFlags == 0 else { throw ProtocolError.malformed("Reserved relay flags") }
        guard (1...maxPages).contains(page.count), (0..<page.count).contains(page.index) else { throw ProtocolError.malformed("Reach page index") }
        guard (1...maxEntriesPerPage).contains(page.entries.count) else { throw ProtocolError.malformed("Reach entries per page") }
        guard !page.entries.contains(where: { $0.target == page.relayPrefix }) else { throw ProtocolError.malformed("Reach target is the relay") }
        guard Set(page.entries.map(\.target)).count == page.entries.count else { throw ProtocolError.malformed("Duplicate reach target") }
        var w = BinaryWriter()
        w.byte(page.rotating ? versionRdi : version); w.bytes(page.relayPrefix); w.byte(page.relayFlags)
        w.byte(UInt8((page.index << 4) | page.count))
        for e in page.entries { w.bytes(e.target); w.byte(UInt8((e.cost << 5) | e.ageUnits)); w.bytes(e.via) }
        return w.data
    }

    public static func decode(_ data: Data) throws -> ReachPage {
        let bytes = data.rebased
        guard bytes.count == headerBytes + entryBytes || bytes.count == headerBytes + 2 * entryBytes else {
            throw ProtocolError.malformed("Reach page length")
        }
        var r = BinaryReader(bytes)
        let v = try r.byte()
        guard v == version || v == versionRdi else { throw ProtocolError.malformed("Reach page version") }
        let relay = try r.bytes(6)
        let flags = try r.byte()
        guard flags & ~knownFlags == 0 else { throw ProtocolError.malformed("Reserved relay flags") }
        let page = Int(try r.byte())
        let index = page >> 4, count = page & 0x0f
        guard (1...maxPages).contains(count), index < count else { throw ProtocolError.malformed("Reach page index") }
        var entries: [ReachPageEntry] = []
        let n = (bytes.count - headerBytes) / entryBytes
        for _ in 0..<n {
            let target = try r.bytes(6)
            let costAge = Int(try r.byte())
            let via = try r.bytes(viaBytes)
            guard target != relay else { throw ProtocolError.malformed("Reach target is the relay") }
            entries.append(try ReachPageEntry(target: target, cost: costAge >> 5, ageUnits: costAge & 0x1f, via: via))
        }
        guard Set(entries.map(\.target)).count == entries.count else { throw ProtocolError.malformed("Duplicate reach target") }
        return ReachPage(relayPrefix: relay, relayFlags: flags, index: index, count: count, entries: entries, rotating: v == versionRdi)
    }

    /// `entries` (best first) in pages of at most two, at most `maxPages` pages.
    public static func pages(relayPrefix: Data, relayFlags: UInt8, entries: [ReachPageEntry], maxPages: Int = 2, rotating: Bool = false) throws -> [Data] {
        let kept = Array(entries.prefix(maxPages * maxEntriesPerPage))
        let chunks = stride(from: 0, to: kept.count, by: maxEntriesPerPage).map { Array(kept[$0..<min($0 + maxEntriesPerPage, kept.count)]) }
        return try chunks.enumerated().map { i, chunk in
            try encode(ReachPage(relayPrefix: relayPrefix, relayFlags: relayFlags, index: i, count: chunks.count, entries: chunk, rotating: rotating))
        }
    }
}
