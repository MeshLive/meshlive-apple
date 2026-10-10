import XCTest
@testable import NearbyCore

final class VideoRateControllerTests: XCTestCase {
    /// Replays the measured iPhone -> M31 GATT case: the link carries ~130 kbps of video, the encoder starts at
    /// 200 kbps (overshooting to ~240). The target must settle below the link rate so the queue drains.
    func testSettlesBelowTheMeasuredLinkRateAndRecovers() {
        var rc = VideoRateController(startKbps: 200, maxKbps: 200)
        var queueSeconds = 0.0           // backlog in seconds of video at the link rate
        let link = 130.0
        var history: [Int] = []
        var worstLateQueue = 0.0
        for window in 0..<30 {
            let encoded = Double(rc.targetKbps) * 1.2
            let delivered = min(link, encoded + queueSeconds * link)
            queueSeconds = max(0, queueSeconds + (encoded - delivered) / link)
            _ = rc.update(queueAge: queueSeconds, encodedKbps: encoded, deliveredKbps: delivered)
            history.append(rc.targetKbps)
            if window >= 10 { worstLateQueue = max(worstLateQueue, queueSeconds) }
        }
        XCTAssertLessThan(Double(rc.targetKbps) * 1.2, link * 1.05, "encoder output fits the link: \(history)")
        XCTAssertLessThan(worstLateQueue, 0.8, "the backlog stays bounded instead of growing to seconds: \(history)")
        XCTAssertGreaterThanOrEqual(rc.targetKbps, 60)
        // A faster link (L2CAP) lets it climb back to the requested maximum, never above.
        for _ in 0..<60 { _ = rc.update(queueAge: 0.02, encodedKbps: Double(rc.targetKbps), deliveredKbps: Double(rc.targetKbps)) }
        XCTAssertEqual(rc.targetKbps, 200)
    }

    /// The measured retest: the first window after a 9 s stall reported encoded 5 / delivered 4 kbps with a
    /// 300 ms queue. That is no evidence about the link, so the target must not collapse.
    func testStalledWindowIsNotEvidence() {
        var rc = VideoRateController(startKbps: 200, maxKbps: 200)
        XCTAssertNil(rc.update(queueAge: 0.3, encodedKbps: 5, deliveredKbps: 4))
        XCTAssertNil(rc.update(queueAge: 2.0, encodedKbps: 0, deliveredKbps: 0))
        XCTAssertEqual(rc.targetKbps, 200)
    }

    func testBoundsAndNoChangeWithoutCause() {
        var rc = VideoRateController(startKbps: 500, maxKbps: 300, minKbps: 48)
        XCTAssertEqual(rc.targetKbps, 300)
        XCTAssertNil(rc.update(queueAge: 0.2, encodedKbps: 300, deliveredKbps: 300), "middle band holds")
        for _ in 0..<20 { _ = rc.update(queueAge: 3, encodedKbps: Double(rc.targetKbps), deliveredKbps: 0) }
        XCTAssertEqual(rc.targetKbps, 48)
    }
}
