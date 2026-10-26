import Foundation
import Security
import NearbyCore

/// The preview must never reach the production Keychain, including this older presence-key migration.
enum DesktopLegacyPresenceCleanup {
    static func run(preview: Bool, deleteItem: (CFDictionary) -> OSStatus = SecItemDelete) {
        guard !preview else { return }
        _ = deleteItem([kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: KeychainServices.legacyPresence] as CFDictionary)
    }
}
