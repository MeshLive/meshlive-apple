import XCTest
@testable import NearbyCore

/// Apple's source roles behind the release gate (C1.1): a release build watches only, a DEBUG switch restores the rest.
final class LiveParityTests: XCTestCase {
    func testWithoutSourceRolesNothingOffersGoingLiveOrForwarding() {
        let gate = StreamSourceGate(sourceRoles: false)
        XCTAssertFalse(gate.allowsGoLive)
        XCTAssertFalse(gate.allowsForwarding)
        XCTAssertFalse(gate.showsSourceControls)
        XCTAssertEqual(gate.footerNotice, StreamSourceGate.laterNotice)
        XCTAssertEqual(gate.footerNotice, "Going live and passing streams on return in a later update.")
    }

    func testWithoutSourceRolesTheRelaySettingReadsOffWhateverIsStored() {
        let off = StreamSourceGate(sourceRoles: false)
        XCTAssertFalse(off.effectiveRelayForOthers(requested: true), "a stored choice never turns forwarding on")
        XCTAssertFalse(off.effectiveRelayForOthers(requested: false))
        let on = StreamSourceGate(sourceRoles: true)
        XCTAssertTrue(on.effectiveRelayForOthers(requested: true))
        XCTAssertFalse(on.effectiveRelayForOthers(requested: false))
    }

    func testWithSourceRolesEverythingIsAsBefore() {
        let gate = StreamSourceGate(sourceRoles: true)
        XCTAssertTrue(gate.allowsGoLive)
        XCTAssertTrue(gate.allowsForwarding)
        XCTAssertTrue(gate.showsSourceControls)
        XCTAssertNil(gate.footerNotice)
    }
}
