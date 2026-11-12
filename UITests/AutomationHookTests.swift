import XCTest

/// A6: DEBUG call automation hooks (compiled only; the reviewer runs these on a simulator).
final class AutomationHookTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    func testAutoDeclinePlainClosesTheRingScreen() {
        let app = launch(["-NearbyFixture", "readme", "-NearbyScreen", "call-incoming",
                          "-NearbyAutoDecline", "plain", "-NearbyDeclineAfterS", "1"])
        let accept = app.buttons["Accept"].firstMatch
        XCTAssertTrue(accept.waitForExistence(timeout: 10))
        XCTAssertTrue(accept.waitForNonExistence(timeout: 10))
        app.terminate()
    }

    func testAutoDeclineBlockSaysDeclinedAndBlocked() {
        let app = launch(["-NearbyFixture", "readme", "-NearbyScreen", "call-incoming",
                          "-NearbyAutoDecline", "block", "-NearbyDeclineAfterS", "1"])
        let accept = app.buttons["Accept"].firstMatch
        XCTAssertTrue(accept.waitForExistence(timeout: 10))
        XCTAssertTrue(accept.waitForNonExistence(timeout: 10))
        // The notice is on the Calls tab, and the call cover takes two seconds to dismiss: a tap while it is still
        // closing does not switch tabs, so tap until the tab is selected.
        let calls = app.tabBars.buttons["Calls"]
        XCTAssertTrue(calls.waitForExistence(timeout: 5))
        for _ in 0..<6 where !calls.isSelected {
            calls.tap()
            if !calls.isSelected { Thread.sleep(forTimeInterval: 0.7) }
        }
        let notice = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Declined and blocked")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        app.terminate()
    }

    func testAutoAcceptWinsOverAutoDecline() {
        // The readme/call-incoming fixture cannot reach .active after an accept (the controller phase is set directly,
        // while accept needs a real ringing engine), so this uses the plan's fallback: AutoAccept wins if no decline
        // notice appears.
        let app = launch(["-NearbyFixture", "readme", "-NearbyScreen", "call-incoming",
                          "-NearbyAutoAccept", "voice", "-NearbyAutoDecline", "plain",
                          "-NearbyDeclineAfterS", "1"])
        XCTAssertTrue(app.buttons["Accept"].firstMatch.waitForExistence(timeout: 10))
        let declined = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Declined")).firstMatch
        XCTAssertFalse(declined.waitForExistence(timeout: 5), "AutoAccept must win; AutoDecline must not run")
        app.terminate()
    }
}
