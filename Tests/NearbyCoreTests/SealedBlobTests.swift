import XCTest
@testable import NearbyCore

/// Recent calls and pins are sealed at rest; a blob opens only with its key and its purpose.
final class SealedBlobTests: XCTestCase {
    let key = Data(repeating: 7, count: 32)

    func testRoundTripAndNoPlaintextAtRest() throws {
        let plain = Data(#"[{"prefixHex":"a1b2c3d4e5f6"}]"#.utf8)
        let sealed = try SealedBlob.seal(plain, key: key, purpose: "recent-calls-v1")
        XCTAssertNil(sealed.range(of: Data("a1b2c3d4e5f6".utf8)), "the prefix is not readable at rest")
        XCTAssertEqual(SealedBlob.open(sealed, key: key, purpose: "recent-calls-v1"), plain)
    }

    func testWrongKeyPurposeOrDamageReadsAsAbsent() throws {
        let sealed = try SealedBlob.seal(Data("pins".utf8), key: key, purpose: "hidden-identity-pins-v1")
        XCTAssertNil(SealedBlob.open(sealed, key: Data(repeating: 8, count: 32), purpose: "hidden-identity-pins-v1"))
        XCTAssertNil(SealedBlob.open(sealed, key: key, purpose: "recent-calls-v1"), "one store's blob never opens as another")
        var damaged = sealed; damaged[damaged.count - 1] ^= 1
        XCTAssertNil(SealedBlob.open(damaged, key: key, purpose: "hidden-identity-pins-v1"))
        XCTAssertNil(SealedBlob.open(Data([1, 2, 3]), key: key, purpose: "hidden-identity-pins-v1"))
    }
}
