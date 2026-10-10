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
        // Earlier experimental v1 identity, too.
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
    static var onboardingDone: Bool {
        get { d.bool(forKey: "onboardingDone") }
        set { d.set(newValue, forKey: "onboardingDone") }
    }
}
