import XCTest

/// Store-release behaviour on the iPhone: the terms come before any permission prompt, Skip never passes them, the
/// permissions page has one Continue, a denial never blocks, and an existing user sees the terms once.
final class StoreReleaseTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ arguments: [String], fixture: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + (fixture ? ["-NearbyFixture", "populated"] : [])
        app.launch()
        return app
    }

    private func advanceToTerms(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["onboarding-title-0"].waitForExistence(timeout: 5))
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["onboarding-title-1"].waitForExistence(timeout: 5))
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["onboarding-title-2"].waitForExistence(timeout: 5))
    }

    func testAFreshInstallMustAgreeToTheTermsBeforeThePermissionsPage() {
        let app = launch(["-NearbyScreen", "onboarding"])
        advanceToTerms(app)
        XCTAssertTrue(app.buttons["terms-agree"].exists)
        XCTAssertFalse(app.buttons["Skip"].exists, "the terms page cannot be skipped")
        XCTAssertFalse(app.buttons["Not now"].exists)
        XCTAssertFalse(app.staticTexts["onboarding-title-3"].exists, "no permission page before agreeing")
        app.buttons["terms-agree"].tap()
        XCTAssertTrue(app.staticTexts["onboarding-title-3"].waitForExistence(timeout: 5))
        app.terminate()

        let skipped = launch(["-NearbyScreen", "onboarding"])
        XCTAssertTrue(skipped.staticTexts["onboarding-title-0"].waitForExistence(timeout: 5))
        skipped.buttons["Skip"].tap()
        XCTAssertTrue(skipped.staticTexts["onboarding-title-2"].waitForExistence(timeout: 5), "Skip lands on the terms")
        XCTAssertFalse(skipped.tabBars.buttons["Live"].exists, "and never leaves onboarding")
        skipped.terminate()
    }

    func testThePermissionsPageHasOneContinueAndNoSkipOrAllowButtons() {
        let app = launch(["-NearbyScreen", "onboarding"])
        advanceToTerms(app)
        app.buttons["terms-agree"].tap()
        XCTAssertTrue(app.staticTexts["onboarding-title-3"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["permissions-continue"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "permission-")).count, 0,
                       "no per-permission Allow buttons")
        XCTAssertFalse(app.buttons["Skip"].exists)
        XCTAssertFalse(app.buttons["Not now"].exists)
        XCTAssertFalse(app.buttons["Allow"].exists)
        app.terminate()
    }

    func testADeniedPermissionStillReachesTheReadyPage() {
        let app = launch(["-NearbyScreen", "onboarding"])
        advanceToTerms(app)
        app.buttons["terms-agree"].tap()
        XCTAssertTrue(app.staticTexts["onboarding-title-3"].waitForExistence(timeout: 5))
        addUIInterruptionMonitor(withDescription: "deny permissions") { alert in
            for label in ["Don’t Allow", "Don't Allow", "Don’t Allow While Using App", "Deny", "Cancel", "OK"] {
                if alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            }
            return false
        }
        app.buttons["permissions-continue"].tap()
        app.tap() // Let the interruption monitor answer any system prompt.
        XCTAssertTrue(app.staticTexts["onboarding-title-4"].waitForExistence(timeout: 15), "a denial never blocks the app")
        app.buttons["Start"].tap()
        XCTAssertTrue(app.tabBars.buttons["Live"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Live"].isSelected)
        app.terminate()
    }

    func testAnExistingUserSeesTheTermsOnceThenTheApp() {
        var app = launch(["-onboardingComplete", "YES", "-termsAcceptedVersion", "0"], fixture: false)
        XCTAssertTrue(app.staticTexts["onboarding-title-2"].waitForExistence(timeout: 8), "only the terms page")
        XCTAssertFalse(app.staticTexts["onboarding-title-0"].exists)
        app.buttons["terms-agree"].tap()
        XCTAssertTrue(app.tabBars.buttons["Live"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.tabBars.buttons["Live"].isSelected)
        app.terminate()

        app = launch(["-onboardingComplete", "YES"], fixture: false)
        XCTAssertTrue(app.tabBars.buttons["Live"].waitForExistence(timeout: 8), "the second launch goes straight to the app")
        XCTAssertFalse(app.staticTexts["onboarding-title-2"].exists)
        app.terminate()
    }

    func testACrashReportWaitsUntilTheTermsAreAgreed() {
        // Launch arguments shadow stored defaults for the whole run, so the app uses its in-run dismissed flag to
        // release the prompt after Agree. `-NearbyScreen terms` shows the terms page; the crash fixture would otherwise
        // be hidden by the scripted-run rule.
        let app = launch(["-onboardingComplete", "YES", "-termsAcceptedVersion", "0",
                          "-NearbyScreen", "terms", "-crashReports", "YES",
                          "-NearbyCrashReportFixture", "1"], fixture: false)
        XCTAssertTrue(app.staticTexts["onboarding-title-2"].waitForExistence(timeout: 8))
        let title = app.staticTexts["MeshLive closed unexpectedly"]
        XCTAssertFalse(title.exists, "the crash report waits for the terms")
        app.buttons["terms-agree"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 6), "the kept report appears after the terms are accepted")
        app.terminate()
    }

    func testAboutOffersPrivacyTermsAndLicencesAndTheStoreUpdateNote() {
        let app = launch(["-NearbyScreen", "about", "-NearbyDistribution", "appstore"])
        XCTAssertTrue(app.descendants(matching: .any)["about-privacy-policy"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["about-terms"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["about-licences"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Updates come from the App Store."))
            .firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.allElementsBoundByIndex.contains { $0.label.localizedCaseInsensitiveContains("GitHub") },
                       "an App Store build never shows the GitHub sentence")
        app.descendants(matching: .any)["about-licences"].firstMatch.tap()
        let libvpx = app.buttons["settings-link-libvpx"].firstMatch
        XCTAssertTrue(libvpx.waitForExistence(timeout: 5), "the licence page lists libvpx")
        libvpx.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "BSD")).firstMatch.waitForExistence(timeout: 5),
                      "libvpx's page names its BSD licence")
        app.terminate()
    }

    func testASourceBuildAboutKeepsTheGitHubUpdateNote() {
        let app = launch(["-NearbyScreen", "about", "-NearbyDistribution", "source"])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "GitHub")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.allElementsBoundByIndex.contains { $0.label.contains("Updates come from the App Store.") })
        app.terminate()
    }

    func testAboutTermsOpenInTheAppWithTheWebLinkSecondary() {
        let app = launch(["-NearbyScreen", "about"])
        let terms = app.descendants(matching: .any)["about-terms"].firstMatch
        XCTAssertTrue(terms.waitForExistence(timeout: 5))
        terms.tap()
        XCTAssertTrue(app.staticTexts["Before you start"].waitForExistence(timeout: 5), "the terms are readable in the app")
        XCTAssertTrue(app.staticTexts["You must be 18 or older."].exists)
        XCTAssertTrue(app.descendants(matching: .any)["terms-link-terms"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["terms-web-link"].firstMatch.exists, "the web page is a secondary link")
        app.terminate()
    }

    private func labels(_ app: XCUIApplication) -> [String] {
        app.staticTexts.allElementsBoundByIndex.map(\.label)
            + app.buttons.allElementsBoundByIndex.map(\.label)
            + app.switches.allElementsBoundByIndex.map(\.label)
    }

    func testSettingsHidesRelayVideoForOthersByDefaultAndShowsItWithTheGate() {
        let relay = NSPredicate(format: "label BEGINSWITH 'Relay video for others'")
        let hidden = launch(["-NearbyScreen", "settings"])
        XCTAssertTrue(hidden.switches["Allow calls"].waitForExistence(timeout: 8))
        XCTAssertFalse(hidden.switches.matching(relay).firstMatch.exists, "the relay row is off by default")
        hidden.terminate()

        let shown = launch(["-NearbyScreen", "settings", "-appleSourceRoles", "YES"])
        XCTAssertTrue(shown.switches.matching(relay).firstMatch.waitForExistence(timeout: 8), "the source-roles gate shows the row")
        shown.terminate()
    }

    func testExperimentsShowsOnlyTheReleaseRowsAndNoBeta() {
        let app = launch(["-NearbyScreen", "experiments"])
        XCTAssertTrue(app.switches["Relayed calls"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.switches["Relay: slow viewers skip to keyframes"].exists, "hidden with the relay gate")
        XCTAssertFalse(labels(app).contains { $0.localizedCaseInsensitiveContains("beta") })
        app.terminate()
    }

    func testTheConnectionPageHasNoWiFiSectionByDefault() {
        let app = launch(["-NearbyScreen", "connection"])
        XCTAssertTrue(app.staticTexts["Bluetooth transport"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Wi-Fi"].exists, "the Wi-Fi experiment is off in this build")
        app.terminate()
    }

    func testNoBetaWordOnAnyPage() {
        for screen in ["settings", "privacy", "experiments", "connection", "about", "help", "video", "manual",
                       "licences", "terms", "onboarding"] {
            let app = launch(["-NearbyScreen", screen])
            XCTAssertTrue(app.staticTexts.firstMatch.waitForExistence(timeout: 8), screen)
            if screen == "onboarding" {
                for page in 0..<5 {
                    XCTAssertTrue(app.staticTexts["onboarding-title-\(page)"].waitForExistence(timeout: 8),
                                  "\(screen) page \(page)")
                    XCTAssertFalse(labels(app).contains { $0.localizedCaseInsensitiveContains("beta") },
                                   "\(screen) page \(page)")
                    switch page {
                    case 0, 1: app.buttons["Next"].tap()
                    case 2: app.buttons["terms-agree"].tap()
                    case 3: app.buttons["permissions-continue"].tap()
                    default: break
                    }
                }
            } else {
                XCTAssertFalse(labels(app).contains { $0.localizedCaseInsensitiveContains("beta") }, screen)
            }
            app.terminate()
        }
    }
}
