import XCTest
@testable import NearbyCore

/// Experimental GR1 lost-chunk recovery between two simulated link ends (Android GattChunkRecoveryTest): the sender
/// (A) writes data, the reader (B) asks for what is missing, A resends the stored value byte for byte.
final class GattChunkRecoveryTests: XCTestCase {
    private final class End {
        let recovery = GattChunkRecovery { _ in }
        var reader: GattChunkReader
        var writer = GattChunkWriter()
        var delivered = Data()
        init() { reader = GattChunkReader(recovery: nil); reader.recovery = recovery }
    }

    /// Moves every queued control value or resend from `from` to `to` (data values go into the reader).
    private func flush(_ from: End, _ to: End, now: TimeInterval, drop: (Data) -> Bool = { _ in false }) throws {
        while let value = from.recovery.nextPriorityValue(now: now) {
            if drop(value) { continue }
            if value.first == Gr1.type { to.recovery.onControl(value, now: now, reader: &to.reader) }
            else { to.delivered += try to.reader.accept(value, now: now) }
        }
    }

    private func linked() throws -> (End, End) {
        let a = End(), b = End()
        a.recovery.start(valueLimit: 100, now: 0); b.recovery.start(valueLimit: 100, now: 0)
        try flush(a, b, now: 0); try flush(b, a, now: 0)            // HELLOs cross
        XCTAssertTrue(a.recovery.readerActive && b.recovery.readerActive)
        return (a, b)
    }

    /// A sends `count` one-byte data values; those in `lost` never arrive.
    private func send(_ a: End, _ b: End, count: Int, lost: Set<UInt32>, now: TimeInterval) throws {
        for value in a.writer.chunks(Data((0..<count).map { UInt8($0) }), valueLimit: 6) {
            let sequence = UInt32(value[1]) << 24 | UInt32(value[2]) << 16 | UInt32(value[3]) << 8 | UInt32(value[4])
            a.recovery.onDataSent(sequence: sequence, value: value, now: now)
            if !lost.contains(sequence) { b.delivered += try b.reader.accept(value, now: now) }
        }
    }

    func testALostValueIsResentByteForByteAndTheStreamContinues() throws {
        let (a, b) = try linked()
        try send(a, b, count: 5, lost: [2], now: 0.1)
        XCTAssertEqual(b.delivered, Data([0, 1]), "chunks 3 and 4 wait behind the gap")
        try b.reader.check(now: 0.12)                                   // B asks (NACK)
        try flush(b, a, now: 0.13)                                      // A queues the resend
        try flush(a, b, now: 0.14)                                      // the stored value arrives
        XCTAssertEqual(b.delivered, Data([0, 1, 2, 3, 4]))
        XCTAssertNoThrow(try b.reader.check(now: 5), "nothing missing any more")
    }

    func testAnIdleProbeRecoversALostLastValue() throws {
        let (a, b) = try linked()
        try send(a, b, count: 3, lost: [2], now: 0)
        XCTAssertEqual(b.delivered, Data([0, 1]), "the reader cannot see that the last value is missing")
        a.recovery.tick(now: 0.25)                                       // 200 ms idle: HIGH 2
        try flush(a, b, now: 0.25)
        try b.reader.check(now: 0.26); try flush(b, a, now: 0.27); try flush(a, b, now: 0.28)
        XCTAssertEqual(b.delivered, Data([0, 1, 2]))
    }

    func testAValueTheSenderNoLongerHoldsEndsTheStream() throws {
        let (a, b) = try linked()
        try send(a, b, count: 5, lost: [2], now: 0)                    // B's request is queued at once
        try flush(b, a, now: 2.1); try flush(a, b, now: 2.1)            // it arrives after A's 2 s history: GONE
        XCTAssertThrowsError(try b.reader.check(now: 2.1)) { XCTAssertTrue("\($0)".contains("no longer holds"), "\($0)") }
    }

    func testUnansweredRequestsEndTheStreamAfterOneSecond() throws {
        let (a, b) = try linked()
        try send(a, b, count: 5, lost: [2], now: 0)
        for t in stride(from: 0.05, to: 1.0, by: 0.05) {
            try b.reader.check(now: t)
            try flush(b, a, now: t, drop: { _ in true })                // every NACK is lost
        }
        XCTAssertThrowsError(try b.reader.check(now: 1.01)) { XCTAssertTrue("\($0)".contains("GATT chunk 2 was lost (3 requests"), "\($0)") }
    }

    func testWithoutThePeersHelloTheReaderKeepsTheFailFast() throws {
        let b = End()
        b.recovery.start(valueLimit: 100, now: 0)
        XCTAssertFalse(b.recovery.readerActive)
        _ = try b.reader.accept(Gr1Fixture.data(0), now: 0)
        _ = try b.reader.accept(Gr1Fixture.data(2), now: 0)
        XCTAssertThrowsError(try b.reader.check(now: 1.1), "option A applies")
    }

    func testCodecClampsAndRejects() {
        XCTAssertEqual(Gr1.decode(Gr1.hello(values: 60_000, bytes: 9_000_000, ms: 9_000)), .hello(values: 1_024, bytes: 262_144, ms: 2_000))
        let nack = Gr1.nack([Gr1.SeqRange(first: 7, run: 3)])
        XCTAssertEqual(Gr1.decode(nack), .nack([Gr1.SeqRange(first: 7, run: 3)]))
        XCTAssertNil(Gr1.decode(nack.dropLast()), "wrong length")
        XCTAssertNil(Gr1.decode(Data([2, 0x47, 0x52, 9])), "unknown op")
        XCTAssertNil(Gr1.decode(Data([2, 1, 2, 3])), "another type-2 value is not GR1")
        XCTAssertEqual(Gr1.nackRangesFitting(valueLimit: 20), 3)
    }
}

enum Gr1Fixture {
    static func data(_ sequence: UInt32) -> Data { var w = BinaryWriter(capacity: 6); w.byte(1); w.u32(sequence); w.byte(9); return w.data }
}
