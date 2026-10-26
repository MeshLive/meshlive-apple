import Foundation
import Security
import CryptoKit
import os
import NearbyCore

/// Persistent P-256 identity in the Secure Enclave (non-exportable, like Android Keystore), or a
/// Keychain software key where no Secure Enclave exists (simulator). Node ID = SHA-256(SPKI)[0:16].
final class SecureEnclaveSigningIdentity: SigningIdentity {
    let key: SecureEnclave.P256.Signing.PrivateKey
    let publicKeyEncoded: Data
    init(key: SecureEnclave.P256.Signing.PrivateKey) { self.key = key; publicKeyEncoded = key.publicKey.derRepresentation }
    func sign(_ message: Data) throws -> Data { try key.signature(for: message).derRepresentation }
}

enum KeychainItem {
    /// Current service; items of the old `org.nearbyintercom.mesh.v2` move here once (`migrateLegacyServices`).
    static let service = KeychainServices.current
    private static let store = SecKeychainServiceStore()
    #if os(macOS) && DEBUG
    /// DEBUG-only `-NearbyEphemeralIdentity 1`: keep this run's identity and presence state in memory, so an
    /// unattended interop run of a freshly built (differently ad-hoc signed) app never waits on a login-keychain
    /// access prompt. Radio, media and protocol paths are the normal runtime; the identity is new each launch.
    private static var memory: [String: Data] = [:]
    static var ephemeral: Bool { ProcessInfo.processInfo.arguments.contains("-NearbyEphemeralIdentity") }
    #endif
    static func read(_ account: String) throws -> Data? {
        if DesktopPreview.enabled { return nil }
        #if os(macOS) && DEBUG
        if ephemeral { return memory[account] }
        #endif
        // The current service, or the old one while its migration is unfinished; an error is never absence.
        let found = KeychainServices.read(account, store: store)
        if found.status == errSecItemNotFound { return nil }
        guard found.status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(found.status)) }
        return found.item?.data
    }
    /// Adds the item only when none exists (a key must never silently replace another): throws
    /// `SealedRecordKeyError.duplicate` when one appeared meanwhile.
    static func addOnly(_ account: String, _ data: Data, accessible: CFString) throws {
        if DesktopPreview.enabled || EmergencyWipe.happened { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed)) }
        #if os(macOS) && DEBUG
        if ephemeral { if memory[account] != nil { throw SealedRecordKeyError.duplicate }; memory[account] = data; return }
        #endif
        var add = base(account); add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = accessible
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem { throw SealedRecordKeyError.duplicate }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    static func write(_ account: String, _ data: Data, accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) throws {
        if DesktopPreview.enabled { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed)) }
        // Nothing new reaches the Keychain after an emergency wipe in this run (late writers).
        if EmergencyWipe.happened { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed)) }
        #if os(macOS) && DEBUG
        if ephemeral { memory[account] = data; return }
        #endif
        // Update in place (add only when missing): a failed write never leaves the account without its old value.
        let status = KeychainReplace.write(
            update: {
                SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data,
                                                              kSecAttrAccessible as String: accessible] as CFDictionary)
            },
            add: {
                var add = base(account); add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = accessible
                return SecItemAdd(add as CFDictionary, nil)
            })
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    static func delete(_ account: String) throws {
        if DesktopPreview.enabled { return }
        #if os(macOS) && DEBUG
        if ephemeral { memory[account] = nil; return }
        #endif
        // Under both names, so an unfinished migration cannot bring the deleted secret back.
        let status = KeychainServices.delete(account, store: store)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    /// Moves the items of the old service names to the current ones (once; a failure keeps the old item readable
    /// and retries at the next launch). Never in the preview or an ephemeral DEBUG run.
    static func migrateLegacyServices() {
        if DesktopPreview.enabled { return }
        #if os(macOS) && DEBUG
        if ephemeral { return }
        #endif
        let result = KeychainServiceMigration.run(from: KeychainServices.legacyCurrent, to: service, store: store)
        if result.moved > 0 || !result.complete {
            AppLog.event("keychain_migration", ["moved": "\(result.moved)", "pending": "\(result.pending)",
                                                "listFailed": "\(result.listFailed)", "complete": "\(result.complete)"])
        }
    }
    /// Every service this app ever used, old and new names (`KeychainServices.all`).
    static let allServices = KeychainServices.all
    /// Deletes every item of every service; one status per service.
    @discardableResult
    static func deleteAll() -> [OSStatus] {
        if DesktopPreview.enabled { return [] }
        #if os(macOS) && DEBUG
        // An ephemeral DEBUG run only ever held this run's in-memory items; the login Keychain is left untouched.
        if ephemeral { memory.removeAll(); return allServices.map { _ in errSecSuccess } }
        #endif
        return KeychainServices.deleteAll(store: store)
    }
    /// The Mac's data-protection keychain (the records key lives there): one deletion status per service. Without the
    /// entitlement for it nothing can be stored there, so `errSecMissingEntitlement` counts as nothing found.
    static func deleteAllDataProtection() -> [OSStatus] {
        #if os(macOS)
        if DesktopPreview.enabled { return [] }
        #if DEBUG
        if ephemeral { return [] }
        #endif
        return KeychainServices.all.map { service in
            let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecUseDataProtectionKeychain as String: true] as CFDictionary)
            return status == errSecMissingEntitlement ? errSecItemNotFound : status
        }
        #else
        return []
        #endif
    }
    static func verifyDataProtectionDeleted() -> [OSStatus] {
        #if os(macOS)
        if DesktopPreview.enabled { return [] }
        #if DEBUG
        if ephemeral { return [] }
        #endif
        return KeychainServices.all.map { service in
            var item: CFTypeRef?
            let status = SecItemCopyMatching([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                              kSecUseDataProtectionKeychain as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                                              kSecReturnAttributes as String: true] as CFDictionary, &item)
            return status == errSecMissingEntitlement ? errSecItemNotFound : status
        }
        #else
        return []
        #endif
    }
    /// One query per service: `errSecItemNotFound` only when no item of it remains; an error is not absence.
    static func verifyAllDeleted() -> [OSStatus] {
        #if os(macOS) && DEBUG
        if ephemeral { return allServices.map { _ in memory.isEmpty ? errSecItemNotFound : errSecSuccess } }
        #endif
        return KeychainServices.verifyAllDeleted(store: store)
    }
    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

enum IdentityStore {
    static func loadOrCreate() throws -> SigningIdentity {
        if DesktopPreview.enabled { return SoftwareSigningIdentity() }
        if let blob = try KeychainItem.read("identity-se") {
            return SecureEnclaveSigningIdentity(key: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob))
        }
        if let raw = try KeychainItem.read("identity-software") { return try SoftwareSigningIdentity(rawScalar: raw) }
        if SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.Signing.PrivateKey() {
            try KeychainItem.write("identity-se", key.dataRepresentation)
            return SecureEnclaveSigningIdentity(key: key)
        }
        let software = SoftwareSigningIdentity()
        try KeychainItem.write("identity-software", software.privateKey.rawRepresentation)
        return software
    }
}

/// Verified contacts sealed at rest with AES-GCM under a Keychain key (this-device-only), in a
/// complete-protection file excluded from backup. A damaged file stays unread (fail open: every peer
/// counts as unverified) until the user resets it; it is never overwritten implicitly.
enum VerifiedContactsStore {
    enum LoadResult { case loaded([VerifiedContact]), empty, unreadable(String) }
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("identity-verification", isDirectory: true)
        return dir.appendingPathComponent("verified-contacts.bin")
    }
    static func load() -> LoadResult {
        if DesktopPreview.enabled { return .empty }
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        do {
            guard let keyData = try KeychainItem.read("contacts-key") else { return .unreadable("The contacts key is missing") }
            let box = try AES.GCM.SealedBox(combined: try Data(contentsOf: url))
            let plain = try AES.GCM.open(box, using: SymmetricKey(data: keyData), authenticating: Data("verified-contacts-v1".utf8))
            return .loaded(try JSONDecoder().decode([VerifiedContact].self, from: plain))
        } catch { return .unreadable("\(error)") }
    }
    struct WriteBlocked: Error {}
    static func save(_ contacts: [VerifiedContact]) throws {
        if DesktopPreview.enabled { return }
        if EmergencyWipe.happened { throw WriteBlocked() }
        var keyData = try KeychainItem.read("contacts-key")
        if keyData == nil { let k = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }; try KeychainItem.write("contacts-key", k); keyData = k }
        let plain = try JSONEncoder().encode(contacts)
        let sealed = try AES.GCM.seal(plain, using: SymmetricKey(data: keyData!), authenticating: Data("verified-contacts-v1".utf8)).combined!
        var dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        BackupExclusion.apply(&dir)
        try sealed.write(to: url, options: [.atomic, .completeFileProtection])
    }
    static func reset() { if !DesktopPreview.enabled { try? FileManager.default.removeItem(at: url) } }
}

/// Excludes a directory of app data from backups; a failure is logged (status only, no path).
enum BackupExclusion {
    static func apply(_ dir: inout URL) {
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        do { try dir.setResourceValues(values) } catch { AppLog.event("storage", ["event": "backup_exclusion", "result": "failed"]) }
    }
}

/// BMH3 pins (Android `hidden-identity-pins`): next to the verified contacts, sealed at rest (`SealedRecords`, review
/// 2026-10-27: the pins name peers by ID prefix), excluded from backup, readable after the first unlock (an incoming
/// call can arrive while the phone is locked), deleted by the emergency wipe. The plain-text file of earlier builds
/// moves into the sealed one once.
final class Bmh3PinFile: Bmh3PinStorage {
    static let fileName = "hidden-identity-pins.bin"
    static let purpose = "MeshLive/HiddenIdentityPins/1"
    static var url: URL { SealedRecords.files.url(fileName) }
    static var legacyURL: URL { SealedRecords.files.url("hidden-identity-pins.txt") }
    struct Unreadable: Error {}
    /// nil when nothing is stored; throws when the sealed pins exist but cannot be read (never treated as empty).
    func read() throws -> String? {
        switch SealedRecords.files.read(Self.fileName, purpose: Self.purpose) {
        case .absent: return nil
        case .value(let data): return String(data: data, encoding: .utf8)
        case .unreadable: throw Unreadable()
        }
    }
    func write(_ value: String) { SealedRecords.files.write(Data(value.utf8), name: Self.fileName, purpose: Self.purpose) }
}

/// Emergency wipe (Android EmergencyWipe semantics, adapted to iOS): marker first, keys first, then
/// data, a second sweep, and the marker last. A remaining marker resumes the wipe on the next launch.
enum EmergencyWipe {
    /// Set when the user's wipe starts in this session and kept for the rest of this run: late writers (a call that
    /// finishes, a pin, a vault rotation, the log, a notification) must not bring data back after the wipe (review
    /// 2026-10-27). A wipe resumed at launch does not latch: that run starts clean and may store a new identity.
    static var happened: Bool { latch.withLock { $0 } }
    private static let latch = OSAllocatedUnfairLock(initialState: false)
    static var markerURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("emergency-wipe-pending")
    }
    static var pending: Bool { FileManager.default.fileExists(atPath: markerURL.path) }

    /// Runs synchronously; returns true only when the wipe is verified (`WipeVerification`): every Keychain deletion
    /// succeeded or found nothing, a query then confirmed every service empty (an error is not absence), and the
    /// contacts, the presence-vault guard (with its temporary files) and the BMH3 pins are gone. Otherwise the marker
    /// stays and the wipe resumes at the next launch.
    @discardableResult
    static func run(userInitiated: Bool = true) -> Bool {
        if DesktopPreview.enabled { return false }
        if userInitiated {
            latch.withLock { $0 = true }
            AppLog.stopFileLogging()
            CallNotifier.shared.removeAllForWipe()
            CrashReports.shared.wipe()
        }
        try? Data().write(to: markerURL, options: .atomic)
        var deletions = KeychainItem.deleteAll() + KeychainItem.deleteAllDataProtection()
        sweep()
        if let domain = Bundle.main.bundleIdentifier { DesktopPreview.preferences.removePersistentDomain(forName: domain) }
        sweep()
        deletions += KeychainItem.deleteAll() + KeychainItem.deleteAllDataProtection()
        let fm = FileManager.default
        // The directory holding the contacts, the vault guard (and its temporary files) and the pins: gone or empty.
        let identityDir = VerifiedContactsStore.url.deletingLastPathComponent()
        let filesLeft = [VerifiedContactsStore.url, PresenceVault.guardURL, Bmh3PinFile.url, Bmh3PinFile.legacyURL].filter { fm.fileExists(atPath: $0.path) }.count
            + ((try? fm.contentsOfDirectory(atPath: identityDir.path))?.count ?? 0)
        let complete = WipeVerification.complete(deletions: deletions,
                                                 verifications: KeychainItem.verifyAllDeleted() + KeychainItem.verifyDataProtectionDeleted(),
                                                 filesLeft: filesLeft)
        if complete { try? FileManager.default.removeItem(at: markerURL) }
        return complete
    }

    private static func sweep() {
        let fm = FileManager.default
        let dirs: [URL] = [fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0], fm.urls(for: .documentDirectory, in: .userDomainMask)[0],
                           fm.urls(for: .cachesDirectory, in: .userDomainMask)[0], fm.temporaryDirectory]
        for dir in dirs {
            for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: item) }
        }
    }
}

/// User preferences (not secrets).
struct AppSettings {
    private static let d = DesktopPreview.preferences
    #if os(macOS)
    static var desktopPauseCallDiscovery: Bool {
        get { d.bool(forKey: "experimentalDesktopPauseCallDiscovery") }
        set { d.set(newValue, forKey: "experimentalDesktopPauseCallDiscovery") }
    }
    /// Experimental scanner/call compatibility; independent of this Mac's advertised identity settings.
    static var desktopAndroidCompatibility: Bool {
        get { d.bool(forKey: "experimentalDesktopAndroidCompatibility") }
        set { d.set(newValue, forKey: "experimentalDesktopAndroidCompatibility") }
    }
    static var desktopGeneratedNames: Bool {
        get { d.bool(forKey: "experimentalDesktopGeneratedNames") }
        set { d.set(newValue, forKey: "experimentalDesktopGeneratedNames") }
    }
    static var desktopCallDeliveryFeedback: Bool {
        get { d.bool(forKey: "experimentalDesktopCallDeliveryFeedback") }
        set { d.set(newValue, forKey: "experimentalDesktopCallDeliveryFeedback") }
    }
    #endif
    static var displayName: String {
        get { d.string(forKey: "displayName") ?? "" }
        set { d.set(newValue, forKey: "displayName") }
    }
    static var transport: MeshTransport {
        get { MeshTransport(rawValue: d.string(forKey: "transport") ?? "") ?? .gatt }
        set { d.set(newValue.rawValue, forKey: "transport") }
    }
    static var availableForCalls: Bool {
        get { d.object(forKey: "availableForCalls") as? Bool ?? true }
        set { d.set(newValue, forKey: "availableForCalls") }
    }
    static var mismatchPolicyWarnOnly: Bool {
        get { d.bool(forKey: "mismatchWarnOnly") }
        set { d.set(newValue, forKey: "mismatchWarnOnly") }
    }
    /// Experimental names and titles (naming phase 1), off by default like Android's test_peer_labels.
    static var peerLabels: Bool {
        get { d.bool(forKey: "experimentalPeerLabels") }
        set { d.set(newValue, forKey: "experimentalPeerLabels") }
    }
    /// Experimental BMH3 "Hidden identities" for calls (Android `bmh3`; Android ships it ON since 0.2.0-beta, the
    /// iPhone keeps it off until phone tests pass and it is reviewed).
    static var hiddenIdentities: Bool {
        get { d.bool(forKey: "experimentalBmh3") }
        set { d.set(newValue, forKey: "experimentalBmh3") }
    }
    /// Experimental "Pseudonymous toward strangers" (Android `bmh3_pseudonyms`, a child of Hidden identities that also
    /// needs rotating discovery IDs). In this mode the phone neither speaks nor accepts BMH2 for calls.
    static var bmh3Pseudonyms: Bool {
        get { d.bool(forKey: "experimentalBmh3Pseudonyms") }
        set { d.set(newValue, forKey: "experimentalBmh3Pseudonyms") }
    }
    /// Stream link pacing (Android LinkPacer, on) and the on-time seed raise (on since 2026-10-16). Control arms for
    /// tests only: launch arguments `-linkPacing NO`, `-onTimeSeedRaise NO`; there is no Settings switch.
    static var linkPacing: Bool { d.object(forKey: "linkPacing") as? Bool ?? true }
    static var onTimeSeedRaise: Bool { d.object(forKey: "onTimeSeedRaise") as? Bool ?? true }
    /// Viewer on-time reports (Android test_on_time_reports, on); control arm `-onTimeReports NO`.
    static var onTimeReports: Bool { d.object(forKey: "onTimeReports") as? Bool ?? true }
    /// Call and stream audio: when the output starts, audio that arrived while it was still starting is dropped down
    /// to the playout target, instead of staying as latency for the whole call (on). Control arm `-audioStartTrim NO`.
    static var audioStartTrim: Bool { d.object(forKey: "audioStartTrim") as? Bool ?? true }
    /// Failed live joins say "Couldn't join <title>." with Try again and retry once by themselves when the stream is
    /// listed again (Android `test_stream_join_retry`, on). Control arm `-streamJoinRetry NO`.
    static var streamJoinRetry: Bool { d.object(forKey: "streamJoinRetry") as? Bool ?? true }
    /// Audio-only live streams (Android `audio_live`, on for everyone since 2026-10-17 with no Settings row). Off, Go
    /// live offers no audio-only stream, audio-only offers are not listed and a `BTL1` header is refused as unsupported.
    /// Control arm for tests only: launch argument `-audioLive NO`.
    static var audioLive: Bool { d.object(forKey: "audioLive") as? Bool ?? true }
    /// Advanced "Relay: slow viewers skip to keyframes" (Android relay_child_media_age, default ON).
    static var relayChildMediaAge: Bool {
        get { d.object(forKey: "relayChildMediaAge") as? Bool ?? true }
        set { d.set(newValue, forKey: "relayChildMediaAge") }
    }
    /// Quick wipe gesture (Android `panic_wipe_gesture`): off by default, so a stray triple-tap erases nothing.
    /// UserDefaults key `quickWipeGesture` (a launch argument `-quickWipeGesture YES` sets it for UI tests).
    static var quickWipeGesture: Bool {
        get { d.bool(forKey: "quickWipeGesture") }
        set { d.set(newValue, forKey: "quickWipeGesture") }
    }
    /// The one-time question for call alerts (local notifications) was asked.
    static var callAlertsAsked: Bool {
        get { d.bool(forKey: "callAlertsAsked") }
        set { d.set(newValue, forKey: "callAlertsAsked") }
    }
    /// The one-time "Hold Mute to talk" hint was shown.
    static var holdMuteHintShown: Bool {
        get { d.bool(forKey: "holdMuteHintShown") }
        set { d.set(newValue, forKey: "holdMuteHintShown") }
    }
    /// Call resolution ladder (default on for user calls, like Android).
    static var resolutionLadder: Bool {
        get { d.object(forKey: "resolutionLadder") as? Bool ?? true }
        set { d.set(newValue, forKey: "resolutionLadder") }
    }
    /// EXPERIMENTAL call audio FEC (off; Android test_call_native_opus): in-band FEC + recovery.
    static var callAudioFec: Bool {
        get { d.bool(forKey: "experimentalCallAudioFec") }
        set { d.set(newValue, forKey: "experimentalCallAudioFec") }
    }
    /// EXPERIMENTAL rotating discovery IDs (off): call-ready presence uses a 15-minute rotating ID.
    static var rotatingIds: Bool {
        get { d.bool(forKey: "experimentalRotatingIds") }
        set { d.set(newValue, forKey: "experimentalRotatingIds") }
    }
    /// EXPERIMENTAL, off by default: pass streams (and calls) on to other phones nearby.
    static var relayForOthers: Bool {
        get { d.bool(forKey: "experimentalRelayForOthers") }
        set { d.set(newValue, forKey: "experimentalRelayForOthers") }
    }
    /// What this phone learned about relaying (proven load, saturation ceiling), as Android's link_capacity.
    static var relayLearned: LearnedLinkCapacity {
        get { (d.data(forKey: "relayLearnedCapacity")).flatMap { try? JSONDecoder().decode(LearnedLinkCapacity.self, from: $0) } ?? LearnedLinkCapacity() }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "relayLearnedCapacity") }
    }
    static var onboardingDone: Bool {
        get { d.bool(forKey: "onboardingDone") }
        set { d.set(newValue, forKey: "onboardingDone") }
    }
}
