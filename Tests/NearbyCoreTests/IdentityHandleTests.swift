import XCTest
@testable import NearbyCore

/// Vectors from the naming design draft (handle_vectors.py), shared with Android's IdentityHandleTest.
final class IdentityHandleTests: XCTestCase {
    func testVectorsAndParsing() {
        let vectors = ["010203040506": "04106-1050R", "a1b2c3d4e5f6": "M6SC7-N75YR", "000000000000": "00000-00000", "ffffffffffff": "ZZZZZ-ZZZZW"]
        for (prefixHex, handle) in vectors {
            let prefix = Data(hex: prefixHex)!
            XCTAssertEqual(IdentityHandle.handle(prefix: prefix), handle)
            XCTAssertEqual(IdentityHandle.parse(handle), prefix)
            XCTAssertEqual(IdentityHandle.parse(handle.lowercased().replacingOccurrences(of: "-", with: " ")), prefix)
        }
        XCTAssertEqual(IdentityHandle.shortHandle(prefix: Data(hex: "a1b2c3d4e5f6")!), "M6SC7")
        XCTAssertEqual(IdentityHandle.parse("o4lO6-lO5OR"), Data(hex: "010203040506")) // O->0, l/I->1 read-aloud mistakes
        XCTAssertNil(IdentityHandle.parse("ZZZZZ-ZZZZZ"))   // low 2 bits must be zero
        XCTAssertNil(IdentityHandle.parse("M6SC7-N75Y"))    // 9 symbols
        XCTAssertNil(IdentityHandle.parse("M6SC7-N75YU"))   // U is not Crockford
    }
}
