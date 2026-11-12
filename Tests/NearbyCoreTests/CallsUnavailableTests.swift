import XCTest
@testable import NearbyCore

/// Android "Calls unavailable" (`CallsAvailabilityTracker`, on since 2026-11-05) on Apple: calls are wanted and Bluetooth
/// is ready, but the call service is not hosted (the stack stopped answering); the status says so instead of Ready.
final class CallsUnavailableTests: XCTestCase {
    func testAServiceNotHostedWithinFiveSecondsIsCallsUnavailable() {
        var watch = CallsEndpointWatch()
        XCTAssertNil(watch.observe(enabled: true, wanted: true, endpointReady: false, now: 100))
        XCTAssertNil(watch.observe(enabled: true, wanted: true, endpointReady: false, now: 104.9), "a normal start takes about a second")
        XCTAssertEqual(watch.observe(enabled: true, wanted: true, endpointReady: false, now: 105), .stalled)
        XCTAssertEqual(watch.observe(enabled: true, wanted: true, endpointReady: false, now: 300), .stalled, "it stays until the service is hosted")
    }

    func testHostingOrNotWantingCallsClearsItAndRestartsTheClock() {
        var watch = CallsEndpointWatch()
        _ = watch.observe(enabled: true, wanted: true, endpointReady: false, now: 0)
        XCTAssertEqual(watch.observe(enabled: true, wanted: true, endpointReady: false, now: 6), .stalled)
        XCTAssertNil(watch.observe(enabled: true, wanted: true, endpointReady: true, now: 7), "hosted: calls can reach this device")
        XCTAssertNil(watch.observe(enabled: true, wanted: true, endpointReady: false, now: 8), "a new start gets its own 5 s")
        XCTAssertNil(watch.observe(enabled: true, wanted: false, endpointReady: false, now: 20), "Allow calls off or Bluetooth not ready")
        XCTAssertNil(watch.observe(enabled: true, wanted: true, endpointReady: false, now: 21), "the clock restarted")
        XCTAssertEqual(watch.observe(enabled: true, wanted: true, endpointReady: false, now: 26), .stalled)
    }

    func testTheControlArmNeverShowsIt() {
        var watch = CallsEndpointWatch()
        for second in stride(from: 0.0, through: 60, by: 2) {
            XCTAssertNil(watch.observe(enabled: false, wanted: true, endpointReady: false, now: second))
        }
    }

    func testCallsUnavailableComesAfterTheScreenAndBeforeHidden() {
        XCTAssertEqual(StatusKind.of(readiness: .ready, hidden: false, relayPaused: true, hot: true, callsUnavailable: true), .callsUnavailable)
        XCTAssertEqual(StatusKind.of(readiness: .ready, hidden: true, relayPaused: false, hot: false, callsUnavailable: true), .callsUnavailable)
        XCTAssertEqual(StatusKind.of(readiness: .ready, hidden: false, relayPaused: false, hot: false, screen: .watching, callsUnavailable: true), .watching)
        XCTAssertEqual(StatusKind.of(readiness: .bluetoothOff, hidden: false, relayPaused: false, hot: false, callsUnavailable: true), .bluetoothOff)
        XCTAssertEqual(StatusKind.of(readiness: .ready, hidden: false, relayPaused: false, hot: false), .ready, "nothing changes without it")
        XCTAssertTrue(StatusKind.callsUnavailable.problem)
    }
}
