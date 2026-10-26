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
