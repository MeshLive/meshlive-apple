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

/// The block list (Android `BlockedPeopleStore`, `blocked-people.bin`): full fingerprints only, sealed at rest with the
/// records key (`SealedRecords`, next to the verified contacts, excluded from backup), deleted by the emergency wipe.
/// A list that cannot be opened or decoded blocks nobody (fail open, as Android) and is never overwritten; Blocked
/// people offers a reset only when it is damaged.
enum BlockedPeopleFile {
    static let fileName = "blocked-people.bin"
    static let purpose = "MeshLive/BlockedPeople/1"

    static func load() -> BlockListLoad {
        if DesktopPreview.enabled { return .loaded(BlockList()) }
        return BlockListLoad.classify(SealedRecords.files.read(fileName, purpose: purpose))
    }

    /// False when nothing was written (a wipe started, a preview, or a storage failure).
    static func save(_ list: BlockList) -> Bool {
        guard !DesktopPreview.enabled, !EmergencyWipe.happened, let data = try? list.encoded() else { return false }
        var directory = SealedRecords.files.directory
        BackupExclusion.apply(&directory)
        return SealedRecords.files.write(data, name: fileName, purpose: purpose)
    }

    static func reset() { SealedRecords.files.delete(fileName) }
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
    /// Mac "Android compatibility": no Settings row since 2026-11-04 (with rotating IDs, hidden identities and
    /// pseudonyms always on it adds nothing); a stored choice is ignored. Control arm: DEBUG launch argument
    /// `-experimentalDesktopAndroidCompatibility YES`, for runs that turn the trio off.
    static var desktopAndroidCompatibility: Bool { LabSwitch.promoted("experimentalDesktopAndroidCompatibility", shipped: false) }
    static var desktopCallDeliveryFeedback: Bool {
        get { d.bool(forKey: "experimentalDesktopCallDeliveryFeedback") }
        set { d.set(newValue, forKey: "experimentalDesktopCallDeliveryFeedback") }
    }
    #endif
    /// Generated nearby names (Android names-v2), iPhone and Mac: always on since 2026-11-04, as Android ("Friendly
    /// names are always shown"); no Settings switch, a stored "off" is ignored. Control arm: DEBUG launch argument
    /// `-experimentalDesktopGeneratedNames NO` (the key keeps its Mac name).
    static var desktopGeneratedNames: Bool { LabSwitch.promoted("experimentalDesktopGeneratedNames", shipped: true) }
    static var displayName: String {
        get { d.string(forKey: "displayName") ?? "" }
        set { d.set(newValue, forKey: "displayName") }
    }
    static var transport: MeshTransport {
        get { MeshTransport(rawValue: d.string(forKey: "transport") ?? "") ?? .gatt }
        set { d.set(newValue.rawValue, forKey: "transport") }
    }
    static var availableForCalls: Bool {
        get { flag("availableForCalls", default: true) }
        set { d.set(newValue, forKey: "availableForCalls") }
    }
    /// Names and titles (Android PeerLabelFeature, a constant on since 2026-10-17): always on for iPhone and Mac since P5
    /// (owner, 2026-11-04, "one name"); no Settings switch, a stored "off" is ignored. Control arm: DEBUG launch argument
    /// `-experimentalPeerLabels NO` (or automation `-NearbyLabels 0` for one run).
    static var peerLabels: Bool { LabSwitch.promoted("experimentalPeerLabels", shipped: true) }
    /// "Who sees my name" (Android NamingSettings.PREF_AUDIENCE, the same stored values): People I call or who call me
    /// (default), Only my contacts, Nobody.
    static var namesAudience: NamesAudience {
        get { NamesAudience.stored(d.string(forKey: "namesAudience")) }
        set { d.set(newValue.rawValue, forKey: "namesAudience") }
    }
    /// Experimental "Show my name before they answer" (Android NAMES_BEFORE_ANSWER): off for every launch since the owner
    /// decision of 2026-11-06 ("A caller's name waits for the reveal"); no Settings row, a stored value is ignored. Only
    /// the DEBUG launch argument `-namesBeforeAnswer YES` turns the comparison arm on (never a release build). On, a
    /// person this device blocked who answers from a fresh throwaway key would receive the name.
    static var namesBeforeAnswer: Bool { LabSwitch.promoted("namesBeforeAnswer", shipped: false) }
    /// "Block unknown callers" (Android CallBlocking.PREF_BLOCK_UNKNOWN), off by default; wiped with the settings.
    static var blockUnknownCallers: Bool {
        get { flag("blockUnknownCallers", default: false) }
        set { d.set(newValue, forKey: "blockUnknownCallers") }
    }
    /// "Not now" on "Declined. Block all unknown callers?" (Android block_unknown_offer_dismissed): never asked again.
    static var blockUnknownOfferDismissed: Bool {
        get { d.bool(forKey: "blockUnknownOfferDismissed") }
        set { d.set(newValue, forKey: "blockUnknownOfferDismissed") }
    }
    /// Android "Show names on lock screen" (`lock_screen_peer_names`), off by default; wiped with the settings.
    static var lockScreenNames: Bool {
        get { flag("lockScreenNames", default: false) }
        set { d.set(newValue, forKey: "lockScreenNames") }
    }
    /// BMH3 "Hidden identities" for calls (Android `bmh3`, on since 0.2.0-beta): always on for iPhone and Mac since
    /// 2026-11-04 (decision after the Mac <-> Android test); no Settings switch, a stored "off" is ignored.
    /// Control arm: DEBUG launch argument `-experimentalBmh3 NO`.
    static var hiddenIdentities: Bool { LabSwitch.promoted("experimentalBmh3", shipped: true) }
    /// "Pseudonymous toward strangers" (Android `bmh3_pseudonyms`; needs hidden identities and rotating discovery
    /// IDs): always on since 2026-11-04, no Settings switch. In this mode the phone neither speaks nor accepts BMH2
    /// for calls. Control arm: DEBUG launch argument `-experimentalBmh3Pseudonyms NO`.
    static var bmh3Pseudonyms: Bool { LabSwitch.promoted("experimentalBmh3Pseudonyms", shipped: true) }
    /// Experimental "Relayed calls" (Android `test_relayed_calls`, off): a call that reaches this phone through another
    /// phone rings only with this on; otherwise it is declined before it rings (the relayed-call target rule).
    /// Since 2026-11-06 (product decision, Android `RelayedCallsFeature` without `advancedOnly`) the stored choice counts with
    /// or without Manual video settings.
    static var relayedCalls: Bool {
        get { d.bool(forKey: "experimentalRelayedCalls") }
        set { d.set(newValue, forKey: "experimentalRelayedCalls") }
    }
    /// `LabSwitch.flag` and `LabSwitch.read` in this app's preferences (isolated under the Mac preview).
    static func flag(_ key: String, default value: Bool, in store: UserDefaults = d) -> Bool { LabSwitch.flag(key, default: value, in: store) }
    static func labSwitch(_ key: String, shipped: Bool) -> Bool { LabSwitch.read(key, shipped: shipped, in: d) }
    /// Android "Calls unavailable" status (`test_calls_unavailable_status`, on since 2026-11-05): with Allow calls on and
    /// Bluetooth ready, a call service not hosted within 5 s shows "Calls unavailable" instead of Ready. Control arm for
    /// tests only: launch argument `-callsUnavailableStatus NO`.
    static var callsUnavailableStatus: Bool { labSwitch("callsUnavailableStatus", shipped: true) }
    /// Relayed calls from unverified strangers ring (Android `test_relayed_stranger_calls`, on). Control arm for tests
    /// only: launch argument `-relayedStrangerCalls NO` (relayed calls from contacts only); no Settings switch.
    static var relayedStrangerCalls: Bool { labSwitch("relayedStrangerCalls", shipped: true) }
    /// Android "Video stops if the phone gets too hot" (critical thermal state; Android has no switch). Control arm for
    /// tests only: launch argument `-thermalCriticalStop NO`.
    static var thermalCriticalStop: Bool { labSwitch("thermalCriticalStop", shipped: true) }
    /// Android `privateCallVideoSettings` call budget with Manual video on (GATT 180, L2CAP 200 kbps). Control arm
    /// `-callTransportCap NO`.
    static var callTransportCap: Bool { labSwitch("callTransportCap", shipped: true) }
    /// Android `RemoteVideoFit` (on): a strongly different call video shape is shown whole; a double-tap flips it.
    /// Control arm `-remoteVideoFit NO` (Fill screen with video alone decides).
    static var remoteVideoFit: Bool { labSwitch("remoteVideoFit", shipped: true) }
    /// Android viewer recovery after an unexpected loss (on, no switch on Android). Control arm `-viewerRecovery NO`: the
    /// viewer ends on a lost link, as before.
    static var viewerRecovery: Bool { labSwitch("viewerRecovery", shipped: true) }
    /// Android relayed-child parent-link watch (`test_relay_parent_watch`, on) and its trickle close
    /// (`test_relay_parent_trickle`, on). Control arms `-relayParentWatch NO`, `-relayParentTrickle NO`.
    static var relayParentWatch: Bool { labSwitch("relayParentWatch", shipped: true) }
    static var relayParentTrickle: Bool { labSwitch("relayParentTrickle", shipped: true) }
    /// Android `PreAuthAdmissionGate` (`test_viewer_admission_bounds`, on). Control arm `-viewerAdmissionBounds NO`.
    static var viewerAdmissionBounds: Bool { labSwitch("viewerAdmissionBounds", shipped: true) }
    /// Android `relayAutoPaused` for Relay video for others (on, no switch on Android). Control arm `-relayBatteryPause NO`.
    static var relayBatteryPause: Bool { labSwitch("relayBatteryPause", shipped: true) }
    /// Android's End live confirmation while someone watches (on, no switch on Android). Control arm `-liveEndConfirm NO`.
    static var liveEndConfirm: Bool { labSwitch("liveEndConfirm", shipped: true) }
    /// AW1 build gate (Experimental): DEBUG launch argument `-wifiWire YES`; release builds never. Off: no WIFI marker,
    /// no CAPS, hop type 16 rejected, the Settings Wi-Fi section hidden (every byte as before).
    static var wifiWire: Bool { labSwitch("wifiWire", shipped: false) }
    /// AW1 user switch (Experimental, off): "Use Wi-Fi for faster connections".
    static var wifiCarrier: Bool {
        get { d.bool(forKey: "wifiCarrier") }
        set { d.set(newValue, forKey: "wifiCarrier") }
    }
    /// AW1 user switch (Experimental, off): "Join Wi-Fi Direct groups".
    static var wifiDirect: Bool {
        get { d.bool(forKey: "wifiDirect") }
        set { d.set(newValue, forKey: "wifiDirect") }
    }
    /// Android call readiness permissions (`test_call_readiness_permissions`, on): onboarding asks for Bluetooth, the
    /// microphone and notifications; the camera is asked at the first video use. Control arm `-callReadinessPermissions NO`.
    static var callReadinessPermissions: Bool { labSwitch("callReadinessPermissions", shipped: true) }
    /// Mac only: radio Pause turns the microphone off, as Android ("Paused. The microphone is off"). Control arm
    /// `-radioPauseMicOff NO` (the microphone stays on while paused, as on the iPhone).
    static var radioPauseMicOff: Bool { labSwitch("radioPauseMicOff", shipped: true) }
    /// Mac only: the 2.4 GHz Wi-Fi advice before video (Android `WifiAdvicePolicy`, no switch there). Control arm
    /// `-wifiAdvice NO`.
    static var wifiAdvice: Bool { labSwitch("wifiAdvice", shipped: true) }
    /// When the Wi-Fi advice was last answered (seconds since 1970; 0 = never). Local only.
    static var wifiAdviceAnsweredAt: Double {
        get { d.double(forKey: "wifiAdviceAnsweredAt") }
        set { d.set(newValue, forKey: "wifiAdviceAnsweredAt") }
    }
    /// Relayed calls sub-switch "Let phones nearby relay calls to me" (Android `relayed_calls_consent`, on within the
    /// experiment): the consent bit on this device's call offer, and whether a relayed call may ring here.
    static var relayedCallsConsent: Bool {
        get { flag("relayedCallsConsent", default: true) }
        set { d.set(newValue, forKey: "relayedCallsConsent") }
    }
    /// Relayed calls sub-switch "Help calls nearby" (Android `relayed_calls_help`, preselected on within the experiment):
    /// this device may pass other people's calls on while it is idle.
    static var relayedCallsHelp: Bool {
        get { flag("relayedCallsHelp", default: true) }
        set { d.set(newValue, forKey: "relayedCallsHelp") }
    }
    /// EXPERIMENTAL route search (Android DEBUG `test_relayed_on_demand`, off): while helping, the call listener signs
    /// RELAY_SEEK and answers searches (SEEK) from what this device scans. Launch argument `-relayedOnDemand YES`.
    static var relayedOnDemand: Bool { labSwitch("relayedOnDemand", shipped: false) }
    /// DEBUG lab mask (Android `test_relayed_calls_no_direct`, off): the reach tables ignore every target's own offer,
    /// as if no target were in direct range (needed for a co-located chain test). Launch argument `-relayedNoDirect YES`.
    static var relayedNoDirect: Bool { labSwitch("relayedNoDirect", shipped: false) }
    /// Pseudonymous relay edges (Android `test_relayed_pseudonymous_edges`, on). Control arm for tests only:
    /// launch argument `-relayedPseudonymousEdges NO`; no Settings switch.
    static var relayedPseudonymousEdges: Bool { labSwitch("relayedPseudonymousEdges", shipped: true) }
    /// Stream link pacing (Android LinkPacer, on) and the on-time seed raise (on since 2026-10-16). Control arms for
    /// tests only: launch arguments `-linkPacing NO`, `-onTimeSeedRaise NO`; there is no Settings switch.
    static var linkPacing: Bool { labSwitch("linkPacing", shipped: true) }
    static var onTimeSeedRaise: Bool { labSwitch("onTimeSeedRaise", shipped: true) }
    /// Viewer on-time reports (Android test_on_time_reports, on); control arm `-onTimeReports NO`.
    static var onTimeReports: Bool { labSwitch("onTimeReports", shipped: true) }
    /// Viewer measured link reports (Android viewers' arrival-train reports, always on there); control arm
    /// `-viewerLinkReports NO` keeps only the on-time reports.
    static var viewerLinkReports: Bool { labSwitch("viewerLinkReports", shipped: true) }
    /// Call and stream audio: when the output starts, audio that arrived while it was still starting is dropped down
    /// to the playout target, instead of staying as latency for the whole call (on). Control arm `-audioStartTrim NO`.
    static var audioStartTrim: Bool { labSwitch("audioStartTrim", shipped: true) }
    /// Failed live joins say "Couldn't join <title>." with Try again and retry once by themselves when the stream is
    /// listed again (Android `test_stream_join_retry`, on). Control arm `-streamJoinRetry NO`.
    static var streamJoinRetry: Bool { labSwitch("streamJoinRetry", shipped: true) }
    /// Audio-only live streams (Android `audio_live`, on for everyone since 2026-10-17 with no Settings row). Off, Go
    /// live offers no audio-only stream, audio-only offers are not listed and a `BTL1` header is refused as unsupported.
    /// Control arm for tests only: launch argument `-audioLive NO`.
    static var audioLive: Bool { labSwitch("audioLive", shipped: true) }
    /// Experiments "Relay: slow viewers skip to keyframes" (Android relay_child_media_age, default ON). Since 2026-11-06
    /// (product decision, as Android) the stored choice counts with or without Manual video settings.
    static var relayChildMediaAge: Bool {
        get { flag("relayChildMediaAge", default: true) }
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
    /// Android `audio_live_disclosed`: the first-time "Going live" warning for audio only was confirmed.
    static var audioLiveDisclosed: Bool {
        get { d.bool(forKey: "audioLiveDisclosed") }
        set { d.set(newValue, forKey: "audioLiveDisclosed") }
    }
    /// Android `audio_live_last_choice`: true when Audio only was the last Go live choice (drawn white next time).
    static var audioLiveLastChoice: Bool {
        get { d.bool(forKey: "audioLiveLastChoice") }
        set { d.set(newValue, forKey: "audioLiveLastChoice") }
    }
    /// Call resolution ladder (default on for user calls, like Android).
    static var resolutionLadder: Bool {
        get { flag("resolutionLadder", default: true) }
        set { d.set(newValue, forKey: "resolutionLadder") }
    }
    /// EXPERIMENTAL call audio FEC (Android `test_call_native_opus`, "Call audio with loss recovery"): in-band FEC +
    /// recovery, off. No Settings switch since 2026-11-04 (the Android decision "Fewer switches (2026-11-04)"): a choice
    /// stored by the old "Call audio error correction" row (`experimentalCallAudioFec`) is ignored. DEBUG builds: launch
    /// argument `-callAudioFec YES`, or `-NearbyCallAudioFec 1` (Automation), runs the FEC arm; release builds never do.
    static var callAudioFec: Bool { callAudioFecThisRun ?? labSwitch("callAudioFec", shipped: false) }
    /// Set only by DEBUG automation (`-NearbyCallAudioFec 1|0`) for the current run; never stored.
    static var callAudioFecThisRun: Bool?
    /// Rotating discovery IDs (Android `RotatingDiscoveryFeature`, on since 0.2.0-beta): call-ready presence uses a
    /// 15-minute rotating ID. Always on for iPhone and Mac since 2026-11-04; no Settings switch, a stored "off" is
    /// ignored. Control arm: DEBUG launch argument `-experimentalRotatingIds NO`.
    static var rotatingIds: Bool { LabSwitch.promoted("experimentalRotatingIds", shipped: true) }
    /// Rotating discovery IDs phase 1b, viewer side (Android Phase 1b, on there by default): a rotating (version 5)
    /// stream is joined with a compact v2 request carrying this device's role-2 RDI, its role-2 entries go in the
    /// stream hop's BDO1, and the request rotates at each boundary. Control arm for tests only: launch argument
    /// `-rotatingViewer NO` refuses such a stream as before (never a fixed-prefix request instead).
    static var rotatingViewer: Bool { labSwitch("rotatingViewer", shipped: true) }
    /// AB4, EXPERIMENTAL: rotating discovery IDs phase 1b, source side (Android Phase 1b items 1-7, on there by default).
    /// On: this device's live offer is a compact v2 stream offer with its role-1 RDI (route token logical XOR mask(RDI),
    /// rotated at each boundary with a 1-8 s silence, own role-1 pins in the stream hop's BDO1), and it answers version 5
    /// and compact v2 viewer requests through the 60 s route-token window after checking the viewer's role-2 opening.
    /// Off (the default until the Mac <-> Android device check passes): the fixed-prefix offer exactly as before. DEBUG
    /// launch argument `-rotatingSource YES`; release builds always off.
    static var rotatingSource: Bool { labSwitch("rotatingSource", shipped: false) }
    /// Settings › Manual video (Android `VideoSettings`): what calls and broadcasts ask to send. A stored value that is not
    /// one of Android's choices reads as the standard request; nothing is rewritten. DEBUG launch arguments
    /// `-videoLines 360 -videoFps 15 -videoKbps 300` set it for one run.
    static var videoRequest: VideoRequest {
        get {
            let lines = d.object(forKey: "videoLines") == nil ? 240 : d.integer(forKey: "videoLines")
            let fps = d.object(forKey: "videoFps") == nil ? 15 : d.integer(forKey: "videoFps")
            let kbps = d.object(forKey: "videoKbps") == nil ? 200 : d.integer(forKey: "videoKbps")
            return VideoRequest(lines: lines, fps: fps, kbps: kbps) ?? .standard
        }
        set {
            d.set(newValue.lines, forKey: "videoLines"); d.set(newValue.fps, forKey: "videoFps"); d.set(newValue.kbps, forKey: "videoKbps")
        }
    }
    /// Android "Manual video settings" (`PREF_ADVANCED_SETTINGS`, off): on, nothing adapts to the link.
    static var manualVideo: Bool {
        get { flag("manualVideo", default: false) }
        set { d.set(newValue, forKey: "manualVideo") }
    }
    /// Android "Fill screen with video" (`VideoScaleMode.FILL`, the default): remote video fills the view, edges cropped.
    static var videoFill: Bool {
        get { flag("videoFill", default: true) }
        set { d.set(newValue, forKey: "videoFill") }
    }
    /// Android "Show temperature" (`PREF_SHOW_DEVICE_HEALTH`, off): the heat and battery line on call and live screens.
    static var showTemperature: Bool {
        get { flag("showTemperature", default: false) }
        set { d.set(newValue, forKey: "showTemperature") }
    }
    /// Android "Lower quality when hot" (`PREF_AUTOMATIC_THERMAL_REDUCTION`, on): `ThermalVideoPolicy`.
    static var lowerQualityWhenHot: Bool {
        get { flag("lowerQualityWhenHot", default: true) }
        set { d.set(newValue, forKey: "lowerQualityWhenHot") }
    }
    /// EXPERIMENTAL Android "Warn when video freezes" (`viewer_frame_age`, off): `ViewerFreeze`.
    static var viewerFreezeWarning: Bool {
        get { flag("viewerFreezeWarning", default: false) }
        set { d.set(newValue, forKey: "viewerFreezeWarning") }
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
}
