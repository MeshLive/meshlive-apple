import Foundation

/// Where the presence vault is stored (the app: one Keychain item, this device only).
public protocol PresenceVaultStorage: AnyObject {
    /// The stored bytes, or nil when nothing is stored. Throws when a stored vault exists but cannot be read now
    /// (a locked device, a Keychain error): that is never treated as "nothing stored".
    func read() throws -> Data?
    func write(_ data: Data) throws
    func delete() throws
}

/// The highest presence generation this phone ever used (Android GenerationFloor), kept outside the vault (the app:
/// preferences). It survives a vault that could not be stored or read, so an older copy can never come back into use.
public protocol PresenceGenerationFloor: AnyObject {
    var value: UInt32 { get }
    func raise(to value: UInt32)
}

/// The phase 2 presence vault over a `PresenceVaultStorage` (Android PresenceVault): the rules of `PresenceVaultState`
/// plus the storage discipline that keeps revocations final.
///
/// - A store that cannot be read is never overwritten: the vault runs with an in-memory **ephemeral** window (fresh
///   IDs nobody recognises), delivers no lease, recognises nobody and retries the read at most every 5 s.
/// - A store that does not decode is latched as corrupt; only "Reset presence key" replaces it.
/// - Every revocation raises the generation floor first. A stored vault below the floor (a revocation that could not
///   be stored, or an older copy restored) is replaced by a fresh window above it at the next load; its contacts stay.
/// - A day key is stored before it is used for a lease, and a delivery is stored before the lease is returned.
public final class PresenceVaultCore {
    public enum LoadState: Equatable { case loaded, unreadable, corrupt }
    public static let retryInterval: TimeInterval = 5

    private let storage: PresenceVaultStorage
    private let floor: PresenceGenerationFloor
    private let epochSource: () -> Int64
    private let uptime: () -> TimeInterval
    private let newKey: () -> Data
    private let lock = NSLock()
    private var state: PresenceVaultState?
    private var corrupt = false
    private var ephemeral: [Int64: Data] = [:]
    private var lastRetry: TimeInterval?
    /// iOS keeps Keychain items when the app is deleted but not its files: the first launch of a fresh install drops
    /// every contact record from a vault it finds and starts a new generation (once the vault could be read).
    private var pendingFreshInstall: Bool
    private let onFreshInstallHandled: () -> Void
    public var log: (String, [String: String]) -> Void = { _, _ in }

    public init(storage: PresenceVaultStorage, floor: PresenceGenerationFloor, epoch: @escaping () -> Int64,
                uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                newKey: @escaping () -> Data = { randomBytes(32) },
                freshInstall: Bool = false, onFreshInstallHandled: @escaping () -> Void = {}) {
        self.storage = storage; self.floor = floor; epochSource = epoch; self.uptime = uptime; self.newKey = newKey
        pendingFreshInstall = freshInstall; self.onFreshInstallHandled = onFreshInstallHandled
        lock.lock(); _ = ensureLoadedLocked(); lock.unlock()
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
        let stored: Data?
        do { stored = try storage.read() } catch {
            log("store", ["result": "unreadable"])
            return false
        }
        guard let stored else {
            // Nothing stored: a new vault above the floor, written at its first change (a delivered or stored lease),
            // so a phone that never uses the experiment writes nothing.
            var created = PresenceVaultState()
            created.generation = floor.value &+ 1
            created.dayKeys = DayKeyWindow.fresh(epoch: epochSource(), newKey: newKey)
            state = created; ephemeral = [:]
            finishFreshInstall()
            return true
        }
        guard let loaded = try? JSONDecoder().decode(PresenceVaultState.self, from: stored) else {
            corrupt = true
            log("store", ["result": "corrupt"])
            return false
        }
        if loaded.generation < floor.value || pendingFreshInstall {
            // Below the floor: a revocation that could not be stored, or an older copy came back. Its keys must
            // never be used again. A fresh install also starts over without the contacts the app no longer knows.
            var next = loaded
            next.generation = max(floor.value, loaded.generation) &+ 1
            next.dayKeys = DayKeyWindow.fresh(epoch: epochSource(), newKey: newKey)
            if pendingFreshInstall { next.contacts = [:] }
            floor.raise(to: next.generation)
            if save(next) {
                state = next; ephemeral = [:]
                log("generation", ["generation": "\(next.generation)", "reason": pendingFreshInstall ? "fresh_install" : "below_floor"])
                finishFreshInstall()
            }
        } else {
            state = loaded; ephemeral = [:]
            floor.raise(to: loaded.generation)
        }
        return state != nil
    }

    private func finishFreshInstall() {
        guard pendingFreshInstall else { return }
        pendingFreshInstall = false
        onFreshInstallHandled()
    }

    /// While the store is unreadable every key lookup may retry the load, at most every few seconds.
    private func retryIfDue() {
        guard state == nil, !corrupt else { return }
        let now = uptime()
        if let last = lastRetry, now >= last, now - last < Self.retryInterval { return }
        lastRetry = now
        _ = ensureLoadedLocked()
    }

    private func save(_ next: PresenceVaultState) -> Bool {
        do { try storage.write(try JSONEncoder().encode(next)); return true }
        catch { log("store", ["result": "write_failed"]); return false }
    }

    /// Stores `change(state)`; false (and the state unchanged) when it could not be stored.
    private func mutate(_ change: (inout PresenceVaultState) -> Void) -> Bool {
        guard var next = state else { return false }
        change(&next)
        guard save(next) else { return false }
        state = next
        floor.raise(to: next.generation)
        return true
    }

    // MARK: Keys

    public var generation: UInt32 { lock.lock(); defer { lock.unlock() }; return state?.generation ?? max(floor.value, 1) }

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

    public func canSeeMe(_ peer: NodeId) -> Bool { lock.lock(); defer { lock.unlock() }; return state?.canSeeMe(peer.hex) ?? true }

    public func deliveredTo(_ peer: NodeId) -> Bool { lock.lock(); defer { lock.unlock() }; return state?.holdsCurrentLease(peer.hex) ?? false }

    public var contactCount: Int { lock.lock(); defer { lock.unlock() }; return state?.contacts.count ?? 0 }

    public func leaseKey(of contact: Data, day: Int64) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return state?.contacts[contact.hex]?.leases[day]
    }

    /// The lease for a verified contact (RD1): the window rolled and stored first, the delivery stored before the
    /// lease is returned, keys and generation from the same state. Nil (nothing delivered) when any step fails.
    public func deliverLease(to peer: NodeId, epoch: Int64, verified: Bool) -> DiscoveryExchange.PresenceLease? {
        lock.lock(); defer { lock.unlock() }
        guard verified, let current = state, current.canSeeMe(peer.hex) else { return nil }
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

    /// "Can see when I'm nearby". Turning it off for a contact that holds a current lease revokes it (true).
    @discardableResult
    public func setCanSeeMe(_ peer: NodeId, _ on: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let current = state else { return failClosed(revoke: !on) }
        guard current.canSeeMe(peer.hex) != on else { return false }
        let revoke = !on && current.holdsCurrentLease(peer.hex)
        _ = mutate { s in
            var record = s.contacts[peer.hex] ?? PresenceVaultState.ContactRecord()
            record.canSeeMe = on
            s.contacts[peer.hex] = record
        }
        return revoke ? bumpLocked(reason: "contact_switch_off") : false
    }

    /// Forgets a contact: revokes first when it holds a current lease, then drops its record.
    @discardableResult
    public func forget(_ peer: NodeId) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let current = state else { return failClosed(revoke: true) }
        guard current.contacts[peer.hex] != nil else { return false }
        let revoked = current.holdsCurrentLease(peer.hex) ? bumpLocked(reason: "forget") : false
        _ = mutate { $0.contacts.removeValue(forKey: peer.hex) }
        return revoked
    }

    /// Drops the records of contacts that are no longer verified, revoking when one held a current lease. Catches a
    /// Forget or a reset that happened while the vault could not run, so a former contact cannot keep recognising
    /// this phone. `verified` holds node IDs in hex.
    @discardableResult
    public func reconcile(verified: Set<String>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let current = state else { return false }
        let stale = current.contacts.keys.filter { !verified.contains($0) }
        guard !stale.isEmpty else { return false }
        let revoked = stale.contains { current.holdsCurrentLease($0) } ? bumpLocked(reason: "reconcile") : false
        _ = mutate { s in for peer in stale { s.contacts.removeValue(forKey: peer) } }
        return revoked
    }

    /// The verified contacts were reset: every contact record goes, and a new generation starts if any lease of the
    /// current generation was delivered.
    @discardableResult
    public func resetContacts() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let current = state else { return failClosed(revoke: true) }
        let revoked = current.contacts.keys.contains { current.holdsCurrentLease($0) } ? bumpLocked(reason: "reset_contacts") : false
        _ = mutate { $0.contacts = [:] }
        return revoked
    }

    // MARK: Generations

    /// A revocation, forward-jump recovery or "Reset presence key": a whole new window under a new generation. The
    /// floor is raised first; if the new state cannot be stored, the old keys leave memory (ephemeral window) and the
    /// next load replaces the stored ones. True when the old keys are no longer in use.
    @discardableResult
    public func newGeneration(reason: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return bumpLocked(reason: reason)
    }

    private func bumpLocked(reason: String) -> Bool {
        guard let current = state else { return failClosed(revoke: true) }
        var next = current
        next.generation = max(floor.value, current.generation) &+ 1
        next.dayKeys = DayKeyWindow.fresh(epoch: epochSource(), newKey: newKey)
        floor.raise(to: next.generation)
        if save(next) { state = next } else { state = nil; ephemeral = [:] }
        log("generation", ["generation": "\(next.generation)", "reason": reason])
        return true
    }

    /// The vault cannot be read: a requested revocation still moves the floor, so no stored key stays valid.
    private func failClosed(revoke: Bool) -> Bool {
        guard revoke else { return false }
        floor.raise(to: max(floor.value, 1) &+ 1)
        ephemeral = [:]
        log("generation", ["generation": "\(floor.value)", "reason": "revoked_while_unreadable"])
        return true
    }

    /// "Reset presence key". A corrupt store (latched, nothing could be stored) is deleted and replaced, losing its
    /// lease records: the only recovery from it short of the emergency wipe. Otherwise a normal new generation.
    @discardableResult
    public func resetKey() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if state == nil, corrupt {
            floor.raise(to: max(floor.value, 1) &+ 1)
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
