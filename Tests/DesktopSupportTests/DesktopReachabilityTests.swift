import XCTest
@testable import DesktopSupport

final class DesktopReachabilityTests: XCTestCase {
    private let ready = DesktopPresence(radioReady: true, allowCalls: true, appActive: false)

    func testMenuStateFollowsReachabilityCallAndLive() {
        XCTAssertEqual(DesktopReachabilityPolicy.state(DesktopPresence()), .notReachable)
        XCTAssertEqual(DesktopReachabilityPolicy.state(DesktopPresence(radioReady: true)), .notReachable, "Allow calls off")
        XCTAssertEqual(DesktopReachabilityPolicy.state(DesktopPresence(allowCalls: true)), .notReachable, "Bluetooth not ready")
        XCTAssertEqual(DesktopReachabilityPolicy.state(ready), .reachable)
        var p = ready; p.call = .incomingRinging
        XCTAssertEqual(DesktopReachabilityPolicy.state(p), .inCall)
        p.call = .other
        XCTAssertEqual(DesktopReachabilityPolicy.state(p), .inCall)
        p = ready; p.watching = true
        XCTAssertEqual(DesktopReachabilityPolicy.state(p), .live)
        // Broadcasting is never hidden behind another state.
        p = DesktopPresence(call: .other, liveSource: true)
        XCTAssertEqual(DesktopReachabilityPolicy.state(p), .live)
    }

    func testNoActivityWithDefaultSettings() {
        let defaults = DesktopReachabilitySettings()
        for presence in [ready, DesktopPresence(radioReady: true, allowCalls: true, call: .other, callVideo: true),
                         DesktopPresence(liveSource: true, liveVideo: true), DesktopPresence(watching: true)] {
            XCTAssertNil(DesktopReachabilityPolicy.activity(presence, defaults))
        }
    }

    func testMediaActivityCoversCallsLiveRadioAndRelayAndNeverLatencyCritical() {
        let s = DesktopReachabilitySettings(activityDuringMedia: true)
        let cases: [(DesktopPresence, Bool)] = [
            (DesktopPresence(call: .incomingRinging), false),
            (DesktopPresence(call: .other), false),
            (DesktopPresence(call: .other, callVideo: true), true),
            (DesktopPresence(call: .incomingRinging, callVideo: true), false),
            (DesktopPresence(liveSource: true), false),            // audio-only live (radio)
            (DesktopPresence(liveSource: true, liveVideo: true), true),
            (DesktopPresence(watching: true), false),              // listening to radio
            (DesktopPresence(watching: true, watchVideo: true), true),
            (DesktopPresence(relayingCall: true), false),
        ]
        for (presence, video) in cases {
            let activity = DesktopReachabilityPolicy.activity(presence, s)
            XCTAssertNotNil(activity, "\(presence)")
            XCTAssertTrue(activity!.options.contains(.userInitiated), "\(presence)")
            XCTAssertTrue(activity!.options.contains(.idleSystemSleepDisabled), "\(presence)")
            XCTAssertEqual(activity!.options.contains(.idleDisplaySleepDisabled), video, "\(presence)")
            XCTAssertFalse(activity!.options.contains(.latencyCritical), "\(presence)")
        }
        XCTAssertNil(DesktopReachabilityPolicy.activity(DesktopPresence(), s), "Nothing running, not reachable")
    }

    func testReachableBackgroundPreventsAppNapButAllowsSleepUnlessKeepAwake() {
        let noNap = DesktopReachabilitySettings(noAppNapWhileReachable: true)
        let nap = DesktopReachabilityPolicy.activity(ready, noNap)
        XCTAssertEqual(nap?.options, .userInitiatedAllowingIdleSystemSleep)
        XCTAssertFalse(nap!.options.contains(.idleSystemSleepDisabled))
        XCTAssertFalse(nap!.options.contains(.latencyCritical))
        XCTAssertNil(DesktopReachabilityPolicy.activity(DesktopPresence(radioReady: true), noNap), "Allow calls off")
        XCTAssertNil(DesktopReachabilityPolicy.activity(DesktopPresence(allowCalls: true), noNap), "Bluetooth off")

        let awake = DesktopReachabilityPolicy.activity(ready, DesktopReachabilitySettings(noAppNapWhileReachable: true, keepAwakeWhileReachable: true))
        XCTAssertEqual(awake?.options, .userInitiated)
        XCTAssertTrue(awake!.options.contains(.idleSystemSleepDisabled))
        XCTAssertFalse(awake!.options.contains(.idleDisplaySleepDisabled))
        XCTAssertNil(DesktopReachabilityPolicy.activity(DesktopPresence(allowCalls: true),
                                                        DesktopReachabilitySettings(keepAwakeWhileReachable: true)))
    }

    func testMediaSwitchOffFallsBackToReachableRule() {
        var p = ready; p.call = .other
        XCTAssertEqual(DesktopReachabilityPolicy.activity(p, DesktopReachabilitySettings(noAppNapWhileReachable: true))?.options,
                       .userInitiatedAllowingIdleSystemSleep)
    }

    func testHolderBeginsAndEndsWithCallAndLiveLifecycle() {
        var log: [String] = []
        final class Token: NSObject { let n: Int; init(_ n: Int) { self.n = n } }
        var next = 0
        let holder = DesktopActivityHolder(begin: { options, _ in next += 1; log.append("begin\(next):\(options.rawValue)"); return Token(next) },
                                           end: { log.append("end\(($0 as! Token).n)") })
        let s = DesktopReachabilitySettings(activityDuringMedia: true, noAppNapWhileReachable: true)
        func step(_ p: DesktopPresence) { holder.apply(DesktopReachabilityPolicy.activity(p, s)) }

        step(DesktopPresence())                                // idle, not reachable
        XCTAssertEqual(log, [])
        step(ready)                                            // reachable in background
        step(ready)                                            // unchanged: no churn
        var call = ready; call.call = .incomingRinging
        step(call)                                             // ringing -> media
        call.call = .other
        step(call)                                             // answered voice: same options and reason
        call.callVideo = true
        step(call)                                             // video on -> display stays awake
        step(ready)                                            // hung up -> back to reachable
        step(DesktopPresence())                                // Allow calls off / Bluetooth off
        let napFree = ProcessInfo.ActivityOptions.userInitiatedAllowingIdleSystemSleep.rawValue
        let media = ProcessInfo.ActivityOptions.userInitiated.rawValue
        let video = ProcessInfo.ActivityOptions([.userInitiated, .idleDisplaySleepDisabled]).rawValue
        XCTAssertEqual(log, ["begin1:\(napFree)", "begin2:\(media)", "end1", "begin3:\(video)", "end2",
                             "begin4:\(napFree)", "end3", "end4"])
        XCTAssertNil(holder.current)
    }

    func testHolderEndsOnDeinit() {
        var ended = 0
        var holder: DesktopActivityHolder? = DesktopActivityHolder(begin: { _, _ in NSObject() }, end: { _ in ended += 1 })
        holder?.apply(DesktopActivity(options: .userInitiated, reason: "test"))
        holder = nil
        XCTAssertEqual(ended, 1)
    }

    func testRingWindowOnlyWhenEnabledRingingAndInBackground() {
        let on = DesktopReachabilitySettings(ringWindow: true)
        var p = ready; p.call = .incomingRinging
        XCTAssertTrue(DesktopReachabilityPolicy.showsRingWindow(p, on))
        XCTAssertFalse(DesktopReachabilityPolicy.showsRingWindow(p, DesktopReachabilitySettings()), "default off")
        p.appActive = true
        XCTAssertFalse(DesktopReachabilityPolicy.showsRingWindow(p, on), "frontmost: the call screen shows it")
        p.appActive = false; p.call = .other
        XCTAssertFalse(DesktopReachabilityPolicy.showsRingWindow(p, on), "answered")
        p.call = .none
        XCTAssertFalse(DesktopReachabilityPolicy.showsRingWindow(p, on))
    }

    func testSettingsReadDefaultsAndMenuBarDefaultsOn() {
        let defaults = UserDefaults(suiteName: "DesktopReachabilityTests-\(UUID().uuidString)")!
        XCTAssertEqual(DesktopReachabilitySettings(defaults: defaults), DesktopReachabilitySettings())
        XCTAssertTrue(DesktopReachabilitySettings.showsMenuBar(defaults))
        defaults.set(false, forKey: DesktopReachabilitySettings.menuBarKey)
        XCTAssertFalse(DesktopReachabilitySettings.showsMenuBar(defaults))
        defaults.set(true, forKey: DesktopReachabilitySettings.ringWindowKey)
        defaults.set(true, forKey: DesktopReachabilitySettings.keepAwakeWhileReachableKey)
        XCTAssertEqual(DesktopReachabilitySettings(defaults: defaults), DesktopReachabilitySettings(keepAwakeWhileReachable: true, ringWindow: true))
    }
}
