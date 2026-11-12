import XCTest

/// C1 watching checks (compiled only; the reviewer runs them): the source gate hides every way to go live, and the
/// watching screens match Android.
final class LiveWatchingUITests: XCTestCase {
    private func launch(_ arguments: [String], sourceRoles: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        var args = arguments
        if !args.contains("-NearbyFixture") { args += ["-NearbyFixture", "populated"] }
        if sourceRoles { args += ["-appleSourceRoles", "YES"] }
        app.launchArguments = args
        app.launch()
        return app
    }

    func testLiveTabHasNoGoLiveWithoutSourceRoles() {
        let app = launch(["-NearbyScreen", "live"])
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'stream-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "the fixture's streams are listed")
        XCTAssertFalse(app.buttons["Go live"].exists, "a release build has no Go live")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "liveSourceLater").firstMatch.waitForExistence(timeout: 4),
                      "the footer says going live comes later")
        app.terminate()
    }

    func testStatusSheetHidesTheRelayRowWithoutSourceRoles() {
        var app = launch(["-NearbyScreen", "live"])
        openStatus(app)
        XCTAssertTrue(app.descendants(matching: .any)["status-row-bluetooth"].exists, "the status sheet opened")
        XCTAssertFalse(app.descendants(matching: .any)["status-row-relay"].exists, "no relay row without source roles")
        app.terminate()
        app = launch(["-NearbyScreen", "live"], sourceRoles: true)
        openStatus(app)
        XCTAssertTrue(app.descendants(matching: .any)["status-row-bluetooth"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.descendants(matching: .any)["status-row-relay"].exists, "the control arm keeps the relay row")
        app.terminate()
    }

    func testGoLiveIsBackWithSourceRolesOn() {
        let app = launch(["-NearbyScreen", "live"], sourceRoles: true)
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 10))
        app.terminate()
    }

    func testALostStreamClosesTheWatchAndOffersARescan() {
        let app = launch(["-NearbyScreen", "live", "-NearbyWatchTimeout", "3", "-NearbyFixtureStreamLost", "1"])
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'stream-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        rows.firstMatch.tap()
        let leave = app.buttons["Leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 10), "the watch screen opened")
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: leave)], timeout: 25)
        let notice = app.staticTexts["The stream was lost. Showing nearby broadcasts."]
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "the Live tab says the stream was lost")
        let action = app.buttons["notice-action"]
        XCTAssertTrue(action.waitForExistence(timeout: 4), "Try again")
        XCTAssertTrue(rows.firstMatch.isHittable, "the stream rows are back")
        action.tap()
        XCTAssertFalse(notice.waitForExistence(timeout: 2), "Try again removes the notice")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 4), "the streams are still listed")
        XCTAssertFalse(app.buttons["Leave"].exists, "Try again rescans, it does not rejoin")
        app.terminate()
    }

    func testEmptyLiveListTellsWhatAndThatItIsLooking() {
        let app = launch(["-NearbyScreen", "live", "-NearbyFixture", "empty"])
        XCTAssertTrue(app.staticTexts["No one is live nearby"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Livestreams from people nearby show up here."].exists)
        let scanning = app.staticTexts["Looking for livestreams nearby\u{2026}"]
        #if targetEnvironment(simulator)
        // No Bluetooth on a simulator: the status card explains it, and the list does not claim to be looking.
        XCTAssertFalse(scanning.waitForExistence(timeout: 3), "no scanning line without Bluetooth")
        #else
        XCTAssertTrue(scanning.waitForExistence(timeout: 5), "the scanning line")
        #endif
        app.terminate()
    }

    private func openStatus(_ app: XCUIApplication) {
        let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'statusChip-'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 8), "status chip")
        chip.tap()
        XCTAssertTrue(app.descendants(matching: .any)["status-row-bluetooth"].waitForExistence(timeout: 4), "the status sheet")
    }
}
