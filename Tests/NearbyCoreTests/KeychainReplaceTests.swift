import XCTest
@testable import NearbyCore

/// Replacing a Keychain item never loses the old value when the write fails.
final class KeychainReplaceTests: XCTestCase {
    /// A one-account keychain whose writes can fail, modelling update, add and delete.
    final class Keychain {
        var item: Data?
        var writesFail = false
        func update(_ data: Data) -> Int32 {
            guard item != nil else { return KeychainReplace.itemNotFound }
            if writesFail { return -25308 }   // errSecInteractionNotAllowed: the device is locked
            item = data; return KeychainReplace.success
        }
        func add(_ data: Data) -> Int32 {
            if item != nil { return KeychainReplace.duplicateItem }
            if writesFail { return -25308 }
            item = data; return KeychainReplace.success
        }
        func delete() { item = nil }
    }

    func testAFailedReplacementKeepsTheOldValue() {
        let keychain = Keychain()
        XCTAssertEqual(KeychainReplace.write(update: { keychain.update(Data([1])) }, add: { keychain.add(Data([1])) }), KeychainReplace.success)
        XCTAssertEqual(keychain.item, Data([1]), "added when missing")
        keychain.writesFail = true
        XCTAssertNotEqual(KeychainReplace.write(update: { keychain.update(Data([2])) }, add: { keychain.add(Data([2])) }), KeychainReplace.success)
        XCTAssertEqual(keychain.item, Data([1]), "the old value survives a failed write")
        // The previous delete-then-add order lost it:
        keychain.delete(); _ = keychain.add(Data([2]))
        XCTAssertNil(keychain.item)
        keychain.writesFail = false
        keychain.item = Data([1])
        XCTAssertEqual(KeychainReplace.write(update: { keychain.update(Data([3])) }, add: { keychain.add(Data([3])) }), KeychainReplace.success)
        XCTAssertEqual(keychain.item, Data([3]), "replaced in place")
    }

    func testAnItemAddedConcurrentlyIsUpdated() {
        let keychain = Keychain()
        var first = true
        let status = KeychainReplace.write(update: {
            if first { first = false; return KeychainReplace.itemNotFound }
            return keychain.update(Data([9]))
        }, add: { keychain.item = Data([8]); return KeychainReplace.duplicateItem })
        XCTAssertEqual(status, KeychainReplace.success)
        XCTAssertEqual(keychain.item, Data([9]))
    }
}
