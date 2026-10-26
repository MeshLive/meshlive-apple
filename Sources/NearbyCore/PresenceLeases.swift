import Foundation
import CryptoKit

// EXPERIMENTAL rotating discovery IDs, phase 2: daily keys, presence leases and recognition (Android
// PresenceLeases.kt, RotatingEndpoint.kt PresenceSession; PROTOCOL "Keys and epochs" and "Recognition and presence
// leases"). Pure and unit-tested against the Android vectors. A day key L_d is an independent random 32-byte key (the
// GAEN daily key model): no master key, no derivation between days; every salt, the owner's own included, is keyed by
// L_d(e). Mutual verified contacts exchange 28 days of keys in an answered call (BDX1 OFFER + LEASE).

public enum PresenceLeases {
    public static let epochsPerDay: Int64 = 96
    public static let daysPerDelivery = 28
    public static let leaseDomain = Data("BluetoothVideoMesh/Discovery/Lease/2".utf8) + Data([0])

    /// The day of an epoch: its start time's day (epoch * 900 / 86400 = epoch / 96).
    public static func dayOf(_ epoch: Int64) -> Int64 {
        let seconds = epoch * RotatingDiscoveryIds.epochSeconds
        return seconds >= 0 ? seconds / 86_400 : -((-seconds + 86_399) / 86_400)
    }

    /// MIGRATION AND VECTORS ONLY: Android's earlier derivation of day keys from a long-lived presence key P.
    public static func legacyLeaseKey(presenceKey: Data, day: Int64) -> Data {
        RotatingDiscoveryIds.hmac(presenceKey, leaseDomain + RotatingDiscoveryIds.u32(day))
    }

    /// The phone's own opening entry for an epoch: the salt keyed by that day's key.
    public static func ownEntry(dayKeys: [Int64: Data], nodeId: Data, epoch: Int64, role: UInt8) -> OpeningEntry? {
        guard let key = dayKeys[dayOf(epoch)] else { return nil }
        return RotatingDiscoveryIds.entry(saltKey: key, nodeId: nodeId, epoch: epoch, role: role)
    }

    /// The lease a contact receives at `epoch`: today and the next 27 days. Nil if a day is missing.
    public static func delivery(dayKeys: [Int64: Data], generation: UInt32, epoch: Int64) -> DiscoveryExchange.PresenceLease? {
        let first = dayOf(epoch)
        var keys: [Data] = []
        for offset in 0..<Int64(daysPerDelivery) {
            guard let key = dayKeys[first + offset] else { return nil }
            keys.append(key)
        }
        return DiscoveryExchange.PresenceLease(generation: generation, senderEpoch: UInt32(truncatingIfNeeded: epoch),
                                               firstDay: UInt32(truncatingIfNeeded: first), leases: keys)
    }
}

/// The owner's day-key window `[dayOf(E - 1), dayOf(E) + 27]`: keys created once from a CSPRNG when their day enters the
/// window and deleted when it leaves; an existing key is never replaced.
public enum DayKeyWindow {
    public static let daysAhead: Int64 = 27
    public static func firstDay(_ epoch: Int64) -> Int64 { PresenceLeases.dayOf(max(epoch - 1, 0)) }
    public static func lastDay(_ epoch: Int64) -> Int64 { PresenceLeases.dayOf(epoch) + daysAhead }
    public static func contains(epoch: Int64, day: Int64) -> Bool { (firstDay(epoch)...lastDay(epoch)).contains(day) }

    public static func roll(_ keys: [Int64: Data], epoch: Int64, newKey: () -> Data = { randomBytes(32) }) -> [Int64: Data] {
        var next = keys.filter { $0.key >= firstDay(epoch) }
        for day in PresenceLeases.dayOf(epoch)...lastDay(epoch) where next[day] == nil { next[day] = newKey() }
        return next
    }

    /// A brand-new window (a new generation): every key fresh.
    public static func fresh(epoch: Int64, newKey: () -> Data = { randomBytes(32) }) -> [Int64: Data] { roll([:], epoch: epoch, newKey: newKey) }

    /// MIGRATION AND VECTORS ONLY: the window derived from a presence key P the way earlier builds did.
    public static func migrated(presenceKey: Data, epoch: Int64) -> [Int64: Data] {
        var out: [Int64: Data] = [:]
        for day in firstDay(epoch)...lastDay(epoch) { out[day] = PresenceLeases.legacyLeaseKey(presenceKey: presenceKey, day: day) }
        return out
    }
}

/// What this phone stores for one contact's presence.
public struct ContactPresence: Equatable {
    public static let maxSkewEpochs: Int64 = 30 * PresenceLeases.epochsPerDay
    public static let maxDaysKept = 32
    public let nodeId: Data
    public let generation: UInt32
    public let leasesByDay: [Int64: Data]
    /// `sender epoch - my epoch` at receipt, clamped to +-30 days.
    public let skewEpochs: Int64
    public let receivedAt: TimeInterval

    public init(nodeId: Data, generation: UInt32, leasesByDay: [Int64: Data], skewEpochs: Int64, receivedAt: TimeInterval) {
        self.nodeId = nodeId; self.generation = generation; self.leasesByDay = leasesByDay; self.skewEpochs = skewEpochs; self.receivedAt = receivedAt
    }

    /// Receiver rule: a higher generation replaces; the same generation merges and drops days before the first
    /// delivered one, unless any shared day differs (a reused generation number: replace); a lower one is ignored.
    public static func receive(stored: ContactPresence?, nodeId: Data, lease: DiscoveryExchange.PresenceLease, myEpoch: Int64,
                               now: TimeInterval) -> ContactPresence {
        if let stored, lease.generation < stored.generation { return stored }
        var delivered: [Int64: Data] = [:]
        for (index, key) in lease.leases.enumerated() { delivered[Int64(lease.firstDay) + Int64(index)] = key }
        let sameKey = stored.map { s in
            s.generation == lease.generation && delivered.allSatisfy { entry in s.leasesByDay[entry.key].map { $0 == entry.value } ?? true }
        } ?? false
        var merged = delivered
        if let stored, sameKey {
            merged = stored.leasesByDay.filter { $0.key >= Int64(lease.firstDay) }.merging(delivered) { _, new in new }
            let keep = merged.keys.sorted().suffix(maxDaysKept)
            merged = merged.filter { keep.contains($0.key) }
        }
        let skew = min(max(Int64(lease.senderEpoch) - myEpoch, -maxSkewEpochs), maxSkewEpochs)
        return ContactPresence(nodeId: nodeId, generation: lease.generation, leasesByDay: merged, skewEpochs: skew, receivedAt: now)
    }

    /// Days before `dayOf(myEpoch + skew) - 1` are deleted (a seized holder keeps no finished day). Nil when none is left.
    public func pruned(myEpoch: Int64) -> ContactPresence? {
        let keepFrom = PresenceLeases.dayOf(myEpoch + skewEpochs) - 1
        let kept = leasesByDay.filter { $0.key >= keepFrom }
        if kept.count == leasesByDay.count { return self }
        if kept.isEmpty { return nil }
        return ContactPresence(nodeId: nodeId, generation: generation, leasesByDay: kept, skewEpochs: skewEpochs, receivedAt: receivedAt)
    }
}

/// For every contact, roles 0 and 1, every epoch in `myEpoch + skew + [-1, +1]` (`[-8, +8]` while the record is older
/// than 14 days) that a lease covers: RDI -> (contact, epoch, role). A hit is only a hint ("seen nearby, unconfirmed"),
/// never a check mark and never a reason to connect.
public final class RecognitionTable {
    public struct Hit: Equatable { public let contact: Data; public let epoch: Int64; public let role: UInt8 }
    public static let narrowRadius: Int64 = 1, wideRadius: Int64 = 8
    public static let staleAfter: TimeInterval = 14 * 24 * 3600
    public static let recognisedRoles: [UInt8] = [RotatingDiscoveryIds.roleCallOffer, RotatingDiscoveryIds.roleStreamOffer]
    private var table: [Data: [Hit]] = [:]
    /// Design OR: each contact's search window (node ID -> centre, staleness, role-0 IDs by epoch).
    private var windows: [Data: RelaySeekSelectors.Window] = [:]
    private let lock = NSLock()
    public init() {}

    public var size: Int { lock.lock(); defer { lock.unlock() }; return table.values.reduce(0) { $0 + $1.count } }

    public func rebuild(_ contacts: [ContactPresence], myEpoch: Int64, now: TimeInterval) {
        var next: [Data: [Hit]] = [:]
        var nextWindows: [Data: RelaySeekSelectors.Window] = [:]
        for contact in contacts {
            let stale = now - contact.receivedAt > Self.staleAfter
            let radius = stale ? Self.wideRadius : Self.narrowRadius
            let centre = myEpoch + contact.skewEpochs
            var callIds: [Int64: Data] = [:]
            for epoch in (centre - radius)...(centre + radius) where epoch >= 0 {
                guard let lease = contact.leasesByDay[PresenceLeases.dayOf(epoch)] else { continue }
                for role in Self.recognisedRoles {
                    let salt = RotatingDiscoveryIds.salt(key: lease, epoch: epoch, role: role)
                    let rdi = RotatingDiscoveryIds.rdi(nodeId: contact.nodeId, epoch: epoch, role: role, salt: salt)
                    next[rdi, default: []].append(Hit(contact: contact.nodeId, epoch: epoch, role: role))
                    if role == RotatingDiscoveryIds.roleCallOffer { callIds[epoch] = rdi }
                }
            }
            nextWindows[contact.nodeId] = RelaySeekSelectors.Window(centreEpoch: centre, stale: stale, ids: callIds)
        }
        lock.lock(); table = next; windows = nextWindows; lock.unlock()
    }

    /// Design OR: the search window of the one contact whose node ID starts with `prefixHex`; nil without IDs.
    public func seekWindow(prefixHex: String) -> RelaySeekSelectors.Window? {
        lock.lock(); defer { lock.unlock() }
        let hits = windows.filter { $0.key.hex.hasPrefix(prefixHex) }
        guard hits.count == 1, let w = hits.first?.value, !w.ids.isEmpty else { return nil }
        return w
    }

    /// Every contact whose ID equals `sixBytes`.
    public func lookup(_ sixBytes: Data) -> [Hit] { lock.lock(); defer { lock.unlock() }; return table[sixBytes.rebased] ?? [] }
}

/// The OFFER/LEASE exchange of one answered call between mutual verified contacts (Android PresenceSession).
public final class PresenceSession {
    public enum Action: Equatable { case sendOffer, sendLease, storeLease(DiscoveryExchange.PresenceLease), reject(String) }
    private let localEligible: Bool
    private var started = false, sentOffer = false, receivedOffer = false, sentLease = false, receivedLease = false
    public init(localEligible: Bool) { self.localEligible = localEligible }

    /// Once, when the call is answered. A peer that offered first gets the lease right after this side's OFFER.
    public func start() -> [Action] {
        guard localEligible, !started else { return [] }
        started = true; sentOffer = true
        if receivedOffer && !sentLease { sentLease = true; return [.sendOffer, .sendLease] }
        return [.sendOffer]
    }

    /// The OFFER could not be sent after all: this side never offered, so it neither sends nor stores a lease.
    public func offerWithheld() { sentOffer = false; sentLease = true }

    public func onRecord(_ record: DiscoveryExchange.Record, peerVerifiedNow: Bool) -> [Action] {
        switch record {
        case .opening: return [.reject("opening repeated")]
        case .identityReveal: return [.reject("reveal outside the reveal exchange")]
        case .recognitionOffer:
            if receivedOffer { return [.reject("duplicate offer")] }
            receivedOffer = true
            if sentOffer && !sentLease { sentLease = true; return [.sendLease] }
            return []
        case .presenceLease(let lease):
            if receivedLease { return [.reject("duplicate lease")] }
            if !sentOffer || !receivedOffer { return [.reject("lease without both offers")] }
            if !peerVerifiedNow { return [.reject("peer is not a verified contact")] }
            receivedLease = true
            return [.storeLease(lease)]
        }
    }
}

/// Phase 2 contact tags for BMH3 (Android Bmh3ContactTags "Real lease keys"): a caller that recognised the selected
/// advert as exactly one contact, and holds that contact's lease for the advert's day, tags msg1 with
/// `K_tag = HKDF-Expand(L_d, "BluetoothVideoMesh/BMH3/ContactTag/1")` bound to the RDI (role 0, epoch field 0); the
/// callee checks its own day key of each pinned call entry against that entry's RDI. A match means real keys both ways.
public enum PresenceContactTags {
    public static func initiatorTag(selected: DiscoveryAnnouncement, recognition: RecognitionTable,
                                    leaseKey: (Data, Int64) -> Data?) -> Bmh3ContactTag? {
        guard selected.rotating, selected.routeCost == 0 else { return nil }
        let hits = recognition.lookup(selected.nodeIdPrefix).filter { $0.role == RotatingDiscoveryIds.roleCallOffer }
        guard hits.count == 1, let hit = hits.first, let lease = leaseKey(hit.contact, PresenceLeases.dayOf(hit.epoch)),
              let key = try? Bmh3Crypto.contactTagKey(leaseKey: lease), let expected = try? NodeId(bytes: hit.contact) else { return nil }
        return try? Bmh3ContactTag(key: key, binding: Bmh3Crypto.advertBinding(selected6: selected.nodeIdPrefix, role: RotatingDiscoveryIds.roleCallOffer, wallEpoch: nil),
                                   expectedPeer: expected)
    }

    public static func responderChecks(entries: [OpeningEntry], ownDayKey: (Int64) -> Data?) -> [Bmh3ContactTag] {
        entries.filter { $0.role == RotatingDiscoveryIds.roleCallOffer }.compactMap { entry in
            guard let dayKey = ownDayKey(entry.epoch), let key = try? Bmh3Crypto.contactTagKey(leaseKey: dayKey) else { return nil }
            return try? Bmh3ContactTag(key: key, binding: Bmh3Crypto.advertBinding(selected6: entry.rdi, role: RotatingDiscoveryIds.roleCallOffer, wallEpoch: nil))
        }
    }
}
