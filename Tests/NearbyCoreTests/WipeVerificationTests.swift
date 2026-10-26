import XCTest
@testable import NearbyCore

/// The emergency wipe is finished only when absence is confirmed, never when a check merely failed.
final class WipeVerificationTests: XCTestCase {
    let notFound = KeychainReplace.itemNotFound, ok = KeychainReplace.success
    let locked: Int32 = -25308   // errSecInteractionNotAllowed

    func testOnlyNotFoundConfirmsAbsence() {
        XCTAssertTrue(WipeVerification.complete(deletions: [ok, notFound], verifications: [notFound, notFound], filesLeft: 0))
        XCTAssertFalse(WipeVerification.complete(deletions: [ok], verifications: [locked], filesLeft: 0), "an error is not absence")
        XCTAssertFalse(WipeVerification.complete(deletions: [ok], verifications: [ok], filesLeft: 0), "an item is still there")
        XCTAssertFalse(WipeVerification.complete(deletions: [locked], verifications: [notFound], filesLeft: 0), "a failed deletion")
        XCTAssertFalse(WipeVerification.complete(deletions: [ok], verifications: [notFound], filesLeft: 1), "a file is left")
        XCTAssertFalse(WipeVerification.complete(deletions: [ok], verifications: [], filesLeft: 0), "nothing was verified")
    }
}
