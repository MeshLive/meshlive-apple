import XCTest
@testable import NearbyCore

/// Android PreAuthAdmissionGate on Apple: a flood of fresh request keys cannot keep a real viewer out, and the source
/// never starts more than the window allows.
final class ViewerAdmissionTests: XCTestCase {
    /// 50 fresh fake keys a second, each heard in one scan only and never authenticating; a real viewer from second 2.
    func testAFloodOfFreshKeysCannotKeepARealViewerOut() {
        let gate = ViewerAdmissionGate()
        var attemptTimes: [TimeInterval] = []
        var admittedAt: TimeInterval?
        for second in 0..<30 where admittedAt == nil {
            let now = TimeInterval(second)
            var listed = (0..<50).map { "fake-\(second)-\($0)" }
            if second >= 2 { listed.append("real") }
            let selection = gate.select(listed, key: { $0 }, isRecovery: { _ in false }, fanOut: 3, now: now)
            for key in selection.chosen {
                gate.noteAttempt(now: now)
                attemptTimes.append(now)
                if key == "real" { admittedAt = now; break }
                gate.noteFailure(key, now: now)
            }
        }
        let admitted = try! XCTUnwrap(admittedAt)
        XCTAssertLessThanOrEqual(admitted - 2, 15, "the real viewer is tried within 15 s")
        for start in attemptTimes {
            XCTAssertLessThanOrEqual(attemptTimes.filter { $0 >= start && $0 < start + ViewerAdmissionGate.window }.count, 4,
                                     "at most 4 attempts in any 10 s")
        }
    }

    func testAFailedKeyIsTriedAfterUntriedOnesButNeverExcluded() {
        let gate = ViewerAdmissionGate()
        _ = gate.select(["a"], key: { $0 }, isRecovery: { _ in false }, fanOut: 3, now: 0)
        gate.noteAttempt(now: 0); gate.noteFailure("a", now: 0)
        let selection = gate.select(["a", "b"], key: { $0 }, isRecovery: { _ in false }, fanOut: 3, now: 1)
        XCTAssertEqual(selection.chosen, ["b", "a"], "the older but failed key goes after the new one")
        let later = gate.select(["a", "b"], key: { $0 }, isRecovery: { _ in false }, fanOut: 3, now: 11)
        XCTAssertEqual(later.chosen.first, "a", "after 10 s the failure no longer counts and the oldest goes first")
    }

    func testRecoveryRequestsGoFirstAndAreNotCounted() {
        let gate = ViewerAdmissionGate()
        for _ in 0..<4 { gate.noteAttempt(now: 0) }
        let selection = gate.select(["x", "rec"], key: { $0 }, isRecovery: { $0 == "rec" }, fanOut: 3, now: 1)
        XCTAssertEqual(selection.chosen, ["rec"])
        XCTAssertEqual(selection.deferred, ["x"], "deferred, not refused")
    }

    /// Fresh keys that all claim to recover a child this source does not hold are paced like any other request.
    func testAFloodClaimingRecoveryIsStillBounded() {
        let gate = ViewerAdmissionGate()
        let child = Data([1, 2, 3, 4, 5, 6]), stranger = Data([9, 9, 9, 9, 9, 9])
        var attempts = 0
        for second in 0..<10 {
            let keys = (0..<50).map { "fake-\(second)-\($0)" }
            let selection = gate.select(keys, key: { $0 }, isRecovery: { _ in
                ViewerAdmissionGate.isRecovery(requester: Data([7, 7, 7, 7, 7, 7]), namedChild: stranger, children: [child])
            }, fanOut: 3, now: TimeInterval(second))
            for key in selection.chosen { gate.noteAttempt(now: TimeInterval(second)); gate.noteFailure(key, now: TimeInterval(second)); attempts += 1 }
        }
        XCTAssertEqual(attempts, 4, "4 attempts in the 10 s window, whatever the requests claim")
        XCTAssertTrue(ViewerAdmissionGate.isRecovery(requester: stranger, namedChild: child, children: [child]), "a held child's recovery")
        XCTAssertFalse(ViewerAdmissionGate.isRecovery(requester: child, namedChild: child, children: [child]), "not its own recovery")
    }

    func testAWholeGroupStillFillsEveryFreeSlot() {
        let gate = ViewerAdmissionGate()
        let keys = (0..<10).map { "v\($0)" }
        XCTAssertEqual(gate.select(keys, key: { $0 }, isRecovery: { _ in false }, fanOut: 6, now: 0).chosen, Array(keys.prefix(6)))
    }

    func testOffEveryRequestIsChosenInOrder() {
        let gate = ViewerAdmissionGate(enabled: { false })
        let keys = (0..<50).map { "v\($0)" }
        let selection = gate.select(keys, key: { $0 }, isRecovery: { _ in false }, fanOut: 3, now: 0)
        XCTAssertEqual(selection.chosen, keys)
        XCTAssertTrue(selection.deferred.isEmpty)
    }

    func testTheTablesStayBoundedUnderALongFlood() {
        let gate = ViewerAdmissionGate()
        for second in 0..<120 {
            let now = TimeInterval(second)
            let keys = (0..<50).map { "f-\(second)-\($0)" }
            for key in gate.select(keys, key: { $0 }, isRecovery: { _ in false }, fanOut: 3, now: now).chosen {
                gate.noteAttempt(now: now); gate.noteFailure(key, now: now)
            }
            XCTAssertLessThanOrEqual(gate.trackedKeys, 2 * ViewerAdmissionGate.maxTracked)
        }
    }
}
