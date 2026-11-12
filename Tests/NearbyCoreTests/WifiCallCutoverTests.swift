import XCTest
@testable import NearbyCore

final class WifiCallCutoverTests: XCTestCase {
    private let t = Data(repeating: 7, count: 8)
    private let t2 = Data(repeating: 8, count: 8)
    private func record(_ n: UInt8) -> Data { Data([n]) }

    func testAfterASwitchBluetoothBelowTheBoundaryAndWifiFromItAreDelivered() {
        var c = WifiCallCutover()
        c.carrierUp(ticket: t)
        XCTAssertEqual(c.receivedSwitch(gen: 1, ticket: t, boundary: 10), .accepted)
        XCTAssertEqual(c.bluetoothVerdict(sequence: 9), .deliver)
        XCTAssertEqual(c.bluetoothVerdict(sequence: 10), .drop)
        XCTAssertEqual(c.wifiVerdict(sequence: 10, record: record(10), now: 0), .deliver)
        c.delivered(sequence: 10)
        XCTAssertEqual(c.wifiVerdict(sequence: 10, record: record(10), now: 0), .drop)
    }

    func testWifiRecordsBeforeTheSwitchAreHeldThenReleasedInOrder() {
        var c = WifiCallCutover()
        c.carrierUp(ticket: t)
        XCTAssertEqual(c.wifiVerdict(sequence: 5, record: record(5), now: 0), .hold)
        XCTAssertEqual(c.wifiVerdict(sequence: 6, record: record(6), now: 0), .hold)
        XCTAssertEqual(c.bluetoothVerdict(sequence: 4), .deliver)
        c.delivered(sequence: 4)
        XCTAssertEqual(c.receivedSwitch(gen: 1, ticket: t, boundary: 5), .accepted)
        let released = c.takeReleased(now: 0)
        XCTAssertEqual(released.map { $0.sequence }, [5, 6])
        XCTAssertEqual(released.map { $0.record }, [record(5), record(6)])
    }

    func testHeldRecordsAreDeliveredAfterOneSecondWithoutASwitch() {
        var c = WifiCallCutover()
        c.delivered(sequence: 2)
        c.carrierUp(ticket: t)
        XCTAssertEqual(c.wifiVerdict(sequence: 3, record: record(3), now: 0), .hold)
        XCTAssertTrue(c.takeReleased(now: 0.5).isEmpty)
        XCTAssertEqual(c.takeReleased(now: 1.0).map { $0.sequence }, [3])
        XCTAssertEqual(c.bluetoothVerdict(sequence: 3), .drop)
    }

    func testASwitchForTheBindingAttemptAppliesWhenTheCarrierComesUp() {
        var c = WifiCallCutover()
        c.expect(ticket: t)
        XCTAssertEqual(c.receivedSwitch(gen: 1, ticket: t, boundary: 8), .accepted)
        c.carrierUp(ticket: t)
        XCTAssertTrue(c.acceptWifi)
        XCTAssertEqual(c.boundary, 8)
    }

    func testStaleRepeatedAndForeignSwitchesChangeNothing() {
        var c = WifiCallCutover()
        c.carrierUp(ticket: t)
        XCTAssertEqual(c.receivedSwitch(gen: 2, ticket: t, boundary: 10), .accepted)
        XCTAssertEqual(c.receivedSwitch(gen: 2, ticket: t, boundary: 10), .repeated)
        XCTAssertEqual(c.receivedSwitch(gen: 2, ticket: t, boundary: 11), .dropped)
        XCTAssertEqual(c.receivedSwitch(gen: 1, ticket: t, boundary: 12), .dropped)
        let other = Data(repeating: 3, count: 8)
        XCTAssertEqual(c.receivedSwitch(gen: 3, ticket: other, boundary: 12), .dropped)
        XCTAssertEqual(c.receivedSwitch(gen: 3, ticket: t, boundary: 12), .dropped)
    }

    func testAResumeClosesWifiAndFencesOldBluetooth() {
        var c = WifiCallCutover()
        c.carrierUp(ticket: t)
        XCTAssertEqual(c.receivedResume(gen: 1, ticket: t, next: 20), .closeWifi)
        c.wifiLost(now: 0)
        XCTAssertEqual(c.bluetoothVerdict(sequence: 19), .drop)
        XCTAssertEqual(c.bluetoothVerdict(sequence: 20), .deliver)
        XCTAssertEqual(c.receivedResume(gen: 1, ticket: t, next: 20), .dropped)
    }

    func testTheSenderSwitchesOnlyUnderAndroidsConditions() {
        var c = WifiCallCutover()
        c.carrierUp(ticket: t)
        XCTAssertFalse(c.requestSwitch(now: 10, activeSince: 8, oldestQueuedAge: 0.1))
        XCTAssertFalse(c.requestSwitch(now: 10, activeSince: 0, oldestQueuedAge: 0.6))
        XCTAssertTrue(c.requestSwitch(now: 10, activeSince: 7, oldestQueuedAge: 0.1))
        XCTAssertEqual(c.takeMarker(nextSequence: 40), .switchTo(gen: 1, ticket: t, e2eBoundary: 40, meshBoundary: 0))
        XCTAssertTrue(c.sendOnWifi)
    }

    func testAFallbackSendsAResumeAndCoolsDown() {
        var c = WifiCallCutover()
        c.carrierUp(ticket: t)
        XCTAssertTrue(c.requestSwitch(now: 10, activeSince: 0, oldestQueuedAge: 0))
        XCTAssertEqual(c.takeMarker(nextSequence: 40), .switchTo(gen: 1, ticket: t, e2eBoundary: 40, meshBoundary: 0))
        c.wifiLost(now: 100)
        XCTAssertEqual(c.takeMarker(nextSequence: 55), .resume(gen: 2, ticket: t, e2eNext: 55, meshNext: 0))
        XCTAssertEqual(c.fallbacks, 1)
        c.carrierUp(ticket: t2)
        XCTAssertFalse(c.requestSwitch(now: 110, activeSince: 0, oldestQueuedAge: 0))
        XCTAssertTrue(c.requestSwitch(now: 131, activeSince: 0, oldestQueuedAge: 0))
        XCTAssertEqual(c.takeMarker(nextSequence: 60), .switchTo(gen: 3, ticket: t2, e2eBoundary: 60, meshBoundary: 0))
        c.wifiLost(now: 132)
        XCTAssertEqual(c.fallbacks, 2)
        c.carrierUp(ticket: t)
        XCTAssertFalse(c.requestSwitch(now: 999, activeSince: 0, oldestQueuedAge: 0))
    }

    func testAViolationLossSendsNoResume() {
        var c = WifiCallCutover()
        c.carrierUp(ticket: t)
        c.wifiLost(now: 0, announce: false)
        XCTAssertNil(c.takeMarker(nextSequence: 1))
    }

    func testADuplicateOrLowerHeldRecordIsNeverReleasedTwice() {
        var c = WifiCallCutover()
        c.carrierUp(ticket: t)
        for s: UInt8 in [5, 5, 4, 6, 6] { XCTAssertEqual(c.wifiVerdict(sequence: UInt64(s), record: record(s), now: 0), .hold) }
        XCTAssertEqual(c.receivedSwitch(gen: 1, ticket: t, boundary: 4), .accepted)
        // Opening the same BME1 sequence twice throws a replay and would end the whole call.
        XCTAssertEqual(c.takeReleased(now: 0).map { $0.sequence }, [5, 6])
    }

    func testAFallbackOrAPromotionAsksForFragmentResync() {
        var c = WifiCallCutover()
        c.carrierUp(ticket: t)
        XCTAssertEqual(c.receivedSwitch(gen: 1, ticket: t, boundary: 3), .accepted)
        XCTAssertTrue(c.requestSwitch(now: 10, activeSince: 0, oldestQueuedAge: 0))
        _ = c.takeMarker(nextSequence: 4)
        XCTAssertFalse(c.takeFragmentActions().suppressReceive)
        // The peer's RESUME while its direction was on Wi-Fi: the frame it was sending there may be half delivered.
        XCTAssertEqual(c.receivedResume(gen: 2, ticket: t, next: 9), .closeWifi)
        c.wifiLost(now: 11)
        let lost = c.takeFragmentActions()
        XCTAssertTrue(lost.suppressReceive)
        XCTAssertTrue(lost.resetSend)
        XCTAssertFalse(c.takeFragmentActions().suppressReceive)
        XCTAssertFalse(c.takeFragmentActions().resetSend)

        var p = WifiCallCutover()
        p.carrierUp(ticket: t)
        XCTAssertEqual(p.wifiVerdict(sequence: 0, record: record(0), now: 0), .hold)
        XCTAssertEqual(p.takeReleased(now: 1).map { $0.sequence }, [0])
        let promoted = p.takeFragmentActions()
        XCTAssertTrue(promoted.suppressReceive)
        XCTAssertFalse(promoted.resetSend)
    }

    func testSuppressModeSkipsTheTailOfALostFrameAndResyncsOnTheNextFrame() throws {
        func fragment(total: Int, offset: Int, _ bytes: [UInt8]) -> Data {
            var w = BinaryWriter(); w.u32(UInt32(total)); w.u32(UInt32(offset)); w.bytes(bytes); return w.data
        }
        var r = CallVideoReassembler()
        XCTAssertNil(try r.accept(flags: 0, fragment: fragment(total: 4, offset: 0, [1, 2])))
        r.suppress()
        XCTAssertTrue(r.idle)
        XCTAssertNil(try r.accept(flags: 0, fragment: fragment(total: 4, offset: 2, [3, 4])))
        XCTAssertNil(try r.accept(flags: 0, fragment: fragment(total: 3, offset: 0, [7, 8])))
        XCTAssertEqual(try r.accept(flags: 0, fragment: fragment(total: 3, offset: 2, [9])), Data([7, 8, 9]))
        // Outside suppress mode the strict checks are unchanged: a tail without its start is a protocol error.
        XCTAssertThrowsError(try r.accept(flags: 0, fragment: fragment(total: 4, offset: 2, [3, 4])))
    }
}
