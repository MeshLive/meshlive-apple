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
}
