import XCTest
@testable import NearbyCore

/// Missed-call notifications as Android's MissedCallNotification: who counts as missed, one per caller, a count.
final class MissedCallAlertTests: XCTestCase {
    func testOnlyAnUnansweredIncomingCallThatWasNotDeclinedIsMissed() {
        XCTAssertTrue(MissedCallAlert.isMissed(incoming: true, rang: true, wasActive: false, declinedHere: false))
        XCTAssertFalse(MissedCallAlert.isMissed(incoming: true, rang: true, wasActive: true, declinedHere: false), "answered")
        XCTAssertFalse(MissedCallAlert.isMissed(incoming: true, rang: true, wasActive: false, declinedHere: true), "declined here")
        XCTAssertFalse(MissedCallAlert.isMissed(incoming: false, rang: false, wasActive: false, declinedHere: false), "our own call")
        XCTAssertFalse(MissedCallAlert.isMissed(incoming: true, rang: false, wasActive: false, declinedHere: false),
                       "a link that failed before ringing was never shown as a call")
    }

    func testEachCallerHasItsOwnNotificationAndCount() {
        XCTAssertNotEqual(MissedCallAlert.identifier(prefixHex: "a1b2c3d4e5f6"), MissedCallAlert.identifier(prefixHex: "0102030405a8"))
        XCTAssertEqual(MissedCallAlert.identifier(prefixHex: "A1B2C3D4E5F6"), MissedCallAlert.identifier(prefixHex: "a1b2c3d4e5f6"))
        XCTAssertEqual(MissedCallAlert.nextCount(stillShowing: true, previous: 2), 3)
        XCTAssertEqual(MissedCallAlert.nextCount(stillShowing: false, previous: 2), 1, "a dismissed notification starts over")
    }

    func testTitleNamesOnlyAKnownCallerAndCountsCalls() {
        let named = MissedCallAlert.title(peerName: "Asha", stranger: false, count: 3)
        XCTAssertTrue(named.contains("Asha") && named.contains("3"))
        XCTAssertFalse(MissedCallAlert.title(peerName: "Gold Fox", stranger: true, count: 1).contains("Gold Fox"),
                       "a throwaway-key caller has no name to show")
        let hostile = String(repeating: "x", count: 200) + "\u{202E}"
        XCTAssertLessThan(MissedCallAlert.title(peerName: hostile, stranger: false, count: 1).count, 80)
    }
}
