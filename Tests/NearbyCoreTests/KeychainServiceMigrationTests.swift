import XCTest
@testable import NearbyCore

/// Moving Keychain items from the old `org.nearbyintercom.*` service names to `io.github.meshlive.app.*`: the identity
/// stays readable through every failure, a later launch finishes the move, and the wipe reaches both names.
final class KeychainServiceMigrationTests: XCTestCase {
    let ok = KeychainReplace.success, notFound = KeychainReplace.itemNotFound
    let old = KeychainServices.legacyCurrent, new = KeychainServices.current

    /// In-memory Keychain with injectable failures. A "crash" makes every call after it fail, as if the process died.
    final class MockKeychain: KeychainServiceStore {
        static let locked: Int32 = -25308   // errSecInteractionNotAllowed
        var items: [String: [String: KeychainStoredItem]] = [:]
        /// "op:service" or "op:service:account", op in list, read, add, delete, deleteAll.
        var failing: Set<String> = []
        var crashAfterAdds: Int?
        var corruptAdds = false
        private var adds = 0, crashed = false

        func relaunch() { crashed = false; crashAfterAdds = nil; failing = []; corruptAdds = false; adds = 0 }
        private func fails(_ op: String, _ service: String, _ account: String? = nil) -> Bool {
            crashed || failing.contains("\(op):\(service)") || account.map { failing.contains("\(op):\(service):\($0)") } == true
        }
        func accounts(service: String) -> (status: Int32, accounts: [String]) {
            if fails("list", service) { return (Self.locked, []) }
            let names = items[service].map { Array($0.keys) } ?? []
            return names.isEmpty ? (KeychainReplace.itemNotFound, []) : (KeychainReplace.success, names)
        }
        func read(service: String, account: String) -> (status: Int32, item: KeychainStoredItem?) {
            if fails("read", service, account) { return (Self.locked, nil) }
            guard let item = items[service]?[account] else { return (KeychainReplace.itemNotFound, nil) }
            return (KeychainReplace.success, item)
        }
        func add(service: String, account: String, item: KeychainStoredItem) -> Int32 {
            if fails("add", service, account) { return Self.locked }
            if items[service]?[account] != nil { return KeychainReplace.duplicateItem }
            items[service, default: [:]][account] = corruptAdds ? KeychainStoredItem(data: Data([0xEE]), accessible: item.accessible) : item
            adds += 1
            if let limit = crashAfterAdds, adds >= limit { crashed = true }
            return KeychainReplace.success
        }
        func delete(service: String, account: String) -> Int32 {
            if fails("delete", service, account) { return Self.locked }
            return items[service]?.removeValue(forKey: account) == nil ? KeychainReplace.itemNotFound : KeychainReplace.success
        }
        func deleteAll(service: String) -> Int32 {
            if fails("deleteAll", service) { return Self.locked }
            let had = !(items[service]?.isEmpty ?? true)
            items[service] = nil
            return had ? KeychainReplace.success : KeychainReplace.itemNotFound
        }
    }

    private let identity = KeychainStoredItem(data: Data("secure-enclave-key".utf8), accessible: "akuo")
    private let contacts = KeychainStoredItem(data: Data("contacts-key".utf8), accessible: "akuo")
    private let guardSecret = KeychainStoredItem(data: Data("guard".utf8), accessible: "cku")

    private func existingInstall() -> MockKeychain {
        let keychain = MockKeychain()
        keychain.items[old] = ["identity-se": identity, "contacts-key": contacts, "presence-guard": guardSecret]
        return keychain
    }

    private func value(_ account: String, _ keychain: MockKeychain) -> KeychainStoredItem? {
        let found = KeychainServices.read(account, store: keychain)
        XCTAssertTrue(found.status == ok || found.status == notFound, "read failed with \(found.status)")
        return found.item
    }

    func testMovesEveryItemOnceAndKeepsItsProtection() {
        let keychain = existingInstall()
        let result = KeychainServiceMigration.run(from: old, to: new, store: keychain)
        XCTAssertEqual(result, .init(moved: 3))
        XCTAssertTrue(result.complete)
        XCTAssertNil(keychain.items[old]?.values.first, "nothing is left under the old name")
        XCTAssertEqual(keychain.items[new], ["identity-se": identity, "contacts-key": contacts, "presence-guard": guardSecret])
        XCTAssertEqual(KeychainServiceMigration.run(from: old, to: new, store: keychain), .init(), "a second launch has nothing to do")
        XCTAssertEqual(value("identity-se", keychain), identity)
    }

    func testFreshInstallHasNothingToMove() {
        let keychain = MockKeychain()
        XCTAssertTrue(KeychainServiceMigration.run(from: old, to: new, store: keychain).complete)
        XCTAssertNil(value("identity-se", keychain), "no identity: the app creates one under the new name")
    }

    func testFailedCopyKeepsTheOldItemReadableAndTheNextLaunchFinishes() {
        let keychain = existingInstall()
        keychain.failing = ["add:\(new):identity-se"]
        let first = KeychainServiceMigration.run(from: old, to: new, store: keychain)
        XCTAssertEqual(first, .init(moved: 2, pending: 1))
        XCTAssertFalse(first.complete)
        XCTAssertEqual(keychain.items[old]?["identity-se"], identity, "the old identity is never deleted before its copy exists")
        XCTAssertEqual(value("identity-se", keychain), identity, "the app still reads the identity")

        keychain.relaunch()
        XCTAssertEqual(KeychainServiceMigration.run(from: old, to: new, store: keychain), .init(moved: 1))
        XCTAssertEqual(keychain.items[new]?["identity-se"], identity)
        XCTAssertNil(keychain.items[old]?["identity-se"])
    }

    func testFailedDeleteKeepsBothCopiesUntilTheNextLaunch() {
        let keychain = existingInstall()
        keychain.failing = ["delete:\(old):contacts-key"]
        XCTAssertEqual(KeychainServiceMigration.run(from: old, to: new, store: keychain), .init(moved: 2, pending: 1))
        XCTAssertEqual(keychain.items[old]?["contacts-key"], contacts)
        XCTAssertEqual(value("contacts-key", keychain), contacts)
        keychain.relaunch()
        XCTAssertEqual(KeychainServiceMigration.run(from: old, to: new, store: keychain), .init(moved: 1))
        XCTAssertNil(keychain.items[old]?["contacts-key"])
    }

    func testCrashBetweenCopyAndDeleteIsFinishedByTheNextLaunch() {
        let keychain = existingInstall()
        keychain.crashAfterAdds = 1     // the process dies right after writing the first copy
        let interrupted = KeychainServiceMigration.run(from: old, to: new, store: keychain)
        XCTAssertFalse(interrupted.complete)
        XCTAssertEqual(keychain.items[old]?.count, 3, "no old item was deleted")
        XCTAssertEqual(keychain.items[new]?.count, 1, "one copy was written before the crash")

        keychain.relaunch()
        XCTAssertEqual(value("identity-se", keychain), identity, "after the crash the identity reads the same")
        XCTAssertEqual(KeychainServiceMigration.run(from: old, to: new, store: keychain), .init(moved: 3))
        XCTAssertEqual(keychain.items[new], ["identity-se": identity, "contacts-key": contacts, "presence-guard": guardSecret])
        XCTAssertNil(keychain.items[old]?.values.first)
    }

    func testValueWrittenAfterTheRenameWins() {
        let keychain = existingInstall()
        let newer = KeychainStoredItem(data: Data("vault-generation-2".utf8), accessible: "akuo")
        keychain.items[old]?["presence-vault"] = KeychainStoredItem(data: Data("vault-generation-1".utf8), accessible: "akuo")
        keychain.items[new] = ["presence-vault": newer]
        XCTAssertEqual(value("presence-vault", keychain), newer, "reads prefer the new name")
        XCTAssertTrue(KeychainServiceMigration.run(from: old, to: new, store: keychain).complete)
        XCTAssertEqual(keychain.items[new]?["presence-vault"], newer, "the older copy never overwrites it")
        XCTAssertNil(keychain.items[old]?["presence-vault"])
    }

    func testCopyThatReadsBackDifferentlyIsRemovedAndTheOldItemKept() {
        let keychain = existingInstall()
        keychain.corruptAdds = true
        XCTAssertEqual(KeychainServiceMigration.run(from: old, to: new, store: keychain), .init(pending: 3))
        XCTAssertNil(keychain.items[new]?.values.first, "a bad copy would win over the good old item")
        XCTAssertEqual(value("identity-se", keychain), identity)
    }

    func testLockedKeychainIsNotAbsence() {
        let keychain = existingInstall()
        keychain.failing = ["list:\(old)"]
        let result = KeychainServiceMigration.run(from: old, to: new, store: keychain)
        XCTAssertTrue(result.listFailed)
        XCTAssertFalse(result.complete)
        XCTAssertEqual(keychain.items[old]?.count, 3)

        // A failed read of the new name is reported, not treated as "no identity" (which would create a new one).
        keychain.failing = ["read:\(new):identity-se"]
        XCTAssertEqual(KeychainServices.read("identity-se", store: keychain).status, MockKeychain.locked)
    }

    func testDeletingAnItemRemovesItUnderBothNames() {
        let keychain = existingInstall()
        keychain.failing = ["delete:\(old):contacts-key"]
        _ = KeychainServiceMigration.run(from: old, to: new, store: keychain)
        keychain.relaunch()
        XCTAssertEqual(KeychainServices.delete("contacts-key", store: keychain), ok)
        XCTAssertNil(value("contacts-key", keychain), "an unfinished migration cannot bring a deleted secret back")
        XCTAssertEqual(KeychainServiceMigration.run(from: old, to: new, store: keychain), .init())
    }

    func testWipeDeletesAndVerifiesOldAndNewNames() {
        let keychain = existingInstall()
        keychain.failing = ["add:\(new):identity-se"]
        _ = KeychainServiceMigration.run(from: old, to: new, store: keychain)   // interrupted: items under both names
        keychain.relaunch()
        keychain.items[KeychainServices.legacyPresence] = ["presence-key": guardSecret]
        keychain.items[KeychainServices.legacyV1Identity] = ["static-x25519": identity]
        keychain.items[KeychainServices.v1Identity] = ["static-x25519": identity]
        XCTAssertEqual(Set(KeychainServices.all), [new, old, KeychainServices.legacyPresence,
                                                   KeychainServices.v1Identity, KeychainServices.legacyV1Identity])

        let deletions = KeychainServices.deleteAll(store: keychain)
        let verifications = KeychainServices.verifyAllDeleted(store: keychain)
        XCTAssertTrue(WipeVerification.complete(deletions: deletions, verifications: verifications, filesLeft: 0))
        XCTAssertTrue(keychain.items.values.allSatisfy(\.isEmpty))
        XCTAssertNil(value("identity-se", keychain))
    }

    func testWipeIsUnfinishedWhileAnOldNameStillHoldsItems() {
        let keychain = existingInstall()
        keychain.failing = ["deleteAll:\(old)"]
        let deletions = KeychainServices.deleteAll(store: keychain)
        keychain.relaunch()
        let verifications = KeychainServices.verifyAllDeleted(store: keychain)
        XCTAssertFalse(WipeVerification.complete(deletions: deletions, verifications: verifications, filesLeft: 0),
                       "the identity under the old name survived, so the wipe resumes at the next launch")
    }
}
