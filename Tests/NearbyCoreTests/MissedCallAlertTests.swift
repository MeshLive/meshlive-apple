import XCTest
@testable import NearbyCore

/// Missed-call notifications as Android's MissedCallNotification: who counts as missed, one per caller, a count.
final class MissedCallAlertTests: XCTestCase {
    func testOnlyAnUnansweredIncomingCallThatWasNotDeclinedIsMissed() {
        XCTAssertTrue(MissedCallAlert.isMissed(incoming: true, rang: true, wasActive: false, declinedHere: false))
        XCTAssertFalse(MissedCallAlert.isMissed(incoming: true, rang: true, wasActive: true, declinedHere: false), "answered")
        XCTAssertFalse(MissedCallAlert.isMissed(incoming: true, rang: true, wasActive: false, declinedHere: true), "declined here")
        XCTAssertFalse(MissedCallAlert.isMissed(incoming: false, rang: false, wasActive: false, declinedHere: false), "our own call")
        XCTAssertFalse(MissedCallAlert.isMissed(incoming: true, rang: false, wasActive: false, declinedHere: false),
                       "a link that failed before ringing was never shown as a call")
    }

    func testEachCallerHasItsOwnNotificationAndCount() {
        XCTAssertNotEqual(MissedCallAlert.identifier(prefixHex: "a1b2c3d4e5f6"), MissedCallAlert.identifier(prefixHex: "0102030405a8"))
        XCTAssertEqual(MissedCallAlert.identifier(prefixHex: "A1B2C3D4E5F6"), MissedCallAlert.identifier(prefixHex: "a1b2c3d4e5f6"))
        XCTAssertEqual(MissedCallAlert.nextCount(stillShowing: true, previous: 2), 3)
        XCTAssertEqual(MissedCallAlert.nextCount(stillShowing: false, previous: 2), 1, "a dismissed notification starts over")
    }

    func testTitleNamesOnlyAKnownCallerAndCountsCalls() {
        let named = MissedCallAlert.title(peerName: "Asha", stranger: false, count: 3)
        XCTAssertTrue(named.contains("Asha") && named.contains("3"))
        XCTAssertFalse(MissedCallAlert.title(peerName: "Gold Fox", stranger: true, count: 1).contains("Gold Fox"),
                       "a throwaway-key caller has no name to show")
        let hostile = String(repeating: "x", count: 200) + "\u{202E}"
        XCTAssertLessThan(MissedCallAlert.title(peerName: hostile, stranger: false, count: 1).count, 80)
    }
}

/// Recent outcomes, the stranger follow-up, ringback and the camera pause at the ear, as Android.
final class CallsAndRecentRulesTests: XCTestCase {
    func testEveryEndingGetsAndroidsOutcome() {
        XCTAssertEqual(RecentCallOutcome.of(answered: true, missed: false, declinedHere: false, cancelledHere: false, reason: "Peer ended the call"), .answered)
        XCTAssertEqual(RecentCallOutcome.of(answered: false, missed: true, declinedHere: false, cancelledHere: false, reason: "Caller cancelled"), .missed)
        XCTAssertEqual(RecentCallOutcome.of(answered: false, missed: false, declinedHere: true, cancelledHere: false, reason: nil), .declined)
        XCTAssertEqual(RecentCallOutcome.of(answered: false, missed: false, declinedHere: false, cancelledHere: false, reason: "Call declined (rejected)"), .declined)
        XCTAssertEqual(RecentCallOutcome.of(answered: false, missed: false, declinedHere: false, cancelledHere: false, reason: "Declined as busy (already in a call)"), .declined)
        XCTAssertEqual(RecentCallOutcome.of(answered: false, missed: false, declinedHere: false, cancelledHere: true, reason: nil), .noAnswer)
        XCTAssertEqual(RecentCallOutcome.of(answered: false, missed: false, declinedHere: false, cancelledHere: false, reason: "Call cancelled"), .noAnswer)
        XCTAssertEqual(RecentCallOutcome.of(answered: false, missed: false, declinedHere: false, cancelledHere: false, reason: "Peer stopped responding"), .failed)
        XCTAssertEqual(RecentCallOutcome.of(answered: true, missed: false, declinedHere: false, cancelledHere: false, reason: "Call declined"), .answered,
                       "a call that was active is answered however it ended")
    }

    func testOlderRecordsReadAsAndroidsLegacyEntries() {
        XCTAssertEqual(RecentCallOutcome.legacy(missed: true), .missed)
        XCTAssertEqual(RecentCallOutcome.legacy(missed: false), .answered)
    }

    func testTheRowLineShowsTheDirectionOnlyWithCompleteRecent() {
        let outgoing = RecentCallOutcome.line(outgoing: true, outcome: .answered, detail: "Video, now", complete: true)
        let incoming = RecentCallOutcome.line(outgoing: false, outcome: .answered, detail: "Video, now", complete: true)
        XCTAssertNotEqual(outgoing, incoming, "the arrow tells the direction")
        XCTAssertEqual(RecentCallOutcome.line(outgoing: true, outcome: .missed, detail: "Video, now", complete: false), "Video, now",
                       "the control arm keeps the plain text")
    }

    func testOnlyAnUnsavedUnblockedPersonIsOfferedAsAContact() {
        XCTAssertNotNil(StrangerCallFollowUp.name(enabled: true, blocked: false, isContact: false, generatedName: "gold fox", handle: nil))
        XCTAssertNil(StrangerCallFollowUp.name(enabled: true, blocked: false, isContact: true, generatedName: "gold fox", handle: nil), "already a contact")
        XCTAssertNil(StrangerCallFollowUp.name(enabled: true, blocked: true, isContact: false, generatedName: "gold fox", handle: nil), "blocked")
        XCTAssertNil(StrangerCallFollowUp.name(enabled: false, blocked: false, isContact: false, generatedName: "gold fox", handle: nil), "control arm")
        XCTAssertEqual(StrangerCallFollowUp.name(enabled: true, blocked: false, isContact: false, generatedName: nil, handle: "ABCDE-FGHIJ"), "ABCDE-FGHIJ",
                       "an unsaved fixed ID by its handle")
        XCTAssertNil(StrangerCallFollowUp.name(enabled: true, blocked: false, isContact: false, generatedName: " ", handle: ""), "nobody to name")
    }

    func testTheCameraPausesAtTheEarOnlyWhenAllHold() {
        XCTAssertTrue(EarCameraPause.shouldPause(enabled: true, userCameraOn: true, earpiece: true, near: true))
        XCTAssertFalse(EarCameraPause.shouldPause(enabled: true, userCameraOn: true, earpiece: false, near: true), "speaker or headset")
        XCTAssertFalse(EarCameraPause.shouldPause(enabled: true, userCameraOn: false, earpiece: true, near: true), "camera already off")
        XCTAssertFalse(EarCameraPause.shouldPause(enabled: true, userCameraOn: true, earpiece: true, near: false), "away from the ear")
        XCTAssertFalse(EarCameraPause.shouldPause(enabled: false, userCameraOn: true, earpiece: true, near: true), "control arm")
    }

    func testAVideoCallGetsItsCameraBackAfterLockThenUnlockStraightToTheHomeScreen() {
        var state = BackgroundCameraRestore()
        state.enterBackground(cameraOn: true)          // lock: the call turns the camera off
        state.enterBackground(cameraOn: false)         // unlock, then home before the app was active
        XCTAssertTrue(state.enterForeground(cameraOn: false, callEnded: false), "reopening MeshLive turns the camera on")
        XCTAssertFalse(state.backgrounded)
    }

    func testTheCameraComesBackOnlyWhenItWasOnAndTheCallGoesOn() {
        var state = BackgroundCameraRestore()
        state.enterBackground(cameraOn: false)
        XCTAssertFalse(state.enterForeground(cameraOn: false, callEnded: false), "the user had turned the camera off")
        state.enterBackground(cameraOn: true)
        XCTAssertFalse(state.enterForeground(cameraOn: false, callEnded: true), "the call ended in the background")
        XCTAssertFalse(state.enterForeground(cameraOn: false, callEnded: false), "nothing saved without a background")
        state.enterBackground(cameraOn: true)
        XCTAssertFalse(state.enterForeground(cameraOn: true, callEnded: false), "already on")
    }

    func testRingbackPlaysOnlyWhileTheOtherPhoneRings() {
        XCTAssertTrue(CallTones.ringbackPlays(enabled: true, phase: .outgoingRinging))
        for phase: PrivateCallPhase in [.outgoingInvite, .incomingRinging, .negotiatingMedia, .active, .ended] {
            XCTAssertFalse(CallTones.ringbackPlays(enabled: true, phase: phase), "\(phase)")
        }
        XCTAssertFalse(CallTones.ringbackPlays(enabled: false, phase: .outgoingRinging), "control arm")
    }
}
