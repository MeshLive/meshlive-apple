import XCTest
@testable import NearbyCore

/// B1F step 4: a decoder failure needs a key frame that arrived and failed, or three errors after a good key frame.
/// Ordinary loss before the next key frame never climbs the recovery ladder.
final class VideoDecoderLossTests: XCTestCase {
    func testALostFrameAndFailingDeltasBeforeAGoodKeyFrameAreNotAFailure() {
        var health = VideoDecoderHealth()
        XCTAssertFalse(health.apply(.rebuilt))
        for _ in 0..<5 { XCTAssertFalse(health.apply(.error(keyFramePacket: false, invalidSession: false))) }
        XCTAssertFalse(health.apply(.keyFrame), "the good key frame clears the loss")
        XCTAssertFalse(health.apply(.picture))
    }

    func testAKeyFrameThatFailsToDecodeIsAFailure() {
        var health = VideoDecoderHealth()
        XCTAssertFalse(health.apply(.rebuilt))
        XCTAssertTrue(health.apply(.error(keyFramePacket: true, invalidSession: false)))
    }

    func testWaitingForKeyFrameInputsBeforeTheFirstKeyFrameAfterARebuildAreNotCounted() {
        var health = VideoDecoderHealth()
        XCTAssertFalse(health.apply(.rebuilt))
        for _ in 0..<10 { XCTAssertFalse(health.apply(.error(keyFramePacket: false, invalidSession: false))) }
    }

    func testAKeyFrameArrivedClearsTheErrorsBeforeIt() {
        var health = VideoDecoderHealth()
        XCTAssertFalse(health.apply(.rebuilt))
        XCTAssertFalse(health.apply(.picture))
        XCTAssertFalse(health.apply(.error(keyFramePacket: false, invalidSession: false)))
        XCTAssertFalse(health.apply(.error(keyFramePacket: false, invalidSession: false)))
        XCTAssertFalse(health.apply(.keyFrame), "a good key frame clears the run")
        XCTAssertFalse(health.apply(.error(keyFramePacket: false, invalidSession: false)))
        XCTAssertFalse(health.apply(.error(keyFramePacket: false, invalidSession: false)))
        XCTAssertTrue(health.apply(.error(keyFramePacket: false, invalidSession: false)))
    }
}
