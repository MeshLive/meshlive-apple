import Foundation
import Security
import CryptoKit
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
    static let service = "org.nearbyintercom.mesh.v2"
    static func read(_ account: String) throws -> Data? {
        var query = base(account); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return item as? Data
    }
    static func write(_ account: String, _ data: Data) throws {
        SecItemDelete(base(account) as CFDictionary)
        var add = base(account); add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    static func deleteAll() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        // The phase 1 rotating-ID presence key (now replaced by the presence vault), and the earlier v1 identity.
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.nearbyintercom.rotating"] as CFDictionary)
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.nearbyintercom.identity.v1"] as CFDictionary)
    }
    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

enum IdentityStore {
    static func loadOrCreate() throws -> SigningIdentity {
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
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        do {
            guard let keyData = try KeychainItem.read("contacts-key") else { return .unreadable("The contacts key is missing") }
            let box = try AES.GCM.SealedBox(combined: try Data(contentsOf: url))
            let plain = try AES.GCM.open(box, using: SymmetricKey(data: keyData), authenticating: Data("verified-contacts-v1".utf8))
            return .loaded(try JSONDecoder().decode([VerifiedContact].self, from: plain))
        } catch { return .unreadable("\(error)") }
    }
    static func save(_ contacts: [VerifiedContact]) throws {
        var keyData = try KeychainItem.read("contacts-key")
        if keyData == nil { let k = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }; try KeychainItem.write("contacts-key", k); keyData = k }
        let plain = try JSONEncoder().encode(contacts)
        let sealed = try AES.GCM.seal(plain, using: SymmetricKey(data: keyData!), authenticating: Data("verified-contacts-v1".utf8)).combined!
        var dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try? dir.setResourceValues(values)
        try sealed.write(to: url, options: [.atomic, .completeFileProtection])
    }
    static func reset() { try? FileManager.default.removeItem(at: url) }
}

/// Emergency wipe (Android EmergencyWipe semantics, adapted to iOS): marker first, keys first, then
/// data, a second sweep, and the marker last. A remaining marker resumes the wipe on the next launch.
enum EmergencyWipe {
    static var markerURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("emergency-wipe-pending")
    }
    static var pending: Bool { FileManager.default.fileExists(atPath: markerURL.path) }

    /// Runs synchronously; returns true when the final sweep left nothing behind.
    @discardableResult
    static func run() -> Bool {
        try? Data().write(to: markerURL, options: .atomic)
        KeychainItem.deleteAll()
        sweep()
        if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
        sweep()
        KeychainItem.deleteAll()
        let complete = (try? KeychainItem.read("identity-se")) == nil && (try? KeychainItem.read("identity-software")) == nil && !FileManager.default.fileExists(atPath: VerifiedContactsStore.url.path)
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
    private static let d = UserDefaults.standard
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
    /// iPhone keeps it off until phone tests pass and the root reviews it).
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
    /// EXPERIMENTAL native call screen (off): a call that rings in the background is reported to CallKit.
    static var callKit: Bool {
        get { d.bool(forKey: "experimentalCallKit") }
        set { d.set(newValue, forKey: "experimentalCallKit") }
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
