import XCTest
@testable import NearbyCore

/// B1.2 F4: the main-thread stall tracker names the task that was running and reports while the stall is still open.
final class MainStallTrackerTests: XCTestCase {
    func testNothingIsReportedBeforeThreeQuartersOfASecond() {
        var tracker = MainStallTracker()
        tracker.pingSent(at: 0)
        XCTAssertNil(tracker.poll(at: 0.5))
        XCTAssertNil(tracker.poll(at: 0.74))
        XCTAssertNil(tracker.pingAnswered(at: 0.7))
    }

    func testAStallNamesTheInnermostRunningTask() {
        var tracker = MainStallTracker()
        tracker.enter("outer", at: 0)
        tracker.enter("inner", at: 0.1)
        tracker.pingSent(at: 0)
        let open = tracker.poll(at: 0.8)
        XCTAssertEqual(open?.running, ["outer", "inner"])
        XCTAssertEqual(open?.runningForMs, 700)
        XCTAssertEqual(open?.stalledMs, 800)
    }

    func testAnUnmarkedStallSaysSoAndNamesTheLastFinishedTask() {
        var tracker = MainStallTracker()
        tracker.enter("work", at: 0)
        tracker.exit(at: 0.1)
        tracker.pingSent(at: 0.2)
        let open = tracker.poll(at: 1.0)
        XCTAssertEqual(open?.running, [])
        XCTAssertEqual(open?.lastFinished, "work")
        XCTAssertEqual(open?.lastFinishedAgoMs, 900)
    }

    func testItReportsAgainAtTwoFiveAndTenSeconds() {
        var tracker = MainStallTracker()
        tracker.pingSent(at: 0)
        XCTAssertNotNil(tracker.poll(at: 0.8))
        XCTAssertNil(tracker.poll(at: 1.9))
        XCTAssertNotNil(tracker.poll(at: 2.1))
        XCTAssertNil(tracker.poll(at: 4.9))
        XCTAssertNotNil(tracker.poll(at: 5.1))
        XCTAssertNil(tracker.poll(at: 9.9))
        XCTAssertNotNil(tracker.poll(at: 10.1))
        XCTAssertNil(tracker.poll(at: 19.9))
        XCTAssertNotNil(tracker.poll(at: 20.1))
    }

    func testTheEndReportsTheTotalAndTheLongestMarkedTask() {
        var tracker = MainStallTracker()
        tracker.enter("short", at: 0)
        tracker.exit(at: 0.2)
        tracker.enter("slow", at: 0.3)
        tracker.pingSent(at: 0.3)
        XCTAssertEqual(tracker.poll(at: 2.0)?.running, ["slow"])
        tracker.exit(at: 2.0)
        let ended = tracker.pingAnswered(at: 2.1)
        XCTAssertEqual(ended?.totalMs, 1800)
        XCTAssertEqual(ended?.longestMarked, "slow")
        XCTAssertEqual(ended?.longestMarkedMs, 1700)
    }

    func testTaskBracketsNestToEightAndDeeperOnesAreIgnored() {
        var tracker = MainStallTracker()
        for depth in 1...9 { tracker.enter("task\(depth)", at: Double(depth) * 0.01) }
        tracker.pingSent(at: 0)
        let open = tracker.poll(at: 0.8)
        XCTAssertEqual(open?.running, (1...8).map { "task\($0)" })
        for _ in 1...9 { tracker.exit(at: 0.9) }
        tracker.pingSent(at: 1.0)
        XCTAssertEqual(tracker.poll(at: 2.0)?.running, [])
    }
}
