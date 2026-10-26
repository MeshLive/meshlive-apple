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
}
