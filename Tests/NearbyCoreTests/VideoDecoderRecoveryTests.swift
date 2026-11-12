import XCTest
@testable import NearbyCore

/// B1.5 (Android decoder stall recovery): a failing decoder never ends the call or silences the voice; it rebuilds,
/// tries the other decoder, then stops video on this phone.
final class VideoDecoderRecoveryTests: XCTestCase {
    func testThreeConsecutiveErrorsAfterAKeyFrameAreAFailure() {
        var health = VideoDecoderHealth()
        XCTAssertFalse(health.apply(.rebuilt))
        XCTAssertFalse(health.apply(.picture))
        XCTAssertFalse(health.apply(.error(keyFramePacket: false, invalidSession: false)))
        XCTAssertFalse(health.apply(.error(keyFramePacket: false, invalidSession: false)))
        XCTAssertTrue(health.apply(.error(keyFramePacket: false, invalidSession: false)))
    }

    func testErrorsBeforeTheFirstKeyFrameAreNotFailures() {
        var health = VideoDecoderHealth()
        XCTAssertFalse(health.apply(.rebuilt))
        for _ in 0..<5 { XCTAssertFalse(health.apply(.error(keyFramePacket: false, invalidSession: false))) }
    }

    func testADecodedPictureClearsTheErrorCount() {
        var health = VideoDecoderHealth()
        XCTAssertFalse(health.apply(.rebuilt))
        XCTAssertFalse(health.apply(.picture))
        XCTAssertFalse(health.apply(.error(keyFramePacket: false, invalidSession: false)))
        XCTAssertFalse(health.apply(.error(keyFramePacket: false, invalidSession: false)))
        XCTAssertFalse(health.apply(.picture))
        XCTAssertFalse(health.apply(.error(keyFramePacket: false, invalidSession: false)))
        XCTAssertFalse(health.apply(.error(keyFramePacket: false, invalidSession: false)))
        XCTAssertTrue(health.apply(.error(keyFramePacket: false, invalidSession: false)))
    }

    func testAnInvalidSessionIsAFailureAtOnce() {
        var health = VideoDecoderHealth()
        XCTAssertFalse(health.apply(.rebuilt))
        XCTAssertTrue(health.apply(.error(keyFramePacket: false, invalidSession: true)))
    }

    func testNoStallBelowTheInputCountOrTheAge() {
        var stall = VideoDecoderStallDetector()
        stall.onReset(at: 0)
        for index in 0..<59 { stall.onInput(at: 1.0 + Double(index) * 0.017) }
        XCTAssertNil(stall.check(at: 2.5, fps: 30, suspended: false), "one input short of 2*fps")
        stall.onInput(at: 2.0)
        XCTAssertNil(stall.check(at: 2.0, fps: 30, suspended: false), "60 inputs but under 1.5 s")
        XCTAssertNotNil(stall.check(at: 2.5, fps: 30, suspended: false))
    }

    func testAStallNeedsInputsWithNoOutputForOneAndAHalfSeconds() {
        var stall = VideoDecoderStallDetector()
        stall.onReset(at: 0)
        for index in 0..<9 { stall.onInput(at: Double(index) * 0.1) }
        XCTAssertNil(stall.check(at: 1.6, fps: 5, suspended: false))
        stall.onInput(at: 1.0)
        XCTAssertNotNil(stall.check(at: 1.6, fps: 5, suspended: false))
    }

    func testAnOutputClearsTheStallClock() {
        var stall = VideoDecoderStallDetector()
        stall.onReset(at: 0)
        for index in 0..<10 { stall.onInput(at: Double(index) * 0.1) }
        XCTAssertNotNil(stall.check(at: 2.0, fps: 5, suspended: false))
        stall.onOutput(at: 2.1)
        XCTAssertNil(stall.check(at: 2.2, fps: 5, suspended: false))
    }

    func testASuspendedStreamIsNeverAStall() {
        var stall = VideoDecoderStallDetector()
        stall.onReset(at: 0)
        for index in 0..<60 { stall.onInput(at: Double(index) * 0.01) }
        XCTAssertNil(stall.check(at: 2.0, fps: 30, suspended: true))
    }

    func testTheFirstFailureRebuildsTheSameDecoder() {
        var recovery = VideoDecoderRecovery()
        XCTAssertEqual(recovery.onFailure(otherDecoderExists: true), .rebuildSame)
        XCTAssertFalse(recovery.videoStopped)
    }

    func testASecondFailureTriesTheOtherDecoderWhenThereIsOne() {
        var recovery = VideoDecoderRecovery()
        XCTAssertEqual(recovery.onFailure(otherDecoderExists: true), .rebuildSame)
        XCTAssertEqual(recovery.onFailure(otherDecoderExists: true), .tryOther)
        XCTAssertFalse(recovery.videoStopped)
    }

    func testASecondFailureWithNoOtherDecoderStopsVideo() {
        var recovery = VideoDecoderRecovery()
        XCTAssertEqual(recovery.onFailure(otherDecoderExists: false), .rebuildSame)
        XCTAssertEqual(recovery.onFailure(otherDecoderExists: false), .stopVideo)
        XCTAssertTrue(recovery.videoStopped)
    }

    func testAThirdFailureStopsVideo() {
        var recovery = VideoDecoderRecovery()
        XCTAssertEqual(recovery.onFailure(otherDecoderExists: true), .rebuildSame)
        XCTAssertEqual(recovery.onFailure(otherDecoderExists: true), .tryOther)
        XCTAssertEqual(recovery.onFailure(otherDecoderExists: true), .stopVideo)
        XCTAssertTrue(recovery.videoStopped)
    }

    func testSixtyHealthyPicturesForgetEarlierFailures() {
        var recovery = VideoDecoderRecovery()
        XCTAssertEqual(recovery.onFailure(otherDecoderExists: true), .rebuildSame)
        for _ in 0..<60 { recovery.onPicture() }
        XCTAssertEqual(recovery.onFailure(otherDecoderExists: true), .rebuildSame)
    }

    func testAStopIsFinalForTheCall() {
        var recovery = VideoDecoderRecovery()
        _ = recovery.onFailure(otherDecoderExists: false)
        _ = recovery.onFailure(otherDecoderExists: false)
        XCTAssertTrue(recovery.videoStopped)
        XCTAssertEqual(recovery.onFailure(otherDecoderExists: true), .stopVideo)
        recovery.onPicture()
        XCTAssertTrue(recovery.videoStopped)
    }

    func testTheNoticesAreTheAndroidTexts() {
        XCTAssertEqual(VideoRecoveryNotice.recovering, "Recovering remote video; audio and call remain connected")
        XCTAssertEqual(VideoRecoveryNotice.stopped, "Video stopped on this phone; voice continues")
    }
}
