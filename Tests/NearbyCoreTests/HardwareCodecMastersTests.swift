import XCTest
@testable import NearbyCore

/// B1.6: the two Design HC masters follow `ReleaseGates.hardwareCodecs`; a DEBUG launch argument for one codec still wins.
final class HardwareCodecMastersTests: XCTestCase {
    func testWithNoOverrideBothMastersFollowTheGate() {
        let on = HardwareCodecMasters.resolve(gate: true, hevcOverride: nil, h264Override: nil)
        XCTAssertTrue(on.hevc)
        XCTAssertTrue(on.h264)
        let off = HardwareCodecMasters.resolve(gate: false, hevcOverride: nil, h264Override: nil)
        XCTAssertFalse(off.hevc)
        XCTAssertFalse(off.h264)
    }

    func testAnOverrideWinsEitherWay() {
        let one = HardwareCodecMasters.resolve(gate: false, hevcOverride: true, h264Override: false)
        XCTAssertTrue(one.hevc)
        XCTAssertFalse(one.h264)
        let other = HardwareCodecMasters.resolve(gate: true, hevcOverride: false, h264Override: true)
        XCTAssertFalse(other.hevc)
        XCTAssertTrue(other.h264)
    }

    func testOneCodecCanBeOnWhileTheOtherFollowsAClosedGate() {
        let masters = HardwareCodecMasters.resolve(gate: false, hevcOverride: true, h264Override: nil)
        XCTAssertTrue(masters.hevc)
        XCTAssertFalse(masters.h264)
    }
}
