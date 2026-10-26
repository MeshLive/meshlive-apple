import Foundation
import Security
import CryptoKit
import NearbyCore

/// Local recent-calls history (Android v7 Home "Recent calls"): the last 20 calls on this device only, never sent
/// anywhere. Sealed at rest (`SealedRecords`, review 2026-10-27), kept out of backups, so it does not move to a new
/// device. A call with someone who is not a verified contact keeps only its generated name and the time (PROTOCOL
/// "After the reveal", amending Phase 2 step 5): no ID, so a seized device holds no list of strangers' keys.
struct CallRecord: Codable, Identifiable, Equatable {
    enum Direction: String, Codable { case outgoing, incoming, missed }
    var id = UUID()
    /// The contact's 12-hex prefix; empty for a call with someone who is not a verified contact.
    let prefixHex: String
    let direction: Direction
    let video: Bool
    let at: Date
    let seconds: Int
    /// For a non-contact: the generated name shown during the call (nil: "Someone nearby").
    var name: String? = nil
    var callable: Bool { prefixHex.count == 12 }
}

enum CallHistory {
    static let legacyKey = "recentCalls"
    static let fileName = "recent-calls.bin"
    static let purpose = "MeshLive/RecentCalls/1"
    static let limit = 20

    static var all: [CallRecord] {
        guard case .value(let data) = SealedRecords.files.read(fileName, purpose: purpose),
              let list = try? JSONDecoder().decode([CallRecord].self, from: data) else { return [] }
        return list
    }

    static func add(_ record: CallRecord) {
        let current: [CallRecord]
        switch SealedRecords.files.read(fileName, purpose: purpose) {
        case .absent: current = []
        case .value(let data): current = (try? JSONDecoder().decode([CallRecord].self, from: data)) ?? []
        case .unreadable: return      // never overwrite a history this run cannot read
        }
        guard let data = try? JSONEncoder().encode(Array(([record] + current).prefix(limit))) else { return }
        SealedRecords.files.write(data, name: fileName, purpose: purpose)
    }

    static func clear() {
        DesktopPreview.preferences.removeObject(forKey: legacyKey)
        SealedRecords.files.delete(fileName)
    }
}

/// The records key in the Keychain (this device only, readable after the first unlock: a call can arrive while the
/// phone is locked). Created add-only; a key that appeared meanwhile is read back. On the Mac it lives in the
/// data-protection keychain (review 2026-10-27), where accessibility and device binding apply as on iOS; a build without
/// the entitlement for it (`errSecMissingEntitlement`) falls back to the login keychain, and the log says which.
final class KeychainRecordKeyStore: SealedRecordKeyStore {
    static let account = "records-key"
    #if os(macOS)
    private var useDataProtection: Bool {
        #if DEBUG
        if KeychainItem.ephemeral { return false }
        #endif
        return !DesktopPreview.enabled
    }
    private func dpQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: KeychainServices.current,
         kSecAttrAccount as String: Self.account, kSecUseDataProtectionKeychain as String: true]
    }
    #endif

    func readKey() throws -> Data? {
        #if os(macOS)
        if useDataProtection {
            var query = dpQuery(); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess { return item as? Data }
            guard status == errSecItemNotFound || status == errSecMissingEntitlement else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }
        #endif
        return try KeychainItem.read(Self.account)
    }

    func addKey(_ key: Data) throws {
        #if os(macOS)
        if useDataProtection {
            var add = dpQuery(); add[kSecValueData as String] = key
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecDuplicateItem { throw SealedRecordKeyError.duplicate }
            if status == errSecSuccess { logActual(); return }
            guard status == errSecMissingEntitlement else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
            AppLog.event("storage", ["event": "records_key", "keychain": "login", "reason": "missing_entitlement"])
        }
        #endif
        try KeychainItem.addOnly(Self.account, key, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    func replaceKey(_ key: Data) throws {
        #if os(macOS)
        if useDataProtection { SecItemDelete(dpQuery() as CFDictionary) }
        #endif
        try? KeychainItem.delete(Self.account)
        try addKey(key)
    }

    #if os(macOS)
    /// Logs the keychain and protection class the key actually got (read back, not assumed).
    private func logActual() {
        var query = dpQuery(); query[kSecReturnAttributes as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let accessible = (item as? [String: Any])?[kSecAttrAccessible as String] as? String ?? "unknown"
        AppLog.event("storage", ["event": "records_key", "keychain": "data_protection", "status": "\(status)", "accessible": accessible])
    }
    #endif
}

/// Small local records sealed at rest (recent calls, BMH3 pins): `SealedRecordFiles` next to the verified contacts.
enum SealedRecords {
    static let files = SealedRecordFiles(
        directory: VerifiedContactsStore.url.deletingLastPathComponent(), keys: KeychainRecordKeyStore(),
        latched: { EmergencyWipe.happened }, log: { line in AppLog.event("storage", ["detail": line]) },
        fileProtection: .completeFileProtectionUntilFirstUserAuthentication)

    /// One-time moves of the plain copies of earlier builds, at launch after a resumed wipe and before any reader.
    static func migrateLegacy() {
        if DesktopPreview.enabled { return }
        let defaults = DesktopPreview.preferences
        files.migrate(legacy: defaults.data(forKey: CallHistory.legacyKey), name: CallHistory.fileName, purpose: CallHistory.purpose,
                      removeLegacy: { defaults.removeObject(forKey: CallHistory.legacyKey) })
        // The pin file moves whether or not Hidden identities is on.
        files.migrate(legacy: try? Data(contentsOf: Bmh3PinFile.legacyURL), name: Bmh3PinFile.fileName, purpose: Bmh3PinFile.purpose,
                      removeLegacy: { try? FileManager.default.removeItem(at: Bmh3PinFile.legacyURL) })
    }
}
