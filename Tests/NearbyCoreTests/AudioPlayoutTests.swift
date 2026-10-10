import XCTest
@testable import NearbyCore

final class AudioPlayoutTests: XCTestCase {
    private func packet(_ i: Int) -> Data { Data([0xfc, UInt8(i & 0xff)]) }

    func testBuffersToTargetThenPlaysInOrderWithConcealment() {
        var p = AudioPlayout(targetFrames: 3)
        let base: Int64 = 1_234_567
        p.push(presentationTimeUs: base, payload: packet(0))
        XCTAssertEqual(p.pop(), .silence)
        p.push(presentationTimeUs: base + 20_000, payload: packet(1))
        p.push(presentationTimeUs: base + 60_000, payload: packet(3)) // slot 2 lost
        XCTAssertEqual(p.pop(), .packet(packet(0)))
        XCTAssertEqual(p.pop(), .packet(packet(1)))
        XCTAssertEqual(p.pop(), .conceal)
        XCTAssertEqual(p.pop(), .packet(packet(3)))
        p.push(presentationTimeUs: base + 40_000, payload: packet(2)) // too late
        XCTAssertEqual(p.late, 1)
        XCTAssertEqual(p.pop(), .silence); XCTAssertEqual(p.underruns, 1)
        XCTAssertEqual(p.targetFrames, 5, "drain grows the target")
    }

    func testAndroidBatchesAndSmallTimestampJitter() throws {
        var p = AudioPlayout(targetFrames: 4)
        // A BTA2 batch of 20 packets arrives at once, timestamps with +-300 us jitter.
        let batch = (0..<20).map { MediaPacket(flags: StreamProtocol.flagAudio, presentationTimeUs: Int64($0) * 20_000 + ($0 % 2 == 0 ? 300 : -300), payload: packet($0)) }
        for unit in try MediaPacket.combineAudio(batch).splitAudio() { p.push(presentationTimeUs: unit.presentationTimeUs, payload: unit.payload) }
        var played: [Data] = []
        for _ in 0..<20 { if case .packet(let d) = p.pop() { played.append(d) } }
        XCTAssertEqual(played, (0..<20).map(packet))
    }

    func testSenderRestartResetsTimelineAndOverflowIsBounded() {
        var p = AudioPlayout(targetFrames: 2, capacityFrames: 10)
        for i in 0..<5 { p.push(presentationTimeUs: Int64(i) * 20_000, payload: packet(i)) }
        _ = p.pop()
        p.push(presentationTimeUs: 900_000_000, payload: packet(99)) // clock jump: new timeline
        p.push(presentationTimeUs: 900_020_000, payload: packet(100))
        XCTAssertEqual(p.pop(), .packet(packet(99)))
        for i in 0..<40 { p.push(presentationTimeUs: 900_040_000 + Int64(i) * 20_000, payload: packet(i)) }
        XCTAssertLessThanOrEqual(p.bufferedFrames, 10); XCTAssertGreaterThan(p.overflows, 0)
    }

    /// Experimental FEC: one missing frame is rebuilt from the next packet (not concealed); longer gaps still
    /// conceal until the frame just before an arrived packet.
    func testFecRecoversTheFrameJustBeforeAnArrivedPacket() {
        var p = AudioPlayout(targetFrames: 2)
        p.fecRecovery = true
        for i in [0, 1, 3, 4] { p.push(presentationTimeUs: Int64(i) * 20_000, payload: Data([UInt8(i)])) }
        XCTAssertEqual(p.pop(), .packet(Data([0]))); XCTAssertEqual(p.pop(), .packet(Data([1])))
        XCTAssertEqual(p.pop(), .recover(fromNext: Data([3])), "frame 2 from packet 3's in-band FEC")
        XCTAssertEqual(p.pop(), .packet(Data([3])), "packet 3 itself still plays")
        XCTAssertEqual(p.recovered, 1); XCTAssertEqual(p.concealed, 0)
        var off = AudioPlayout(targetFrames: 2)
        for i in [0, 1, 3] { off.push(presentationTimeUs: Int64(i) * 20_000, payload: Data([UInt8(i)])) }
        _ = off.pop(); _ = off.pop()
        XCTAssertEqual(off.pop(), .conceal, "off by default: PLC as before")
    }
}
