import XCTest
@testable import NearbyCore

final class CallAlertTests: XCTestCase {
    func testContentMirrorsAndroidWordingAndHidesStrangers() {
        XCTAssertEqual(CallAlertPolicy.content(voice: false, peerName: "Asha", stranger: false), .init(title: "Incoming video call", body: "Asha"))
        XCTAssertEqual(CallAlertPolicy.content(voice: true, peerName: "Asha", stranger: false).title, "Incoming voice call")
        XCTAssertEqual(CallAlertPolicy.content(voice: false, peerName: "Asha", stranger: true).body, "Open the app to see who is calling.")
        XCTAssertEqual(CallAlertPolicy.content(voice: false, peerName: "  ", stranger: false).body, "Open the app to see who is calling.")
        XCTAssertEqual(CallAlertPolicy.lockedPlaceholder, "Incoming call")
    }

    func testMissedCallKeepsTheNameRulesAndDropsTheType() {
        XCTAssertEqual(CallAlertPolicy.missedContent(peerName: "Asha", stranger: false), .init(title: "Missed call", body: "Asha"))
        XCTAssertEqual(CallAlertPolicy.missedContent(peerName: "Asha", stranger: true).body, "Open the app to see who is calling.")
    }

    func testNamesAreCleanedAndBounded() {
        XCTAssertEqual(CallAlertPolicy.sanitizedName(" A\u{202E}sha\u{0007} "), "Asha")
        let long = String(repeating: "x", count: 80)
        XCTAssertEqual(CallAlertPolicy.sanitizedName(long)?.count, 40)
        XCTAssertNil(CallAlertPolicy.sanitizedName("\u{200B}\u{200E}"))
    }

    func testPostingAndAskingRules() {
        XCTAssertTrue(CallAlertPolicy.shouldPost(ringing: true, appActive: false, authorization: .authorized))
        XCTAssertFalse(CallAlertPolicy.shouldPost(ringing: true, appActive: true, authorization: .authorized))
        XCTAssertFalse(CallAlertPolicy.shouldPost(ringing: false, appActive: false, authorization: .authorized))
        XCTAssertFalse(CallAlertPolicy.shouldPost(ringing: true, appActive: false, authorization: .denied))
        XCTAssertTrue(CallAlertPolicy.shouldRequest(.reachableTurnedOn, authorization: .notDetermined, alreadyAsked: false))
        XCTAssertFalse(CallAlertPolicy.shouldRequest(.callEnded, authorization: .notDetermined, alreadyAsked: true))
        XCTAssertTrue(CallAlertPolicy.shouldRequest(.settingsButton, authorization: .notDetermined, alreadyAsked: true))
        XCTAssertFalse(CallAlertPolicy.shouldRequest(.settingsButton, authorization: .denied, alreadyAsked: false))
        XCTAssertFalse(CallAlertPolicy.shouldRequest(.launch, authorization: .notDetermined, alreadyAsked: false))
        XCTAssertTrue(CallAlertPolicy.statusText(.denied).contains("Settings"))
    }
}
