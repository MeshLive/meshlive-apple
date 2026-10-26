import XCTest

/// Local incoming-call alerts on the simulator: the permission prompt and its denied state in Settings, and (when
/// allowed) the alert for a call that rings while MeshLive is in the background, with its Decline action.
/// Run: `SIMULATOR=<udid> NEARBY_ALERT_ANSWER=allow|deny bash Scripts/run-uitest.sh alerts` (each run starts uninstalled).
final class CallAlertUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png"); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = env["NEARBY_SHOT_DIR"], !dir.isEmpty { try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")) }
    }

    private func openSettings(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-NearbyScreen", "settings"] + extra
        app.launch()
        return app
    }

    private func answerPrompt(allow: Bool) {
        let button = springboard.buttons[allow ? "Allow" : "Don’t Allow"]
        let fallback = springboard.buttons[allow ? "Allow" : "Don't Allow"]
        if button.waitForExistence(timeout: 8) { button.tap() } else if fallback.exists { fallback.tap() }
    }

    func testPermissionPromptAndStatus() {
        let allow = env["NEARBY_ALERT_ANSWER"] == "allow"
        let app = openSettings()
        let ask = app.buttons["allowCallAlerts"]
        XCTAssertTrue(ask.waitForExistence(timeout: 10), "a fresh install offers to allow call alerts")
        shot("alerts-not-determined")
        ask.tap()
        answerPrompt(allow: allow)
        let status = app.staticTexts["callAlertsStatus"]
        let expected = allow ? "On." : "Off."
        let predicate = NSPredicate(format: "label BEGINSWITH %@", expected)
        expectation(for: predicate, evaluatedWith: status)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(app.buttons["openNotificationSettings"].exists, !allow, "the denied state links to iPhone Settings")
        XCTAssertFalse(app.buttons["allowCallAlerts"].exists)
        shot(allow ? "alerts-allowed" : "alerts-denied")
    }

    func testRingingCallInTheBackgroundShowsAnAlertWithDecline() throws {
        guard env["NEARBY_ALERT_ANSWER"] == "allow" else { throw XCTSkip("needs NEARBY_ALERT_ANSWER=allow") }
        // Allow first (fresh install), then relaunch on a ringing fixture call and leave the app while it rings.
        var app = openSettings()
        if app.buttons["allowCallAlerts"].waitForExistence(timeout: 8) { app.buttons["allowCallAlerts"].tap(); answerPrompt(allow: true) }
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-NearbyScreen", "call-incoming"]
        app.launch()
        XCTAssertTrue(app.buttons["Decline"].waitForExistence(timeout: 10), "the fixture call rings")
        XCUIDevice.shared.press(.home)
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "Incoming video call")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "the alert appears while the app is in the background")
        shot("alerts-banner")
        banner.press(forDuration: 1.2)
        let decline = springboard.buttons["Decline"]
        XCTAssertTrue(decline.waitForExistence(timeout: 8), "the alert offers Decline")
        XCTAssertTrue(springboard.buttons["Accept"].exists, "the alert offers Accept")
        shot("alerts-actions")
        decline.tap()
        app.activate()
        let ringing = app.buttons["Decline"]
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: ringing)
        waitForExpectations(timeout: 10)
    }

    /// A call that stops ringing unanswered leaves a missed-call notification. The fixture caller is not a verified
    /// contact, so (review 2026-10-27) it is neither named nor offered Call back.
    func testUnansweredCallLeavesAMissedCallNotificationWithCallBack() throws {
        guard env["NEARBY_ALERT_ANSWER"] == "allow" else { throw XCTSkip("needs NEARBY_ALERT_ANSWER=allow") }
        var app = openSettings()
        if app.buttons["allowCallAlerts"].waitForExistence(timeout: 8) { app.buttons["allowCallAlerts"].tap(); answerPrompt(allow: true) }
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-NearbyScreen", "call-incoming", "-NearbyFixtureMissAfter", "6"]
        app.launch()
        XCTAssertTrue(app.buttons["Decline"].waitForExistence(timeout: 10), "the fixture call rings")
        XCUIDevice.shared.press(.home)
        let missed = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "Missed call")).firstMatch
        XCTAssertTrue(missed.waitForExistence(timeout: 25), "the missed call is announced after the ringing stops")
        XCTAssertFalse(missed.label.contains("Asha"), "a caller who is not a verified contact is not named")
        shot("missed-call")
        missed.press(forDuration: 1.2)
        XCTAssertFalse(springboard.buttons["Call back"].waitForExistence(timeout: 4), "no Call back for a non-contact")
        shot("missed-call-actions")
    }
}
