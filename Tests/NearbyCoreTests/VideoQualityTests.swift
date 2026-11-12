import XCTest
@testable import NearbyCore

/// Video quality and Manual video (Android Settings › Video quality, Manual video), the heat limit, the frozen-picture
/// rule and Calls search.
final class VideoQualityTests: XCTestCase {
    func testTheStandardRequestIsTodaysCallAndBroadcastVideo() {
        let standard = VideoRequest.standard
        XCTAssertEqual([standard.width, standard.height, standard.fps, standard.kbps], [240, 426, 15, 200])
        XCTAssertEqual(VideoRequest(lines: 240, fps: 15, kbps: 200), standard)
    }

    func testOnlyAndroidsChoicesAreRequests() {
        XCTAssertNotNil(VideoRequest(lines: 360, fps: 24, kbps: 325))
        XCTAssertNotNil(VideoRequest(lines: 480, fps: 30, kbps: 1_500))
        XCTAssertNil(VideoRequest(lines: 720, fps: 15, kbps: 200), "no 720p")
        XCTAssertNil(VideoRequest(lines: 240, fps: 60, kbps: 200), "no 60 FPS")
        XCTAssertNil(VideoRequest(lines: 240, fps: 15, kbps: 90), "below the floor")
        XCTAssertNil(VideoRequest(lines: 240, fps: 15, kbps: 210), "not a 25 kbps step")
        XCTAssertNil(VideoRequest(lines: 240, fps: 15, kbps: 1_525), "above the ceiling")
    }

    func testApplePortraitSizesFollowAndroidsSixteenByNine() {
        for (lines, long) in [(240, 426), (360, 640), (480, 854)] {
            let request = VideoRequest(lines: lines, fps: 15, kbps: 200)!
            XCTAssertEqual(request.width, lines)
            XCTAssertEqual(request.height, long)
        }
    }

    func testTheSliderNeverCutsAStoredBitrate() {
        XCTAssertEqual(VideoRequest.sliderMaxKbps(.gatt, current: 200), 1_100)
        XCTAssertEqual(VideoRequest.sliderMaxKbps(.l2cap, current: 200), 1_200)
        XCTAssertEqual(VideoRequest.sliderMaxKbps(.gatt, current: 1_400), 1_400)
    }

    func testHeatLowersFrameRateAndBitrateOnlyWhenOnAndHot() {
        XCTAssertEqual(ThermalVideoPolicy.percent(thermalState: 0, reduction: true), 100)
        XCTAssertEqual(ThermalVideoPolicy.percent(thermalState: 1, reduction: true), 100)
        XCTAssertEqual(ThermalVideoPolicy.percent(thermalState: 2, reduction: true), 80)
        XCTAssertEqual(ThermalVideoPolicy.percent(thermalState: 3, reduction: true), 80)
        XCTAssertEqual(ThermalVideoPolicy.percent(thermalState: 3, reduction: false), 100)
        XCTAssertEqual(ThermalVideoPolicy.scaled(200, percent: 80), 160)
        XCTAssertEqual(ThermalVideoPolicy.scaled(15, percent: 80), 12)
        XCTAssertEqual(ThermalVideoPolicy.scaled(1, percent: 80), 1, "never zero")
        XCTAssertEqual(ThermalVideoPolicy.scaled(200, percent: 100), 200, "never above the request")
    }

    func testAFrozenPictureIsReportedOnlyAfterTheThresholdAndNeverWhileQuiet() {
        XCTAssertEqual(ViewerFreeze.thresholdMs(fps: 15), 1_500)
        XCTAssertEqual(ViewerFreeze.thresholdMs(fps: 1), 3_000, "slow streams wait three frames")
        XCTAssertNil(ViewerFreeze.stalledMs(nowMs: 10_000, sinceMs: 9_000, fps: 15, quiet: false))
        XCTAssertEqual(ViewerFreeze.stalledMs(nowMs: 10_000, sinceMs: 8_000, fps: 15, quiet: false), 2_000)
        XCTAssertNil(ViewerFreeze.stalledMs(nowMs: 10_000, sinceMs: 1_000, fps: 15, quiet: true), "paused or camera off")
        XCTAssertNil(ViewerFreeze.stalledMs(nowMs: 10_000, sinceMs: nil, fps: 15, quiet: false), "before the first picture")
    }

    func testTheAgeNeverReadsAhead() {
        let ages = [999, 3_249, 3_299, 65_000].map(ViewerFreeze.ageText)
        XCTAssertNotEqual(ages[0], ages[1])
        XCTAssertEqual(ages[1], ages[2], "3.249 s and 3.299 s show the same tenth")
        XCTAssertNotEqual(ages[2], ages[3])
    }

    func testSearchShowsInACrowdOrWhileTypedAndMatchesPartOfTheName() {
        XCTAssertFalse(NearbySearch.showsField(people: 8, query: ""))
        XCTAssertTrue(NearbySearch.showsField(people: 9, query: ""))
        XCTAssertTrue(NearbySearch.showsField(people: 1, query: "a"))
        XCTAssertTrue(NearbySearch.matches("Blue Otter", query: "otter"))
        XCTAssertTrue(NearbySearch.matches("Asha", query: " "))
        XCTAssertFalse(NearbySearch.matches("Asha", query: "Ravi"))
    }

    func testCallInfoExplainsEveryLowerValueAndNothingWhenEqual() {
        XCTAssertTrue(CallVideoNotes.notes(requestedKbps: 200, startKbps: 200, relayed: false, sendingKbps: 200, heatPercent: 100,
                                           manual: false, mac: false).isEmpty)
        XCTAssertEqual(CallVideoNotes.notes(requestedKbps: 400, startKbps: 110, relayed: true, sendingKbps: 110, heatPercent: 100,
                                            manual: false, mac: false).count, 1, "the relay cap")
        XCTAssertEqual(CallVideoNotes.notes(requestedKbps: 200, startKbps: 200, relayed: false, sendingKbps: 120, heatPercent: 100,
                                            manual: false, mac: false).count, 1, "the link")
        XCTAssertEqual(CallVideoNotes.notes(requestedKbps: 200, startKbps: 200, relayed: false, sendingKbps: 160, heatPercent: 80,
                                            manual: false, mac: true).count, 1, "heat alone is not also called the link")
        XCTAssertEqual(CallVideoNotes.notes(requestedKbps: 200, startKbps: 200, relayed: false, sendingKbps: 200, heatPercent: 100,
                                            manual: true, mac: false).count, 1, "manual says nothing adapts")
    }

    func testCriticalHeatStopsVideoWithTheSwitchOnOrOffAndOnlyAtCritical() {
        XCTAssertFalse(ThermalVideoState.blocksVideo(thermalState: 2), "serious only lowers quality")
        XCTAssertTrue(ThermalVideoState.blocksVideo(thermalState: 3))
        XCTAssertFalse(ThermalVideoState.blocksVideo(thermalState: 3, enabled: false), "the control arm")
    }

    func testAtCriticalHeatACallIsStillPlacedOrAnsweredAsVoice() {
        // The decision "Calls at critical heat" (2026-11-06): only video is refused.
        XCTAssertEqual(ThermalVideoState.callType(.video, videoBlocked: true), .voice)
        XCTAssertEqual(ThermalVideoState.callType(.voice, videoBlocked: true), .voice)
        XCTAssertEqual(ThermalVideoState.callType(.video, videoBlocked: false), .video, "below critical the choice stands")
        XCTAssertEqual(ThermalVideoState.callType(.voice, videoBlocked: false), .voice)
        for state in 0...3 {
            let blocked = ThermalVideoState.blocksVideo(thermalState: state)
            XCTAssertEqual(ThermalVideoState.callType(.video, videoBlocked: blocked), state >= 3 ? .voice : .video, "state \(state)")
        }
    }

    func testAHotterStateLowersAtOnceAndACoolerOneWaitsThirtySeconds() {
        var state = ThermalVideoState()
        XCTAssertEqual(state.update(thermalState: 2, reduction: true, nowMs: 0), 80)
        XCTAssertEqual(state.update(thermalState: 1, reduction: true, nowMs: 1_000), 80, "cooling waits")
        XCTAssertEqual(state.update(thermalState: 1, reduction: true, nowMs: 30_999), 80)
        XCTAssertEqual(state.update(thermalState: 1, reduction: true, nowMs: 31_000), 100, "restored after 30 s")
        XCTAssertEqual(state.update(thermalState: 2, reduction: true, nowMs: 32_000), 80, "hotter applies at once")
        XCTAssertEqual(state.update(thermalState: 1, reduction: true, nowMs: 40_000), 80)
        XCTAssertEqual(state.update(thermalState: 2, reduction: true, nowMs: 50_000), 80)
        XCTAssertEqual(state.update(thermalState: 1, reduction: true, nowMs: 60_000), 80, "hot again restarted the wait")
        XCTAssertEqual(state.update(thermalState: 1, reduction: true, nowMs: 89_999), 80)
        XCTAssertEqual(state.update(thermalState: 2, reduction: false, nowMs: 90_000), 100, "switch off: no limit at once")
    }

    func testTheTransportBudgetAppliesOnlyWithManualVideoAndNeverRaisesTheRequest() {
        XCTAssertNil(CallTransportCap.cap(transport: .gatt, manual: false, enabled: true), "Automatic keeps the request")
        XCTAssertEqual(CallTransportCap.cap(transport: .gatt, manual: true, enabled: true), 180)
        XCTAssertEqual(CallTransportCap.cap(transport: .l2cap, manual: true, enabled: true), 200)
        XCTAssertNil(CallTransportCap.cap(transport: .gatt, manual: true, enabled: false), "the control arm")
        XCTAssertEqual(CallTransportCap.startKbps(requested: 400, cap: 180), 180)
        XCTAssertEqual(CallTransportCap.startKbps(requested: 150, cap: 180), 150, "never above the request")
        XCTAssertEqual(CallTransportCap.startKbps(requested: 400, cap: nil), 400)
    }

    func testCallInfoBlamesTheTransportBudgetNotTheOtherDevice() {
        let capped = CallVideoNotes.notes(requestedKbps: 400, startKbps: 180, relayed: false, sendingKbps: 180, heatPercent: 100,
                                          manual: true, mac: false, transportCapKbps: 180, transport: .gatt)
        XCTAssertEqual(capped.first, CallTransportCap.note(cap: 180, transport: .gatt))
        XCTAssertEqual(capped.count, 2, "the budget and manual; the other device did not lower it")
        let peerLower = CallVideoNotes.notes(requestedKbps: 400, startKbps: 150, relayed: false, sendingKbps: 150, heatPercent: 100,
                                             manual: true, mac: false, transportCapKbps: 180, transport: .gatt)
        XCTAssertEqual(peerLower.count, 3, "the budget, the other device below it, and manual")
        let underBudget = CallVideoNotes.notes(requestedKbps: 150, startKbps: 150, relayed: false, sendingKbps: 150, heatPercent: 100,
                                               manual: true, mac: false, transportCapKbps: 180, transport: .gatt)
        XCTAssertEqual(underBudget.count, 1, "a request under the budget is not limited")
    }

    func testRemoteCallVideoFillsCloseShapesAndShowsStrongMismatchesWhole() {
        let phoneWidth = 390.0, phoneHeight = 844.0
        XCTAssertTrue(RemoteVideoFit.automaticFill(videoAspect: 9.0 / 16.0, viewWidth: phoneWidth, viewHeight: phoneHeight),
                      "ratio 1.2: portrait on portrait fills")
        XCTAssertFalse(RemoteVideoFit.automaticFill(videoAspect: 16.0 / 9.0, viewWidth: phoneWidth, viewHeight: phoneHeight),
                       "ratio 3.9: a landscape camera on a portrait phone is shown whole")
        XCTAssertFalse(RemoteVideoFit.automaticFill(videoAspect: 1.85 * phoneWidth / phoneHeight, viewWidth: phoneWidth, viewHeight: phoneHeight),
                       "a ratio above 1.8 is shown whole")
        XCTAssertFalse(RemoteVideoFit.automaticFill(videoAspect: 4.0 / 3.0, viewWidth: 850, viewHeight: 1_000),
                       "landscape against portrait below 1.8 is shown whole")
        XCTAssertTrue(RemoteVideoFit.automaticFill(videoAspect: 1.0, viewWidth: 1_000, viewHeight: 1_000))
    }

    func testTheDoubleTapChoiceWinsAndFillOffShowsTheWholePicture() {
        XCTAssertFalse(RemoteVideoFit.fill(enabled: true, fillSetting: true, override: false, videoAspect: 9.0 / 16.0,
                                           viewWidth: 390, viewHeight: 844), "double-tap to the whole picture")
        XCTAssertTrue(RemoteVideoFit.fill(enabled: true, fillSetting: true, override: true, videoAspect: 16.0 / 9.0,
                                          viewWidth: 390, viewHeight: 844), "double-tap to fill")
        XCTAssertFalse(RemoteVideoFit.fill(enabled: true, fillSetting: false, override: nil, videoAspect: 9.0 / 16.0,
                                           viewWidth: 390, viewHeight: 844), "Fill screen off")
        XCTAssertTrue(RemoteVideoFit.fill(enabled: false, fillSetting: true, override: false, videoAspect: 16.0 / 9.0,
                                          viewWidth: 390, viewHeight: 844), "the control arm: the setting alone")
    }
}
