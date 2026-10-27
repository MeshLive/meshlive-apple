import XCTest
@testable import NearbyCore

/// Android `ArrivalTrainMeter` rules on Apple's chunk deliveries.
final class ArrivalTrainMeterTests: XCTestCase {
    /// One record of `chunks` 200-byte chunks, `spacing` apart, starting at `start` after an idle link.
    private func record(_ meter: ArrivalTrainMeter, start: TimeInterval, chunks: Int = 50, spacing: TimeInterval = 0.01,
                        pendingBefore: Int = 0) -> Int? {
        var result: Int?
        for i in 0..<chunks {
            let last = i == chunks - 1
            result = meter.noteChunk(bytes: 200, at: start + Double(i) * spacing, pendingBefore: i == 0 ? pendingBefore : 1,
                                     completedRecords: last ? 1 : 0, pendingAfter: 0)
        }
        return result
    }

    func testALargeRecordIsATrainAndItsFirstChunkIsNotCounted() {
        let meter = ArrivalTrainMeter()
        // 49 counted chunks of 200 bytes over 0.49 s: 160 kbps.
        XCTAssertEqual(record(meter, start: 1), 160)
        XCTAssertEqual(meter.trains, 1)
        XCTAssertEqual(meter.estimateKbps(now: 2), 160)
    }

    func testABacklogOrARecordAlreadyBufferedIsNotATrain() {
        let meter = ArrivalTrainMeter()
        _ = meter.noteChunk(bytes: 100, at: 1, pendingBefore: 0, completedRecords: 1, pendingAfter: 0)
        // Delivered 1 ms after the previous chunk: it waited in a backlog, so the link's timing is unknown.
        XCTAssertNil(record(meter, start: 1.001))
        // The record's start arrived with the previous chunk.
        XCTAssertNil(record(meter, start: 3, pendingBefore: 40))
        // Too short a train (under 8000 bytes).
        XCTAssertNil(record(meter, start: 5, chunks: 30))
        XCTAssertEqual(meter.trains, 0)
        XCTAssertNil(meter.estimateKbps(now: 6))
    }

    func testTheEstimateIsTheMedianOfTheLastTenSeconds() {
        let meter = ArrivalTrainMeter()
        XCTAssertEqual(record(meter, start: 1, spacing: 0.02), 80)
        XCTAssertEqual(record(meter, start: 3, spacing: 0.005), 320)
        XCTAssertEqual(record(meter, start: 5), 160)
        XCTAssertEqual(meter.estimateKbps(now: 6), 160)
        XCTAssertEqual(meter.estimateKbps(now: 12), 160, "the first train has left the window: median of 320 and 160")
        XCTAssertNil(meter.estimateKbps(now: 16))
    }
}
