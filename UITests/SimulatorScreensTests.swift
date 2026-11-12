import XCTest
import UIKit

/// Simulator UI checks (no Bluetooth): every screen reachable through the DEBUG aids `-NearbyScreen` and
/// `-NearbyFixture populated`, with a screenshot each, the system accessibility audit, the design rules that
/// can be read from the accessibility tree, settings persistence, rotation and background/terminate cycles.
/// Run with `SIMULATOR=<udid> bash Scripts/run-uitest.sh screens`. Optional `TEST_RUNNER_NEARBY_CONTENT_SIZE`
/// (a UIContentSizeCategory name such as UICTContentSizeCategoryAccessibilityXXXL) and `TEST_RUNNER_NEARBY_RTL=1`.
final class SimulatorScreensTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() { continueAfterFailure = true }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        var args = arguments + ["-NearbyFixture", "populated"]
        if !args.contains("-appleSourceRoles") { args += ["-appleSourceRoles", "YES"] }
        if let size = env["NEARBY_CONTENT_SIZE"], !size.isEmpty { args += ["-UIPreferredContentSizeCategoryName", size] }
        if env["NEARBY_RTL"] == "1" { args += ["-AppleTextDirection", "YES", "-NSForceRightToLeftWritingDirection", "YES"] }
        app.launchArguments = args
        app.launch()
        return app
    }

    private var suffix: String {
        var parts: [String] = []
        if let size = env["NEARBY_CONTENT_SIZE"], !size.isEmpty { parts.append(size.replacingOccurrences(of: "UICTContentSizeCategory", with: "")) }
        if env["NEARBY_RTL"] == "1" { parts.append("rtl") }
        return parts.isEmpty ? "" : "-" + parts.joined(separator: "-")
    }

    /// Simulator only: the runner shares the Mac's file system, so screenshots and notes are also written to
    /// NEARBY_SHOT_DIR (the result bundle can be lost when xcodebuild hangs after the run).
    private func save(_ data: Data, _ file: String) {
        guard let dir = env["NEARBY_SHOT_DIR"], !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name + suffix; attachment.lifetime = .keepAlways
        add(attachment)
        save(screenshot.pngRepresentation, name + suffix + ".png")
    }

    private func note(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name + suffix; attachment.lifetime = .keepAlways
        add(attachment)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        save(Data(text.utf8), base + suffix + (ext.isEmpty ? "" : "." + ext))
    }

    /// Runs the system audit and records every issue as a named failure plus a text attachment (kept visible).
    private func audit(_ app: XCUIApplication, _ screen: String) {
        guard #available(iOS 17.0, *) else { return }
        var issues: [String] = [], warnings: [String] = []
        // iOS 26+ floats a translucent tab bar over the scrolling page, with a soft scroll-edge fade about 44 pt above
        // it: rows passing under them are not a real contrast fault.
        let tabBarTop = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY - 44 : .greatestFiniteMagnitude
        // WCAG 1.4.3 exempts inactive controls from the contrast minimum: in a voice call Flip is disabled and drawn dim
        // on purpose (as on Android). The audit reports its text as an unnamed node, so an unnamed contrast finding on a
        // call screen whose Flip is disabled is a warning (the audit file still lists it).
        let flip = app.buttons["callFlip"]
        let flipInactive = screen.hasPrefix("call") && flip.exists && !flip.isEnabled
        do {
            try app.performAccessibilityAudit { issue in
                let line = "\(issue.compactDescription) | \(issue.element?.label ?? "-") | \(issue.element.map { "\($0.elementType.rawValue) \($0.frame)" } ?? "-") | \(issue.detailedDescription)"
                // Dynamic Type and clipping findings are warnings: the audit reports grouped-list headers/footers and
                // fixed-size avatar discs as "partially unsupported" and single-line rows as "clipped" at the default size.
                // They are checked visually in the accessibility-size screenshots instead.
                let underTabBar = issue.auditType == .contrast && (issue.element?.frame.maxY ?? 0) > tabBarTop
                // An AssistiveTouch button floats over the lower right of the call screens on the lab iPhone (screenshots: it sits on Accept / the
                // speaker label; the element is not named): the audit measures text under that translucent disc, so an unnamed contrast
                // finding on a call screen is a warning on a device.
                var onDevice = true
                #if targetEnvironment(simulator)
                onDevice = false
                #endif
                let underFloatingButton = issue.auditType == .contrast && issue.element == nil && onDevice && screen.hasPrefix("call")
                let inactiveFlip = issue.auditType == .contrast && issue.element == nil && flipInactive
                if issue.auditType == .dynamicType || issue.auditType == .textClipped || underTabBar || underFloatingButton || inactiveFlip { warnings.append(line) } else { issues.append(line) }
                return true // handled: recorded here
            }
        } catch { issues.append("audit error: \(error)") }
        note("audit-\(screen).txt", (issues.map { "FAIL " + $0 } + warnings.map { "WARN " + $0 }).joined(separator: "\n").ifEmpty("no issues"))
        if !issues.isEmpty { XCTFail("Accessibility audit, \(screen): \(issues.count) issue(s): \(issues.joined(separator: " || "))") }
    }

    /// Scrolls (up to five swipes) until `element` exists and is hittable: large text sizes push rows off screen.
    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 5) -> Bool {
        if element.waitForExistence(timeout: timeout) && element.isHittable { return true }
        for _ in 0..<8 {
            app.swipeUp()
            if element.exists && element.isHittable { return true }
        }
        return element.exists
    }

    /// Closes a sheet and waits until `marker` (an element only the sheet has) is gone. A swipe from the middle is not always
    /// enough on a real iPhone (the sheet stays up and covers the page behind it), so a second drag and a tap on the dimmed area follow.
    private func dismissSheet(_ app: XCUIApplication, marker: String) {
        let element = app.descendants(matching: .any)[marker].firstMatch
        let steps: [() -> Void] = [
            { app.swipeDown() },
            { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap() },
            { app.swipeDown(velocity: .fast) },
        ]
        for step in steps {
            step()
            let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
            if XCTWaiter().wait(for: [gone], timeout: 3) == .completed { return }
        }
        XCTFail("the sheet with \(marker) did not close")
    }

    /// A partially visible button can be hittable. Require the full control to fit in the window.
    private func revealFully(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.waitForExistence(timeout: 5) else { return false }
        let visible = app.frame
        for _ in 0..<8 {
            let frame = element.frame
            if element.isHittable, visible.contains(frame) { return true }
            if frame.minY < visible.minY { app.swipeDown() } else { app.swipeUp() }
        }
        return element.isHittable && visible.contains(element.frame)
    }

    /// Every interactive element needs a non-empty label for VoiceOver.
    private func checkLabels(_ app: XCUIApplication, _ screen: String) {
        let unlabeled = app.buttons.allElementsBoundByIndex.filter { $0.exists && $0.isHittable && $0.label.trimmingCharacters(in: .whitespaces).isEmpty }
        if !unlabeled.isEmpty { XCTFail("\(screen): \(unlabeled.count) button(s) without a VoiceOver label at \(unlabeled.map { "\($0.frame)" })") }
    }

    private let screens: [(name: String, args: [String], expect: String)] = [
        ("home", [], "Go live"),
        ("people", ["-NearbyScreen", "people"], "Nearby"),
        ("watch", ["-NearbyScreen", "live"], "Live nearby"),
        ("contacts", ["-NearbyScreen", "contacts"], "Add contact"),
        ("settings", ["-NearbyScreen", "settings"], "Settings"),
        ("privacy", ["-NearbyScreen", "privacy"], "Triple-tap to delete everything"),
        ("experiments", ["-NearbyScreen", "experiments", "-manualVideo", "YES"], "Relayed calls"),
        ("verify", ["-NearbyScreen", "verify"], "Scan their code"),
        ("live", ["-NearbyScreen", "live"], "Go live"),
        ("call-outgoing", ["-NearbyScreen", "call"], "Cancel"),
        ("call-incoming-video", ["-NearbyScreen", "call-incoming"], "Accept"),
        ("call-incoming-voice", ["-NearbyScreen", "call-incoming-voice"], "Accept"),
        ("call-active", ["-NearbyScreen", "call-active"], "End"),
        ("call-mismatch", ["-NearbyScreen", "call-mismatch"], "This contact's ID has changed"),
        ("call-ended", ["-NearbyScreen", "call-ended"], "Call ended"),
    ]


    func testAccessibilityLargeTextControls() {
        let size = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        var app = launch(["-NearbyScreen", "golive"] + size)
        XCTAssertTrue(app.buttons["Video and audio"].waitForExistence(timeout: 5))
        shot("large-text-go-live-top")
        for title in ["Video and audio", "Audio only"] {
            let button = app.buttons[title]
            XCTAssertTrue(revealFully(button, in: app), "\(title) remains reachable at the largest text size")
            XCTAssertTrue(button.isHittable, "\(title) is visible and tappable")
        }
        app.swipeUp()
        shot("large-text-go-live")
        checkLabels(app, "large-text-go-live")
        app.terminate()

        app = launch(["-NearbyScreen", "radio"] + size)
        XCTAssertTrue(revealFully(app.buttons["Stop"], in: app))
        XCTAssertTrue(app.buttons["Stop"].isHittable)
        shot("large-text-radio")
        checkLabels(app, "large-text-radio")
        app.terminate()

        app = launch(["-NearbyScreen", "call-incoming"] + size)
        for title in ["Decline", "Voice", "Accept"] {
            XCTAssertTrue(revealFully(app.buttons[title], in: app), "\(title): frame \(app.buttons[title].frame), window \(app.frame)")
            XCTAssertTrue(app.buttons[title].isHittable)
            let frame = app.buttons[title].frame
            XCTAssertGreaterThanOrEqual(frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(frame.maxX, app.frame.maxX)
        }
        shot("large-text-incoming-call")
        app.terminate()

        app = launch(["-NearbyScreen", "broadcast-radio"] + size)
        XCTAssertTrue(app.buttons["Mute"].waitForExistence(timeout: 5))
        shot("large-text-broadcast-top")
        for title in ["Mute", "Pause", "End"] {
            XCTAssertTrue(revealFully(app.buttons[title], in: app), "\(title): frame \(app.buttons[title].frame), window \(app.frame)")
            XCTAssertTrue(app.buttons[title].isHittable)
        }
        shot("large-text-broadcast-controls")
        checkLabels(app, "large-text-broadcast")
        app.terminate()

        app = launch(["-NearbyScreen", "broadcast-radio-setup", "-audioLiveDisclosed", "YES"] + size)
        for title in ["Voice", "Low data", "Music", "Start"] {
            XCTAssertTrue(revealFully(app.buttons[title], in: app), "\(title) remains reachable at the largest text size")
            XCTAssertTrue(app.buttons[title].isHittable)
        }
        shot("large-text-radio-setup")
        app.terminate()

        app = launch(["-NearbyScreen", "contacts"] + size)
        XCTAssertTrue(app.buttons["Contact info Asha"].waitForExistence(timeout: 5))
        for title in ["Video call Asha", "Voice call Asha", "Contact info Asha"] {
            XCTAssertTrue(revealFully(app.buttons[title], in: app), "\(title): frame \(app.buttons[title].frame), window \(app.frame)")
        }
        shot("large-text-contacts")
        checkLabels(app, "large-text-contacts")
        app.terminate()
    }

    func testEveryScreen() {
        for screen in screens {
            let app = launch(screen.args)
            let expected = screen.expect
            let predicate = NSPredicate(format: "label CONTAINS[c] %@", expected)
            _ = app.staticTexts.matching(predicate).firstMatch.waitForExistence(timeout: 8)
            let found = app.staticTexts.matching(predicate).firstMatch.exists || app.buttons.matching(predicate).firstMatch.exists
                || app.navigationBars[expected].exists || reveal(app.staticTexts.matching(predicate).firstMatch, in: app, timeout: 1)
            if !found { XCTFail("\(screen.name): expected '\(expected)' on screen") }
            sleep(1)
            shot("screen-\(screen.name)")
            checkLabels(app, screen.name)
            audit(app, screen.name)
            app.terminate()
        }
    }

    /// The populated fixture shows the rows (people, streams, recent calls) with readable VoiceOver labels.
    func testPopulatedLists() {
        let app = launch(["-NearbyScreen", "people"])
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'person-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 8), "person rows")
        // Collect while scrolling: large text sizes push rows off screen.
        var seen: [String] = []
        for _ in 0..<6 {
            for label in rows.allElementsBoundByIndex.map(\.label) where !seen.contains(label) {
                seen.append(label)
            }
            if seen.count >= 3 { break }
            app.swipeUp()
        }
        let people = seen
        note("people-labels.txt", people.joined(separator: "\n"))
        XCTAssertEqual(people.count, 3, "three fixture people (present in the tree even when scrolled off)")
        shot("list-people")
        app.buttons["Recent"].firstMatch.tap()
        // The row combines its children for VoiceOver, so the call-back action can surface on the row element itself.
        XCTAssertTrue(reveal(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'recent-'")).firstMatch, in: app, timeout: 8),
                      "recent call rows")
        shot("list-recent")
        app.terminate()
        let watchApp = launch(["-NearbyScreen", "live"])
        XCTAssertTrue(watchApp.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Live from'")).firstMatch.waitForExistence(timeout: 5), "stream rows")
        XCTAssertTrue(watchApp.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'paused'")).firstMatch.exists, "paused stream detail")
        shot("list-watch")
    }

    /// Live rows expose their kind, retain the full title and keep the empty state truthful.
    func testLiveRowsAndEmptyState() {
        var app = launch(["-NearbyScreen", "live"])
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'stream-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.allElementsBoundByIndex.filter { ($0.value as? String) == "Video stream" }.count, 2)
        XCTAssertEqual(rows.allElementsBoundByIndex.filter { ($0.value as? String) == "Audio only stream" }.count, 1)
        XCTAssertTrue(app.staticTexts["Neighbourhood radio, ward 12 updates"].exists)
        XCTAssertFalse(app.staticTexts["LIVE"].exists)
        shot("live-kinds")
        app.terminate()
        app = launch(["-NearbyScreen", "live", "-NearbyFixture", "empty"])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'No one is live nearby'")).firstMatch.waitForExistence(timeout: 5))
        shot("live-empty")
    }

    func testCallsSkipSubject() {
        let app = launch(["-NearbyScreen", "people", "-NearbyLabels", "1"])
        XCTAssertTrue(app.buttons["Nearby"].exists)
        XCTAssertTrue(app.buttons["Recent"].exists)
        XCTAssertFalse(app.textFields["Subject (optional)"].exists)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'person-'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Voice call"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["Video call"].exists)
        XCTAssertFalse(app.textFields["Subject (optional)"].exists)
        shot("call-choice")
        app.terminate()
    }

    func testContactNotNearbyExplainsAndOpensNearby() {
        let app = launch(["-NearbyScreen", "contacts", "-NearbyFixtureReach", "recognisable"])
        XCTAssertTrue(app.buttons["Voice call Asha"].waitForExistence(timeout: 4))
        app.buttons["Voice call Asha"].tap()
        let dialog = app.alerts["Asha is not found nearby yet"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 4))
        XCTAssertTrue(app.tabBars.buttons["Contacts"].isSelected)
        shot("contact-not-nearby")
        dialog.buttons["Cancel"].tap()
        XCTAssertTrue(app.tabBars.buttons["Contacts"].isSelected)
        app.buttons["Video call Asha"].tap()
        XCTAssertTrue(dialog.waitForExistence(timeout: 4))
        dialog.buttons["Open Nearby"].tap()
        XCTAssertTrue(app.tabBars.buttons["Calls"].isSelected)
        XCTAssertTrue(app.buttons["Nearby"].isSelected)
        shot("contact-open-nearby")
    }

    func testOnboardingWalkthroughAndPersistence() {
        var app = launch(["-NearbyScreen", "onboarding"])
        addUIInterruptionMonitor(withDescription: "onboarding permissions") { alert in
            for label in ["Allow", "OK", "Allow While Using App", "Allow Once"] {
                if alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            }
            return false
        }
        XCTAssertTrue(app.staticTexts["onboarding-title-0"].waitForExistence(timeout: 4))
        shot("onboarding-welcome")
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["onboarding-title-1"].exists)
        shot("onboarding-capabilities")
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["onboarding-title-2"].exists)
        XCTAssertTrue(app.buttons["terms-agree"].exists, "the terms page sits between What you can do and the permissions page")
        shot("onboarding-terms")
        app.buttons["terms-agree"].tap()
        XCTAssertTrue(app.staticTexts["onboarding-title-3"].exists)
        XCTAssertTrue(app.staticTexts["Bluetooth"].exists)
        XCTAssertTrue(reveal(app.staticTexts["Notifications"], in: app))
        XCTAssertFalse(app.staticTexts["Camera"].exists, "the camera is asked at the first video use")
        shot("onboarding-permissions")
        app.buttons["permissions-continue"].tap()
        app.tap() // Let the interruption monitor answer any system prompt.
        XCTAssertTrue(app.staticTexts["onboarding-title-4"].waitForExistence(timeout: 10), "the ready page follows the prompts")
        XCTAssertGreaterThanOrEqual(app.staticTexts["onboarding-title-4"].frame.minY, app.frame.minY)
        sleep(1) // Let the native button label transition finish before capturing.
        shot("onboarding-ready")
        app.buttons["Start"].tap()
        XCTAssertTrue(app.tabBars.buttons["Live"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Live"].isSelected)
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-appleSourceRoles", "YES"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Live"].waitForExistence(timeout: 5), "completion survives a normal relaunch")
        XCTAssertFalse(app.staticTexts["onboarding-title-0"].exists)
    }

    /// Android call readiness permissions: only the control arm lists the camera on the permissions page.
    func testOnboardingCameraRowOnlyInTheControlArm() {
        let app = launch(["-NearbyScreen", "onboarding", "-callReadinessPermissions", "NO"])
        XCTAssertTrue(app.staticTexts["onboarding-title-0"].waitForExistence(timeout: 4))
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["onboarding-title-1"].waitForExistence(timeout: 4))
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["onboarding-title-2"].waitForExistence(timeout: 4))
        app.buttons["terms-agree"].tap()
        XCTAssertTrue(app.staticTexts["onboarding-title-3"].waitForExistence(timeout: 4))
        XCTAssertTrue(reveal(app.staticTexts["Camera"], in: app), "control arm: the camera row is back")
        XCTAssertFalse(app.buttons["Allow Camera"].exists, "the permissions page has no per-permission buttons")
        app.terminate()
    }

    func testSettingsInfoBuildAndTypedWipe() {
        var app = launch(["-NearbyScreen", "settings"])
        let info = app.buttons["About Allow calls"]
        XCTAssertTrue(info.waitForExistence(timeout: 4))
        info.tap()
        XCTAssertTrue(app.alerts["Allow calls"].waitForExistence(timeout: 4))
        shot("settings-explanation")
        app.alerts.buttons["OK"].tap()
        let about = app.buttons["About this app"].firstMatch
        XCTAssertTrue(reveal(about, in: app))
        about.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Version'")).firstMatch.waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Source'")).firstMatch.exists)
        shot("about-build")
        app.terminate()
        app = launch(["-NearbyScreen", "settings"])
        let wipe = app.buttons["Delete everything"]
        XCTAssertTrue(reveal(wipe, in: app))
        wipe.tap()
        let dialog = app.alerts["Delete everything?"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 4))
        let erase = dialog.buttons["Delete everything"]
        XCTAssertFalse(erase.isEnabled)
        dialog.textFields.firstMatch.tap()
        dialog.textFields.firstMatch.typeText("DELETEX")
        XCTAssertFalse(erase.isEnabled)
        dialog.textFields.firstMatch.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(erase.isEnabled)
        shot("wipe-typed-confirmation")
        dialog.buttons["Cancel"].tap()
        XCTAssertTrue(app.tabBars.buttons["Settings"].isSelected)
    }

    /// A Settings switch can be flipped and survives a terminate/relaunch.
    func testSettingsAdvancedPersist() {
        var app = launch(["-NearbyScreen", "settings", "-appleSourceRoles", "YES"])
        let relay = NSPredicate(format: "label BEGINSWITH 'Relay video for others'")
        let toggle = app.switches.matching(relay).firstMatch
        XCTAssertTrue(reveal(toggle, in: app, timeout: 3), "relay toggle")
        let before = toggle.value as? String
        shot("settings-advanced")
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        let after = toggle.value as? String
        XCTAssertNotEqual(before, after, "toggle changed")
        let toggles = app.switches.allElementsBoundByIndex.map { "\($0.label) = \($0.value ?? "-")" }
        note("settings-toggles.txt", toggles.joined(separator: "\n"))
        app.terminate()
        app = launch(["-NearbyScreen", "settings", "-appleSourceRoles", "YES"])
        let again = app.switches.matching(relay).firstMatch
        reveal(again, in: app, timeout: 3)
        XCTAssertEqual(again.value as? String, after, "toggle persisted across relaunch")
        // Restore.
        again.switches.firstMatch.exists ? again.switches.firstMatch.tap() : again.tap()
        app.terminate()
    }

    /// Help and feedback > Export diagnostics shows the exact text; it names no contact and no ID from the fixture.
    func testExportDiagnosticsShowsATextWithoutNamesOrIDs() {
        let app = launch(["-NearbyScreen", "help"])
        let export = app.buttons["exportDiagnostics"].firstMatch
        XCTAssertTrue(reveal(export, in: app, timeout: 8))
        XCTAssertFalse(app.buttons["reportBug"].exists, "Report a bug is hidden as on Android")
        export.tap()
        let text = app.descendants(matching: .any).matching(identifier: "diagnostics-text").firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        let shown = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'app_version'")).firstMatch
        XCTAssertTrue(shown.waitForExistence(timeout: 5))
        for leaked in ["Asha", "a1b2c3d4e5f6", "0102030405a8", "112233445566"] {
            XCTAssertFalse(shown.label.contains(leaked), leaked)
        }
        XCTAssertTrue(app.buttons["Share"].exists)
        shot("export-diagnostics")
        app.buttons["Done"].tap()
        app.terminate()
    }

    /// Show names on lock screen is off by default and keeps the choice.
    func testShowNamesOnLockScreenIsOffByDefault() {
        var app = launch(["-NearbyScreen", "privacy"])
        let toggle = app.switches["lockScreenNames"].firstMatch
        XCTAssertTrue(reveal(toggle, in: app, timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0", "off by default")
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        app.terminate()
        app = launch(["-NearbyScreen", "privacy"])
        let again = app.switches["lockScreenNames"].firstMatch
        XCTAssertTrue(reveal(again, in: app, timeout: 5))
        XCTAssertEqual(again.value as? String, "1", "the choice is kept")
        again.switches.firstMatch.exists ? again.switches.firstMatch.tap() : again.tap()
        app.terminate()
    }

    /// Settings › Video quality opens from its row with Android's defaults (fill and heat limit on, temperature and
    /// the freeze warning off), and a choice is kept.
    func testVideoQualityHasAndroidsDefaultsAndKeepsAChoice() {
        var app = launch(["-NearbyScreen", "settings"])
        let row = app.descendants(matching: .any)["settings-link-Video quality"].firstMatch
        XCTAssertTrue(reveal(row, in: app, timeout: 5))
        row.tap()
        let expected = ["videoFill": "1", "showTemperature": "0", "lowerQualityWhenHot": "1", "viewerFreezeWarning": "0"]
        for (id, value) in expected {
            let toggle = app.switches[id].firstMatch
            XCTAssertTrue(reveal(toggle, in: app, timeout: 5), id)
            XCTAssertEqual(toggle.value as? String, value, id)
        }
        shot("video-quality")
        let temperature = app.switches["showTemperature"].firstMatch
        temperature.switches.firstMatch.exists ? temperature.switches.firstMatch.tap() : temperature.tap()
        app.terminate()
        app = launch(["-NearbyScreen", "video"])
        let again = app.switches["showTemperature"].firstMatch
        XCTAssertTrue(reveal(again, in: app, timeout: 5))
        XCTAssertEqual(again.value as? String, "1", "the choice is kept")
        again.switches.firstMatch.exists ? again.switches.firstMatch.tap() : again.tap()   // restore
        app.terminate()
    }

    /// Manual video: a resolution choice is what the next call will send (shown on Connection, as Android), and it is
    /// kept.
    func testManualVideoChoiceIsWhatTheNextCallSendsAndIsKept() {
        var app = launch(["-NearbyScreen", "manual"])
        let manual = app.switches["manualVideo"].firstMatch
        XCTAssertTrue(reveal(manual, in: app, timeout: 5))
        XCTAssertEqual(manual.value as? String, "0", "off by default")
        let picker = app.buttons["videoResolution"].firstMatch
        XCTAssertTrue(reveal(picker, in: app, timeout: 5))
        picker.tap()
        let option = app.buttons["640\u{00D7}360 (360p)"].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 4))
        option.tap()
        shot("manual-video")
        app.terminate()
        app = launch(["-NearbyScreen", "connection"])
        let next = app.descendants(matching: .any)["videoNextCall"].firstMatch
        XCTAssertTrue(reveal(next, in: app, timeout: 5))
        XCTAssertTrue(next.label.contains("360x640"), "the next call sends the chosen size: \(next.label)")
        app.terminate()
        app = launch(["-NearbyScreen", "manual"])
        let restore = app.buttons["videoResolution"].firstMatch
        XCTAssertTrue(reveal(restore, in: app, timeout: 5))
        restore.tap()
        app.buttons["426\u{00D7}240 (240p)"].firstMatch.tap()
        app.terminate()
    }

    /// Calls search appears only in a crowd and keeps the rows whose name matches.
    func testCallsSearchAppearsInACrowdAndFilters() {
        var app = launch(["-NearbyScreen", "people"])
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'person-'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["nearbySearch"].exists, "no search with three people")
        app.terminate()
        app = launch(["-NearbyScreen", "people", "-NearbyFixtureCrowd", "1"])
        let field = app.textFields["nearbySearch"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Asha")
        XCTAssertTrue(app.descendants(matching: .any)["person-a1b2c3d4e5f6"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["person-0102030405a8"].firstMatch.exists, "others are filtered out")
        shot("calls-search")
        app.terminate()
    }

    /// Decision 2026-11-06 (as Android): Experiments' relay rows are offered with or without Manual video settings.
    func testExperimentsRelayRowsShowWithoutManualVideo() {
        let app = launch(["-NearbyScreen", "experiments", "-manualVideo", "NO"])
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(reveal(app.switches["Relayed calls"].firstMatch, in: app, timeout: 5), "shown with Manual video off")
        let skip = app.descendants(matching: .any).matching(identifier: "Relay: slow viewers skip to keyframes").firstMatch
        XCTAssertTrue(reveal(skip, in: app, timeout: 5), "shown with Manual video off")
        shot("experiments-without-manual")
        app.terminate()
    }

    /// Android Link health: call info shows the connection and the sound bitrate for a voice call too, and no video rows.
    func testCallInfoShowsTheConnectionAndSoundForAVoiceCall() {
        let app = launch(["-NearbyScreen", "call-active"])
        let info = app.buttons["Call info: encryption and verification"].firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 5))
        info.tap()
        XCTAssertTrue(reveal(app.descendants(matching: .any).matching(identifier: "callConnection").firstMatch, in: app, timeout: 5))
        XCTAssertTrue(reveal(app.descendants(matching: .any).matching(identifier: "callSound").firstMatch, in: app, timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "callVideoRequested").firstMatch.exists, "a voice call has no video rows")
        shot("call-info-voice")
        app.terminate()
    }

    /// Android critical heat: in a call, video cannot be turned on and the call screen says why; otherwise it can.
    func testCriticalHeatKeepsVideoOffInACall() {
        var app = launch(["-NearbyScreen", "call-active", "-NearbyThermalOverride", "critical"])
        let camera = app.buttons["callCamera"].firstMatch
        XCTAssertTrue(camera.waitForExistence(timeout: 5))
        XCTAssertFalse(camera.isEnabled, "no video at critical heat")
        XCTAssertTrue(app.descendants(matching: .any)["callHealth"].firstMatch.exists, "the screen says why")
        shot("call-critical-heat")
        app.terminate()
        app = launch(["-NearbyScreen", "call-active", "-NearbyThermalOverride", "nominal"])
        let normal = app.buttons["callCamera"].firstMatch
        XCTAssertTrue(normal.waitForExistence(timeout: 5))
        XCTAssertTrue(normal.isEnabled)
        app.terminate()
    }

    /// Android's call budget: with Manual video on, the next GATT call starts at 180 kbps although 400 is chosen; with
    /// it off the request is kept.
    func testNextCallShowsTheTransportBudgetWithManualVideo() {
        var app = launch(["-NearbyScreen", "connection", "-transport", "gatt", "-manualVideo", "YES", "-videoKbps", "400"])
        var next = app.descendants(matching: .any)["videoNextCall"].firstMatch
        XCTAssertTrue(reveal(next, in: app, timeout: 5))
        XCTAssertTrue(next.label.contains("180 kbps"), "the GATT budget: \(next.label)")
        app.terminate()
        app = launch(["-NearbyScreen", "connection", "-transport", "gatt", "-manualVideo", "NO", "-videoKbps", "400"])
        next = app.descendants(matching: .any)["videoNextCall"].firstMatch
        XCTAssertTrue(reveal(next, in: app, timeout: 5))
        XCTAssertTrue(next.label.contains("400 kbps"), "Automatic keeps the request: \(next.label)")
        app.terminate()
    }

    /// Android End live: with a viewer, End asks first and Cancel keeps the live; with nobody watching, End ends at once.
    func testEndLiveAsksOnlyWithViewers() {
        var app = launch(["-NearbyScreen", "broadcast-video", "-NearbyFixtureViewers", "1"])
        let end = app.descendants(matching: .any)["liveEnd"].firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 8))
        end.tap()
        XCTAssertTrue(app.alerts.buttons["End live"].firstMatch.waitForExistence(timeout: 4), "asks with a viewer")
        shot("end-live-confirm")
        app.alerts.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(end.waitForExistence(timeout: 2), "Cancel keeps the live")
        app.terminate()
        app = launch(["-NearbyScreen", "broadcast-video"])
        let alone = app.descendants(matching: .any)["liveEnd"].firstMatch
        XCTAssertTrue(alone.waitForExistence(timeout: 8))
        alone.tap()
        XCTAssertFalse(app.alerts.buttons["End live"].firstMatch.waitForExistence(timeout: 2), "nobody watching: no question")
        app.terminate()
    }

    /// Call blocking (Android): Block unknown callers is off by default and keeps the choice; Blocked people opens.
    func testBlockUnknownCallersIsOffByDefaultAndBlockedPeopleOpens() {
        var app = launch(["-NearbyScreen", "privacy"])
        let toggle = app.switches["blockUnknownCallers"].firstMatch
        XCTAssertTrue(reveal(toggle, in: app, timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0", "off by default")
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        app.terminate()
        app = launch(["-NearbyScreen", "privacy"])
        let again = app.switches["blockUnknownCallers"].firstMatch
        XCTAssertTrue(reveal(again, in: app, timeout: 5))
        XCTAssertEqual(again.value as? String, "1", "the choice is kept")
        again.switches.firstMatch.exists ? again.switches.firstMatch.tap() : again.tap()
        let blocked = app.descendants(matching: .any)["settings-link-Blocked people"].firstMatch
        XCTAssertTrue(reveal(blocked, in: app, timeout: 5))
        blocked.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5), "Blocked people is a pushed page")
        shot("blocked-people")
        app.terminate()
    }

    /// Decline and block and Report are offered only for a caller that showed its real key.
    func testOnlyARealKeyCallerCanBeDeclinedAndBlocked() {
        var app = launch(["-NearbyScreen", "call-incoming"])
        XCTAssertTrue(app.buttons["declineAndBlock"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["declineAndReport"].exists)
        shot("call-incoming-block")
        app.terminate()
        app = launch(["-NearbyScreen", "call-incoming-voice"])
        XCTAssertTrue(app.buttons["Decline"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["declineAndBlock"].exists, "a one-time ID cannot be blocked one by one")
        app.terminate()
    }

    /// Add contact as Android: Scan their code | Show my code; the code side shows your ID and full fingerprint, and the
    /// Settings row "Your code" opens on the code.
    func testAddContactSwitchesBetweenScanningAndShowingTheCode() {
        var app = launch(["-NearbyScreen", "verify"])
        XCTAssertTrue(app.buttons["Scan their code"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Full fingerprint"].exists, "the scan side shows no code")
        app.buttons["Show my code"].tap()
        XCTAssertTrue(app.staticTexts["Full fingerprint"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your ID"].exists)
        shot("verify-show-code")
        app.buttons["Scan their code"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts["Full fingerprint"].waitForExistence(timeout: 2))
        app.terminate()
        app = launch(["-NearbyScreen", "settings"])
        let row = app.descendants(matching: .any)["settings-link-Your code"].firstMatch
        XCTAssertTrue(reveal(row, in: app, timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["Full fingerprint"].waitForExistence(timeout: 5), "Your code opens on the code")
        app.terminate()
    }

    /// Contacts as Android: a tap on the contact opens its sheet with Rename, Block, Report and Forget; a scanned contact
    /// has no Scan to confirm; one checked by code has it, and it opens Add contact on the scan side.
    func testContactRowOpensTheSheetAndScanToConfirmOpensAddContact() {
        let app = launch(["-NearbyScreen", "contacts", "-NearbyFixtureReach", "recognisable"])
        let asha = app.buttons["contactRow-Asha"].firstMatch
        XCTAssertTrue(asha.waitForExistence(timeout: 5))
        asha.tap()
        for id in ["contactRename", "contactBlock", "contactReport", "contactForget"] {
            XCTAssertTrue(reveal(app.buttons[id].firstMatch, in: app, timeout: 4), id)
        }
        XCTAssertFalse(app.buttons["contactScanConfirm"].exists, "Asha was scanned")
        shot("contact-sheet")
        app.buttons["Done"].firstMatch.tap()
        let ravi = app.buttons["contactRow-Ravi"].firstMatch
        XCTAssertTrue(ravi.waitForExistence(timeout: 5))
        ravi.tap()
        let confirm = app.buttons["contactScanConfirm"].firstMatch
        XCTAssertTrue(reveal(confirm, in: app, timeout: 4), "checked by code only")
        confirm.tap()
        XCTAssertTrue(app.buttons["Scan their code"].firstMatch.waitForExistence(timeout: 5), "Add contact opens")
        XCTAssertFalse(app.staticTexts["Full fingerprint"].exists, "on the scan side")
        app.terminate()
    }

    /// Rename keeps a new name everywhere; a name that reads like another contact's changes nothing.
    func testRenameKeepsANewNameAndRefusesATakenOne() {
        let app = launch(["-NearbyScreen", "contacts", "-NearbyFixtureReach", "recognisable"])
        XCTAssertTrue(app.buttons["contactRow-Ravi"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["contactRow-Ravi"].firstMatch.tap()
        let name = app.staticTexts.matching(identifier: "contactSheetName").firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 4))
        let rename = app.buttons["contactRename"].firstMatch
        XCTAssertTrue(reveal(rename, in: app, timeout: 4))
        rename.tap()
        var field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "ASHA")
        app.alerts.buttons["Save"].tap()
        XCTAssertEqual(name.label, "Ravi", "a taken name changes nothing")
        rename.tap()
        field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "Ravi K")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == 'contactSheetName' AND label == 'Ravi K'")).firstMatch.waitForExistence(timeout: 4))
        shot("contact-renamed")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["contactRow-Ravi K"].firstMatch.waitForExistence(timeout: 4), "the list shows the new name")
        app.terminate()
    }

    /// The name a contact now calls themselves is offered, never applied by itself; Use it as my label renames them once.
    func testUseItAsMyLabelRenamesOnlyWhenAsked() {
        let app = launch(["-NearbyScreen", "contacts", "-NearbyFixtureReach", "recognisable"])
        XCTAssertTrue(app.buttons["contactRow-Ravi"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["contactRow-Ravi"].firstMatch.tap()
        let use = app.buttons["contactUseClaim"].firstMatch
        XCTAssertTrue(reveal(use, in: app, timeout: 4))
        XCTAssertEqual(app.staticTexts.matching(identifier: "contactSheetName").firstMatch.label, "Ravi", "the offer changes nothing by itself")
        use.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == 'contactSheetName' AND label == 'Ravi Kumar'")).firstMatch.waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["contactUseClaim"].exists, "asked once")
        app.terminate()
    }

    /// A contact this phone cannot recognise yet: calling explains why and Show my code opens Add contact on the code.
    func testAskToScanOffersShowMyCode() {
        let app = launch(["-NearbyScreen", "contacts", "-NearbyFixtureReach", "ask"])
        let call = app.buttons["Voice call Asha"].firstMatch
        XCTAssertTrue(call.waitForExistence(timeout: 5))
        call.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 4))
        XCTAssertTrue(alert.buttons["Open Nearby"].exists)
        shot("contact-ask-to-scan")
        alert.buttons["Show my code"].tap()
        XCTAssertTrue(app.staticTexts["Full fingerprint"].waitForExistence(timeout: 5), "Add contact opens on the code")
        app.terminate()
    }

    /// Forget asks first and then removes the contact.
    func testForgetRemovesTheContactAfterAsking() {
        let app = launch(["-NearbyScreen", "contacts", "-NearbyFixtureReach", "recognisable"])
        XCTAssertTrue(app.buttons["contactRow-Ravi"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["contactRow-Ravi"].firstMatch.tap()
        let forget = app.buttons["contactForget"].firstMatch
        XCTAssertTrue(reveal(forget, in: app, timeout: 4))
        forget.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 4), "asks first")
        alert.buttons["Forget"].tap()
        XCTAssertFalse(app.buttons["contactRow-Ravi"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["contactRow-Asha"].firstMatch.exists)
        app.terminate()
    }

    /// P6-A1: an authenticated callee link that has not rung shows no call screen.
    func testNoCallScreenBeforeTheRing() {
        let app = launch(["-NearbyScreen", "call-connecting-callee"])
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Accept"].exists)
        XCTAssertFalse(app.buttons["Decline"].exists)
        app.terminate()
    }

    /// P6-A1: the call screen appears when the Invite arrives after `call` was already set.
    func testCallScreenAppearsWhenTheRingArrives() {
        // The fixture rings after 1 s; a real iPhone needs longer than that to reach the first assertion, so it rings after 6 s here.
        let app = launch(["-NearbyScreen", "call-connecting-callee-rings", "-NearbyFixtureRingAfter", "6"])
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Decline"].exists, "no call screen before the Invite")
        XCTAssertTrue(app.buttons["Decline"].waitForExistence(timeout: 12), "the ringing call screen appears")
        app.terminate()
    }

    /// Device test 2026-11-12: a call that rings while the "Block all unknown callers?" alert of the last Decline is
    /// still up shows its screen (the alert closes), so it can be answered or declined.
    func testACallRingingOverTheDeclineOfferStillShowsItsScreen() {
        // As on the phone: a temporary-ID call is declined, its offer shows, and the next call rings 12 s after launch.
        let app = launch(["-NearbyScreen", "call-incoming-voice", "-NearbyFixtureRingAgainAfter", "12", "-NearbyFixtureRingAfter", "1"])
        XCTAssertTrue(app.buttons["Decline"].waitForExistence(timeout: 6), "the first call rings")
        app.buttons["Decline"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "the decline offer is showing")
        XCTAssertTrue(app.buttons["Decline"].waitForExistence(timeout: 16), "the second ringing call shows its screen")
        XCTAssertFalse(app.alerts.firstMatch.exists, "the offer closed for the call")
        app.buttons["Decline"].tap()
        app.terminate()
    }

    /// Android HomeLayoutTest: End (or Cancel) is the middle control of every call and live row, and a control with
    /// nothing to do keeps its slot (Flip is there but disabled while the camera is off).
    func testEndIsTheMiddleControlOfEveryCallAndLiveRow() {
        for (screen, end) in [("call", "callEnd"), ("call-active", "callEnd"), ("call-active-video", "callEnd"),
                              ("broadcast-video", "liveEnd"), ("broadcast-radio", "liveEnd")] {
            let app = launch(["-NearbyScreen", screen])
            let button = app.buttons.matching(identifier: end).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 8), "\(screen): End")
            let window = app.windows.firstMatch.frame
            XCTAssertEqual(button.frame.midX, window.midX, accuracy: 2, "\(screen): End is in the middle")
            if screen == "call-active" {
                let flip = app.buttons.matching(identifier: "callFlip").firstMatch
                XCTAssertTrue(flip.exists, "Flip keeps its slot in a voice call")
                XCTAssertFalse(flip.isEnabled, "Flip does nothing while the camera is off")
            }
            if screen == "call-active-video" {
                XCTAssertTrue(app.buttons.matching(identifier: "callFlip").firstMatch.isEnabled, "Flip works while the camera is on")
            }
            shot("end-in-the-middle-\(screen)")
            app.terminate()
        }
    }

    /// Android audio only: the first broadcast warns that it is public; Cancel leaves, the warning confirmed opens the
    /// setup with the three qualities and Start.
    func testFirstAudioOnlyBroadcastWarnsBeforeTheSetup() {
        var app = launch(["-NearbyScreen", "broadcast-radio-setup", "-audioLiveDisclosed", "NO"])
        XCTAssertTrue(app.alerts["Going live"].waitForExistence(timeout: 8))
        app.alerts["Going live"].buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 8), "Cancel leaves the audio-only screen")
        app.terminate()
        app = launch(["-NearbyScreen", "broadcast-radio-setup", "-audioLiveDisclosed", "NO"])
        XCTAssertTrue(app.alerts["Going live"].waitForExistence(timeout: 8))
        app.alerts["Going live"].buttons["Go live with audio"].tap()
        for title in ["Voice", "Low data", "Music"] { XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5), title) }
        XCTAssertTrue(app.buttons.matching(identifier: "radioStart").firstMatch.exists)
        shot("radio-setup")
        app.terminate()
    }

    /// Android AudioLiveReminderPolicy with a 2-second unit: the reminder asks, Keep going keeps the broadcast; an
    /// unanswered reminder ends it and says so.
    func testRadioReminderKeepsGoingWhenAnsweredAndStopsWhenNot() {
        let app = launch(["-NearbyScreen", "broadcast-radio", "-NearbyRadioReminderUnit", "2"])
        XCTAssertTrue(app.buttons.matching(identifier: "liveEnd").firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.alerts["Still broadcasting"].waitForExistence(timeout: 20), "reminder after 12 s without a listener")
        shot("radio-reminder")
        app.alerts["Still broadcasting"].buttons["Keep going"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "liveEnd").firstMatch.waitForExistence(timeout: 3), "still live after Keep going")
        XCTAssertTrue(app.alerts["Still broadcasting"].waitForExistence(timeout: 20), "asks again 12 s after the answer")
        XCTAssertTrue(app.alerts["Audio broadcast stopped"].waitForExistence(timeout: 15), "unanswered: stopped and told")
        shot("radio-reminder-stopped")
        app.alerts["Audio broadcast stopped"].buttons["OK"].tap()
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 5))
        app.terminate()
    }

    /// Android's Settings tree (2026-11-04): each page opens from its row on the top page and Back returns there.
    func testEverySettingsPageOpensFromItsRowAndBackReturns() {
        let app = launch(["-NearbyScreen", "settings"])
        for title in ["Your code", "Your name", "Privacy", "Connection", "Experiments", "About this app"] {
            let row = app.descendants(matching: .any)["settings-link-" + title].firstMatch
            XCTAssertTrue(reveal(row, in: app, timeout: 5), title)
            row.tap()
            XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5), "\(title) is a pushed page")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.staticTexts["tabTitle"].firstMatch.waitForExistence(timeout: 5), "back on the top page from \(title)")
        }
        let contact = app.buttons["contactUs"].firstMatch
        XCTAssertTrue(reveal(contact, in: app, timeout: 5), "Contact us")
        app.terminate()
    }

    /// Phase 2 presence UI (rotating IDs on): the per-contact switch "Can see when I'm nearby" (off while the contact was
    /// not asked yet) and
    /// Settings > Privacy "Reset nearby recognition" with its confirmation.
    func testPresenceSwitchAndReset() {
        var app = launch(["-NearbyScreen", "contacts", "-experimentalRotatingIds", "YES"])
        let info = app.buttons["Contact info Asha"].firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 8), "contact info button")
        info.tap()
        let toggle = app.switches["canSeeMe-Asha"].firstMatch
        XCTAssertTrue(reveal(toggle, in: app, timeout: 8), "the contact's presence switch")
        XCTAssertEqual(toggle.value as? String, "0", "a contact not yet asked shows off")
        shot("presence-switch-off")
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        XCTAssertEqual(toggle.value as? String, "1", "turned on")
        shot("presence-switch-on")
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()   // restore
        app.terminate()
        app = launch(["-NearbyScreen", "privacy", "-experimentalRotatingIds", "YES"])
        let reset = app.buttons["resetPresenceKey"].firstMatch
        XCTAssertTrue(reveal(reset, in: app, timeout: 5), "Reset presence key")
        reset.tap()
        let alert = app.alerts["Reset nearby recognition?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 4), "asks first")
        shot("presence-reset-confirm")
        alert.buttons["Reset"].tap()
        XCTAssertFalse(alert.exists)
        XCTAssertTrue(app.descendants(matching: .any)["privateIdResetDone"].firstMatch.waitForExistence(timeout: 4),
                      "the reset is confirmed on the page")
        app.terminate()
    }

    /// Settings › Your name (Android 2026-11-04): an accepted name is saved, a rejected name keeps the current name,
    /// and an empty field clears it.
    func testYourNameRejectedNameKeepsTheCurrentName() {
        let app = launch(["-NearbyScreen", "settings"])
        func openName() -> XCUIElement {
            let row = app.descendants(matching: .any)["settings-link-Your name"].firstMatch
            XCTAssertTrue(reveal(row, in: app, timeout: 5), "Your name row")
            row.tap()
            let field = app.textFields["yourNameField"].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5), "name field")
            return field
        }
        func replace(_ field: XCUIElement, with text: String) {
            field.tap()
            let old = (field.value as? String) ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 2) + text)
        }
        func back() { app.navigationBars.buttons.element(boundBy: 0).tap() }
        var field = openName()
        replace(field, with: "Asha")
        back()
        field = openName()
        XCTAssertEqual(field.value as? String, "Asha", "an accepted name is saved")
        replace(field, with: String(repeating: "x", count: 40))
        XCTAssertTrue(app.descendants(matching: .any)["yourNameRejected"].waitForExistence(timeout: 3), "the reason shows while typing")
        shot("your-name-rejected")
        back()
        field = openName()
        XCTAssertEqual(field.value as? String, "Asha", "a rejected name keeps the current name")
        replace(field, with: "")
        back()
        field = openName()
        XCTAssertNotEqual(field.value as? String, "Asha", "an empty field clears the name")
        back()
        app.terminate()
    }

    /// One name (Android 2026-11-04): "Who sees my name" appears once a name is set, keeps the choice, and goes away
    /// when the name is cleared.
    func testWhoSeesMyNameFollowsTheNameAndKeepsTheChoice() {
        let app = launch(["-NearbyScreen", "settings"])
        func setName(_ text: String) {
            let row = app.descendants(matching: .any)["settings-link-Your name"].firstMatch
            XCTAssertTrue(reveal(row, in: app, timeout: 5), "Your name row")
            row.tap()
            let field = app.textFields["yourNameField"].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            let old = (field.value as? String) ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 2) + text)
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        setName("Asha")
        let audience = app.descendants(matching: .any)["settings-link-Who sees my name"].firstMatch
        XCTAssertTrue(reveal(audience, in: app, timeout: 5), "shown while a name is set")
        audience.tap()
        let nobody = app.buttons["namesAudience-nobody"].firstMatch
        XCTAssertTrue(nobody.waitForExistence(timeout: 5))
        nobody.tap()
        shot("who-sees-my-name")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        audience.tap()
        XCTAssertTrue(app.buttons["namesAudience-nobody"].firstMatch.isSelected, "the choice is kept")
        app.buttons["namesAudience-everyone"].firstMatch.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        setName("")
        XCTAssertFalse(app.descendants(matching: .any)["settings-link-Who sees my name"].firstMatch.exists, "hidden without a name")
        app.terminate()
    }

    /// Rotating IDs are always on (2026-11-04): Privacy offers Reset nearby recognition with no switch to turn on,
    /// it asks first, and the DEBUG control arm `-experimentalRotatingIds NO` still turns rotating IDs off.
    func testResetNearbyRecognitionNeedsNoSwitchAndTheControlArmStillWorks() {
        var app = launch(["-NearbyScreen", "privacy"])
        let reset = app.buttons["resetPresenceKey"].firstMatch
        XCTAssertTrue(reveal(reset, in: app, timeout: 5), "Reset nearby recognition is offered by default")
        reset.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 4), "asks first")
        shot("privacy-default")
        alert.buttons["Cancel"].tap()
        app.terminate()
        app = launch(["-NearbyScreen", "privacy", "-experimentalRotatingIds", "NO"])
        XCTAssertTrue(app.switches["quickWipeToggle"].firstMatch.waitForExistence(timeout: 5), "Privacy is open")
        XCTAssertFalse(app.buttons["resetPresenceKey"].firstMatch.exists, "the control arm turns rotating IDs off")
        app.terminate()
    }

    /// The panic gesture asks first; Cancel keeps everything.
    /// Off by default (Android panic_wipe_gesture): three taps do nothing.
    func testQuickWipeIsOffByDefault() {
        let app = launch(["-quickWipeGesture", "NO"])
        let status = app.staticTexts["tabTitle"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 8), "tab title")
        status.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 3), "no erase prompt while the gesture is off")
        XCTAssertTrue(app.buttons["Go live"].exists)
    }

    func testPanicGestureAsksFirst() {
        let app = launch(["-quickWipeGesture", "YES"])
        let status = app.staticTexts["tabTitle"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 8), "tab title")
        status.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 4), "erase confirmation")
        shot("panic-confirm")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Go live"].exists, "still on Live after Cancel")
    }

    /// Title bar (Android view_status_chip, sheet_status): the status chip ends the tab's title row and a pushed
    /// page's navigation bar, and a tap opens the status sheet with its rows.
    func testStatusChipOpensTheStatusSheetOnATabAndAPage() {
        let app = launch(["-NearbyScreen", "settings"])
        let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'statusChip-'"))
        XCTAssertTrue(chips.firstMatch.waitForExistence(timeout: 8), "status chip on the Settings tab")
        chips.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["status-row-bluetooth"].waitForExistence(timeout: 4), "the status sheet")
        XCTAssertTrue(app.descendants(matching: .any)["status-row-calls"].exists)
        shot("status-sheet")
        dismissSheet(app, marker: "status-row-bluetooth")
        let privacy = app.descendants(matching: .any)["settings-link-Privacy"].firstMatch
        XCTAssertTrue(reveal(privacy, in: app, timeout: 5), "Privacy row")
        privacy.tap()
        let pageChip = app.navigationBars.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'statusChip-'")).firstMatch
        XCTAssertTrue(pageChip.waitForExistence(timeout: 5), "status chip in the page's title row")
        shot("privacy-title-row")
        pageChip.tap()
        XCTAssertTrue(app.descendants(matching: .any)["status-row-bluetooth"].waitForExistence(timeout: 4))
        app.terminate()
    }

    /// Portrait only (Info.plist): rotating the simulator keeps the portrait layout.
    func testRotationStaysPortrait() {
        let app = launch([])
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 8))
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        shot("rotation-landscape-request")
        let frame = app.windows.firstMatch.frame
        XCTAssertGreaterThan(frame.height, frame.width, "window stays portrait")
        XCTAssertTrue(app.buttons["Go live"].isHittable, "primary button reachable after rotation")
        XCUIDevice.shared.orientation = .portrait
    }

    /// Background, foreground and an active call screen surviving a trip to the home screen.
    func testBackgroundAndForeground() {
        let app = launch(["-NearbyScreen", "call-active"])
        XCTAssertTrue(app.buttons["End"].waitForExistence(timeout: 8))
        XCUIDevice.shared.press(.home)
        // Background (or suspended: the unconnected fixture call holds no audio session).
        var left = app.wait(for: .runningBackground, timeout: 8) || app.state == .runningBackgroundSuspended
        if !left {
            // Some simulator models ignore the hardware home press (iPhone Duo, iOS 27.1): bring SpringBoard forward.
            note("lifecycle-home.txt", "home press left state \(app.state.rawValue); activated SpringBoard")
            XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
            left = app.wait(for: .runningBackground, timeout: 8) || app.state == .runningBackgroundSuspended
        }
        XCTAssertTrue(left, "app left the foreground (state \(app.state.rawValue))")
        app.activate()
        XCTAssertTrue(app.buttons["End"].waitForExistence(timeout: 5), "call screen restored after foreground")
        shot("lifecycle-foreground-call")
        app.terminate()
        let again = launch([])
        XCTAssertTrue(again.buttons["Go live"].waitForExistence(timeout: 8), "cold relaunch reaches Live")
    }

    /// First call: the system asks for the microphone; "Don't Allow" must leave the app usable and explain the next
    /// step (the fixture person is not on the radio, so the call itself ends with the "isn't nearby" notice).
    /// Needs reset privacy for the app (run-uitest.sh resets it before the run on a simulator).
    /// A crash report waits for the user's answer; "Don't ask again" turns reports off for later launches.
    func testCrashReportIsOfferedAndCanBeTurnedOff() {
        var app = launch(["-crashReports", "YES", "-NearbyCrashReportFixture", "1"])
        let title = app.staticTexts["MeshLive closed unexpectedly"]
        XCTAssertTrue(title.waitForExistence(timeout: 6), "the next launch asks about the crash")
        XCTAssertTrue(app.descendants(matching: .any)["crash-report-text"].exists, "the exact report is shown before sharing")
        XCTAssertTrue(app.buttons["Share"].exists)
        XCTAssertTrue(app.buttons["Not now"].exists)
        shot("crash-report")
        app.buttons["Don't ask again"].tap()
        XCTAssertFalse(title.waitForExistence(timeout: 2))
        app.terminate()
        app = launch(["-NearbyCrashReportFixture", "1"])
        XCTAssertFalse(title.waitForExistence(timeout: 4), "turned off: no report is kept or offered")
    }

    /// A live join that never starts says so and offers Try again (Android StreamJoinRetry).
    func testFailedJoinOffersTryAgain() {
        let app = launch(["-NearbyWatchTimeout", "3"])
        let stream = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'stream-'")).firstMatch
        XCTAssertTrue(stream.waitForExistence(timeout: 5))
        stream.tap()
        let failed = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Couldn't join")).firstMatch
        XCTAssertTrue(failed.waitForExistence(timeout: 25), "the failed join says so (after the one automatic retry)")
        XCTAssertTrue(app.buttons["Try again"].exists)
        shot("stream-join-failed")
        app.buttons["Try again"].tap()
        XCTAssertFalse(app.buttons["Try again"].waitForExistence(timeout: 1), "Try again is used up while the stream is looked for")
    }

    /// A stuck Bluetooth stack gets plain restart guidance on Calls and Live (Android people_bluetooth_restart).
    func testStuckBluetoothExplainsTheRestart() {
        let app = launch(["-NearbyScreen", "people", "-NearbyBluetoothStuck", "1"])
        let title = app.staticTexts["Bluetooth needs a restart to find nearby people"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Calls explains what helps")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "off and on")).firstMatch.exists)
        shot("bluetooth-restart")
        app.tabBars.buttons["Live"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Live shows the same card")
    }

    /// A call that cannot reach the person leaves "Couldn't reach ..." with Call again, which tries once more.
    func testCouldNotReachOffersCallAgain() {
        let app = launch(["-NearbyScreen", "people"])
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'person-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["Voice call"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Voice call"].firstMatch.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 6) { alert.buttons.element(boundBy: alert.buttons.count - 1).tap() }
        let notice = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Couldn't reach")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 8), "the failed call says who could not be reached")
        let again = app.buttons["Call again"]
        XCTAssertTrue(again.exists, "the notice offers Call again")
        shot("call-again")
        again.tap()
        XCTAssertTrue(notice.waitForExistence(timeout: 8), "Call again tried the same person once more")
        app.buttons["Dismiss"].firstMatch.tap()
        XCTAssertFalse(app.buttons["Call again"].waitForExistence(timeout: 2), "dismissing removes the notice")
    }

    /// A rotating ID heard from two phones at once: a call from its row asks first; Cancel places no call; a row without
    /// the warning calls at once.
    func testACopiedIDAsksBeforeTheCall() {
        let app = launch(["-NearbyScreen", "people", "-NearbyFixtureCopiedId", "1"])
        // The simulator names the row `person-...`; on an iPhone SwiftUI gives the row button its warning child's `copiedId-...` identifier.
        let ravi = app.buttons.matching(NSPredicate(format: "identifier IN {'person-0102030405a8', 'copiedId-0102030405a8'}")).firstMatch
        XCTAssertTrue(reveal(ravi, in: app, timeout: 5))
        ravi.tap()
        XCTAssertTrue(app.buttons["Voice call"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Voice call"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Call anyway"].firstMatch.waitForExistence(timeout: 5), "a call to a copied ID asks once more")
        shot("copied-id")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Couldn't reach")).firstMatch.waitForExistence(timeout: 2),
                       "Cancel places no call")
        let asha = app.descendants(matching: .any)["person-a1b2c3d4e5f6"].firstMatch
        XCTAssertTrue(reveal(asha, in: app, timeout: 5))
        asha.tap()
        XCTAssertTrue(app.buttons["Voice call"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Voice call"].firstMatch.tap()
        XCTAssertFalse(app.buttons["Call anyway"].firstMatch.waitForExistence(timeout: 2), "no question without the warning")
        app.terminate()
    }

    /// Touch and hold a Nearby row: Call, Add contact, Block and Report; a temporary ID cannot be blocked one by one.
    func testNearbyRowMenuOffersCallAddContactBlockAndReport() {
        let app = launch(["-NearbyScreen", "people"])
        let stranger = app.descendants(matching: .any)["person-112233445566"].firstMatch
        XCTAssertTrue(reveal(stranger, in: app, timeout: 5))
        stranger.press(forDuration: 1.2)
        for item in ["Call", "Add contact", "Block", "Report"] {
            XCTAssertTrue(app.buttons[item].firstMatch.waitForExistence(timeout: 4), item)
        }
        shot("nearby-menu")
        app.buttons["Block"].firstMatch.tap()
        XCTAssertTrue(app.alerts["Declined, but not blocked"].waitForExistence(timeout: 4), "a temporary ID offers Block unknown callers")
        app.alerts.buttons["Close"].firstMatch.tap()
        app.terminate()
    }

    /// Nobody nearby: Search again restarts the search and the empty state stays until someone appears.
    func testNobodyNearbyOffersSearchAgain() {
        let app = launch(["-NearbyScreen", "people", "-NearbyFixture", "empty"])
        let again = app.buttons["Search again"].firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        again.tap()
        XCTAssertTrue(again.waitForExistence(timeout: 3))
        shot("people-empty")
        app.terminate()
    }

    /// A stranger's recent call cannot be called back: a tap explains how to reach them again, and Open Calls shows Nearby.
    func testAStrangersRecentCallExplainsHowToReachThemAgain() {
        let app = launch(["-NearbyScreen", "people", "-NearbyFixtureStranger", "1"])
        app.buttons["Recent"].firstMatch.tap()
        let row = app.descendants(matching: .any)["recent-stranger"].firstMatch
        XCTAssertTrue(reveal(row, in: app, timeout: 5))
        row.tap()
        let open = app.buttons["Open Calls"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add contact"].firstMatch.exists)
        shot("recent-stranger")
        open.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'person-'")).firstMatch.waitForExistence(timeout: 5),
                      "Open Calls shows Nearby")
        app.terminate()
    }

    /// A history this device cannot open offers Clear history; clearing leaves the ordinary empty list.
    func testAnUnreadableHistoryCanBeCleared() {
        let app = launch(["-NearbyScreen", "people", "-NearbyFixtureRecentUnreadable", "1"])
        app.buttons["Recent"].firstMatch.tap()
        let unreadable = app.buttons["recentUnreadable"].firstMatch
        XCTAssertTrue(unreadable.waitForExistence(timeout: 5))
        shot("recent-unreadable")
        unreadable.tap()
        let clear = app.buttons["Clear history"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertFalse(unreadable.waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["recentEmpty"].firstMatch.waitForExistence(timeout: 5))
        app.terminate()
    }

    /// After a call with someone who is not saved, Calls offers Add contact, which opens Add contact.
    func testAfterAStrangersCallCallsOffersAddContact() {
        let app = launch(["-NearbyScreen", "people", "-NearbyFixtureStrangerFollowUp", "1"])
        let add = app.buttons["notice-action"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        shot("stranger-follow-up")
        add.tap()
        XCTAssertTrue(app.buttons["Scan their code"].firstMatch.waitForExistence(timeout: 5), "Add opens Add contact")
        app.terminate()
    }

    func testMicrophonePromptAndDenial() {
        let app = launch(["-NearbyScreen", "people"])
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'person-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let voice = app.buttons["Voice call"].firstMatch
        XCTAssertTrue(voice.waitForExistence(timeout: 5), "call dialog")
        voice.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 6) {
            note("permission-alert.txt", alert.label)
            XCTAssertTrue(alert.label.localizedCaseInsensitiveContains("microphone"), "microphone prompt, got: \(alert.label)")
            shot("permission-microphone-prompt")
            let deny = alert.buttons["Don’t Allow"].exists ? alert.buttons["Don’t Allow"] : alert.buttons.element(boundBy: 0)
            deny.tap()
        } else {
            note("permission-alert.txt", "no system prompt (permission already decided)")
        }
        let notice = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'nearby right now' OR label CONTAINS[c] 'reach' OR label CONTAINS[c] 'Microphone'")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 8), "a notice explains why no call started")
        shot("permission-denied-notice")
        XCTAssertTrue(app.state == .runningForeground, "app still in the foreground")
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
