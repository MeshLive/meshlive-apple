import XCTest

final class DesktopScreensTests: XCTestCase {
    private func launch(_ args: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        let contentSize = args.contains("-desktopContentSize") ? [] : ["-desktopContentSize", "100"]
        let fixture = args.contains("-NearbyFixture") ? [] : ["-NearbyFixture", "populated"]
        app.launchArguments = contentSize + ["-NearbyPreview", "-ApplePersistenceIgnoreState", "YES"] + fixture + args
        if !app.launchArguments.contains("-appleSourceRoles") { app.launchArguments += ["-appleSourceRoles", "YES"] }
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

    /// The README's Mac row: the invented `readme` fixture (generated names, made-up stream titles) on Calls and Live.
    /// The attachments `readme-calls` and `readme-live` are the published screenshots.
    func testReadmeFixtureCallsAndLive() {
        var app = launch(["-NearbyFixture", "readme", "-NearbyScreen", "people"])
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'artsy cascade'")).firstMatch.waitForExistence(timeout: 10))
        shot(app, "readme-calls")
        app.terminate()
        app = launch(["-NearbyFixture", "readme"])
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Village meeting'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Preview · Bluetooth and media are off"].exists)
        shot(app, "readme-live")
        app.terminate()
    }

    func testGeneratedNearbyNamesAndOwnNameUseTheBundledAndroidLists() {
        let app = launch(["-NearbyFixture", "nearby-names", "-NearbyScreen", "people"])
        let first = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "mild bream")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "amiable otter")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Asha")).firstMatch.exists)
        let own = app.descendants(matching: .any).matching(identifier: "own-nearby-name").firstMatch
        XCTAssertTrue(own.exists)
        XCTAssertTrue((own.label + " " + ((own.value as? String) ?? "")).localizedCaseInsensitiveContains("mild bream"),
                      "the Calls list says which name people nearby see for this Mac")
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
        XCTAssertTrue(app.staticTexts["onboarding-title-0"].waitForExistence(timeout: 5))
        shot(app, "onboarding-welcome")
        app.buttons["Next"].click()
        XCTAssertTrue(app.staticTexts["onboarding-title-1"].waitForExistence(timeout: 5))
        shot(app, "onboarding-features")
        app.buttons["Next"].click()
        XCTAssertTrue(app.staticTexts["onboarding-title-2"].waitForExistence(timeout: 5), "the terms page")
        XCTAssertTrue(app.buttons["terms-agree"].exists)
        shot(app, "onboarding-terms")
        app.buttons["terms-agree"].click()
        XCTAssertTrue(app.staticTexts["onboarding-title-3"].waitForExistence(timeout: 5))
        for title in ["Bluetooth", "Microphone", "Notifications"] {
            XCTAssertTrue(app.staticTexts[title].exists)
        }
        XCTAssertFalse(app.staticTexts["Camera"].exists, "the camera is asked at the first video use")
        let requests = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "permission-"))
        XCTAssertEqual(requests.count, 0, "one Continue, no per-permission buttons")
        shot(app, "onboarding-permissions")
        app.buttons["permissions-continue"].click()
        XCTAssertTrue(app.staticTexts["onboarding-title-4"].waitForExistence(timeout: 5), "the preview advances without prompting")
        shot(app, "onboarding-ready")
        app.buttons["Start"].click()
        let live = app.buttons["desktop-tab-live"]
        XCTAssertTrue(live.waitForExistence(timeout: 5))
        XCTAssertEqual(live.value as? String, "Selected")
        shot(app, "live")
        app.terminate()
    }

    /// Android WifiAdvicePolicy on the Mac: on 2.4 GHz Wi-Fi a video call asks first; Continue anyway places it, and the
    /// next video call that day does not ask again.
    func testWifiAdviceAsksOnceBeforeAVideoCall() {
        let app = launch(["-NearbyScreen", "people", "-NearbyWifiBand", "2.4"])
        let person = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "person-")).firstMatch
        XCTAssertTrue(person.waitForExistence(timeout: 8))
        person.click()
        XCTAssertTrue(app.buttons["Video call"].waitForExistence(timeout: 5))
        app.buttons["Video call"].click()
        XCTAssertTrue(app.buttons["Continue anyway"].waitForExistence(timeout: 5), "2.4 GHz: asks before video")
        XCTAssertTrue(app.buttons["Open Wi-Fi settings"].exists)
        shot(app, "wifi-advice")
        app.buttons["Continue anyway"].click()
        // Preview cannot reach a real peer: the notice shows that the call was placed.
        let notice = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", "Couldn't reach ", "Couldn't reach ")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 8), "Continue anyway goes on with the call")
        app.buttons["Dismiss"].firstMatch.click()
        person.click()
        XCTAssertTrue(app.buttons["Video call"].waitForExistence(timeout: 5))
        app.buttons["Video call"].click()
        XCTAssertFalse(app.buttons["Continue anyway"].waitForExistence(timeout: 2), "answered: not again today")
        app.terminate()
    }

    func testCallsChooseType() {
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
            let notice = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", "Couldn't reach ", "Couldn't reach ")).firstMatch
            XCTAssertTrue(notice.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Call again"].exists, "a failed call offers Call again")
            app.buttons["Dismiss"].firstMatch.click()
            if key == "a" {
                app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "person-")).firstMatch.click()
                XCTAssertTrue(app.buttons["Video call"].waitForExistence(timeout: 5))
            }
        }
        app.terminate()
    }

    /// Calls › Nearby: Control-click offers Android's row menu, and a copied ID asks before the call.
    func testNearbyRowMenuAndCopiedIdPrompt() {
        let app = launch(["-NearbyScreen", "people", "-NearbyFixtureCopiedId", "1"])
        let row = app.descendants(matching: .any).matching(identifier: "person-0102030405a8").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()
        XCTAssertTrue(app.menuItems["Add contact"].firstMatch.waitForExistence(timeout: 4))
        XCTAssertTrue(app.menuItems["Block"].firstMatch.exists)
        app.typeKey(.escape, modifierFlags: [])
        row.click()
        XCTAssertTrue(app.buttons["Voice call"].waitForExistence(timeout: 5))
        app.buttons["Voice call"].click()
        XCTAssertTrue(app.buttons["Call anyway"].waitForExistence(timeout: 5), "a call to a copied ID asks once more")
        shot(app, "copied-id")
        app.buttons["Cancel"].firstMatch.click()
        app.terminate()
    }

    /// Recent: a history this Mac cannot open offers Clear history.
    func testUnreadableHistoryCanBeCleared() {
        let app = launch(["-NearbyScreen", "people", "-NearbyFixtureRecentUnreadable", "1"])
        XCTAssertTrue(app.buttons["Recent"].waitForExistence(timeout: 5))
        app.buttons["Recent"].click()
        let unreadable = app.buttons["recentUnreadable"].firstMatch
        XCTAssertTrue(unreadable.waitForExistence(timeout: 5))
        unreadable.click()
        XCTAssertTrue(app.buttons["Clear history"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Clear history"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "recentEmpty").firstMatch.waitForExistence(timeout: 5))
        shot(app, "recent-cleared")
        app.terminate()
    }

    func testContactStaysUntilOpenNearby() {
        let app = launch(["-NearbyScreen", "contacts", "-NearbyFixtureReach", "recognisable"])
        XCTAssertTrue(app.buttons["Voice call Asha"].waitForExistence(timeout: 5))
        app.buttons["Voice call Asha"].click()
        let heading = app.staticTexts["Asha is not found nearby yet"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
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

    /// Contacts on the Mac: the contact opens its sheet with Android's rows; Use it as my label renames once.
    func testContactSheetRowsAndClaimOffer() {
        let app = launch(["-NearbyScreen", "contacts", "-NearbyFixtureReach", "recognisable"])
        let ravi = app.descendants(matching: .any).matching(identifier: "contactRow-Ravi").firstMatch
        XCTAssertTrue(ravi.waitForExistence(timeout: 5))
        ravi.click()
        for id in ["contactScanConfirm", "contactRename", "contactBlock", "contactReport", "contactForget", "contactUseClaim"] {
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: id).firstMatch.waitForExistence(timeout: 4), id)
        }
        shot(app, "contact-sheet")
        app.descendants(matching: .any).matching(identifier: "contactUseClaim").firstMatch.click()
        let renamed = app.staticTexts.matching(NSPredicate(format: "identifier == 'contactSheetName' AND (label == 'Ravi Kumar' OR value == 'Ravi Kumar')")).firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 4))
        app.buttons["Done"].firstMatch.click()
        app.terminate()
    }

    func testRadioJoinPaneCanLeave() {
        let app = launch(["-NearbyScreen", "radio"])
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Audio only"].waitForExistence(timeout: 5))
        shot(app, "radio-join-pane")
        app.buttons["Stop"].click()
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testAboutShowsBuildAndRealLinkedCodecs() {
        let app = launch(["-NearbyScreen", "about"])
        for title in ["Version", "Source", "Video encode", "Voice"] {
            let row = app.descendants(matching: .any).matching(identifier: "about-" + title).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), title)
            XCTAssertTrue(row.label.hasPrefix(title + ": "))
            XCTAssertGreaterThan(row.label.count, title.count + 2)
        }
        // The shipped hardware-codec gate (on since 2026-11-12) adds the Mac's hardware encoders to the software VP9.
        let encode = app.descendants(matching: .any).matching(identifier: "about-Video encode").firstMatch.label
        for codec in ["VP9, software", "HEVC, hardware", "H.264, hardware"] {
            XCTAssertTrue(encode.contains(codec), "About names \(codec): \(encode)")
        }
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
        for (screen, controls) in [("onboarding", ["Next", "Skip"]), ("call-incoming", ["Decline", "Voice", "Accept"]), ("radio", ["Stop"]), ("broadcast-radio", ["Mute", "Pause", "End"])] {
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
                XCTAssertTrue(app.buttons["desktop-tab-live"].waitForExistence(timeout: 5))
                XCTAssertEqual(app.buttons["desktop-tab-live"].value as? String, "Selected")
            }
            app.terminate()
        }
    }

    func testTypedWipeCanCancelWithoutErasing() {
        let app = launch(["-NearbyScreen", "settings"])
        XCTAssertTrue(reveal(app.buttons["Delete everything"], in: app))
        app.buttons["Delete everything"].click()
        let erase = app.windows.buttons["Delete everything"]
        XCTAssertTrue(erase.waitForExistence(timeout: 5))
        XCTAssertFalse(erase.isEnabled)
        let field = app.windows.textFields.firstMatch
        XCTAssertTrue(field.exists)
        field.click(); field.typeText("DELETE")
        XCTAssertTrue(erase.isEnabled)
        shot(app, "typed-wipe")
        app.windows.buttons["Cancel"].click()
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 5))
        app.terminate()
    }

    /// Settings › Your name (Android 2026-11-04): a rejected name keeps the current name when you leave the page.
    func testYourNameRejectedNameKeepsTheCurrentName() {
        let app = launch(["-NearbyScreen", "settings"])
        func openName() -> XCUIElement {
            let row = app.descendants(matching: .any).matching(identifier: "settings-link-Your name").firstMatch
            XCTAssertTrue(reveal(row, in: app), "Your name row")
            row.click()
            let field = app.descendants(matching: .any).matching(identifier: "yourNameField").firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5), "name field")
            return field
        }
        func replace(_ field: XCUIElement, with text: String) {
            field.click()
            field.typeKey("a", modifierFlags: .command)
            field.typeKey(.delete, modifierFlags: [])
            if !text.isEmpty { field.typeText(text) }
        }
        func leave() {
            app.typeKey("1", modifierFlags: .command)
            XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 5))
            app.typeKey("4", modifierFlags: .command)
        }
        var field = openName()
        replace(field, with: "Asha")
        leave()
        field = openName()
        XCTAssertEqual(field.value as? String, "Asha", "an accepted name is saved")
        replace(field, with: String(repeating: "x", count: 40))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "yourNameRejected").firstMatch.waitForExistence(timeout: 3),
                      "the reason shows while typing")
        leave()
        field = openName()
        XCTAssertEqual(field.value as? String, "Asha", "a rejected name keeps the current name")
        replace(field, with: "")
        leave()
        app.terminate()
    }

    /// One name (Android 2026-11-04): "Who sees my name" appears once a name is set and keeps the choice.
    func testWhoSeesMyNameFollowsTheNameAndKeepsTheChoice() {
        let app = launch(["-NearbyScreen", "settings"])
        let nameRow = app.descendants(matching: .any).matching(identifier: "settings-link-Your name").firstMatch
        XCTAssertTrue(reveal(nameRow, in: app))
        nameRow.click()
        let field = app.descendants(matching: .any).matching(identifier: "yourNameField").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText("Asha")
        // Leave the page the way the Mac Your-name test does (another tab, then Settings again): it applies the name.
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 5))
        app.typeKey("4", modifierFlags: .command)
        let audience = app.descendants(matching: .any).matching(identifier: "settings-link-Who sees my name").firstMatch
        XCTAssertTrue(reveal(audience, in: app), "shown while a name is set")
        audience.click()
        let verified = app.descendants(matching: .any).matching(identifier: "namesAudience-verified").firstMatch
        XCTAssertTrue(verified.waitForExistence(timeout: 5))
        verified.click()
        shot(app, "who-sees-my-name")
        app.terminate()
        let again = launch(["-NearbyScreen", "settings"])
        let row = again.descendants(matching: .any).matching(identifier: "settings-link-Who sees my name").firstMatch
        XCTAssertTrue(reveal(row, in: again))
        row.click()
        XCTAssertTrue(again.descendants(matching: .any).matching(identifier: "namesAudience-verified").firstMatch.isSelected,
                      "the choice is kept across a relaunch")
        again.descendants(matching: .any).matching(identifier: "namesAudience-everyone").firstMatch.click()
        again.terminate()
    }

    /// Title bar (Android view_status_chip): ready by default in the preview, Hidden with Allow calls off, on a tab and
    /// on a pushed page; a tap opens the status sheet.
    func testStatusChipFollowsAllowCallsAndOpensTheSheet() {
        var app = launch(["-NearbyScreen", "settings"])
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "statusChip-ready").firstMatch.waitForExistence(timeout: 8))
        app.terminate()
        app = launch(["-NearbyScreen", "settings", "-availableForCalls", "NO"])
        let hidden = app.descendants(matching: .any).matching(identifier: "statusChip-hidden").firstMatch
        XCTAssertTrue(hidden.waitForExistence(timeout: 8), "Allow calls off shows Hidden")
        shot(app, "status-hidden")
        hidden.click()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "status-row-calls").firstMatch.waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.click()
        let privacy = app.descendants(matching: .any).matching(identifier: "settings-link-Privacy").firstMatch
        XCTAssertTrue(reveal(privacy, in: app))
        privacy.click()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "statusChip-hidden").firstMatch.waitForExistence(timeout: 5),
                      "the page's title row has the chip")
        shot(app, "privacy-title-row")
        app.terminate()
    }

    func testSettingsMenu() {
        let app = launch()
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "settings-link-Your name").firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, 1, "Cmd+, opens Settings in the main window, not a second window")
        shot(app, "settings-window")
        app.terminate()
    }

    /// A launch argument arrives as the string "NO"; the documented control arm must still turn a default-on switch off.
    func testLaunchArgumentNoTurnsOffADefaultOnSwitch() {
        let app = launch(["-NearbyScreen", "experiments", "-manualVideo", "YES", "-relayChildMediaAge", "NO"])
        let toggle = app.descendants(matching: .any).matching(identifier: "Relay: slow viewers skip to keyframes").firstMatch
        XCTAssertTrue(reveal(toggle, in: app))
        XCTAssertEqual((toggle.value as? NSNumber)?.boolValue, false)
        app.terminate()
    }

    /// Rotating IDs are always on (2026-11-04): Privacy offers Reset nearby recognition without any switch, and the
    /// DEBUG control arm still turns rotating IDs off.
    func testResetNearbyRecognitionNeedsNoSwitchAndTheControlArmStillWorks() {
        var app = launch(["-NearbyScreen", "privacy"])
        let reset = app.descendants(matching: .any).matching(identifier: "resetPresenceKey").firstMatch
        XCTAssertTrue(reveal(reset, in: app), "Reset nearby recognition is offered by default")
        shot(app, "privacy-default")
        app.terminate()
        app = launch(["-NearbyScreen", "privacy", "-experimentalRotatingIds", "NO"])
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "quickWipeToggle").firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "resetPresenceKey").firstMatch.exists)
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
        let compatibility = app.descendants(matching: .any).matching(identifier: "desktop-call-delivery-feedback").firstMatch
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
        XCTAssertTrue(app.buttons["Show my code"].waitForExistence(timeout: 5))
        app.buttons["Show my code"].click()
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
        checkSwitchesPersistAcrossRelaunch(["desktop-ring-window-setting", "desktop-activity-media"], screen: "experiments")
    }

    func testAppNapAndKeepAwakeSwitchesToggleAndPersistAcrossRelaunch() {
        checkSwitchesPersistAcrossRelaunch(["desktop-no-app-nap"], screen: "experiments")
        checkSwitchesPersistAcrossRelaunch(["desktop-keep-awake"])
    }

    /// Call blocking (Android): Block unknown callers on Privacy toggles and persists; it is off by default.
    func testBlockUnknownCallersTogglesAndPersistsAcrossRelaunch() {
        checkSwitchesPersistAcrossRelaunch(["blockUnknownCallers"], screen: "privacy")
    }

    /// Show names on lock screen on Privacy toggles and persists; it is off by default.
    func testShowNamesOnLockScreenTogglesAndPersistsAcrossRelaunch() {
        checkSwitchesPersistAcrossRelaunch(["lockScreenNames"], screen: "privacy")
    }

    /// Decision 2026-11-06 (as Android): with Manual video settings off (the default), the Experiments relay rows are
    /// shown, toggle, and keep their choice across a relaunch.
    func testExperimentRowsPersistWithoutManualVideo() {
        checkSwitchesPersistAcrossRelaunch(["Relay: slow viewers skip to keyframes", "Relayed calls"], screen: "experiments",
                                           extraArguments: ["-appleSourceRoles", "YES"])
    }

    /// Video quality switches toggle and persist (fill, temperature, heat limit, freeze warning).
    func testVideoQualitySwitchesToggleAndPersistAcrossRelaunch() {
        checkSwitchesPersistAcrossRelaunch(["videoFill", "showTemperature", "lowerQualityWhenHot", "viewerFreezeWarning"], screen: "video")
    }

    /// Manual video settings toggles and persists; Connection shows what the next call sends (Android's place).
    func testManualVideoSwitchPersistsAndShowsTheNextCall() {
        checkSwitchesPersistAcrossRelaunch(["manualVideo"], screen: "manual")
        let app = launch(["-NearbyScreen", "connection"])
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "videoNextCall").firstMatch.waitForExistence(timeout: 5))
        shot(app, "connection-next-call")
        app.terminate()
    }

    /// Fill screen with video is on by default on the Mac too (owner 2026-11-05).
    func testFillScreenWithVideoIsOnByDefault() {
        let app = launch(["-NearbyScreen", "video"])
        let toggle = app.descendants(matching: .any).matching(identifier: "videoFill").firstMatch
        XCTAssertTrue(reveal(toggle, in: app))
        XCTAssertEqual((toggle.value as? NSNumber)?.boolValue, true)
        app.terminate()
    }

    /// Help and feedback > Export diagnostics on the Mac: the text, without the fixture's names or IDs.
    func testExportDiagnosticsShowsATextWithoutNamesOrIDs() {
        let app = launch(["-NearbyScreen", "help"])
        let export = app.descendants(matching: .any).matching(identifier: "exportDiagnostics").firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 8))
        export.click()
        let shown = app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'app_version' OR label CONTAINS 'app_version'")).firstMatch
        XCTAssertTrue(shown.waitForExistence(timeout: 5))
        let content = "\(shown.label) \(shown.value ?? "")"
        for leaked in ["Asha", "a1b2c3d4e5f6", "0102030405a8", "112233445566"] { XCTAssertFalse(content.contains(leaked), leaked) }
        shot(app, "export-diagnostics")
        app.buttons["Done"].click()
        app.terminate()
    }

    /// Decline and block and Report are offered only for a caller that showed its real key.
    func testOnlyARealKeyCallerCanBeDeclinedAndBlocked() {
        var app = launch(["-NearbyScreen", "call-incoming"])
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "declineAndBlock").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "declineAndReport").firstMatch.exists)
        app.terminate()
        app = launch(["-NearbyScreen", "call-incoming-voice"])
        XCTAssertTrue(app.buttons["Decline"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "declineAndBlock").firstMatch.exists)
        app.terminate()
    }

    /// P6-A1: an authenticated callee link that has not rung shows no call screen.
    func testNoCallScreenBeforeTheRing() {
        let app = launch(["-NearbyScreen", "call-connecting-callee"])
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Accept"].exists)
        XCTAssertFalse(app.buttons["Decline"].exists)
        app.terminate()
    }

    /// P6-A1: the call screen appears when the Invite arrives after `call` was already set.
    func testCallScreenAppearsWhenTheRingArrives() {
        let app = launch(["-NearbyScreen", "call-connecting-callee-rings"])
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Decline"].exists, "no call screen before the Invite")
        XCTAssertTrue(app.buttons["Decline"].waitForExistence(timeout: 5), "the ringing call screen appears")
        app.terminate()
    }

    /// Android HomeLayoutTest on the Mac: End (or Cancel) is the middle control of every call and live row.
    func testEndIsTheMiddleControlOfEveryCallAndLiveRow() {
        for (screen, end) in [("call", "callEnd"), ("call-active", "callEnd"), ("call-active-video", "callEnd"),
                              ("broadcast-video", "liveEnd"), ("broadcast-radio", "liveEnd")] {
            let app = launch(["-NearbyScreen", screen])
            let button = app.descendants(matching: .any).matching(identifier: end).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 8), "\(screen): End")
            let others = ["callFlip", "liveFlip"].map { app.descendants(matching: .any).matching(identifier: $0).firstMatch }
            if screen == "call-active" { XCTAssertFalse(others[0].isEnabled, "Flip keeps its slot but does nothing with the camera off") }
            shot(app, "end-in-the-middle-\(screen)")
            app.terminate()
        }
    }

    /// Relay video for others paused by the battery shows Relay paused in the title bar (Android relayAutoPaused).
    func testRelayPausedShowsInTheStatusChip() {
        var app = launch(["-NearbyScreen", "settings", "-experimentalRelayForOthers", "YES", "-NearbyFixtureRelayPaused", "1"])
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "statusChip-relayPaused").firstMatch.waitForExistence(timeout: 8))
        shot(app, "status-relay-paused")
        app.terminate()
        app = launch(["-NearbyScreen", "settings", "-experimentalRelayForOthers", "YES", "-relayBatteryPause", "NO"])
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "statusChip-ready").firstMatch.waitForExistence(timeout: 8))
        app.terminate()
    }

    /// Android "Calls unavailable": a call service that was never hosted shows Calls unavailable (not Ready), and the sheet
    /// says why and offers Bluetooth settings; the control arm shows Ready and Allow calls off stays Hidden (a choice).
    func testCallsUnavailableShowsInTheStatusChip() {
        var app = launch(["-NearbyScreen", "settings", "-NearbyFixtureCallsUnavailable", "1"])
        let chip = app.descendants(matching: .any).matching(identifier: "statusChip-callsUnavailable").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 8))
        shot(app, "status-calls-unavailable")
        chip.click()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "status-row-calls").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "status-bluetooth-settings").firstMatch.exists,
                      "the sheet offers the fix")
        shot(app, "status-sheet-calls-unavailable")
        app.buttons["Done"].firstMatch.click()
        app.terminate()
        app = launch(["-NearbyScreen", "settings", "-NearbyFixtureCallsUnavailable", "1", "-callsUnavailableStatus", "NO"])
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "statusChip-ready").firstMatch.waitForExistence(timeout: 8),
                      "the control arm keeps Ready")
        app.terminate()
        app = launch(["-NearbyScreen", "settings", "-NearbyFixtureCallsUnavailable", "1", "-availableForCalls", "NO"])
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "statusChip-hidden").firstMatch.waitForExistence(timeout: 8),
                      "Allow calls off is Hidden, never Calls unavailable")
        app.terminate()
    }

    /// Android Link health on the Mac: call info shows the connection and the sound bitrate for a voice call too.
    func testCallInfoShowsTheConnectionAndSoundForAVoiceCall() {
        let app = launch(["-NearbyScreen", "call-active"])
        let info = app.buttons["Call info: encryption and verification"].firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 8))
        info.click()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "callConnection").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "callSound").firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "callVideoRequested").firstMatch.exists, "a voice call has no video rows")
        shot(app, "call-info-voice")
        app.terminate()
    }

    /// Android End live on the Mac: with a viewer, End asks first.
    func testEndLiveAsksWithAViewer() {
        let app = launch(["-NearbyScreen", "broadcast-video", "-NearbyFixtureViewers", "2"])
        let end = app.descendants(matching: .any).matching(identifier: "liveEnd").firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 8))
        end.click()
        XCTAssertTrue(app.buttons["End live"].firstMatch.waitForExistence(timeout: 4))
        shot(app, "end-live-confirm")
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(end.waitForExistence(timeout: 2))
        app.terminate()
    }

    /// The audio-only reminder with a 2-second unit: Keep going keeps the broadcast; unanswered, it stops and says so.
    func testRadioReminderKeepsGoingWhenAnsweredAndStopsWhenNot() {
        let app = launch(["-NearbyScreen", "broadcast-radio", "-NearbyRadioReminderUnit", "2"])
        let keep = app.buttons["Keep going"]
        XCTAssertTrue(keep.waitForExistence(timeout: 20), "reminder after 12 s without a listener")
        shot(app, "radio-reminder")
        keep.click()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "liveEnd").firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Keep going"].waitForExistence(timeout: 20), "asks again")
        XCTAssertTrue(app.buttons["OK"].waitForExistence(timeout: 15), "unanswered: the stopped dialog")
        shot(app, "radio-reminder-stopped")
        app.buttons["OK"].click()
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 5))
        app.terminate()
    }

    private func checkSwitchesPersistAcrossRelaunch(_ keys: [String], screen: String = "settings", extraArguments: [String] = []) {
        for key in keys {
            var app = launch(["-NearbyScreen", screen] + extraArguments)
            var toggle = app.descendants(matching: .any).matching(identifier: key).firstMatch
            XCTAssertTrue(reveal(toggle, in: app), key)
            guard let before = switchValue(toggle) else { XCTFail(key + " has no value"); app.terminate(); continue }
            toggle.click()
            XCTAssertEqual(switchValue(toggle), !before, key)
            if key == "desktop-keep-awake" { shot(app, "reachability-settings") }
            app.terminate()
            app = launch(["-NearbyScreen", screen] + extraArguments)
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
