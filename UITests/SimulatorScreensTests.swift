import XCTest

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
        do {
            try app.performAccessibilityAudit { issue in
                let line = "\(issue.compactDescription) | \(issue.element?.label ?? "-") | \(issue.element.map { "\($0.elementType.rawValue) \($0.frame)" } ?? "-")"
                // Dynamic Type and clipping findings are warnings: the audit reports grouped-list headers/footers and
                // fixed-size avatar discs as "partially unsupported" and single-line rows as "clipped" at the default size.
                // They are checked visually in the accessibility-size screenshots instead.
                let underTabBar = issue.auditType == .contrast && (issue.element?.frame.maxY ?? 0) > tabBarTop
                if issue.auditType == .dynamicType || issue.auditType == .textClipped || underTabBar { warnings.append(line) } else { issues.append(line) }
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
        ("privacy", ["-NearbyScreen", "privacy"], "Advanced privacy"),
        ("advanced-privacy", ["-NearbyScreen", "advanced-privacy"], "Rotating discovery IDs"),
        ("verify", ["-NearbyScreen", "verify"], "Scan their code"),
        ("live", ["-NearbyScreen", "live"], "Go live"),
        ("call-outgoing", ["-NearbyScreen", "call"], "Cancel"),
        ("call-incoming-video", ["-NearbyScreen", "call-incoming"], "Accept"),
        ("call-incoming-voice", ["-NearbyScreen", "call-incoming-voice"], "Accept"),
        ("call-active", ["-NearbyScreen", "call-active"], "End"),
        ("call-mismatch", ["-NearbyScreen", "call-mismatch"], "Identity does not match"),
        ("call-ended", ["-NearbyScreen", "call-ended"], "Call ended"),
    ]

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
        XCTAssertTrue(reveal(app.descendants(matching: .any).matching(NSPredicate(format: "(label CONTAINS 'Call ' AND label CONTAINS ' back') OR label CONTAINS 'Missed voice call'")).firstMatch, in: app, timeout: 8),
                      "recent calls with call-back buttons")
        shot("list-recent")
        app.terminate()
        let watchApp = launch(["-NearbyScreen", "live"])
        XCTAssertTrue(watchApp.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Live from'")).firstMatch.waitForExistence(timeout: 5), "stream rows")
        XCTAssertTrue(watchApp.staticTexts.matching(NSPredicate(format: "label CONTAINS 'paused'")).firstMatch.exists, "paused stream detail")
        shot("list-watch")
    }

    /// A Settings switch can be flipped and survives a terminate/relaunch.
    func testSettingsAdvancedPersist() {
        var app = launch(["-NearbyScreen", "settings"])
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
        app = launch(["-NearbyScreen", "settings"])
        let again = app.switches.matching(relay).firstMatch
        reveal(again, in: app, timeout: 3)
        XCTAssertEqual(again.value as? String, after, "toggle persisted across relaunch")
        // Restore.
        again.switches.firstMatch.exists ? again.switches.firstMatch.tap() : again.tap()
        app.terminate()
    }

    /// Phase 2 presence UI (rotating IDs on): the per-contact switch "Can see when I'm nearby" (default on) and
    /// Settings > Privacy > Advanced privacy "Reset presence key" with its confirmation.
    func testPresenceSwitchAndReset() {
        var app = launch(["-NearbyScreen", "contacts", "-experimentalRotatingIds", "YES"])
        let info = app.buttons["Contact info Asha"].firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 8), "contact info button")
        info.tap()
        let toggle = app.switches["canSeeMe-Asha"].firstMatch
        XCTAssertTrue(reveal(toggle, in: app, timeout: 8), "the contact's presence switch")
        XCTAssertEqual(toggle.value as? String, "1", "default on")
        shot("presence-switch-on")
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        shot("presence-switch-off")
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()   // restore
        app.terminate()
        app = launch(["-NearbyScreen", "advanced-privacy", "-experimentalRotatingIds", "YES"])
        let reset = app.buttons["resetPresenceKey"].firstMatch
        XCTAssertTrue(reveal(reset, in: app, timeout: 5), "Reset presence key")
        reset.tap()
        let alert = app.alerts["Reset presence key?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 4), "asks first")
        shot("presence-reset-confirm")
        alert.buttons["Reset"].tap()
        XCTAssertFalse(alert.exists)
        app.terminate()
    }

    /// The panic gesture asks first; Cancel keeps everything.
    /// Off by default (Android panic_wipe_gesture): three taps do nothing.
    func testQuickWipeIsOffByDefault() {
        let app = launch(["-quickWipeGesture", "NO"])
        let status = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Bluetooth' OR label BEGINSWITH 'Access needed' OR label BEGINSWITH 'No Bluetooth'")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 8), "status row")
        status.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        XCTAssertFalse(app.alerts["Erase everything now?"].waitForExistence(timeout: 3), "no erase prompt while the gesture is off")
        XCTAssertTrue(app.buttons["Go live"].exists)
    }

    func testPanicGestureAsksFirst() {
        let app = launch(["-quickWipeGesture", "YES"])
        let status = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Bluetooth' OR label BEGINSWITH 'Access needed' OR label BEGINSWITH 'No Bluetooth'")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 8), "status row")
        status.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        let alert = app.alerts["Erase everything now?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 4), "erase confirmation")
        shot("panic-confirm")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Go live"].exists, "still on Live after Cancel")
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
