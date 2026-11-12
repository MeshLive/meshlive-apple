import XCTest
@testable import NearbyCore

/// B1F step 5: "Video stopped on this phone" is final for the call; a later stream header never rebuilds the decoder.
final class VideoDecoderStopFinalTests: XCTestCase {
    func testAStoppedRecoveryNeverAcceptsANewStream() {
        var recovery = VideoDecoderRecovery()
        XCTAssertTrue(recovery.acceptsNewStream)
        XCTAssertEqual(recovery.onFailure(otherDecoderExists: false), .rebuildSame)
        XCTAssertEqual(recovery.onFailure(otherDecoderExists: false), .stopVideo)
        XCTAssertTrue(recovery.videoStopped)
        XCTAssertFalse(recovery.acceptsNewStream)
        recovery.onPicture()
        XCTAssertFalse(recovery.acceptsNewStream, "a picture after the stop changes nothing")
    }
}
