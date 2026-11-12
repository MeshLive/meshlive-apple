import XCTest
import ImageIO

/// Store screenshots for the iPhone listing. They run only through `Scripts/store-screenshots.sh`, which sets
/// `NEARBY_STORE_SHOTS=1`, the expected pixel size and the output folder; a normal UI run skips every test.
final class StoreScreenshotTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-NearbyReadyStatus", "1"]
        app.launch()
        return app
    }

    /// Reads the PNG's own pixel size (never points times scale), fails on a different simulator, then writes
    /// `<NN>-<name>.png` under `NEARBY_SHOT_DIR` and keeps the same image as an attachment.
    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "store-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)

        if let expected = env["NEARBY_EXPECT_PIXELS"], !expected.isEmpty {
            guard let source = CGImageSourceCreateWithData(screenshot.pngRepresentation as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                XCTFail("could not read the screenshot size")
                return
            }
            let got = "\(image.width)x\(image.height)"
            guard got == expected else {
                XCTFail("wrong simulator: got \(got)")
                return
            }
        }

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
        capture("01-calls")
        app.terminate()
    }

    func testStoreScreenshot02Live() throws {
        guard ProcessInfo.processInfo.environment["NEARBY_STORE_SHOTS"] == "1" else {
            throw XCTSkip("store screenshots run only through Scripts/store-screenshots.sh")
        }
        let app = launch(["-NearbyFixture", "readme", "-NearbyScreen", "live"])
        XCTAssertTrue(app.staticTexts["Village meeting"].waitForExistence(timeout: 15))
        if app.buttons["Go live"].exists {
            throw XCTSkip("Go live is still shown: capture after the source gate (C1) has merged")
        }
        sleep(1)
        capture("02-live")
        app.terminate()
    }

    func testStoreScreenshot03IncomingCall() throws {
        guard ProcessInfo.processInfo.environment["NEARBY_STORE_SHOTS"] == "1" else {
            throw XCTSkip("store screenshots run only through Scripts/store-screenshots.sh")
        }
        let app = launch(["-NearbyFixture", "readme", "-NearbyScreen", "call-incoming"])
        XCTAssertTrue(app.buttons["Accept"].waitForExistence(timeout: 15))
        sleep(1)
        capture("03-incoming-call")
        app.terminate()
    }

    func testStoreScreenshot04InACall() throws {
        guard ProcessInfo.processInfo.environment["NEARBY_STORE_SHOTS"] == "1" else {
            throw XCTSkip("store screenshots run only through Scripts/store-screenshots.sh")
        }
        let app = launch(["-NearbyFixture", "readme", "-NearbyScreen", "call-active"])
        XCTAssertTrue(app.buttons["End"].waitForExistence(timeout: 15))
        sleep(1)
        capture("04-in-a-call")
        app.terminate()
    }

    func testStoreScreenshot05Contacts() throws {
        guard ProcessInfo.processInfo.environment["NEARBY_STORE_SHOTS"] == "1" else {
            throw XCTSkip("store screenshots run only through Scripts/store-screenshots.sh")
        }
        let app = launch(["-NearbyFixture", "populated", "-NearbyScreen", "contacts"])
        XCTAssertTrue(app.staticTexts["Asha"].waitForExistence(timeout: 15))
        sleep(1)
        capture("05-contacts")
        app.terminate()
    }

    func testStoreScreenshot06Privacy() throws {
        guard ProcessInfo.processInfo.environment["NEARBY_STORE_SHOTS"] == "1" else {
            throw XCTSkip("store screenshots run only through Scripts/store-screenshots.sh")
        }
        let app = launch(["-NearbyFixture", "readme", "-NearbyScreen", "privacy"])
        XCTAssertTrue(shown(app, "Triple-tap to delete everything").waitForExistence(timeout: 15))
        sleep(1)
        capture("06-privacy")
        app.terminate()
    }
}
