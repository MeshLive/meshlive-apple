import XCTest
@testable import NearbyCore

/// B1.4/B1.5: a promoted switch is on in a release build whatever a DEBUG control arm says; only a DEBUG build can turn
/// it off. This is the rule `LabSwitch.read` implements, kept pure so the release test does not need the app target.
final class ControlArmTests: XCTestCase {
    func testTheShippedValueIsUsedWithNoOverride() {
        XCTAssertTrue(ControlArm.resolve(shipped: true, debugOverride: nil, debugBuild: true))
        XCTAssertFalse(ControlArm.resolve(shipped: false, debugOverride: nil, debugBuild: true))
        XCTAssertTrue(ControlArm.resolve(shipped: true, debugOverride: nil, debugBuild: false))
    }

    func testADebugBuildHonoursTheControlArm() {
        XCTAssertFalse(ControlArm.resolve(shipped: true, debugOverride: false, debugBuild: true))
        XCTAssertTrue(ControlArm.resolve(shipped: false, debugOverride: true, debugBuild: true))
    }

    func testAReleaseBuildAlwaysUsesTheShippedValueWhateverTheOverride() {
        XCTAssertTrue(ControlArm.resolve(shipped: true, debugOverride: false, debugBuild: false))
        XCTAssertFalse(ControlArm.resolve(shipped: false, debugOverride: true, debugBuild: false))
    }
}
