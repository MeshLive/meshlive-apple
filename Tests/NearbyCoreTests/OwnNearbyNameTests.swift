import XCTest
@testable import NearbyCore

/// What people nearby who have not added you see for this device, as Android's OwnNearbyName.
final class OwnNearbyNameTests: XCTestCase {
    func testRotatingIdWithGeneratedNamesShowsTheChangingName() {
        let shown = OwnNearbyName.shown(reachableForCalls: true, rotatingOn: true, generatedNamesOn: true, generatedName: "mild bream")
        XCTAssertEqual(shown, .init(name: "mild bream", rotates: true))
        let line = shown.map(OwnNearbyName.line) ?? ""
        XCTAssertTrue(line.contains("mild bream") && line.contains("15 min"), "the line says the name changes")
    }

    func testStableIdentityShowsWhatStrangersSee() {
        let fixed = OwnNearbyName.shown(reachableForCalls: true, rotatingOn: false, generatedNamesOn: true, generatedName: nil)
        XCTAssertEqual(fixed, .init(name: OwnNearbyName.someoneNearby, rotates: false))
        XCTAssertFalse((fixed.map(OwnNearbyName.line) ?? "").contains("15 min"), "a stable name is not said to change")
        let unnamed = OwnNearbyName.shown(reachableForCalls: true, rotatingOn: true, generatedNamesOn: false, generatedName: nil)
        XCTAssertEqual(unnamed, .init(name: OwnNearbyName.nearbyPhone, rotates: false))
    }

    func testNothingWhileNotReachableOrBeforeTheIdIsOnAir() {
        XCTAssertNil(OwnNearbyName.shown(reachableForCalls: false, rotatingOn: true, generatedNamesOn: true, generatedName: "mild bream"))
        XCTAssertNil(OwnNearbyName.shown(reachableForCalls: true, rotatingOn: true, generatedNamesOn: true, generatedName: nil))
    }

    // Settings › Your name (Android 2026-11-04): applying the field never erases or silently replaces the name.
    func testAnEmptyFieldClearsTheName() {
        XCTAssertEqual(OwnNameEdit.outcome(typed: ""), .clear)
        XCTAssertEqual(OwnNameEdit.outcome(typed: "  \n "), .clear)
        XCTAssertEqual(OwnNameEdit.outcome(typed: "").resolved(current: "Asha"), "")
    }

    func testAnAcceptedNameIsSavedInTheFormACallCarries() {
        let edit = OwnNameEdit.outcome(typed: "  Asha   K ")
        XCTAssertEqual(edit, .save("Asha K"))
        XCTAssertNil(edit.rejection)
        let stored = edit.resolved(current: "Old")
        XCTAssertEqual(stored, "Asha K")
        XCTAssertTrue(LabelText.isCanonical(.personName, stored), "the stored name is sent unchanged in a call")
    }

    func testARejectedNameKeepsTheCurrentName() {
        for typed in [String(repeating: "x", count: 40), "Asha \u{2713}"] {
            let edit = OwnNameEdit.outcome(typed: typed)
            XCTAssertNotNil(edit.rejection, "rejected: \(typed)")
            XCTAssertEqual(edit.resolved(current: "Asha"), "Asha", "the current name stays")
            XCTAssertEqual(edit.resolved(current: ""), "", "no name stays no name")
        }
    }
}
