import XCTest

/// B1: the scanner explains every camera permission state, and a call answered or placed with media refused says what is
/// missing (compiled only; the reviewer runs these on a simulator).
final class B1CallsTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() { continueAfterFailure = true }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        var args = arguments + ["-NearbyFixture", "populated"]
        if let size = env["NEARBY_CONTENT_SIZE"], !size.isEmpty { args += ["-UIPreferredContentSizeCategoryName", size] }
        if env["NEARBY_RTL"] == "1" { args += ["-AppleTextDirection", "YES", "-NSForceRightToLeftWritingDirection", "YES"] }
        app.launchArguments = args
        app.launch()
        return app
    }

    func testTheScannerExplainsEachCameraPermissionState() {
        var app = launch(["-NearbyScreen", "verify", "-NearbyFixtureCameraPermission", "denied"])
        XCTAssertTrue(app.buttons["verifyScanButton"].waitForExistence(timeout: 5))
        app.buttons["verifyScanButton"].tap()
        var state = app.staticTexts["verifyCameraState"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertTrue(state.label.contains("Camera access is off"), state.label)
        XCTAssertTrue(app.buttons["verifyCameraAction"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["verifyScanPrompt"].exists, "no scanner behind a blocked camera")
        app.buttons["verifyCameraClose"].firstMatch.tap()
        XCTAssertTrue(state.waitForNonExistence(timeout: 3))
        app.terminate()

        app = launch(["-NearbyScreen", "verify", "-NearbyFixtureCameraPermission", "restricted"])
        XCTAssertTrue(app.buttons["verifyScanButton"].waitForExistence(timeout: 5))
        app.buttons["verifyScanButton"].tap()
        state = app.staticTexts["verifyCameraState"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertTrue(state.label.contains("restricted"), state.label)
        XCTAssertFalse(app.buttons["verifyCameraAction"].exists, "Settings cannot lift a restriction")
        XCTAssertFalse(app.staticTexts["verifyScanPrompt"].exists)
        app.buttons["verifyCameraClose"].firstMatch.tap()
        XCTAssertTrue(state.waitForNonExistence(timeout: 3))
        app.terminate()

        app = launch(["-NearbyScreen", "verify", "-NearbyFixtureCameraPermission", "notDetermined"])
        XCTAssertTrue(app.buttons["verifyScanButton"].waitForExistence(timeout: 5))
        app.buttons["verifyScanButton"].tap()
        state = app.staticTexts["verifyCameraState"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertTrue(state.label.contains("needs the camera"), state.label)
        XCTAssertFalse(app.buttons["verifyCameraAction"].exists, "the app can ask again; no Settings")
        XCTAssertFalse(app.staticTexts["verifyScanPrompt"].exists)
        app.buttons["verifyCameraClose"].firstMatch.tap()
        XCTAssertTrue(state.waitForNonExistence(timeout: 3))
        app.terminate()
    }

    func testAnsweringAVideoCallWithTheCameraOffGoesOnAsVoice() {
        let app = launch(["-NearbyScreen", "call-incoming", "-NearbyFixtureCameraPermission", "denied",
                          "-NearbyFixtureMicrophonePermission", "authorized"])
        let accept = app.buttons["Accept"].firstMatch
        XCTAssertTrue(accept.waitForExistence(timeout: 5))
        accept.tap()
        let notice = app.staticTexts["callAccessNotice"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertEqual(notice.label, "Answered with voice: camera access is off")
        XCTAssertFalse(app.buttons["callAccessSettings"].exists, "nothing to open: the call went on")
        app.terminate()
    }

    func testAnsweringWithTheMicrophoneOffExplainsAndOffersSettings() {
        let app = launch(["-NearbyScreen", "call-incoming", "-NearbyFixtureCameraPermission", "authorized",
                          "-NearbyFixtureMicrophonePermission", "denied"])
        let accept = app.buttons["Accept"].firstMatch
        XCTAssertTrue(accept.waitForExistence(timeout: 5))
        accept.tap()
        let notice = app.staticTexts["callAccessNotice"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(notice.label.contains("the microphone"), notice.label)
        XCTAssertTrue(app.buttons["callAccessSettings"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Accept"].exists, "a refused microphone does not answer")
        app.terminate()
    }
}
