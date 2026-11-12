import XCTest
@testable import NearbyCore

/// B1.3: after the system asks, one decision says whether a call goes on, goes on as voice, or says what is missing.
final class CallMediaAccessTests: XCTestCase {
    private let allowed = CallMediaAccess.Access(granted: true)
    private let denied = CallMediaAccess.Access(granted: false, canAskAgain: false)
    private let notDetermined = CallMediaAccess.Access(granted: false, canAskAgain: true)
    private let restricted = CallMediaAccess.Access(granted: false, canAskAgain: false, restricted: true)

    private func decide(_ use: CallMediaAccess.Use, video: Bool = true, camera: CallMediaAccess.Access,
                        microphone: CallMediaAccess.Access = CallMediaAccess.Access(granted: true),
                        voice: Bool = true) -> CallMediaAccess.Outcome {
        CallMediaAccess.decide(use: use, video: video, camera: camera, microphone: microphone,
                               voiceWhenCameraRefused: voice)
    }

    func testAllAllowedProceeds() {
        for use in [CallMediaAccess.Use.answer, .place, .cameraOn] {
            let outcome = decide(use, camera: allowed, microphone: allowed)
            XCTAssertEqual(outcome, CallMediaAccess.Outcome(step: .proceed, missing: [], opensSettings: false))
        }
    }

    func testAnAnsweredVideoCallWithOnlyTheCameraRefusedGoesOnAsVoice() {
        let outcome = decide(.answer, camera: denied)
        XCTAssertEqual(outcome.step, .voiceInstead)
        XCTAssertEqual(outcome.missing, [.camera])
    }

    func testAPlacedVideoCallWithOnlyTheCameraRefusedGoesOnAsVoice() {
        let outcome = decide(.place, camera: denied)
        XCTAssertEqual(outcome.step, .voiceInstead)
        XCTAssertEqual(outcome.missing, [.camera])
    }

    func testTheControlArmOnlyTellsInsteadOfGoingOnAsVoice() {
        let outcome = decide(.answer, camera: denied, voice: false)
        XCTAssertEqual(outcome.step, .tell)
        XCTAssertEqual(outcome.missing, [.camera])
        XCTAssertTrue(outcome.opensSettings)
    }

    func testARefusedMicrophoneIsOnlyTold() {
        let outcome = decide(.answer, camera: allowed, microphone: denied)
        XCTAssertEqual(outcome.step, .tell)
        XCTAssertEqual(outcome.missing, [.microphone])
        XCTAssertTrue(outcome.opensSettings)
    }

    func testCameraAndMicrophoneRefusedAreBothNamedInOrder() {
        let outcome = decide(.answer, camera: denied, microphone: restricted)
        XCTAssertEqual(outcome.step, .tell)
        XCTAssertEqual(outcome.missing, [.camera, .microphone])
    }

    func testTurningTheCameraOnInACallIsTold() {
        let outcome = decide(.cameraOn, camera: denied, microphone: allowed)
        XCTAssertEqual(outcome.step, .tell)
        XCTAssertEqual(outcome.missing, [.camera])
    }

    func testAVoiceCallDoesNotNeedTheCamera() {
        let outcome = decide(.answer, video: false, camera: denied, microphone: allowed)
        XCTAssertEqual(outcome.step, .proceed)
        XCTAssertEqual(outcome.missing, [])
    }

    func testADeniedStateOffersSettingsAndANotDeterminedOneDoesNot() {
        XCTAssertEqual(decide(.answer, camera: allowed, microphone: denied).opensSettings, true)
        XCTAssertEqual(decide(.answer, camera: allowed, microphone: notDetermined).opensSettings, false)
    }

    func testRestrictedNeverOffersSettings() {
        XCTAssertEqual(decide(.answer, camera: restricted).opensSettings, false)
        XCTAssertEqual(decide(.answer, camera: allowed, microphone: restricted).opensSettings, false)
    }

    func testTheMissingPermissionsJoinWithCommasAndAnd() {
        XCTAssertEqual(MissingPermissions.join([]), "")
        XCTAssertEqual(MissingPermissions.join(["a"]), "a")
        XCTAssertEqual(MissingPermissions.join(["a", "b"]), "a and b")
        XCTAssertEqual(MissingPermissions.join(["a", "b", "c"]), "a, b and c")
        XCTAssertEqual(CallMediaAccess.text(use: .answer, missing: [.camera, .microphone]),
                       "MeshLive needs access to the camera and the microphone to answer this call.")
        XCTAssertEqual(CallMediaAccess.text(use: .place, missing: [.camera]),
                       "MeshLive needs access to the camera to make this call.")
        XCTAssertEqual(CallMediaAccess.text(use: .cameraOn, missing: [.camera]),
                       "MeshLive needs access to the camera to turn your video on.")
        XCTAssertEqual(CallMediaAccess.voiceNotice(use: .answer), "Answered with voice: camera access is off")
        XCTAssertEqual(CallMediaAccess.voiceNotice(use: .place), "Calling with voice: camera access is off")
    }
}
