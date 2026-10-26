import Foundation
import NearbyCore

/// EXPERIMENTAL rotating discovery IDs, phase 2 (Android PresenceVault/PresenceStore): the app side of
/// `PresenceVaultCore` (the rules and the storage discipline live there and are unit-tested). The vault is one
/// Keychain item, this device only, deleted by the emergency wipe; its guard record (generation floor, revocations,
/// pending switch-offs) is a durably written file.
///
/// A Keychain read error is never taken for "nothing stored": the phone then advertises from an in-memory window,
/// sends no OFFER, recognises nobody and never writes over the stored vault until it can be read again.
///
/// Reinstall: iOS keeps Keychain items when the app is deleted, but not the app's files (the verified contacts) or its
/// preferences. The first launch of a fresh install therefore drops every contact record and starts a new generation
/// (marker `presenceVaultInstalled` in UserDefaults, set once the vault could be read), so no phone that held the old
/// keys recognises this one.
final class PresenceVault {
    private static let account = "presence-vault"
    private static let installMarker = "presenceVaultInstalled"
    private let core: PresenceVaultCore
    let recognition = RecognitionTable()

    private final class KeychainStorage: PresenceVaultStorage {
        func read() throws -> Data? { try KeychainItem.read(PresenceVault.account) }
        func write(_ data: Data) throws { try KeychainItem.write(PresenceVault.account, data) }
        func delete() throws { try KeychainItem.delete(PresenceVault.account) }
    }

    /// The guard record (generation floor, revocations, pending switch-offs): a small file next to the verified
    /// contacts, excluded from backup, readable after the first unlock (when the Keychain may still be locked),
    /// written durably before the vault changes, deleted by the emergency wipe.
    private final class GuardFile: PresenceVaultGuardStorage {
        static var url: URL { VerifiedContactsStore.url.deletingLastPathComponent().appendingPathComponent("presence-vault-guard.json") }
        func read() throws -> Data? {
            guard FileManager.default.fileExists(atPath: Self.url.path) else { return nil }
            return try Data(contentsOf: Self.url)
        }
        func write(_ data: Data) throws {
            var dir = Self.url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true; try? dir.setResourceValues(values)
            try DurableFile.write(data, to: Self.url, options: [.completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Hardware-free preview: nothing touches the disk.
    private final class MemoryGuard: PresenceVaultGuardStorage {
        var data: Data?
        func read() throws -> Data? { data }
        func write(_ data: Data) throws { self.data = data }
    }

    init(epoch: @escaping () -> Int64) {
        let defaults = DesktopPreview.preferences
        core = PresenceVaultCore(storage: KeychainStorage(), guardStorage: DesktopPreview.enabled ? MemoryGuard() : GuardFile(), epoch: epoch,
                                 freshInstall: !defaults.bool(forKey: Self.installMarker),
                                 onFreshInstallHandled: { defaults.set(true, forKey: PresenceVault.installMarker) })
        core.log = { event, fields in
            var all = fields; all["event"] = event
            AppLog.event("rotid_presence", all)
        }
        if !core.persistent { AppLog.event("rotid_presence", ["event": "store", "result": "\(core.loadState)"]) }
    }

    /// False while the Keychain could not be read or written: no OFFER is sent and nothing is stored.
    var persistent: Bool { core.persistent }
    var generation: UInt32 { core.generation }

    func entry(nodeId: NodeId, epoch: Int64, role: UInt8) -> OpeningEntry { core.entry(nodeId: nodeId, epoch: epoch, role: role) }
    func ownDayKey(epoch: Int64) -> Data? { core.dayKey(idEpoch: epoch, currentEpoch: epoch) }
    func newGeneration(epoch: Int64, reason: String) { core.newGeneration(reason: reason) }
    func canSeeMe(_ peer: NodeId) -> Bool { core.canSeeMe(peer) }
    func setCanSeeMe(_ peer: NodeId, _ on: Bool, epoch: Int64) {
        core.setCanSeeMe(peer, on)
        rebuildRecognition(myEpoch: epoch)
    }

    /// The lease for a verified contact, recorded as delivered before it is returned (RD1); nil when not eligible.
    func deliverLease(to peer: NodeId, epoch: Int64, verified: Bool) -> DiscoveryExchange.PresenceLease? {
        core.deliverLease(to: peer, epoch: epoch, verified: verified)
    }
    func deliveredTo(_ peer: NodeId) -> Bool { core.deliveredTo(peer) }

    func store(_ lease: DiscoveryExchange.PresenceLease, from peer: NodeId, myEpoch: Int64) {
        if core.store(lease, from: peer, myEpoch: myEpoch, now: Date().timeIntervalSince1970) {
            AppLog.event("rotid_presence", ["event": "lease_stored"])
        }
        rebuildRecognition(myEpoch: myEpoch)
    }

    func leaseKey(of contact: Data, day: Int64) -> Data? { core.leaseKey(of: contact, day: day) }

    func forget(_ peer: NodeId, epoch: Int64) {
        core.forget(peer)
        rebuildRecognition(myEpoch: epoch)
    }

    /// The verified contacts were reset: drop every contact record (revoking any delivered lease).
    func resetContacts(epoch: Int64) {
        core.resetContacts()
        rebuildRecognition(myEpoch: epoch)
    }

    /// Drops the records of contacts that are no longer verified (a Forget or reset this vault did not see).
    func reconcile(verified: [NodeId], epoch: Int64) {
        core.reconcile(verified: Set(verified.map(\.hex)))
        rebuildRecognition(myEpoch: epoch)
    }

    /// "Reset presence key" (also the recovery from a vault that no longer decodes).
    func resetKey() { core.resetKey() }

    /// Rolls the window, stores the pruned lease days, and rebuilds the recognition table for `myEpoch`.
    func rebuildRecognition(myEpoch: Int64) {
        core.maintain(epoch: myEpoch)
        recognition.rebuild(core.leaseHolders(myEpoch: myEpoch), myEpoch: myEpoch, now: Date().timeIntervalSince1970)
    }
}
