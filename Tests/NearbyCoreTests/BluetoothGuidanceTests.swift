import XCTest
@testable import NearbyCore

/// When to tell the user that Bluetooth needs a restart (Android's people_bluetooth_restart guidance).
final class BluetoothGuidanceTests: XCTestCase {
    func testAStuckStackNeedsARestartButAShortResetDoesNot() {
        XCTAssertFalse(BluetoothGuidance.needsRestart(state: .resetting, secondsInState: 2, hostingFailed: false), "a reset takes a moment")
        XCTAssertTrue(BluetoothGuidance.needsRestart(state: .resetting, secondsInState: 12, hostingFailed: false))
        XCTAssertTrue(BluetoothGuidance.needsRestart(state: .unknown, secondsInState: 30, hostingFailed: false), "never came up")
    }

    func testAStackThatRefusesToHostTheServiceNeedsARestart() {
        XCTAssertTrue(BluetoothGuidance.needsRestart(state: .poweredOn, secondsInState: 60, hostingFailed: true))
        XCTAssertFalse(BluetoothGuidance.needsRestart(state: .poweredOn, secondsInState: 60, hostingFailed: false))
    }

    func testOffDeniedAndUnsupportedKeepTheirOwnMessages() {
        for state: BluetoothGuidance.State in [.poweredOff, .unauthorized, .unsupported] {
            XCTAssertFalse(BluetoothGuidance.needsRestart(state: state, secondsInState: 600, hostingFailed: true), "\(state)")
        }
    }
}

/// Android WifiAdvicePolicy: when the Mac asks before video.
final class WifiAdviceTests: XCTestCase {
    func testAsksOnlyOnTwoPointFourGigahertzOnceADayAndNeverBeforeVoice() {
        let day = WifiAdvice.quietSeconds, now: TimeInterval = 1_800_000_000
        XCTAssertTrue(WifiAdvice.shouldAsk(enabled: true, band: .ghz2_4, voice: false, now: now, answeredAt: 0), "never answered")
        XCTAssertFalse(WifiAdvice.shouldAsk(enabled: true, band: .ghz5, voice: false, now: now, answeredAt: 0))
        XCTAssertFalse(WifiAdvice.shouldAsk(enabled: true, band: .unknown, voice: false, now: now, answeredAt: 0), "macOS did not tell the band")
        XCTAssertFalse(WifiAdvice.shouldAsk(enabled: true, band: .ghz2_4, voice: true, now: now, answeredAt: 0), "voice fits a shared radio")
        XCTAssertFalse(WifiAdvice.shouldAsk(enabled: true, band: .ghz2_4, voice: false, now: now, answeredAt: now - day + 60), "answered today")
        XCTAssertTrue(WifiAdvice.shouldAsk(enabled: true, band: .ghz2_4, voice: false, now: now, answeredAt: now - day), "a day later")
        XCTAssertTrue(WifiAdvice.shouldAsk(enabled: true, band: .ghz2_4, voice: false, now: now, answeredAt: now + 60), "the clock moved back")
        XCTAssertFalse(WifiAdvice.shouldAsk(enabled: false, band: .ghz2_4, voice: false, now: now, answeredAt: 0), "control arm")
    }
}
