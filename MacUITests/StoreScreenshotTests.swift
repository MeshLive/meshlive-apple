import XCTest

/// Store screenshots for the Mac listing. They run only through `Scripts/store-screenshots.sh`, which sets
/// `NEARBY_STORE_SHOTS=1` and the output folder; a normal UI run skips every test. The window is centred on a black
/// canvas later by the normaliser.
final class StoreScreenshotTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-desktopContentSize", "100", "-NearbyPreview", "-ApplePersistenceIgnoreState", "YES"]
            + arguments + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-NearbyReadyStatus", "1"]
        app.launch()
        return app
    }

    /// Writes the window PNG as `<NN>-<name>.png` under `NEARBY_SHOT_DIR` and keeps it as an attachment.
    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "store-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let dir = env["NEARBY_SHOT_DIR"], !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    /// Any element whose label contains `text`, ignoring case: fixture names show in title case, and a toggle row's title
    /// is the switch's label rather than a separate text.
    private func shown(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    func testStoreScreenshot01Calls() throws {
        guard ProcessInfo.processInfo.environment["NEARBY_STORE_SHOTS"] == "1" else {
            throw XCTSkip("store screenshots run only through Scripts/store-screenshots.sh")
        }
        let app = launch(["-NearbyFixture", "readme", "-NearbyScreen", "people"])
        XCTAssertTrue(shown(app, "artsy cascade").waitForExistence(timeout: 15))
        sleep(1)
        capture(app, "01-calls")
        app.terminate()
    }

    func testStoreScreenshot02Live() throws {
        guard ProcessInfo.processInfo.environment["NEARBY_STORE_SHOTS"] == "1" else {
            throw XCTSkip("store screenshots run only through Scripts/store-screenshots.sh")
        }
        let app = launch(["-NearbyFixture", "readme", "-NearbyScreen", "live"])
        XCTAssertTrue(shown(app, "Village meeting").waitForExistence(timeout: 15))
        if app.buttons["Go live"].exists {
            throw XCTSkip("Go live is still shown: capture after the source gate (C1) has merged")
        }
        sleep(1)
        capture(app, "02-live")
        app.terminate()
    }

    func testStoreScreenshot03Contacts() throws {
        guard ProcessInfo.processInfo.environment["NEARBY_STORE_SHOTS"] == "1" else {
            throw XCTSkip("store screenshots run only through Scripts/store-screenshots.sh")
        }
        let app = launch(["-NearbyFixture", "populated", "-NearbyScreen", "contacts"])
        XCTAssertTrue(shown(app, "Asha").waitForExistence(timeout: 15))
        sleep(1)
        capture(app, "03-contacts")
        app.terminate()
    }

    func testStoreScreenshot04Privacy() throws {
        guard ProcessInfo.processInfo.environment["NEARBY_STORE_SHOTS"] == "1" else {
            throw XCTSkip("store screenshots run only through Scripts/store-screenshots.sh")
        }
        let app = launch(["-NearbyFixture", "readme", "-NearbyScreen", "privacy"])
        XCTAssertTrue(shown(app, "Triple-tap to delete everything").waitForExistence(timeout: 15))
        sleep(1)
        capture(app, "04-privacy")
        app.terminate()
    }
}
