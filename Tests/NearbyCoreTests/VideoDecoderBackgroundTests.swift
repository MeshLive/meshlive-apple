import XCTest
@testable import NearbyCore

/// B1F step 3: an invalid session while the app is backgrounded asks for one silent rebuild at foreground and never
/// counts as a failure; the first foreground key frame after that rebuild lets a later background period ask again.
final class VideoDecoderBackgroundTests: XCTestCase {
    func testBackgroundInvalidSessionsNeverCountAsFailures() {
        var recovery = VideoDecoderRecovery()
        XCTAssertEqual(recovery.onFailure(otherDecoderExists: true), .rebuildSame)
        XCTAssertEqual(recovery.failureCount, 1)
        XCTAssertTrue(recovery.onBackgroundInvalidSession())
        XCTAssertEqual(recovery.failureCount, 1, "a background invalid session is not a counted failure")
        XCTAssertFalse(recovery.onBackgroundInvalidSession(), "one silent rebuild for one background period")
        XCTAssertEqual(recovery.failureCount, 1)
    }

    func testTheSilentRebuildIsTakenOnceAndTheFirstForegroundKeyFrameResets() {
        var recovery = VideoDecoderRecovery()
        XCTAssertTrue(recovery.onBackgroundInvalidSession())
        XCTAssertTrue(recovery.takeSilentRebuild())
        XCTAssertFalse(recovery.takeSilentRebuild())
        XCTAssertFalse(recovery.onBackgroundInvalidSession(), "no second rebuild before a foreground key frame")
        recovery.onForegroundKeyFrame()
        XCTAssertTrue(recovery.onBackgroundInvalidSession(), "the next background period may ask again")
        XCTAssertEqual(recovery.failureCount, 0, "background errors never touched the real ladder")
    }
}
