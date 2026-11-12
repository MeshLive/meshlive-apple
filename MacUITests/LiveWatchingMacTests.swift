import XCTest

/// C1 watching checks on the Mac (compiled only; the reviewer runs them): the source gate and the watching screens.
final class LiveWatchingMacTests: XCTestCase {
    private func launch(_ args: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        let contentSize = args.contains("-desktopContentSize") ? [] : ["-desktopContentSize", "100"]
        let fixture = args.contains("-NearbyFixture") ? [] : ["-NearbyFixture", "populated"]
        app.launchArguments = contentSize + ["-NearbyPreview", "-ApplePersistenceIgnoreState", "YES"] + fixture + args
        app.launch()
        return app
    }

    func testWithoutSourceRolesTheMacOffersNoGoLive() {
        let app = launch(["-NearbyScreen", "live"])
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "liveSourceLater").firstMatch.waitForExistence(timeout: 10),
                      "the Live page says going live comes later")
        XCTAssertFalse(app.buttons["Go live"].exists)
        let file = app.menuBars.menuBarItems["File"]
        if file.exists {
            file.click()
            XCTAssertFalse(app.menuItems["Go live"].exists, "no Go live menu item")
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        } else {
            XCTAssertFalse(app.menuBars.menuItems["Go live"].exists, "no Go live menu item")
        }
        app.terminate()
    }

    func testWithSourceRolesTheMacOffersGoLiveAgain() {
        let app = launch(["-NearbyScreen", "live", "-appleSourceRoles", "YES"])
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 10))
        let file = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        file.click()
        XCTAssertTrue(app.menuItems["Go live"].waitForExistence(timeout: 4))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        app.terminate()
    }

    func testALostStreamClosesTheWatchAndOffersARescanOnTheMac() {
        let app = launch(["-NearbyWatchTimeout", "3", "-NearbyFixtureStreamLost", "1"])
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'stream-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        rows.firstMatch.click()
        let leave = app.buttons["Leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 10), "the watch view opened")
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: leave)], timeout: 25)
        let notice = app.staticTexts["The stream was lost. Showing nearby broadcasts."]
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "the Live page says the stream was lost")
        let action = app.buttons["notice-action"]
        XCTAssertTrue(action.waitForExistence(timeout: 4), "Try again")
        XCTAssertTrue(rows.firstMatch.isHittable, "the stream rows are back")
        action.click()
        XCTAssertFalse(notice.waitForExistence(timeout: 2), "Try again removes the notice")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 4), "the streams are still listed")
        XCTAssertFalse(app.buttons["Leave"].exists, "Try again rescans, it does not rejoin")
        app.terminate()
    }
}
