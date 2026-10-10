import XCTest

/// Device scenarios with a screenshot at every step (XCTAttachment, kept always), run over SSH through
/// `bash Scripts/gui-run.sh uitest <scenario> [args]` (Scripts/run-uitest.sh). Parameters arrive as
/// `TEST_RUNNER_NEARBY_*` environment variables, which xcodebuild forwards without the prefix:
/// NEARBY_TARGET (handle, short handle or "first"), NEARBY_CALL_TYPE (voice|video), NEARBY_HOLD_SECONDS.
final class ScenarioTests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-NearbyAvailable", "1"]
        // First-run permission prompts (microphone, camera, Bluetooth): allow.
        addUIInterruptionMonitor(withDescription: "Permissions") { alert in
            for title in ["Allow", "OK", "Allow While Using App"] where alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            return false
        }
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func note(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Launch, Home, then the people list with the visible peers written to an attachment.
    func testPeopleList() {
        app.launch(); sleep(2); shot("01-home")
        app.buttons["Call someone"].tap()
        sleep(UInt32(env["NEARBY_SCAN_SECONDS"].flatMap(UInt32.init) ?? 8))
        shot("02-people")
        let names = app.cells.allElementsBoundByIndex.map { $0.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ") }
        note("people.txt", names.isEmpty ? "(nobody visible)" : names.joined(separator: "\n"))
    }

    /// Call NEARBY_TARGET (voice or video), hold NEARBY_HOLD_SECONDS after it connects, hang up.
    func testCall() throws {
        let target = env["NEARBY_TARGET"] ?? "first"
        let type = env["NEARBY_CALL_TYPE"] ?? "voice"
        let hold = Double(env["NEARBY_HOLD_SECONDS"] ?? "20") ?? 20
        app.launch(); sleep(2); shot("01-home")
        app.buttons["Call someone"].tap()
        let prefix = type == "video" ? "Video call " : "Voice call "
        let predicate = target == "first" ? NSPredicate(format: "label BEGINSWITH %@", prefix)
            : NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS[c] %@", prefix, String(target.prefix(5)))
        let button = app.buttons.matching(predicate).firstMatch
        guard button.waitForExistence(timeout: 60) else { shot("02-not-found"); XCTFail("\(target) not listed within 60 s"); return }
        shot("02-people")
        button.tap()
        app.tap() // lets the interruption monitor answer a permission prompt
        sleep(3); shot("03-calling")
        let end = app.buttons["End"]
        guard end.waitForExistence(timeout: 45) else { shot("04-not-connected"); XCTFail("The call did not connect"); return }
        shot("04-connected")
        let started = Date()
        var index = 0
        while Date().timeIntervalSince(started) < hold {
            sleep(UInt32(min(10, max(1, hold - Date().timeIntervalSince(started)))))
            index += 1; shot(String(format: "05-active-%02d", index))
        }
        end.tap()
        sleep(2); shot("06-ended")
    }
}
