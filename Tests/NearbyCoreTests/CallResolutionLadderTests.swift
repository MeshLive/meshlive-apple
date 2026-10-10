import XCTest
@testable import NearbyCore

/// Port of Android CallResolutionLadderTest (same table, rungs, holds and hysteresis).
final class CallResolutionLadderTests: XCTestCase {
    let p360 = VideoResolution(640, 360), p270 = VideoResolution(480, 270), p240 = VideoResolution(426, 240), p180 = VideoResolution(320, 180)
    lazy var offered = [VideoResolution(1280, 720), p360, p270, p240, p180, VideoResolution(256, 144), VideoResolution(640, 480), VideoResolution(320, 240)]
    let vp9 = StreamProtocol.codecVP9
    private func ladder(_ codec: UInt8? = nil) -> CallResolutionLadder { CallResolutionLadder(requested: p360, offered: offered, codecId: codec ?? vp9) }

    func testWebRtcSinglecastStartLimits() {
        XCTAssertEqual(CallResolutionLadder.minStartBps(codecId: vp9, p360), 190_000)
        XCTAssertEqual(CallResolutionLadder.minStartBps(codecId: vp9, p270), 120_000)
        XCTAssertEqual(CallResolutionLadder.minStartBps(codecId: vp9, p240), 120_000)
        XCTAssertEqual(CallResolutionLadder.minStartBps(codecId: vp9, p180), 0)
        XCTAssertEqual(CallResolutionLadder.minStartBps(codecId: vp9, VideoResolution(854, 480)), 350_000)
        XCTAssertEqual(CallResolutionLadder.minStartBps(codecId: StreamProtocol.codecAV1, p360), 256_000)
        XCTAssertEqual(CallResolutionLadder.minStartBps(codecId: StreamProtocol.codecAV1, p270), 176_000)
    }

    func testRungsKeepAspectStayBelowStartAndAboveFloorOnePerBucket() {
        XCTAssertEqual(ladder().rungs, [p360, p270, p180])
        XCTAssertEqual(CallResolutionLadder(requested: p240, offered: offered, codecId: vp9).rungs, [p240, p180])
        XCTAssertFalse(CallResolutionLadder(requested: p180, offered: offered, codecId: vp9).active)
        XCTAssertEqual(CallResolutionLadder(requested: VideoResolution(640, 480), offered: offered, codecId: vp9).rungs, [VideoResolution(640, 480), VideoResolution(320, 240)])
        // The iPhone's portrait call (240x426) steps to 180x320 below 120 kbps.
        XCTAssertEqual(CallResolutionLadder(requested: VideoResolution(240, 426), offered: [VideoResolution(180, 320)], codecId: vp9).rungs,
                       [VideoResolution(240, 426), VideoResolution(180, 320)])
    }

    func testStartChoosesTheLargestRungTheStartRateSupports() {
        XCTAssertEqual(ladder().start(targetBps: 300_000, nowMs: 0).resolution, p360)
        XCTAssertEqual(ladder().start(targetBps: 150_000, nowMs: 0).resolution, p270)
        XCTAssertEqual(ladder().start(targetBps: 80_000, nowMs: 0).resolution, p180)
    }

    func testStepsDownOnlyAfterTheTargetStaysLowForTheHoldTime() {
        let l = ladder(); _ = l.start(targetBps: 300_000, nowMs: 0)
        XCTAssertNil(l.onTarget(targetBps: 150_000, nowMs: 10_000)); XCTAssertNil(l.onTarget(targetBps: 150_000, nowMs: 12_000))
        XCTAssertNil(l.onTarget(targetBps: 200_000, nowMs: 12_500))
        XCTAssertNil(l.onTarget(targetBps: 150_000, nowMs: 13_000)); XCTAssertNil(l.onTarget(targetBps: 150_000, nowMs: 15_999))
        let down = l.onTarget(targetBps: 150_000, nowMs: 16_000)
        XCTAssertEqual(down?.resolution, p270)
        XCTAssertTrue(down?.reason.hasPrefix("weak_link(targetKbps=150") ?? false)
    }

    func testAVeryLowTargetJumpsStraightToTheFloor() {
        let l = ladder(); _ = l.start(targetBps: 300_000, nowMs: 0)
        _ = l.onTarget(targetBps: 60_000, nowMs: 10_000)
        XCTAssertEqual(l.onTarget(targetBps: 60_000, nowMs: 13_000)?.resolution, p180)
        XCTAssertEqual(l.current, p180)
    }

    func testStepsUpOneRungWithHeadroomHoldAndMinimumInterval() {
        let l = ladder(); _ = l.start(targetBps: 100_000, nowMs: 0)
        XCTAssertEqual(l.current, p180)
        for t in stride(from: 0, through: 60_000, by: 1_000) { XCTAssertNil(l.onTarget(targetBps: 140_000, nowMs: 20_000 + Int64(t))) }
        XCTAssertNil(l.onTarget(targetBps: 160_000, nowMs: 100_000)); XCTAssertNil(l.onTarget(targetBps: 160_000, nowMs: 109_999))
        XCTAssertEqual(l.onTarget(targetBps: 160_000, nowMs: 110_000)?.resolution, p270)
        XCTAssertNil(l.onTarget(targetBps: 500_000, nowMs: 111_000)); XCTAssertNil(l.onTarget(targetBps: 500_000, nowMs: 121_000))
        XCTAssertNil(l.onTarget(targetBps: 500_000, nowMs: 124_999))
        XCTAssertEqual(l.onTarget(targetBps: 500_000, nowMs: 125_000)?.resolution, p360)
        XCTAssertNil(l.onTarget(targetBps: 500_000, nowMs: 200_000))
    }

    func testNoOscillationAroundOneLimit() {
        let l = ladder(); _ = l.start(targetBps: 300_000, nowMs: 0)
        var changes = 0, t: Int64 = 10_000
        for i in 0..<300 { if l.onTarget(targetBps: i % 2 == 0 ? 170_000 : 210_000, nowMs: t) != nil { changes += 1 }; t += 1_000 }
        XCTAssertEqual(changes, 0)
    }
}
