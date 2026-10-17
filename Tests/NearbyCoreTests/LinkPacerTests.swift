import XCTest
@testable import NearbyCore

/// Android LinkSelfMeasurementTest pacer cases, same numbers.
final class LinkPacerTests: XCTestCase {
    var nowNs: Int64 = 1_000_000_000
    private func pacer(burstNs: Int64 = LinkPacer.burstNs) -> LinkPacer { LinkPacer(nanoTime: { [unowned self] in self.nowNs }, burstNs: burstNs) }
    private var floor: Int64 { Int64(Double(LinkPacer.minSeedKbps * 1_000 / 8) * LinkPacer.paceGain) }

    func testPacingAllowsOnlyAShortBurstAheadOfTheMeasuredLink() {
        let p = pacer()
        XCTAssertEqual(p.waitNs(), 0)
        p.onSent(100_000)
        XCTAssertEqual(p.waitNs(), 0, "unpaced until a measurement arrives")
        p.setMeasuredLinkKbps(800)                       // 120 000 B/s; 12 000 bytes drain in 100 ms
        p.onSent(12_000)
        XCTAssertEqual(p.waitNs(), 50_000_000)
        nowNs += 60_000_000
        XCTAssertEqual(p.waitNs(), 0)
    }

    func testASeededLinkIsPacedFromTheFirstWriteAndTheFirstReportReplacesTheSeed() {
        let p = pacer()
        XCTAssertFalse(p.measured)
        XCTAssertTrue(p.seed(kbps: 400))                 // 60 000 B/s
        XCTAssertEqual(p.bytesPerSecond, 60_000)
        XCTAssertFalse(p.seed(kbps: 900))
        p.onSent(6_000)                                  // 100 ms of link time
        XCTAssertEqual(p.waitNs(), 50_000_000)
        p.setMeasuredLinkKbps(1_200)                     // 180 000 B/s: the rest drains in a third
        XCTAssertTrue(p.measured)
        XCTAssertEqual(p.bytesPerSecond, 180_000)
        XCTAssertEqual(p.waitNs(), 0)
        XCTAssertFalse(p.seed(kbps: 100))
    }

    func testASeedHeldWithoutAnyReportDecays() {
        let p = pacer()
        p.seed(kbps: 800)
        nowNs += 3_000_000_000
        XCTAssertEqual(p.bytesPerSecond, 120_000)
        nowNs += 2_000_000_000
        XCTAssertEqual(p.bytesPerSecond, 60_000)
        nowNs += 60_000_000_000
        XCTAssertEqual(p.bytesPerSecond, floor)
        p.setMeasuredLinkKbps(800)
        XCTAssertEqual(p.bytesPerSecond, 120_000)
    }

    func testOnTimeReportsFromAnUnmeasuredChildHoldTheSeed() {
        let p = pacer()
        p.seed(kbps: 1_488)
        let seeded = p.bytesPerSecond
        for _ in 0..<30 {
            nowNs += 2_000_000_000
            XCTAssertTrue(p.holdSeed())
            XCTAssertEqual(p.bytesPerSecond, seeded)
        }
        nowNs += 60_000_000_000
        XCTAssertEqual(p.bytesPerSecond, floor)
        XCTAssertTrue(p.holdSeed())
        XCTAssertEqual(p.bytesPerSecond, seeded)
        p.setMeasuredLinkKbps(600)
        XCTAssertFalse(p.holdSeed())
        XCTAssertEqual(p.bytesPerSecond, 90_000)
    }

    func testTheSeedRaiseGrowsAHeldSeedOnlyWhileTheSenderBacksUp() {
        let p = pacer()
        p.seed(kbps: 350)
        XCTAssertTrue(p.holdSeed())
        XCTAssertTrue(p.holdSeed(raiseBacklogMs: LinkPacer.seedRaiseBacklogMs - 1))
        XCTAssertEqual(p.seedKbps, 350)
        XCTAssertTrue(p.holdSeed(raiseBacklogMs: LinkPacer.seedRaiseBacklogMs))
        XCTAssertEqual(p.seedKbps, 437)
        XCTAssertEqual(p.bytesPerSecond, Int64(437.5 * 1_000 / 8 * LinkPacer.paceGain))
        for _ in 0..<20 { p.holdSeed(raiseBacklogMs: 10_000) }
        XCTAssertEqual(p.seedKbps, LinkPacer.seedRaiseCapKbps)
        nowNs += 60_000_000_000
        XCTAssertEqual(p.bytesPerSecond, floor)
        p.setMeasuredLinkKbps(600)
        XCTAssertFalse(p.holdSeed(raiseBacklogMs: 10_000))
        XCTAssertEqual(p.bytesPerSecond, 90_000)
    }

    func testARaisedSeedDrainsWhatWasAlreadyChargedAtTheNewPace() {
        let p = pacer(burstNs: 0)
        p.seed(kbps: 400)
        p.onSent(60_000, writeStartedNs: nowNs)          // one second ahead
        XCTAssertEqual(p.waitNs(), 1_000_000_000)
        p.holdSeed(raiseBacklogMs: LinkPacer.seedRaiseBacklogMs)   // 500 kbps
        XCTAssertEqual(p.waitNs(), 800_000_000)
    }

    func testHoldingAnUnseededPacerLeavesItUnpacedAndDecayNeverRaisesALowSeed() {
        let p = pacer()
        XCTAssertFalse(p.holdSeed())
        XCTAssertEqual(p.bytesPerSecond, 0)
        XCTAssertEqual(LinkPacer.decayedSeed(10_000, silenceNs: 100_000_000_000), 10_000)
        XCTAssertEqual(LinkPacer.seedKbps(.gatt, probeKbps: 620), 620)
        XCTAssertEqual(LinkPacer.seedKbps(.gatt, probeKbps: nil), 350)
        XCTAssertEqual(LinkPacer.seedKbps(.l2cap, probeKbps: 0), 350)
    }

    func testABlockingWriteIsChargedFromItsStart() {
        let p = pacer(burstNs: 0)
        p.setMeasuredLinkKbps(800)                       // 120 000 B/s
        let started = nowNs
        nowNs += 100_000_000                             // the write itself took 100 ms
        p.onSent(12_000, writeStartedNs: started)
        XCTAssertEqual(p.waitNs(), 0, "its transmit time is not paid twice")
    }
}
