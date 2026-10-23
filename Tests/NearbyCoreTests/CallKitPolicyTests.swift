import XCTest
@testable import NearbyCore

final class CallKitPolicyTests: XCTestCase {
    func testReportsOnlyARingingCallOutsideTheAppWhenOn() {
        XCTAssertTrue(CallKitPolicy.shouldReport(enabled: true, ringing: true, appActive: false))
        XCTAssertFalse(CallKitPolicy.shouldReport(enabled: false, ringing: true, appActive: false))
        XCTAssertFalse(CallKitPolicy.shouldReport(enabled: true, ringing: true, appActive: true))
        XCTAssertFalse(CallKitPolicy.shouldReport(enabled: true, ringing: false, appActive: false))
    }

    func testCallerNameFollowsTheAlertRules() {
        XCTAssertEqual(CallKitPolicy.update(voice: true, peerName: " Asha ", stranger: false), .init(callerName: "Asha", hasVideo: false))
        XCTAssertEqual(CallKitPolicy.update(voice: false, peerName: "Asha", stranger: false), .init(callerName: "Asha", hasVideo: true))
        XCTAssertNil(CallKitPolicy.update(voice: false, peerName: "Asha", stranger: true).callerName)
        XCTAssertNil(CallKitPolicy.update(voice: false, peerName: "\u{200B}", stranger: false).callerName)
        XCTAssertEqual(CallKitPolicy.update(voice: false, peerName: String(repeating: "x", count: 80), stranger: false).callerName?.count, 40)
    }

    func testWhileTheCallRuns() {
        XCTAssertEqual(CallKitPolicy.outcome(ringing: true, ended: false, answeredByCallKit: false, endedInApp: false, failed: false), .keep)
        XCTAssertEqual(CallKitPolicy.outcome(ringing: false, ended: false, answeredByCallKit: true, endedInApp: false, failed: false), .keep)
        // Accepted on the MeshLive screen: the native screen steps aside and the app runs the call as without CallKit.
        XCTAssertEqual(CallKitPolicy.outcome(ringing: false, ended: false, answeredByCallKit: false, endedInApp: false, failed: false),
                       .report(.answeredElsewhere))
    }

    func testEndOfARingingCall() {
        // The caller cancelled, the ring timed out or the link dropped: a missed call.
        XCTAssertEqual(CallKitPolicy.outcome(ringing: false, ended: true, answeredByCallKit: false, endedInApp: false, failed: false), .report(.unanswered))
        XCTAssertEqual(CallKitPolicy.outcome(ringing: false, ended: true, answeredByCallKit: false, endedInApp: false, failed: true), .report(.unanswered))
        XCTAssertEqual(CallKitPolicy.outcome(ringing: false, ended: true, answeredByCallKit: false, endedInApp: true, failed: false), .report(.declinedElsewhere))
    }

    func testEndOfAnAnsweredCall() {
        XCTAssertEqual(CallKitPolicy.outcome(ringing: false, ended: true, answeredByCallKit: true, endedInApp: false, failed: false), .report(.remoteEnded))
        XCTAssertEqual(CallKitPolicy.outcome(ringing: false, ended: true, answeredByCallKit: true, endedInApp: false, failed: true), .report(.failed))
        // Hung up on the MeshLive screen: CallKit hears it as the user's own end action.
        XCTAssertEqual(CallKitPolicy.outcome(ringing: false, ended: true, answeredByCallKit: true, endedInApp: true, failed: false), .requestEnd)
    }

    func testFocusAndBlockListKeepARefusedCallSilent() {
        XCTAssertEqual(CallKitPolicy.refusal(filteredByFocusOrBlockList: true), .silent)
        XCTAssertEqual(CallKitPolicy.refusal(filteredByFocusOrBlockList: false), .ringLocally)
    }

    func testProviderResetEndsTheMeshLiveCall() {
        XCTAssertEqual(CallKitPolicy.resetAction(ringing: true), .decline)
        XCTAssertEqual(CallKitPolicy.resetAction(ringing: false), .end)
    }

    func testInAppMuteAndHoldToTalkReachTheNativeScreen() {
        var sync = CallKitPolicy.MuteSync()
        XCTAssertTrue(sync.appChanged(micMuted: true))   // Mute in the app
        XCTAssertFalse(sync.callKitAction(muted: true))  // CallKit performs that request: not applied back
        XCTAssertTrue(sync.appChanged(micMuted: false))  // hold-to-talk pressed: the microphone opens
        XCTAssertFalse(sync.callKitAction(muted: false))
        XCTAssertTrue(sync.appChanged(micMuted: true))   // released: muted again
        XCTAssertFalse(sync.appChanged(micMuted: true))  // no change, no request
    }

    func testNativeMuteReachesTheCallOnce() {
        var sync = CallKitPolicy.MuteSync()
        XCTAssertTrue(sync.callKitAction(muted: true))   // the native Mute button: applied to the call
        XCTAssertFalse(sync.appChanged(micMuted: true))  // the call's own mute change is not sent back to CallKit
        XCTAssertTrue(sync.callKitAction(muted: false))
        XCTAssertFalse(sync.appChanged(micMuted: false))
    }
}
