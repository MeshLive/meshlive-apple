import XCTest
import Security
import NearbyCore
@testable import DesktopSupport

final class DesktopLegacyPresenceCleanupTests: XCTestCase {
    private final class Store {
        var values = [KeychainServices.legacyPresence: "legacy-presence",
                      KeychainServices.current: "current-identity-and-vault"]

        func delete(_ query: CFDictionary) -> OSStatus {
            let query = query as NSDictionary
            guard query[kSecClass] as? String == kSecClassGenericPassword as String,
                  let service = query[kSecAttrService] as? String else { return errSecParam }
            return values.removeValue(forKey: service) == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    func testPreviewLeavesLegacyAndCurrentIdentityUntouched() {
        let store = Store()
        DesktopLegacyPresenceCleanup.run(preview: true, deleteItem: store.delete)
        XCTAssertEqual(store.values[KeychainServices.legacyPresence], "legacy-presence")
        XCTAssertEqual(store.values[KeychainServices.current], "current-identity-and-vault")
    }

    func testNormalStartupRetainsTheExistingLegacyMigration() {
        let store = Store()
        DesktopLegacyPresenceCleanup.run(preview: false, deleteItem: store.delete)
        XCTAssertNil(store.values[KeychainServices.legacyPresence])
        XCTAssertEqual(store.values[KeychainServices.current], "current-identity-and-vault")
        DesktopLegacyPresenceCleanup.run(preview: false, deleteItem: store.delete)
        XCTAssertEqual(store.values[KeychainServices.current], "current-identity-and-vault")
    }

    func testPreviewNeverInvokesKeychainDeletion() {
        DesktopLegacyPresenceCleanup.run(preview: true) { _ in
            XCTFail("Preview reached production Keychain deletion")
            return errSecInteractionNotAllowed
        }
    }
}
