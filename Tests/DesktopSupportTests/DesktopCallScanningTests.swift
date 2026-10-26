import XCTest
@testable import DesktopSupport

final class DesktopCallScanningTests: XCTestCase {
    private final class Radio {
        var scanning = false
        var transitions: [Bool] = []
        var sightings = 0
        func scan(_ on: Bool) { scanning = on; transitions.append(on) }
        func seePeer() { if scanning { sightings += 1 } }
    }

    func testOutgoingRetryKeepsDiscoveryUntilLinkAttachmentAndRestoresItOnEnd() {
        let radio = Radio(), id = UUID()
        let calls = DesktopCallScanning(enabled: true, scan: radio.scan)
        calls.start(); calls.selectCall(id)
        radio.seePeer() // Initial attempt fails; a fresh advertising address is needed.
        calls.start() // Foreground/start refresh must not lose the selected call.
        radio.seePeer()
        XCTAssertEqual(radio.sightings, 2)
        XCTAssertTrue(calls.linkAttached(to: id))
        radio.seePeer()
        XCTAssertEqual(radio.sightings, 2, "An attached call pauses discovery")
        calls.start()
        XCTAssertFalse(radio.scanning, "A refresh must not restart an attached call's scan")
        calls.callEnded(id)
        radio.seePeer()
        XCTAssertEqual(radio.sightings, 3, "Discovery resumes while the ended screen is still visible")
        calls.selectCall(nil)
        XCTAssertEqual(radio.transitions, [true, false, true])
    }

    func testIncomingCallTerminationReleasesTheScanPauseAndRejectsLateAttachment() {
        let radio = Radio(), id = UUID()
        let calls = DesktopCallScanning(enabled: true, scan: radio.scan)
        calls.start(); calls.selectCall(id)
        XCTAssertTrue(calls.linkAttached(to: id))
        calls.callEnded(id)
        XCTAssertTrue(radio.scanning)
        XCTAssertFalse(calls.linkAttached(to: id), "A late callback cannot reattach an ended call")
        XCTAssertTrue(radio.scanning)
    }

    func testReplacedCallIgnoresStaleAttachmentAndEndCallbacks() {
        let radio = Radio(), old = UUID(), current = UUID()
        let calls = DesktopCallScanning(enabled: true, scan: radio.scan)
        calls.start(); calls.selectCall(old); calls.callEnded(old)
        calls.selectCall(current)
        XCTAssertFalse(calls.linkAttached(to: old))
        XCTAssertTrue(radio.scanning)
        XCTAssertTrue(calls.linkAttached(to: current))
        calls.callEnded(old)
        XCTAssertFalse(radio.scanning)
        calls.callEnded(current)
        XCTAssertTrue(radio.scanning)
    }

    func testDisabledExperimentAndLiveTogglePreserveDiscovery() {
        let radio = Radio(), id = UUID()
        let calls = DesktopCallScanning(scan: radio.scan)
        calls.start(); calls.selectCall(id)
        XCTAssertTrue(calls.linkAttached(to: id))
        XCTAssertTrue(radio.scanning, "Default-off retains the existing call behavior")
        calls.setEnabled(true)
        XCTAssertFalse(radio.scanning)
        calls.setEnabled(false)
        XCTAssertTrue(radio.scanning)
        calls.callEnded(id)
        XCTAssertEqual(radio.transitions, [true, false, true])
    }

    func testStopPreventsLateCallbacksFromRestartingDiscovery() {
        let radio = Radio(), id = UUID()
        let calls = DesktopCallScanning(enabled: true, scan: radio.scan)
        calls.selectCall(id); calls.setEnabled(false); calls.setEnabled(true)
        XCTAssertTrue(radio.transitions.isEmpty, "Preview construction must not access the radio")
        calls.start(); XCTAssertTrue(calls.linkAttached(to: id))
        calls.stop(); calls.callEnded(id); calls.selectCall(nil); calls.setEnabled(false)
        XCTAssertFalse(calls.linkAttached(to: id))
        XCTAssertFalse(radio.scanning)
        XCTAssertEqual(radio.transitions, [true, false])
    }

    func testBrowsingAndStreamDiscoveryRemainAvailableWithoutAnAttachedCall() {
        let radio = Radio()
        let calls = DesktopCallScanning(enabled: true, scan: radio.scan)
        calls.start()
        for _ in 0..<3 { calls.selectCall(nil); calls.start(); radio.seePeer() }
        XCTAssertEqual(radio.sightings, 3)
        XCTAssertTrue(radio.scanning)
        XCTAssertFalse(calls.linkAttached(to: UUID()), "A stream link cannot acquire a call pause")
        XCTAssertTrue(radio.scanning)
    }
}
