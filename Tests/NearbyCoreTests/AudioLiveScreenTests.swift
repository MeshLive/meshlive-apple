import XCTest
@testable import NearbyCore

/// Android AudioLiveReminderPolicyTest and the level meter.
final class AudioLiveScreenTests: XCTestCase {
    func testARadioNobodyListensToRemindsAfterThirtyMinutesAndStopsFiveMinutesLater() {
        var policy = AudioLiveReminderPolicy(start: 0)
        policy.onListeners(0, now: 1)
        XCTAssertEqual(policy.decide(now: 1799), .none)
        XCTAssertEqual(policy.decide(now: 1800), .remind)
        XCTAssertEqual(policy.decide(now: 1801), .none, "one reminder, not one per tick")
        XCTAssertEqual(policy.decide(now: 2099), .none)
        XCTAssertEqual(policy.decide(now: 2100), .stop)
    }

    func testAListenerResetsTheEmptyTime() {
        var policy = AudioLiveReminderPolicy(start: 0)
        policy.onListeners(1, now: 1000)
        XCTAssertEqual(policy.decide(now: 2000), .none, "someone is listening")
        policy.onListeners(0, now: 1500)
        XCTAssertEqual(policy.decide(now: 3299), .none)
        XCTAssertEqual(policy.decide(now: 3300), .remind)
    }

    func testTwoHoursOnTheAirRemindEvenWithListeners() {
        var policy = AudioLiveReminderPolicy(start: 0)
        policy.onListeners(3, now: 10)
        XCTAssertEqual(policy.decide(now: 7199), .none)
        XCTAssertEqual(policy.decide(now: 7200), .remind)
    }

    func testAnAnswerKeepsTheBroadcastAndCountsAgainFromTheAnswer() {
        var policy = AudioLiveReminderPolicy(start: 0)
        policy.onListeners(2, now: 0)
        XCTAssertEqual(policy.decide(now: 7200), .remind)
        policy.onUserPresent(now: 7250)
        XCTAssertFalse(policy.reminderOutstanding)
        XCTAssertEqual(policy.decide(now: 7600), .none, "no stop after an answer")
        XCTAssertEqual(policy.decide(now: 14_449), .none)
        XCTAssertEqual(policy.decide(now: 14_450), .remind, "two hours after the answer")
    }

    func testAnAnswerWhileStillEmptyRestartsTheEmptyTime() {
        var policy = AudioLiveReminderPolicy(start: 0)
        XCTAssertEqual(policy.decide(now: 1800), .remind)
        policy.onUserPresent(now: 1900)
        XCTAssertEqual(policy.decide(now: 3699), .none)
        XCTAssertEqual(policy.decide(now: 3700), .remind)
    }

    func testTheDebugUnitScalesEveryTime() {
        var policy = AudioLiveReminderPolicy(start: 0, unitSeconds: 2)
        XCTAssertEqual(policy.decide(now: 11), .none)
        XCTAssertEqual(policy.decide(now: 12), .remind)
        XCTAssertEqual(policy.decide(now: 14), .stop)
        var normal = AudioLiveReminderPolicy(start: 0, unitSeconds: 0)
        XCTAssertEqual(normal.decide(now: 12), .none, "a unit that is not positive keeps Android's times")
    }

    func testTheLevelIsZeroForSilenceFullForLoudSoundAndInBetweenForQuietSpeech() {
        XCTAssertEqual(AudioLiveLevel.rms([Float](repeating: 0, count: 960)), 0)
        XCTAssertEqual(AudioLiveLevel.rms([]), 0)
        let loud = (0..<960).map { Float(sin(Double($0) * 0.13)) }
        XCTAssertEqual(AudioLiveLevel.rms(loud), 1, "clamped")
        let quiet = (0..<960).map { Float(0.03 * sin(Double($0) * 0.13)) }
        let level = AudioLiveLevel.rms(quiet)
        XCTAssertGreaterThan(level, 0.1)
        XCTAssertLessThan(level, 0.3)
        XCTAssertEqual(AudioLiveLevel.rms([Float.nan, 0, 0, 0]), 0, "a broken sample does not fill the meter")
    }
}
