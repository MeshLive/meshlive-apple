import XCTest

/// Store-release behaviour on the Mac: the terms page stands between onboarding and the app, with no way around it.
final class StoreReleaseTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-desktopContentSize", "100", "-NearbyPreview", "-ApplePersistenceIgnoreState", "YES",
                               "-NearbyFixture", "populated"] + arguments
        app.launch()
        return app
    }

    func testTermsCannotBeSkippedBeforeTheApp() {
        let app = launch(["-NearbyScreen", "onboarding"])
        XCTAssertTrue(app.staticTexts["onboarding-title-0"].waitForExistence(timeout: 5))
        app.buttons["Next"].click()
        XCTAssertTrue(app.staticTexts["onboarding-title-1"].waitForExistence(timeout: 5))
        app.buttons["Next"].click()
        XCTAssertTrue(app.staticTexts["onboarding-title-2"].waitForExistence(timeout: 5), "the terms page")
        XCTAssertFalse(app.buttons["Skip"].exists, "no Skip on the terms page")
        XCTAssertFalse(app.buttons["Not now"].exists)
        XCTAssertFalse(app.buttons["desktop-tab-live"].exists, "the app is not open yet")
        XCTAssertTrue(app.buttons["terms-agree"].exists)
        app.buttons["terms-agree"].click()
        XCTAssertTrue(app.staticTexts["onboarding-title-3"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testAboutShowsTheLegalRowsAndTheStoreUpdateNote() {
        let app = launch(["-NearbyScreen", "about", "-NearbyDistribution", "appstore"])
        XCTAssertTrue(app.descendants(matching: .any)["about-privacy-policy"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["about-terms"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["about-licences"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                                          "Updates come from the App Store.",
                                                          "Updates come from the App Store."))
            .firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.allElementsBoundByIndex.contains {
            $0.label.localizedCaseInsensitiveContains("GitHub")
                || (($0.value as? String) ?? "").localizedCaseInsensitiveContains("GitHub")
        })
        app.descendants(matching: .any)["about-licences"].firstMatch.click()
        let libvpx = app.buttons["settings-link-libvpx"].firstMatch
        XCTAssertTrue(libvpx.waitForExistence(timeout: 5), "the licence page lists libvpx")
        libvpx.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "BSD", "BSD"))
            .firstMatch.waitForExistence(timeout: 5), "libvpx's page names its BSD licence")
        app.terminate()
    }

    func testAboutTermsOpenInTheApp() {
        let app = launch(["-NearbyScreen", "about"])
        let terms = app.descendants(matching: .any)["about-terms"].firstMatch
        XCTAssertTrue(terms.waitForExistence(timeout: 5))
        terms.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                                          "Before you start", "Before you start"))
            .firstMatch.waitForExistence(timeout: 5), "the terms are readable in the app")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                                          "You must be 18 or older.", "You must be 18 or older."))
            .firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["terms-web-link"].firstMatch.exists, "the web page is a secondary link")
        app.terminate()
    }

    func testMacExperimentsShowTheDesktopRowsInDebugAndNoBeta() {
        let app = launch(["-NearbyScreen", "experiments"])
        XCTAssertTrue(app.checkBoxes["desktop-call-delivery-feedback"].waitForExistence(timeout: 5),
                      "DEBUG shows the Mac-only experiments")
        XCTAssertTrue(app.checkBoxes["desktop-pause-call-discovery"].exists)
        let labels = app.staticTexts.allElementsBoundByIndex.map(\.label)
            + app.staticTexts.allElementsBoundByIndex.compactMap { $0.value as? String }
            + app.buttons.allElementsBoundByIndex.map(\.label)
            + app.checkBoxes.allElementsBoundByIndex.map(\.label)
        XCTAssertFalse(labels.contains { $0.localizedCaseInsensitiveContains("beta") })
        app.terminate()
    }
}
