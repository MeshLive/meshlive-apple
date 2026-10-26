import Foundation
import CryptoKit

/// Where the presence vault is stored (the app: one Keychain item, this device only).
public protocol PresenceVaultStorage: AnyObject {
    /// The stored bytes, or nil when nothing is stored. Throws when a stored vault exists but cannot be read now
    /// (a locked device, a Keychain error): that is never treated as "nothing stored".
    func read() throws -> Data?
    /// Replaces the stored vault; a failure leaves the previous value in place (`KeychainReplace`).
    func write(_ data: Data) throws
    func delete() throws
}

/// Where the vault's guard record is stored (the app: a small file written durably, outside backups). `write` returns
/// only once the bytes are on disk (`DurableFile`); `read` returns nil when it was never written and throws when it
/// exists but cannot be read now.
public protocol PresenceVaultGuardStorage: AnyObject {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

/// What must survive a vault that cannot be read or written, recorded before the vault changes (Android keeps the
/// highest generation in its epoch clock, `GenerationFloor`; this record adds the revocation and intent state).
public struct PresenceVaultGuard: Codable, Equatable {
    /// The highest generation this phone stored or started (Android GenerationFloor).
    public var floor: UInt32 = 0
    /// Every generation up to and including this one was revoked: a stored vault at or below it is replaced at load.
    public var revokedThrough: UInt32 = 0
    /// A revocation was requested while the vault's generation was unknown (unreadable): the next vault loaded is
    /// revoked whatever its generation.
    public var revokePending = false
    /// Contacts switched off ("Can see when I'm nearby") whose switch-off is not yet stored in the vault, as keyed
    /// hashes of their node IDs (`PresenceVaultCore.guardKey`). No lease goes to them while it is pending.
    public var switchOffPending: [String] = []
    public init() {}
}

/// The phase 2 presence vault over a `PresenceVaultStorage` (Android PresenceVault): the rules of `PresenceVaultState`
/// plus the storage discipline that keeps revocations in force.
///
/// - A store that cannot be read is never overwritten: the vault runs with an in-memory **ephemeral** window (fresh
///   IDs nobody recognises), delivers no lease, recognises nobody and retries the read at most every 5 s.
/// - A store that does not decode is latched as corrupt; only "Reset presence key" replaces it.
/// - A revocation is recorded in the guard (durably, before the vault changes): the revoked generation, or a pending
///   revocation when the generation is unknown. A stored vault at or below the revoked generation, below the floor,
///   or loaded while a revocation is pending, is replaced by a fresh window under a new generation; its contacts stay.
///   If neither the guard nor the vault can be written, the stored vault is deleted rather than left valid.
/// - Switch-offs, Forget, Reset contacts and the launch reconciliation requested while the vault cannot be stored are
///   kept and applied when it can be (switch-offs also in the guard, so they survive a restart; Forget and Reset are
///   caught again by the next launch's reconciliation, since the verified contacts no longer hold those people).
/// - A day key is stored before it is used for a lease, and a delivery is stored before the lease is returned.
public final class PresenceVaultCore {
    public enum LoadState: Equatable { case loaded, unreadable, corrupt }
    public static let retryInterval: TimeInterval = 5
    private static let guardDomain = Data("MeshLive/PresenceVaultGuard/1".utf8) + Data([0])

    private let storage: PresenceVaultStorage
    private let guardStorage: PresenceVaultGuardStorage
    private let epochSource: () -> Int64
    private let uptime: () -> TimeInterval
    private let newKey: () -> Data
    private let lock = NSLock()
    private var state: PresenceVaultState?
    /// Nil until the guard could be read; the vault is not loaded without it.
    private var guardRecord: PresenceVaultGuard?
    private var corrupt = false
    private var ephemeral: [Int64: Data] = [:]
    private var lastRetry: TimeInterval?
    // Intents waiting for a vault that can be stored (in memory; switch-offs are also in the guard).
    private var pendingForgets = Set<String>()
    private var pendingResetAll = false
    private var pendingReconcile: Set<String>?
    /// iOS keeps Keychain items when the app is deleted but not its files: the first launch of a fresh install drops
    /// every contact record from a vault it finds and starts a new generation (once the vault could be read).
    private var pendingFreshInstall: Bool
    /// Guard changes made while the guard could not be read, merged into it once it can be.
    private var overlayRevoke = false
    private var overlaySwitchOffs: [String: Bool] = [:]
    private let onFreshInstallHandled: () -> Void
    public var log: (String, [String: String]) -> Void = { _, _ in }

    public init(storage: PresenceVaultStorage, guardStorage: PresenceVaultGuardStorage, epoch: @escaping () -> Int64,
                uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                newKey: @escaping () -> Data = { randomBytes(32) },
                freshInstall: Bool = false, onFreshInstallHandled: @escaping () -> Void = {}) {
        self.storage = storage; self.guardStorage = guardStorage; epochSource = epoch; self.uptime = uptime; self.newKey = newKey
        pendingFreshInstall = freshInstall; self.onFreshInstallHandled = onFreshInstallHandled
        lock.lock(); _ = ensureLoadedLocked(); lock.unlock()
    }

    /// The guard's key for a contact: a keyed hash, so the guard file does not list contacts' node IDs.
    static func guardKey(_ peerHex: String) -> String {
        Data(SHA256.hash(data: guardDomain + (Data(hex: peerHex) ?? Data()))).prefix(16).hex
    }

    // MARK: Loading

    /// True when the vault is stored (leases may be delivered and recognised).
    public var persistent: Bool { lock.lock(); defer { lock.unlock() }; return state != nil }

    public var loadState: LoadState {
        lock.lock(); defer { lock.unlock() }
        return state != nil ? .loaded : corrupt ? .corrupt : .unreadable
    }

    /// Loads (or creates) the vault; true when persistent. Call again to retry a transient failure.
    @discardableResult
    public func ensureLoaded() -> Bool { lock.lock(); defer { lock.unlock() }; return ensureLoadedLocked() }

    private func ensureLoadedLocked() -> Bool {
        if state != nil { return true }
        if corrupt { return false }
        guard loadGuardLocked(), let record = guardRecord else { return false }
        let stored: Data?
        do { stored = try storage.read() } catch {
            log("store", ["result": "unreadable"])
            return false
        }
        guard let stored else {
            // Nothing stored: a new vault above every generation used, written at its first change (a delivered or
            // stored lease), so a phone that never uses the experiment writes nothing.
            var created = PresenceVaultState()
            created.generation = Self.next(after: record, current: 0)
            created.dayKeys = DayKeyWindow.fresh(epoch: epochSource(), newKey: newKey)
            state = created; ephemeral = [:]
            finishFreshInstall()
            settlePendingLocked()
            return state != nil
        }
        guard let loaded = try? JSONDecoder().decode(PresenceVaultState.self, from: stored) else {
            corrupt = true
            log("store", ["result": "corrupt"])
            return false
        }
        let revoked = record.revokePending || loaded.generation <= record.revokedThrough || loaded.generation < record.floor
        if revoked || pendingFreshInstall {
            // A revoked generation (stored before the revocation could be, or an older copy) must never be used
            // again. A fresh install also starts over without the contacts the app no longer knows.
            var next = loaded
            if pendingFreshInstall { next.contacts = [:] }
            state = next
            _ = bumpLocked(reason: pendingFreshInstall && !revoked ? "fresh_install" : "revoked_generation")
            if state != nil { finishFreshInstall() }
        } else {
            state = loaded; ephemeral = [:]
            if loaded.generation > record.floor {
                var raised = record; raised.floor = loaded.generation
                _ = writeGuard(raised)
            }
        }
        settlePendingLocked()
        return state != nil
    }

    /// Reads the guard once; changes made while it was unreadable are merged in and written.
    private func loadGuardLocked() -> Bool {
        if guardRecord != nil { return true }
        do {
            if let data = try guardStorage.read() {
                // A guard that does not decode says nothing reliable: revoke whatever vault is loaded.
                guardRecord = (try? JSONDecoder().decode(PresenceVaultGuard.self, from: data)) ?? {
                    var unknown = PresenceVaultGuard(); unknown.revokePending = true; return unknown
                }()
            } else {
                guardRecord = PresenceVaultGuard()
            }
        } catch {
            log("store", ["result": "guard_unreadable"])
            return false
        }
        if overlayRevoke || !overlaySwitchOffs.isEmpty, var record = guardRecord {
            if overlayRevoke { record.revokePending = true }
            for (key, pending) in overlaySwitchOffs { Self.setSwitchOff(&record, key, pending) }
            overlayRevoke = false; overlaySwitchOffs = [:]
            _ = writeGuard(record)
        }
        return true
    }

    private static func setSwitchOff(_ record: inout PresenceVaultGuard, _ key: String, _ pending: Bool) {
        record.switchOffPending.removeAll { $0 == key }
        if pending { record.switchOffPending.append(key) }
    }

    /// Records a revocation whose generation is unknown, or a switch-off change, in the guard (durably when it can be
    /// read; otherwise in memory until it can).
    private func updateGuard(revoke: Bool = false, switchOff: (key: String, pending: Bool)? = nil) -> Bool {
        guard loadGuardLocked(), var record = guardRecord else {
            if revoke { overlayRevoke = true }
            if let switchOff { overlaySwitchOffs[switchOff.key] = switchOff.pending }
            return false
        }
        if revoke { record.revokePending = true }
        if let switchOff { Self.setSwitchOff(&record, switchOff.key, switchOff.pending) }
        return record == guardRecord ? true : writeGuard(record)
    }

    private func finishFreshInstall() {
        guard pendingFreshInstall else { return }
        pendingFreshInstall = false
        onFreshInstallHandled()
    }

    /// A generation above every one this phone used or revoked.
    private static func next(after record: PresenceVaultGuard, current: UInt32) -> UInt32 {
        max(record.floor, record.revokedThrough, current) &+ 1
    }

    /// While the store is unreadable every key lookup may retry the load, at most every few seconds.
    private func retryIfDue() {
        guard state == nil, !corrupt else { return }
        let now = uptime()
        if let last = lastRetry, now >= last, now - last < Self.retryInterval { return }
        lastRetry = now
        _ = ensureLoadedLocked()
    }

    /// Writes the guard durably; the in-memory record changes either way (it still applies in this process).
    private func writeGuard(_ record: PresenceVaultGuard) -> Bool {
        guardRecord = record
        do { try guardStorage.write(try JSONEncoder().encode(record)); return true }
        catch { log("store", ["result": "guard_write_failed"]); return false }
    }

    private func save(_ next: PresenceVaultState) -> Bool {
        do { try storage.write(try JSONEncoder().encode(next)); return true }
        catch { log("store", ["result": "write_failed"]); return false }
    }

    /// Stores `change(state)` with the pending switch-offs applied; false (state unchanged) when it could not be.
    private func mutate(_ change: (inout PresenceVaultState) -> Void) -> Bool {
        guard var next = state else { return false }
        change(&next)
        applySwitchOffs(&next)
        if let record = guardRecord, next.generation > record.floor {
            var raised = record; raised.floor = next.generation
            _ = writeGuard(raised)
        }
        guard save(next) else { return false }
        state = next
        clearStoredSwitchOffs()
        return true
    }

    /// Every pending switch-off whose contact has a record is applied to `next` (never a new key window with the
    /// contact still visible).
    private func applySwitchOffs(_ next: inout PresenceVaultState) {
        guard let pending = guardRecord?.switchOffPending, !pending.isEmpty else { return }
        for peer in next.contacts.keys where pending.contains(Self.guardKey(peer)) { next.contacts[peer]?.canSeeMe = false }
    }

    /// Switch-offs now stored in the vault leave the guard.
    private func clearStoredSwitchOffs() {
        guard let record = guardRecord, !record.switchOffPending.isEmpty, let current = state else { return }
        let stored = Set(current.contacts.filter { !$0.value.canSeeMe }.keys.map(Self.guardKey))
        let remaining = record.switchOffPending.filter { !stored.contains($0) }
        guard remaining != record.switchOffPending else { return }
        var cleared = record; cleared.switchOffPending = remaining
        _ = writeGuard(cleared)
    }

    /// Applies the intents that waited for a vault that can be stored, revoking when one of them touches a contact that
    /// holds a current lease.
    private func settlePendingLocked() {
        guard var next = state else { return }
        let hadIntents = pendingResetAll || !pendingForgets.isEmpty || pendingReconcile != nil
            || !(guardRecord?.switchOffPending.isEmpty ?? true)
        guard hadIntents else { return }
        var stale = Set<String>()
        if pendingResetAll { stale.formUnion(next.contacts.keys) }
        stale.formUnion(pendingForgets.filter { next.contacts[$0] != nil })
        if let verified = pendingReconcile { stale.formUnion(next.contacts.keys.filter { !verified.contains($0) }) }
        let switchOffs = guardRecord?.switchOffPending ?? []
        let revoke = stale.contains { next.holdsCurrentLease($0) }
            || next.contacts.contains { switchOffs.contains(Self.guardKey($0.key)) && $0.value.canSeeMe && next.holdsCurrentLease($0.key) }
        for peer in stale { next.contacts.removeValue(forKey: peer) }
        applySwitchOffs(&next)
        state = next
        let settled = revoke ? (bumpLocked(reason: "pending_intents") && state != nil) : (next == state && save(next))
        if settled {
            pendingResetAll = false; pendingForgets = []; pendingReconcile = nil
            clearStoredSwitchOffs()
        }
    }

    // MARK: Keys

    public var generation: UInt32 {
        lock.lock(); defer { lock.unlock() }
        return state?.generation ?? max(guardRecord.map { Self.next(after: $0, current: 0) - 1 } ?? 1, 1)
    }

    /// The day key for the day of `idEpoch`, the stored window rolled to `currentEpoch` (and stored) when it is
    /// missing; an ephemeral in-memory key while the vault is not persistent. Nil for a day outside the window.
    public func dayKey(idEpoch: Int64, currentEpoch: Int64) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return dayKeyLocked(idEpoch: idEpoch, currentEpoch: currentEpoch)
    }

    private func dayKeyLocked(idEpoch: Int64, currentEpoch: Int64) -> Data? {
        retryIfDue()
        let day = PresenceLeases.dayOf(idEpoch)
        guard DayKeyWindow.contains(epoch: currentEpoch, day: day) else { return nil }
        if let current = state {
            if let key = current.dayKeys[day] { return key }
            if rollLocked(currentEpoch), let key = state?.dayKeys[day] { return key }
        }
        ephemeral = DayKeyWindow.roll(ephemeral, epoch: currentEpoch, newKey: newKey)
        return ephemeral[day]
    }

    /// The window moved to `epoch` and stored; false when it could not be stored (the state is unchanged).
    private func rollLocked(_ epoch: Int64) -> Bool {
        guard let current = state else { return false }
        let rolled = DayKeyWindow.roll(current.dayKeys, epoch: epoch, newKey: newKey)
        if rolled == current.dayKeys { return true }
        return mutate { $0.dayKeys = rolled }
    }

    /// This phone's own opening entry for `epoch` (salt keyed by that day's key).
    public func entry(nodeId: NodeId, epoch: Int64, role: UInt8) -> OpeningEntry {
        lock.lock(); defer { lock.unlock() }
        let key = dayKeyLocked(idEpoch: epoch, currentEpoch: epoch) ?? newKey()
        return RotatingDiscoveryIds.entry(saltKey: key, nodeId: nodeId.bytes, epoch: epoch, role: role)
    }

    /// Daily maintenance at `epoch`: rolls the window and drops contacts' lease days that are over, stored once
    /// (Android `maintain`). True when the stored vault changed.
    @discardableResult
    public func maintain(epoch: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if state == nil { retryIfDue() }
        guard let current = state else {
            ephemeral = ephemeral.filter { $0.key >= DayKeyWindow.firstDay(epoch) }
            return false
        }
        var next = current
        next.dayKeys = DayKeyWindow.roll(current.dayKeys, epoch: epoch, newKey: newKey)
        for (peer, record) in current.contacts where record.leaseGeneration > 0 {
            guard let presence = Self.presence(peer, record) else { continue }
            guard let pruned = presence.pruned(myEpoch: epoch) else {
                var cleared = record
                cleared.leaseGeneration = 0; cleared.leaseSkew = 0; cleared.leaseReceivedAt = 0; cleared.leases = [:]
                next.contacts[peer] = cleared
                continue
            }
            if pruned.leasesByDay.count != record.leases.count { next.contacts[peer]?.leases = pruned.leasesByDay }
        }
        guard next != current else { return false }
        return mutate { $0 = next }
    }

    // MARK: Contacts

    private func switchOffPending(_ peerHex: String) -> Bool {
        let key = Self.guardKey(peerHex)
        return overlaySwitchOffs[key] ?? guardRecord?.switchOffPending.contains(key) ?? false
    }

    public func canSeeMe(_ peer: NodeId) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !switchOffPending(peer.hex) && (state?.canSeeMe(peer.hex) ?? true)
    }

    public func deliveredTo(_ peer: NodeId) -> Bool { lock.lock(); defer { lock.unlock() }; return state?.holdsCurrentLease(peer.hex) ?? false }

    public var contactCount: Int { lock.lock(); defer { lock.unlock() }; return state?.contacts.count ?? 0 }

    public func leaseKey(of contact: Data, day: Int64) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return state?.contacts[contact.hex]?.leases[day]
    }

    /// The lease for a verified contact (RD1): the window rolled and stored first, the delivery stored before the
    /// lease is returned, keys and generation from the same state. Nil (nothing delivered) when any step fails, and
    /// always while a switch-off for the contact waits to be stored.
    public func deliverLease(to peer: NodeId, epoch: Int64, verified: Bool) -> DiscoveryExchange.PresenceLease? {
        lock.lock(); defer { lock.unlock() }
        guard verified, let current = state else { return nil }
        if switchOffPending(peer.hex) {
            // Store the switch-off now that the node ID is known (the guard keeps only its hash).
            _ = mutate { s in
                var record = s.contacts[peer.hex] ?? PresenceVaultState.ContactRecord()
                record.canSeeMe = false
                s.contacts[peer.hex] = record
            }
            return nil
        }
        guard current.canSeeMe(peer.hex), !pendingResetAll, !pendingForgets.contains(peer.hex) else { return nil }
        guard rollLocked(epoch), let rolled = state else { return nil }
        guard PresenceLeases.delivery(dayKeys: rolled.dayKeys, generation: rolled.generation, epoch: epoch) != nil else { return nil }
        guard mutate({ s in
            var record = s.contacts[peer.hex] ?? PresenceVaultState.ContactRecord()
            record.deliveredGeneration = s.generation
            s.contacts[peer.hex] = record
        }), let stored = state else { return nil }
        return PresenceLeases.delivery(dayKeys: stored.dayKeys, generation: stored.generation, epoch: epoch)
    }

    /// Stores a contact's lease (the receiver rules of `ContactPresence.receive`, days already over dropped).
    @discardableResult
    public func store(_ lease: DiscoveryExchange.PresenceLease, from peer: NodeId, myEpoch: Int64, now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let current = state else { return false }
        let stored = current.contacts[peer.hex].flatMap { Self.presence(peer.hex, $0) }
        let received = ContactPresence.receive(stored: stored, nodeId: peer.bytes, lease: lease, myEpoch: myEpoch, now: now)
        if let stored, received == stored { return false }
        let kept = received.pruned(myEpoch: myEpoch)
        return mutate { s in
            var record = s.contacts[peer.hex] ?? PresenceVaultState.ContactRecord()
            record.leaseGeneration = kept?.generation ?? 0; record.leaseSkew = kept?.skewEpochs ?? 0
            record.leaseReceivedAt = kept?.receivedAt ?? 0; record.leases = kept?.leasesByDay ?? [:]
            s.contacts[peer.hex] = record
        }
    }

    /// Contacts that gave this phone leases, pruned to `myEpoch` (for the recognition table).
    public func leaseHolders(myEpoch: Int64) -> [ContactPresence] {
        lock.lock(); defer { lock.unlock() }
        guard let current = state else { return [] }
        return current.contacts.compactMap { Self.presence($0.key, $0.value)?.pruned(myEpoch: myEpoch) }
    }

    /// "Can see when I'm nearby". Turning it off is recorded in the guard first, so a vault write that fails cannot
    /// lose it; off for a contact that holds a current lease revokes it (true).
    @discardableResult
    public func setCanSeeMe(_ peer: NodeId, _ on: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // Off is recorded before the vault is touched; on clears it (the vault then holds the new value).
        _ = updateGuard(switchOff: (Self.guardKey(peer.hex), !on))
        guard let current = state else { return failClosed(revoke: !on) }
        let revoke = !on && current.holdsCurrentLease(peer.hex)
        if current.canSeeMe(peer.hex) != on {
            _ = mutate { s in
                var record = s.contacts[peer.hex] ?? PresenceVaultState.ContactRecord()
                record.canSeeMe = on
                s.contacts[peer.hex] = record
            }
        }
        return revoke ? bumpLocked(reason: "contact_switch_off") : false
    }

    /// Forgets a contact: revokes first when it holds a current lease, then drops its record. While the vault cannot
    /// be stored the removal waits (and the next generation is revoked whatever it is).
    @discardableResult
    public func forget(_ peer: NodeId) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let current = state else { pendingForgets.insert(peer.hex); return failClosed(revoke: true) }
        guard current.contacts[peer.hex] != nil else { return false }
        let revoked = current.holdsCurrentLease(peer.hex) ? bumpLocked(reason: "forget") : false
        if state == nil || !mutate({ $0.contacts.removeValue(forKey: peer.hex) }) { pendingForgets.insert(peer.hex) }
        return revoked
    }

    /// Drops the records of contacts that are no longer verified, revoking when one held a current lease. Catches a
    /// Forget or a reset that happened while the vault could not run, so a former contact cannot keep recognising
    /// this phone. `verified` holds node IDs in hex. While the vault cannot be read the reconciliation waits for it.
    @discardableResult
    public func reconcile(verified: Set<String>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let current = state else { pendingReconcile = verified; return false }
        let stale = current.contacts.keys.filter { !verified.contains($0) }
        guard !stale.isEmpty else { return false }
        let revoked = stale.contains { current.holdsCurrentLease($0) } ? bumpLocked(reason: "reconcile") : false
        if state == nil || !mutate({ s in for peer in stale { s.contacts.removeValue(forKey: peer) } }) { pendingReconcile = verified }
        return revoked
    }

    /// The verified contacts were reset: every contact record goes, and a new generation starts if any lease of the
    /// current generation was delivered (or whatever the generation is, while the vault cannot be read).
    @discardableResult
    public func resetContacts() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let current = state else { pendingResetAll = true; return failClosed(revoke: true) }
        let revoked = current.contacts.keys.contains { current.holdsCurrentLease($0) } ? bumpLocked(reason: "reset_contacts") : false
        if state == nil || !mutate({ $0.contacts = [:] }) { pendingResetAll = true }
        return revoked
    }

    // MARK: Generations

    /// A revocation, forward-jump recovery or "Reset presence key": a whole new window under a new generation. The
    /// revocation is recorded in the guard before the vault is written; if the vault cannot be written the old keys
    /// leave memory (ephemeral window) and the next load replaces them; if neither can be written the stored vault is
    /// deleted. True when the old keys are no longer in use.
    @discardableResult
    public func newGeneration(reason: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return bumpLocked(reason: reason)
    }

    private func bumpLocked(reason: String) -> Bool {
        guard let current = state, var record = guardRecord else { return failClosed(revoke: true) }
        var next = current
        next.generation = Self.next(after: record, current: current.generation)
        next.dayKeys = DayKeyWindow.fresh(epoch: epochSource(), newKey: newKey)
        applySwitchOffs(&next)
        record.floor = next.generation
        record.revokedThrough = max(record.revokedThrough, current.generation)
        record.revokePending = false
        let guardStored = writeGuard(record)
        if save(next) {
            state = next
            clearStoredSwitchOffs()
        } else {
            state = nil; ephemeral = [:]
            if !guardStored {
                // Nothing durable says the old generation is revoked: remove it rather than leave it valid.
                let deleted = (try? storage.delete()) != nil
                log("store", ["result": deleted ? "revoked_vault_deleted" : "revocation_not_stored"])
            }
        }
        log("generation", ["generation": "\(next.generation)", "reason": reason])
        return true
    }

    /// The vault cannot be read: a requested revocation is recorded as pending, so whatever generation is stored is
    /// revoked when it is next loaded.
    private func failClosed(revoke: Bool) -> Bool {
        guard revoke else { return false }
        let stored = updateGuard(revoke: true)
        ephemeral = [:]
        log("generation", ["reason": "revoked_while_unreadable", "recorded": "\(stored)"])
        return true
    }

    /// "Reset presence key". A corrupt store (latched, nothing could be stored) is deleted and replaced, losing its
    /// lease records: the only recovery from it short of the emergency wipe. Otherwise a normal new generation.
    @discardableResult
    public func resetKey() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if state == nil, corrupt {
            guard (try? storage.delete()) != nil else { return false }
            corrupt = false; ephemeral = [:]
            _ = ensureLoadedLocked()
            return true
        }
        return bumpLocked(reason: "reset")
    }

    private static func presence(_ peerHex: String, _ record: PresenceVaultState.ContactRecord) -> ContactPresence? {
        guard record.leaseGeneration > 0, let id = Data(hex: peerHex) else { return nil }
        return ContactPresence(nodeId: id, generation: record.leaseGeneration, leasesByDay: record.leases,
                               skewEpochs: record.leaseSkew, receivedAt: record.leaseReceivedAt)
    }
}
