import XCTest
@testable import NearbyCore

/// Android parity: display rotation while the iPhone turns, and which local media failures end a call.
final class CallParityTests: XCTestCase {
    func testTheOtherPhoneIsToldOnlyWhenTheUprightPictureChanges() {
        var rotation = CallDisplayRotation()
        XCTAssertNil(rotation.deviceTurned(.portrait, sending: true), "the header already says 0")
        XCTAssertEqual(rotation.deviceTurned(.landscapeRight, sending: true), 90, "turned clockwise: turn the picture clockwise")
        XCTAssertNil(rotation.deviceTurned(.faceUpOrDownOrUnknown, sending: true), "laid flat: keep the last upright view")
        XCTAssertNil(rotation.deviceTurned(.landscapeRight, sending: true))
        XCTAssertEqual(rotation.deviceTurned(.landscapeLeft, sending: true), 270)
        XCTAssertEqual(rotation.deviceTurned(.portraitUpsideDown, sending: true), 180)
        // Camera off: nothing is sent; turning it on sends where the phone is now.
        XCTAssertNil(rotation.deviceTurned(.portrait, sending: false))
        XCTAssertEqual(rotation.pending(sending: true), 0)
        XCTAssertNil(rotation.pending(sending: true))
    }

    func testAnotherAppHoldingAudioDoesNotEndTheCall() {
        for code in [561_017_449, 560_557_684, 561_015_905] {
            XCTAssertTrue(LocalMediaFailure.isAudioSessionContention(domain: NSOSStatusErrorDomain, code: code))
        }
        XCTAssertFalse(LocalMediaFailure.isAudioSessionContention(domain: NSOSStatusErrorDomain, code: -50), "a broken session ends it")
        XCTAssertFalse(LocalMediaFailure.isAudioSessionContention(domain: "NearbyCore.RadioError", code: 561_017_449))
    }
}
