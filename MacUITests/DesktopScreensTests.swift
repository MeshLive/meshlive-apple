import XCTest

final class DesktopScreensTests: XCTestCase {
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

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLaunchWindow() {
        let app = launch()
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists)
        XCTAssertGreaterThanOrEqual(window.frame.width, 800)
        XCTAssertGreaterThanOrEqual(window.frame.height, 560)
        shot(app, "live")
        app.terminate()
    }

    func testGeneratedNearbyNamesAndOwnNameUseTheBundledAndroidLists() {
        let app = launch(["-NearbyFixture", "nearby-names", "-NearbyScreen", "people"])
        let first = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "mild bream")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "amiable otter")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Asha")).firstMatch.exists)
        let own = app.descendants(matching: .any).matching(identifier: "own-nearby-name").firstMatch
        XCTAssertTrue(own.exists)
        XCTAssertTrue(own.label.contains("mild bream"), "the Calls list says which name people nearby see for this Mac")
        first.click()
        XCTAssertTrue(app.buttons["Voice call"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Video call"].exists)
        shot(app, "generated-nearby-names")
        app.sheets.buttons["Cancel"].click()
        app.terminate()
    }

    func testSidebarAndKeyboardNavigation() {
        let app = launch()
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 10))
        for (tab, expected) in [("calls", "Nearby"), ("contacts", "Add contact"), ("settings", "Your name"), ("live", "Live nearby")] {
            let row = app.descendants(matching: .any).matching(identifier: "desktop-tab-" + tab).firstMatch
            XCTAssertTrue(row.exists)
            row.click()
            let element = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", expected)).firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 5), expected)
            shot(app, tab)
        }
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Nearby"].waitForExistence(timeout: 5))
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Add contact"].waitForExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Video and audio"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Audio only"].exists)
        XCTAssertTrue(app.popUpButtons["desktop-camera"].exists)
        shot(app, "go-live")
        app.buttons["Cancel"].click()
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testCloseWindowQuitsByDefault() {
        let app = launch(["-desktopKeepRunningWithWindowClosed", "NO"])
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 10))
        app.staticTexts["Live nearby"].click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }

    func testKeepRunningCanReopenWindow() {
        let app = launch(["-desktopKeepRunningWithWindowClosed", "YES"])
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 10))
        app.staticTexts["Live nearby"].click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(app.windows.firstMatch.exists)
        XCTAssertNotEqual(app.state, .notRunning)
        app.typeKey("0", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 5))
        shot(app, "reopened")
        app.terminate()
    }

    func testOnboardingPagesWithoutRequestingPermissions() {
        let app = launch(["-NearbyScreen", "onboarding"])
        XCTAssertTrue(app.staticTexts["Calls and live video, no internet needed"].waitForExistence(timeout: 5))
        shot(app, "onboarding-welcome")
        app.buttons["Next"].click()
        XCTAssertTrue(app.staticTexts["What you can do"].waitForExistence(timeout: 5))
        shot(app, "onboarding-features")
        app.buttons["Next"].click()
        XCTAssertTrue(app.staticTexts["Allow what the app needs"].waitForExistence(timeout: 5))
        for title in ["Bluetooth", "Camera", "Microphone", "Notifications"] {
            XCTAssertTrue(app.staticTexts[title].exists)
        }
        let requests = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "permission-"))
        for request in requests.allElementsBoundByIndex { XCTAssertFalse(request.isEnabled) }
        shot(app, "onboarding-permissions")
        app.buttons["Next"].click()
        XCTAssertTrue(app.staticTexts["You are ready"].waitForExistence(timeout: 5))
        shot(app, "onboarding-ready")
        app.buttons["Start"].click()
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testCallsChooseTypeAndKeepLegacySubject() {
        var app = launch(["-NearbyScreen", "people", "-NearbyLabels", "1"])
        XCTAssertTrue(app.buttons["Nearby"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Recent"].exists)
        XCTAssertFalse(app.textFields["Subject (optional)"].exists)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "person-")).firstMatch.click()
        XCTAssertTrue(app.buttons["Voice call"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Video call"].exists)
        shot(app, "call-choice")
        for (key, title) in [("a", "Voice call"), ("v", "Video call")] {
            app.typeKey(key, modifierFlags: [.command, .shift])
            XCTAssertFalse(app.buttons[title].exists)
            // Preview cannot reach a real peer. This confirms the shortcut invokes the call action.
            let notice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Couldn't reach ")).firstMatch
            XCTAssertTrue(notice.waitForExistence(timeout: 5))
            notice.click()
            if key == "a" {
                app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "person-")).firstMatch.click()
                XCTAssertTrue(app.buttons["Video call"].waitForExistence(timeout: 5))
            }
        }
        app.terminate()
        app = launch(["-NearbyScreen", "call-incoming", "-NearbyLegacySubject", "Meeting update"])
        XCTAssertTrue(app.staticTexts["Meeting update"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Accept"].exists)
        shot(app, "legacy-incoming-call")
        app.terminate()
    }

    func testContactStaysUntilOpenNearby() {
        let app = launch(["-NearbyScreen", "contacts"])
        XCTAssertTrue(app.buttons["Voice call Asha"].waitForExistence(timeout: 5))
        app.buttons["Voice call Asha"].click()
        let heading = app.staticTexts["Asha is not found nearby yet"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["If you have not talked since adding them, call them once from the Nearby list. After that, Contacts can call them directly."].exists)
        shot(app, "contact-not-nearby")
        app.windows.buttons["Cancel"].click()
        XCTAssertTrue(app.buttons["Add contact"].exists)
        app.buttons["Video call Asha"].click()
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        app.windows.buttons["Open Nearby"].click()
        XCTAssertTrue(app.buttons["Nearby"].waitForExistence(timeout: 5))
        shot(app, "contact-open-nearby")
        app.terminate()
    }

    func testRadioJoinPaneCanLeave() {
        let app = launch(["-NearbyScreen", "radio"])
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Audio only"].waitForExistence(timeout: 5))
        shot(app, "radio-join-pane")
        app.buttons["Leave"].click()
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testAboutShowsBuildAndRealLinkedCodecs() {
        let app = launch(["-NearbyScreen", "about"])
        for title in ["Version", "Build", "Video encode", "Voice"] {
            let row = app.descendants(matching: .any).matching(identifier: "about-" + title).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), title)
            XCTAssertTrue(row.label.hasPrefix(title + ": "))
            XCTAssertGreaterThan(row.label.count, title.count + 2)
        }
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "about-Video encode").firstMatch.label, "Video encode: VP9, software")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "about-Voice").firstMatch.label, "Voice: Opus 48 kHz")
        shot(app, "about")
        app.terminate()
    }

    private func checkButtonLabels(_ app: XCUIApplication) {
        // AppKit exposes scrollbar internals as unlabeled buttons. Audit their parent value,
        // then check labels on app actions and the native window controls separately.
        let scrollbars = app.windows.scrollBars.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
        for scrollbar in scrollbars { XCTAssertNotNil(scrollbar.value, "Native scrollbar needs a position value") }
        let scrollControls = app.windows.scrollBars.buttons.allElementsBoundByIndex.map { $0.frame }
        let buttons = app.windows.buttons.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
        for button in buttons where !scrollControls.contains(button.frame) {
            XCTAssertFalse(button.label.trimmingCharacters(in: .whitespaces).isEmpty, "Button needs a VoiceOver label")
        }
    }

    func testLargestContentSizeAndKeyboardDismissal() {
        let standard = launch()
        XCTAssertTrue(standard.buttons["Go live"].waitForExistence(timeout: 5))
        let standardWidth = standard.buttons["Go live"].frame.width
        standard.terminate()
        let app = launch(["-desktopContentSize", "130"])
        let goLive = app.buttons["Go live"]
        XCTAssertTrue(goLive.waitForExistence(timeout: 5))
        XCTAssertTrue(goLive.isHittable)
        // SwiftUI reports the button's logical height before scaleEffect. The smaller logical
        // viewport proves reflow; screenshot review verifies rendered enlargement.
        XCTAssertLessThan(goLive.frame.width, standardWidth * 0.9)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(goLive.frame))
        checkButtonLabels(app)
        shot(app, "largest-live")
        app.typeKey("3", modifierFlags: .command)
        for title in ["Voice call Asha", "Video call Asha", "Contact info Asha", "Add contact"] {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons[title].isHittable)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(app.buttons[title].frame))
        }
        checkButtonLabels(app)
        shot(app, "largest-contacts")
        app.typeKey("1", modifierFlags: .command)
        app.typeKey("g", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Video and audio"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Video and audio"].isHittable)
        checkButtonLabels(app)
        shot(app, "largest-go-live")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 5))
        app.terminate()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.waitForExistence(timeout: 5) else { return false }
        for _ in 0..<8 {
            if element.isHittable && app.windows.firstMatch.frame.contains(element.frame) { return true }
            let scrollers = app.windows.scrollViews.allElementsBoundByIndex
            guard let scroll = scrollers.max(by: { $0.frame.width < $1.frame.width }) else { return false }
            scroll.scroll(byDeltaX: 0, deltaY: -200)
        }
        return element.isHittable && app.windows.firstMatch.frame.contains(element.frame)
    }

    func testLargestOnboardingAndMediaControls() {
        for (screen, controls) in [("onboarding", ["Next", "Skip"]), ("call-incoming", ["Decline", "Voice", "Accept"]), ("radio", ["Leave"]), ("broadcast-radio", ["Mute", "Pause", "End"])] {
            let app = launch(["-desktopContentSize", "130", "-NearbyScreen", screen])
            for title in controls { XCTAssertTrue(reveal(app.buttons[title], in: app), screen + ": " + title) }
            checkButtonLabels(app)
            shot(app, "largest-" + screen)
            if screen == "broadcast-radio" {
                let scroll = app.windows.scrollViews.allElementsBoundByIndex.max(by: { $0.frame.width < $1.frame.width })
                XCTAssertNotNil(scroll)
                scroll?.scroll(byDeltaX: 0, deltaY: -300)
                XCTAssertTrue(app.buttons["End"].isHittable)
                shot(app, "largest-radio-end-visible")
                app.buttons["End"].click()
                XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 5))
            }
            app.terminate()
        }
    }

    func testTypedWipeCanCancelWithoutErasing() {
        let app = launch(["-NearbyScreen", "settings"])
        XCTAssertTrue(reveal(app.buttons["Wipe everything"], in: app))
        app.buttons["Wipe everything"].click()
        let erase = app.windows.buttons["Erase now"]
        XCTAssertTrue(erase.waitForExistence(timeout: 5))
        XCTAssertFalse(erase.isEnabled)
        let field = app.windows.textFields.firstMatch
        XCTAssertTrue(field.exists)
        field.click(); field.typeText("WIPE")
        XCTAssertTrue(erase.isEnabled)
        shot(app, "typed-wipe")
        app.windows.buttons["Cancel"].click()
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testSettingsMenu() {
        let app = launch()
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "settings-link-Your name").firstMatch.waitForExistence(timeout: 5))
        shot(app, "settings-window")
        app.terminate()
    }

    func testAndroidCompatibilityCanBeEnabledAndDisabledAcrossRelaunch() {
        let key = "desktop-android-compatibility"
        var app = launch(["-NearbyScreen", "experiments", "-experimentalDesktopAndroidCompatibility", "NO"])
        var toggle = app.descendants(matching: .any).matching(identifier: key).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual((toggle.value as? NSNumber)?.boolValue, false)
        toggle.click()
        XCTAssertEqual((toggle.value as? NSNumber)?.boolValue, true)
        shot(app, "android-compatibility-enabled")
        app.terminate()

        app = launch(["-NearbyScreen", "experiments"])
        toggle = app.descendants(matching: .any).matching(identifier: key).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual((toggle.value as? NSNumber)?.boolValue, true)
        toggle.click()
        XCTAssertEqual((toggle.value as? NSNumber)?.boolValue, false)
        app.terminate()

        app = launch(["-NearbyScreen", "experiments"])
        toggle = app.descendants(matching: .any).matching(identifier: key).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual((toggle.value as? NSNumber)?.boolValue, false)
        app.terminate()
    }

    func testCallDeliveryFeedbackCanBeEnabledAndDisabledAcrossRelaunch() {
        let key = "desktop-call-delivery-feedback"
        var app = launch(["-NearbyScreen", "experiments", "-experimentalDesktopCallDeliveryFeedback", "NO"])
        var toggle = app.descendants(matching: .any).matching(identifier: key).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual((toggle.value as? NSNumber)?.boolValue, false)
        toggle.click()
        XCTAssertEqual((toggle.value as? NSNumber)?.boolValue, true)
        shot(app, "call-delivery-feedback-enabled")
        app.terminate()
        app = launch(["-NearbyScreen", "experiments"])
        toggle = app.descendants(matching: .any).matching(identifier: key).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual((toggle.value as? NSNumber)?.boolValue, true)
        toggle.click()
        XCTAssertEqual((toggle.value as? NSNumber)?.boolValue, false)
        app.terminate()
    }

    func testCallDiscoveryPauseCanBeEnabledAndDisabledAcrossRelaunch() {
        let key = "desktop-pause-call-discovery"
        var app = launch(["-NearbyScreen", "experiments", "-experimentalDesktopPauseCallDiscovery", "NO"])
        var toggle = app.descendants(matching: .any).matching(identifier: key).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual((toggle.value as? NSNumber)?.boolValue, false)
        toggle.click()
        XCTAssertEqual((toggle.value as? NSNumber)?.boolValue, true)
        shot(app, "call-discovery-pause-enabled")
        app.terminate()
        app = launch(["-NearbyScreen", "experiments"])
        toggle = app.descendants(matching: .any).matching(identifier: key).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual((toggle.value as? NSNumber)?.boolValue, true)
        toggle.click()
        XCTAssertEqual((toggle.value as? NSNumber)?.boolValue, false)
        app.terminate()
    }

    func testSidebarAndShortcutsLeaveNestedSettingsPages() {
        let app = launch(["-NearbyScreen", "settings"])
        let experiments = app.descendants(matching: .any).matching(identifier: "settings-link-Experiments").firstMatch
        XCTAssertTrue(reveal(experiments, in: app))
        experiments.click()
        let compatibility = app.descendants(matching: .any).matching(identifier: "desktop-android-compatibility").firstMatch
        XCTAssertTrue(compatibility.waitForExistence(timeout: 5))
        app.descendants(matching: .any).matching(identifier: "desktop-tab-calls").firstMatch.click()
        XCTAssertTrue(app.buttons["Nearby"].waitForExistence(timeout: 5))
        XCTAssertFalse(compatibility.exists)
        app.typeKey("4", modifierFlags: .command)
        let about = app.descendants(matching: .any).matching(identifier: "settings-link-About this app").firstMatch
        XCTAssertTrue(reveal(about, in: app))
        about.click()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "about-Version").firstMatch.waitForExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 5))
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Add contact"].waitForExistence(timeout: 5))
        app.buttons["Add contact"].click()
        XCTAssertTrue(app.staticTexts["Full fingerprint"].waitForExistence(timeout: 5))
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Nearby"].waitForExistence(timeout: 5))
        shot(app, "sidebar-from-nested-settings")
        app.terminate()
    }

    private func switchValue(_ element: XCUIElement) -> Bool? { (element.value as? NSNumber)?.boolValue }

    /// Each reachability switch flips, survives a relaunch and flips back (preview preferences only; Start at login
    /// uses the preview stand-in, never the real Login Items). Unit tests cover the off-by-default values.
    // Two switches per test: each round trip relaunches twice, and six in one test passed the 60 s per-test limit.
    func testMenuBarAndLoginSwitchesToggleAndPersistAcrossRelaunch() {
        checkSwitchesPersistAcrossRelaunch(["desktop-menu-bar", "desktop-start-at-login"])
    }

    func testRingWindowAndMediaActivitySwitchesToggleAndPersistAcrossRelaunch() {
        checkSwitchesPersistAcrossRelaunch(["desktop-ring-window-setting", "desktop-activity-media"])
    }

    func testAppNapAndKeepAwakeSwitchesToggleAndPersistAcrossRelaunch() {
        checkSwitchesPersistAcrossRelaunch(["desktop-no-app-nap", "desktop-keep-awake"])
    }

    private func checkSwitchesPersistAcrossRelaunch(_ keys: [String]) {
        for key in keys {
            var app = launch(["-NearbyScreen", "settings"])
            var toggle = app.descendants(matching: .any).matching(identifier: key).firstMatch
            XCTAssertTrue(reveal(toggle, in: app), key)
            guard let before = switchValue(toggle) else { XCTFail(key + " has no value"); app.terminate(); continue }
            toggle.click()
            XCTAssertEqual(switchValue(toggle), !before, key)
            if key == "desktop-keep-awake" { shot(app, "reachability-settings") }
            app.terminate()
            app = launch(["-NearbyScreen", "settings"])
            toggle = app.descendants(matching: .any).matching(identifier: key).firstMatch
            XCTAssertTrue(reveal(toggle, in: app), key)
            XCTAssertEqual(switchValue(toggle), !before, key + " after relaunch")
            toggle.click()
            XCTAssertEqual(switchValue(toggle), before, key)
            app.terminate()
        }
    }

    func testMenuBarItemOffersOpenReachableAndQuit() {
        let app = launch(["-desktopKeepRunningWithWindowClosed", "YES", "-desktopShowMenuBar", "YES"])
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 10))
        let item = app.statusItems.firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        app.staticTexts["Live nearby"].click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(app.windows.firstMatch.exists)
        item.click()
        let menu = item.descendants(matching: .menuItem)
        XCTAssertTrue(menu["Open MeshLive"].waitForExistence(timeout: 5))
        XCTAssertTrue(menu["Reachable for calls"].exists)
        XCTAssertTrue(menu["Quit MeshLive"].exists)
        // The preview has no radio and counts as ready: the state follows Allow calls, flipped here and restored.
        let reachable = menu["Reachable"].exists
        XCTAssertTrue(reachable || menu["Not reachable"].exists)
        XCTAssertEqual(item.title, reachable ? "MeshLive, Reachable" : "MeshLive, Not reachable")
        menu["Reachable for calls"].click()
        let flipped = reachable ? "MeshLive, Not reachable" : "MeshLive, Reachable"
        wait(for: [expectation(for: NSPredicate(format: "title == %@", flipped), evaluatedWith: item)], timeout: 5)
        item.click()
        XCTAssertTrue(menu["Reachable for calls"].waitForExistence(timeout: 5))
        menu["Reachable for calls"].click()
        wait(for: [expectation(for: NSPredicate(format: "title == %@", reachable ? "MeshLive, Reachable" : "MeshLive, Not reachable"),
                               evaluatedWith: item)], timeout: 5)
        item.click()
        XCTAssertTrue(menu["Open MeshLive"].waitForExistence(timeout: 5))
        menu["Open MeshLive"].click()
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 5))
        item.click()
        XCTAssertTrue(menu["Quit MeshLive"].waitForExistence(timeout: 5))
        menu["Quit MeshLive"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }

    /// Experimental ring window: hidden while MeshLive is frontmost (the call screen shows the call), shown while
    /// another app is in front, and gone again when MeshLive comes forward. No real call, ringer or notification runs.
    func testRingWindowAppearsOnlyBehindAnotherApp() {
        let app = launch(["-NearbyScreen", "call-incoming-voice", "-experimentalDesktopRingWindow", "YES"])
        XCTAssertTrue(app.buttons["Accept"].waitForExistence(timeout: 10))
        let ring = app.descendants(matching: .any).matching(identifier: "desktop-ring-view").firstMatch
        XCTAssertFalse(ring.exists)
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        XCTAssertTrue(ring.waitForExistence(timeout: 5))
        XCTAssertTrue(ring.buttons["Decline"].exists)
        XCTAssertTrue(ring.buttons["Accept"].exists)
        XCTAssertTrue(ring.staticTexts["Incoming voice call"].exists)
        let attachment = XCTAttachment(screenshot: ring.screenshot())
        attachment.name = "ring-window"; attachment.lifetime = .keepAlways; add(attachment)
        app.activate()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: ring)
        wait(for: [gone], timeout: 5)
        app.terminate()
    }
}
