import XCTest
@testable import NearbyCore

/// A lost GATT value ends the stream after 1 s (or 128 later chunks) with its reason, instead of the call ending 8 s
/// later as "peer stopped responding" (Android ChunkGapPolicyTest).
final class ChunkGapPolicyTests: XCTestCase {
    private func value(_ sequence: UInt32, _ byte: UInt8 = 0xAB) -> Data {
        var w = BinaryWriter(capacity: 6); w.byte(GattChunk.typeData); w.u32(sequence); w.byte(byte); return w.data
    }

    func testAGapHeldOneSecondFailsWithItsReason() throws {
        var reader = GattChunkReader()
        XCTAssertEqual(try reader.accept(value(0), now: 0).count, 1)
        _ = try reader.accept(value(2), now: 0.1)             // chunk 1 is missing
        XCTAssertNoThrow(try reader.check(now: 1.0))
        XCTAssertThrowsError(try reader.check(now: 1.1)) { error in
            XCTAssertTrue("\(error)".contains("GATT chunk 1 was lost"), "\(error)")
        }
    }

    func test128HeldChunksFailBeforeOneSecond() throws {
        var reader = GattChunkReader()
        _ = try reader.accept(value(0), now: 0)
        for sequence in 2..<129 { _ = try reader.accept(value(UInt32(sequence)), now: 0.01) }
        XCTAssertThrowsError(try reader.accept(value(129), now: 0.02), "128 later chunks waited")
    }

    func testABriefReorderDeliversEveryByte() throws {
        var reader = GattChunkReader()
        var out = Data()
        for sequence: UInt32 in [0, 2, 3, 1, 4] { out += try reader.accept(value(sequence, UInt8(sequence)), now: 0.05) }
        XCTAssertEqual(out, Data([0, 1, 2, 3, 4]))
        XCTAssertNil(reader.gapOpenedAt)
        XCTAssertNoThrow(try reader.check(now: 60))
    }

    func testASecondGapLeftBehindAFilledOneStartsItsOwnClock() throws {
        var reader = GattChunkReader()
        _ = try reader.accept(value(0), now: 0)
        _ = try reader.accept(value(2), now: 0)                // gap at 1
        _ = try reader.accept(value(4), now: 0.2)              // and at 3
        _ = try reader.accept(value(1), now: 0.9)              // first gap filled; 3 still missing
        XCTAssertEqual(reader.gapOpenedAt, 0.9)
        XCTAssertNoThrow(try reader.check(now: 1.5), "the old clock no longer counts")
        XCTAssertThrowsError(try reader.check(now: 1.95))
    }

    func testTheControlArmKeepsWaiting() throws {
        var reader = GattChunkReader(failFast: false)
        _ = try reader.accept(value(0), now: 0)
        for sequence in 2..<300 { _ = try reader.accept(value(UInt32(sequence)), now: 0.01) }
        XCTAssertNoThrow(try reader.check(now: 30))
    }
}

/// EXPERIMENTAL GATT client write pacing (`-gattWriteBurst N`): at most N data values per 10 ms window however often the
/// link pumps (sends, CoreBluetooth's ready callbacks, GR1 ticks), with one resume scheduled at a time.
final class GattWritePacerTests: XCTestCase {
    /// One `GattClientLink.pump` as the app runs it: writes while the pacer allows and values wait; a refusal schedules at
    /// most one resume (its due time is appended to `resumes`). Returns how many values were written.
    private func pump(_ pacer: inout GattWritePacer, now: TimeInterval, waiting: inout Int, resumes: inout [TimeInterval]) -> Int {
        var written = 0
        while waiting > 0 {
            guard pacer.mayWrite(now: now) else {
                if let delay = pacer.scheduleResume(now: now) { resumes.append(now + delay) }
                break
            }
            waiting -= 1; written += 1
        }
        return written
    }

    func testRepeatedPumpCallsAndReadyCallbacksNeverExceedTheBurstPerWindow() {
        var pacer = GattWritePacer(burst: 4)
        var waiting = 1_000
        var resumes: [TimeInterval] = []
        var writes: [TimeInterval] = []
        var now = 0.0
        // 200 ms with a send or a ready callback every 0.5 ms, plus every scheduled resume when it is due.
        while now < 0.2 {
            if let due = resumes.first, due <= now { resumes.removeFirst(); pacer.resumeFired() }
            let count = pump(&pacer, now: now, waiting: &waiting, resumes: &resumes)
            writes += Array(repeating: now, count: count)
            XCTAssertLessThanOrEqual(resumes.count, 1, "one resume scheduled at a time")
            now += 0.0005
        }
        for start in writes {
            let inWindow = writes.filter { $0 >= start && $0 < start + GattWritePacer.window }.count
            XCTAssertLessThanOrEqual(inWindow, 4, "at most 4 values in the 10 ms from \(start)")
        }
        XCTAssertGreaterThanOrEqual(writes.count, 4 * 18, "the link keeps writing, about 4 values per 10 ms")
    }

    func testPacingOffWritesEverythingAndNeverSchedulesAResume() {
        var pacer = GattWritePacer(burst: 0)
        var waiting = 500
        var resumes: [TimeInterval] = []
        XCTAssertEqual(pump(&pacer, now: 0, waiting: &waiting, resumes: &resumes), 500)
        XCTAssertTrue(resumes.isEmpty)
    }
}
