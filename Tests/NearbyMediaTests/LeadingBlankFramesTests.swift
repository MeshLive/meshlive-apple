import XCTest
@testable import NearbyMedia

/// The camera's first-frame check: leading black buffers are counted, and dropped only with the experiment on.
final class LeadingBlankFramesTests: XCTestCase {
    private func black() -> I420Picture {
        var p = I420Picture(width: 64, height: 48)
        for i in p.y.indices { p.y[i] = 0 }
        return p
    }
    private func real() -> I420Picture {
        var p = I420Picture(width: 64, height: 48)
        for i in p.y.indices { p.y[i] = UInt8(40 + i % 50) }
        return p
    }

    func testBlankAndRealPictures() {
        XCTAssertTrue(LeadingBlankFrames.isBlank(black()))
        XCTAssertFalse(LeadingBlankFrames.isBlank(real()))
        XCTAssertFalse(LeadingBlankFrames.isBlank(I420Picture(width: 64, height: 48)), "studio black (luma 16) is a real dark picture")
    }

    func testLeadingBlankFramesAreDroppedOnlyWithTheExperimentOn() {
        var on = LeadingBlankFrames(dropBlank: true)
        XCTAssertEqual((0..<4).map { on.shouldDrop(black(), now: Double($0) * 0.07) }, [true, true, true, true])
        XCTAssertFalse(on.shouldDrop(real(), now: 0.3), "the first real frame is sent")
        XCTAssertFalse(on.shouldDrop(black(), now: 0.4), "nothing after the first real frame is dropped")
        XCTAssertEqual(on.droppedFrames, 4)

        var off = LeadingBlankFrames(dropBlank: false)
        XCTAssertFalse(off.shouldDrop(black(), now: 0))
        XCTAssertFalse(off.shouldDrop(real(), now: 0.1))
        XCTAssertEqual(off.blankFrames, 1, "the check still counts them")
        XCTAssertTrue(off.done)
    }

    func testDroppingStopsAtTheBound() {
        var gate = LeadingBlankFrames(dropBlank: true)
        let drops = (0..<20).map { gate.shouldDrop(black(), now: Double($0) * 0.01) }
        XCTAssertEqual(drops.filter { $0 }.count, LeadingBlankFrames.maxFrames)
        var slow = LeadingBlankFrames(dropBlank: true)
        _ = slow.shouldDrop(black(), now: 0)
        XCTAssertFalse(slow.shouldDrop(black(), now: 1.5), "more than 1 s after the first frame")
    }
}
