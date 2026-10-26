import XCTest
import Security
@testable import DesktopSupport

final class DesktopLegacyPresenceCleanupTests: XCTestCase {
    private final class Store {
        var values = ["org.nearbyintercom.rotating": "legacy-presence",
                      "org.nearbyintercom.mesh.v2": "current-identity-and-vault"]

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
        XCTAssertEqual(store.values["org.nearbyintercom.rotating"], "legacy-presence")
        XCTAssertEqual(store.values["org.nearbyintercom.mesh.v2"], "current-identity-and-vault")
    }

    func testNormalStartupRetainsTheExistingLegacyMigration() {
        let store = Store()
        DesktopLegacyPresenceCleanup.run(preview: false, deleteItem: store.delete)
        XCTAssertNil(store.values["org.nearbyintercom.rotating"])
        XCTAssertEqual(store.values["org.nearbyintercom.mesh.v2"], "current-identity-and-vault")
        DesktopLegacyPresenceCleanup.run(preview: false, deleteItem: store.delete)
        XCTAssertEqual(store.values["org.nearbyintercom.mesh.v2"], "current-identity-and-vault")
    }

    func testPreviewNeverInvokesKeychainDeletion() {
        DesktopLegacyPresenceCleanup.run(preview: true) { _ in
            XCTFail("Preview reached production Keychain deletion")
            return errSecInteractionNotAllowed
        }
    }
}
