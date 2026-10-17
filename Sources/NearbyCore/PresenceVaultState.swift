import Foundation

/// The pure state of the phase 2 presence vault (Android PresenceVault rules), persisted by the app as one Keychain
/// item: this phone's generation and day-key window, and per contact (by node ID hex) its lease, the generation
/// delivered to it and the switch "Can see when I'm nearby" (default on, as Android). Every revocation draws a whole
/// new window under a higher generation, so contacts recognise nothing from the old keys.
public struct PresenceVaultState: Codable, Equatable {
    public struct ContactRecord: Codable, Equatable {
        public var leaseGeneration: UInt32 = 0
        public var leaseSkew: Int64 = 0
        public var leaseReceivedAt: TimeInterval = 0
        public var leases: [Int64: Data] = [:]
        public var deliveredGeneration: UInt32 = 0
        public var canSeeMe = true
        public init() {}
    }
    public var generation: UInt32 = 1
    public var dayKeys: [Int64: Data] = [:]
    public var contacts: [String: ContactRecord] = [:]
    public init() {}

    /// True when `peer` holds a lease of the current generation.
    public func holdsCurrentLease(_ peer: String) -> Bool {
        guard let record = contacts[peer] else { return false }
        return record.deliveredGeneration > 0 && record.deliveredGeneration == generation
    }

    public func canSeeMe(_ peer: String) -> Bool { contacts[peer]?.canSeeMe ?? true }

    /// A new generation: a whole new window of fresh keys (Reset presence key, revocation, forward-jump recovery).
    public mutating func newGeneration(epoch: Int64, newKey: () -> Data = { randomBytes(32) }) {
        generation &+= 1
        dayKeys = DayKeyWindow.fresh(epoch: epoch, newKey: newKey)
    }

    /// The per-contact switch. Turning it off for a contact that already holds a current lease revokes it (returns true:
    /// a new generation started); turning it off before any delivery changes nothing on the wire.
    @discardableResult
    public mutating func setCanSeeMe(_ peer: String, _ on: Bool, epoch: Int64, newKey: () -> Data = { randomBytes(32) }) -> Bool {
        let revoke = !on && holdsCurrentLease(peer)
        var record = contacts[peer] ?? ContactRecord()
        record.canSeeMe = on
        contacts[peer] = record
        if revoke { newGeneration(epoch: epoch, newKey: newKey) }
        return revoke
    }

    /// A forgotten contact's record goes; if it held a current lease, a new generation starts (returns true).
    @discardableResult
    public mutating func forget(_ peer: String, epoch: Int64, newKey: () -> Data = { randomBytes(32) }) -> Bool {
        let revoke = holdsCurrentLease(peer)
        contacts.removeValue(forKey: peer)
        if revoke { newGeneration(epoch: epoch, newKey: newKey) }
        return revoke
    }

    /// A fresh install on iOS keeps Keychain items (the vault) but loses app files (the verified contacts): the leases
    /// this phone held and the deliveries it recorded no longer belong to anyone the app knows. Start over: no contact
    /// records and a new generation, so phones that held this phone's old keys recognise nothing.
    public mutating func freshInstall(epoch: Int64, newKey: () -> Data = { randomBytes(32) }) {
        contacts = [:]
        newGeneration(epoch: epoch, newKey: newKey)
    }
}
