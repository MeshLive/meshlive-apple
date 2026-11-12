import XCTest

/// B1 on the Mac: the scanner's denied state, the ring panel's block and report, and a call answered with the camera off
/// (compiled only; the reviewer runs these).
final class B1CallsTests: XCTestCase {
    private func launch(_ args: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        let contentSize = args.contains("-desktopContentSize") ? [] : ["-desktopContentSize", "100"]
        let fixture = args.contains("-NearbyFixture") ? [] : ["-NearbyFixture", "populated"]
        app.launchArguments = contentSize + ["-NearbyPreview", "-ApplePersistenceIgnoreState", "YES"] + fixture + args
        app.launch()
        let tree = XCTAttachment(string: app.windows.debugDescription)
        tree.name = "launch-tree"; tree.lifetime = .keepAlways; add(tree)
        return app
    }

    func testTheScannerExplainsADeniedCamera() {
        let app = launch(["-NearbyScreen", "verify", "-NearbyFixtureCameraPermission", "denied"])
        XCTAssertTrue(app.buttons["verifyScanButton"].waitForExistence(timeout: 10))
        app.buttons["verifyScanButton"].tap()
        let state = app.staticTexts["verifyCameraState"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertTrue(state.label.contains("System Settings"), state.label)
        XCTAssertTrue(app.buttons["verifyCameraAction"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["verifyScanPrompt"].exists, "no scanner behind a blocked camera")
        app.buttons["verifyCameraClose"].firstMatch.tap()
        XCTAssertTrue(state.waitForNonExistence(timeout: 3))
        app.terminate()
    }

    func testAnsweringWithTheCameraOffOnTheMacGoesOnAsVoice() {
        let app = launch(["-NearbyScreen", "call-incoming", "-NearbyFixtureCameraPermission", "denied",
                          "-NearbyFixtureMicrophonePermission", "authorized"])
        let accept = app.buttons["Accept"].firstMatch
        XCTAssertTrue(accept.waitForExistence(timeout: 10))
        accept.click()
        let notice = app.staticTexts["callAccessNotice"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertEqual(notice.label, "Answered with voice: camera access is off")
        app.terminate()
    }

    func testRingWindowOffersBlockAndReportForARealKeyCaller() {
        var app = launch(["-NearbyScreen", "call-incoming", "-experimentalDesktopRingWindow", "YES"])
        XCTAssertTrue(app.buttons["Accept"].waitForExistence(timeout: 10))
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        let ring = app.descendants(matching: .any).matching(identifier: "desktop-ring-view").firstMatch
        XCTAssertTrue(ring.waitForExistence(timeout: 5))
        XCTAssertTrue(ring.buttons["Decline"].exists)
        XCTAssertTrue(ring.buttons["Voice"].exists)
        XCTAssertTrue(ring.buttons["Accept"].exists)
        XCTAssertTrue(ring.descendants(matching: .any)["declineAndBlock"].firstMatch.exists)
        XCTAssertTrue(ring.descendants(matching: .any)["declineAndReport"].firstMatch.exists)
        app.terminate()

        app = launch(["-NearbyScreen", "call-incoming-voice", "-experimentalDesktopRingWindow", "YES"])
        XCTAssertTrue(app.buttons["Accept"].waitForExistence(timeout: 10))
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        let voiceRing = app.descendants(matching: .any).matching(identifier: "desktop-ring-view").firstMatch
        XCTAssertTrue(voiceRing.waitForExistence(timeout: 5))
        XCTAssertTrue(voiceRing.buttons["Decline"].exists)
        XCTAssertFalse(voiceRing.descendants(matching: .any)["declineAndBlock"].firstMatch.exists)
        XCTAssertFalse(voiceRing.descendants(matching: .any)["declineAndReport"].firstMatch.exists)
        app.terminate()
    }
}
