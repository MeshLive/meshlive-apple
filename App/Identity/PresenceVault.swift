import Foundation
import NearbyCore

/// EXPERIMENTAL rotating discovery IDs, phase 2 (Android PresenceVault/PresenceStore): persists PresenceVaultState (the
/// rules live there and are unit-tested) as one Keychain item, this device only, deleted by the emergency wipe.
///
/// Reinstall: iOS keeps Keychain items when the app is deleted, but not the app's files (the verified contacts) or its
/// preferences. The first launch of a fresh install therefore drops every contact record and starts a new generation
/// (marker `presenceVaultInstalled` in UserDefaults), so no phone that held the old keys recognises this one.
final class PresenceVault {
    private static let account = "presence-vault"
    private static let installMarker = "presenceVaultInstalled"
    private var state: PresenceVaultState
    private let lock = NSLock()
    let recognition = RecognitionTable()
    /// False when the Keychain could not be read or written: the phone then advertises from memory, sends no OFFER
    /// and stores nothing (Android: never regenerate over an unreadable store, no lease from a non-persistent vault).
    private(set) var persistent = true

    init(epoch: () -> Int64) {
        var loaded = PresenceVaultState()
        let existing = try? KeychainItem.read(Self.account)
        if let data = existing ?? nil {
            if let decoded = try? JSONDecoder().decode(PresenceVaultState.self, from: data) { loaded = decoded } else { persistent = false }
        }
        state = loaded
        if !UserDefaults.standard.bool(forKey: Self.installMarker) {
            if (existing ?? nil) != nil, persistent {
                state.freshInstall(epoch: epoch())
                AppLog.event("rotid_presence", ["event": "generation", "reason": "fresh_install", "generation": "\(state.generation)"])
                save()
            }
            UserDefaults.standard.set(true, forKey: Self.installMarker)
        }
    }

    private func save() {
        do { try KeychainItem.write(Self.account, try JSONEncoder().encode(state)); persistent = true }
        catch { persistent = false; AppLog.event("rotid_presence", ["event": "store", "result": "write_failed"]) }
    }

    private func rolled(_ epoch: Int64) -> [Int64: Data] {
        let next = DayKeyWindow.roll(state.dayKeys, epoch: epoch)
        if next != state.dayKeys { state.dayKeys = next; save() }
        return next
    }

    var generation: UInt32 { lock.lock(); defer { lock.unlock() }; return state.generation }

    func entry(nodeId: NodeId, epoch: Int64, role: UInt8) -> OpeningEntry {
        lock.lock(); defer { lock.unlock() }
        let keys = rolled(epoch)
        return PresenceLeases.ownEntry(dayKeys: keys, nodeId: nodeId.bytes, epoch: epoch, role: role)
            ?? RotatingDiscoveryIds.entry(saltKey: randomBytes(32), nodeId: nodeId.bytes, epoch: epoch, role: role)
    }

    func ownDayKey(epoch: Int64) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return state.dayKeys[PresenceLeases.dayOf(epoch)]
    }

    func newGeneration(epoch: Int64, reason: String) {
        lock.lock(); defer { lock.unlock() }
        state.newGeneration(epoch: epoch)
        save()
        AppLog.event("rotid_presence", ["event": "generation", "generation": "\(state.generation)", "reason": reason])
    }

    func canSeeMe(_ peer: NodeId) -> Bool { lock.lock(); defer { lock.unlock() }; return state.canSeeMe(peer.hex) }

    func setCanSeeMe(_ peer: NodeId, _ on: Bool, epoch: Int64) {
        lock.lock(); defer { lock.unlock() }
        if state.setCanSeeMe(peer.hex, on, epoch: epoch) {
            AppLog.event("rotid_presence", ["event": "generation", "generation": "\(state.generation)", "reason": "contact_switch_off"])
        }
        save()
    }

    /// The lease for a verified contact, recorded as delivered before it is returned (RD1); nil when not eligible.
    func deliverLease(to peer: NodeId, epoch: Int64, verified: Bool) -> DiscoveryExchange.PresenceLease? {
        lock.lock(); defer { lock.unlock() }
        guard verified, persistent, state.canSeeMe(peer.hex) else { return nil }
        let keys = rolled(epoch)
        guard let lease = PresenceLeases.delivery(dayKeys: keys, generation: state.generation, epoch: epoch) else { return nil }
        var record = state.contacts[peer.hex] ?? PresenceVaultState.ContactRecord()
        record.deliveredGeneration = state.generation
        state.contacts[peer.hex] = record
        save()
        guard persistent else { return nil }
        return lease
    }

    func deliveredTo(_ peer: NodeId) -> Bool { lock.lock(); defer { lock.unlock() }; return state.holdsCurrentLease(peer.hex) }

    func store(_ lease: DiscoveryExchange.PresenceLease, from peer: NodeId, myEpoch: Int64) {
        lock.lock()
        var record = state.contacts[peer.hex] ?? PresenceVaultState.ContactRecord()
        let stored = record.leaseGeneration == 0 ? nil : ContactPresence(nodeId: peer.bytes, generation: record.leaseGeneration, leasesByDay: record.leases,
                                                                        skewEpochs: record.leaseSkew, receivedAt: record.leaseReceivedAt)
        let next = ContactPresence.receive(stored: stored, nodeId: peer.bytes, lease: lease, myEpoch: myEpoch, now: Date().timeIntervalSince1970)
        record.leaseGeneration = next.generation; record.leaseSkew = next.skewEpochs
        record.leaseReceivedAt = next.receivedAt; record.leases = next.leasesByDay
        state.contacts[peer.hex] = record
        save()
        lock.unlock()
        AppLog.event("rotid_presence", ["event": "lease_stored", "days": "\(next.leasesByDay.count)"])
        rebuildRecognition(myEpoch: myEpoch)
    }

    func leaseKey(of contact: Data, day: Int64) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return state.contacts[contact.hex]?.leases[day]
    }

    func forget(_ peer: NodeId, epoch: Int64) {
        lock.lock()
        if state.forget(peer.hex, epoch: epoch) {
            AppLog.event("rotid_presence", ["event": "generation", "generation": "\(state.generation)", "reason": "forget"])
        }
        save()
        lock.unlock()
        rebuildRecognition(myEpoch: epoch)
    }

    func rebuildRecognition(myEpoch: Int64) {
        lock.lock()
        var contacts: [ContactPresence] = []
        for (hex, record) in state.contacts where record.leaseGeneration > 0 {
            guard let id = Data(hex: hex) else { continue }
            let presence = ContactPresence(nodeId: id, generation: record.leaseGeneration, leasesByDay: record.leases,
                                           skewEpochs: record.leaseSkew, receivedAt: record.leaseReceivedAt)
            if let kept = presence.pruned(myEpoch: myEpoch) { contacts.append(kept) }
        }
        lock.unlock()
        recognition.rebuild(contacts, myEpoch: myEpoch, now: Date().timeIntervalSince1970)
    }
}
