import XCTest
@testable import NearbyCore
@testable import NearbyV1Experimental

final class MediaTests: XCTestCase {
    func testZeroStreamAndRepeatedPlayedTimestampAreRejected() throws {
        let profile = MediaProfile(codec: .pcmDiagnostic, video: false)
        func packet(_ stream: UInt32, _ time: UInt64, _ discontinuity: Bool) -> AudioPacket {
            AudioPacket(stream: stream, timestamp: time, final: false, discontinuity: discontinuity, validSamples: 160, payload: Data(repeating: 0, count: 320))
        }
        XCTAssertThrowsError(try AudioPacket(decoding: packet(0, 0, true).encoded, profile: profile))
        var jitter = JitterBuffer(sampleRate: 8000)
        for i in 0..<3 { try jitter.push(packet(1, UInt64(i * 160), i == 0)) }
        _ = jitter.pop(); _ = jitter.pop(); _ = jitter.pop()
        XCTAssertThrowsError(try jitter.push(packet(1, 320, false)))
        try jitter.push(packet(1, 480, false))
    }
    func testLateFinalStopsPlayoutAndRequiresNewStream() throws {
        var jitter = JitterBuffer(sampleRate: 8000)
        let payload = Data(repeating: 0, count: 320)
        for i in 0..<3 { try jitter.push(AudioPacket(stream: 1, timestamp: UInt64(i * 160), final: false, discontinuity: i == 0, validSamples: 160, payload: payload)) }
        for _ in 0..<5 { _ = jitter.pop() }
        try jitter.push(AudioPacket(stream: 1, timestamp: 480, final: true, discontinuity: false, validSamples: 0, payload: Data()))
        XCTAssertFalse(jitter.running); XCTAssertEqual(jitter.late, 1)
        XCTAssertThrowsError(try jitter.push(AudioPacket(stream: 1, timestamp: 640, final: false, discontinuity: false, validSamples: 160, payload: payload)))
    }
    func testH264DependencyRecoveryAndMalformedNALs() throws {
        var w = BinaryWriter(); w.u32(2); w.bytes(Data([0x65,0xAA]))
        let idr = try VideoFrame(timestamp: 0, keyframe: true, discontinuity: true, avcc: w.data)
        var p = BinaryWriter(); p.u32(2); p.bytes(Data([0x41,0xBB]))
        let predictive = try VideoFrame(timestamp: 200000, keyframe: false, discontinuity: false, avcc: p.data)
        var gate = VideoDependencyGate()
        XCTAssertFalse(try gate.accept(predictive)); XCTAssertTrue(try gate.accept(idr)); XCTAssertTrue(try gate.accept(predictive))
        XCTAssertThrowsError(try gate.accept(predictive)); gate.decoderFailed()
        let future = try VideoFrame(timestamp: 400000, keyframe: false, discontinuity: false, avcc: p.data)
        XCTAssertFalse(try gate.accept(future)); XCTAssertTrue(try gate.accept(try VideoFrame(timestamp: 600000, keyframe: true, discontinuity: true, avcc: w.data)))
        XCTAssertThrowsError(try VideoFrame(timestamp: 1, keyframe: true, discontinuity: false, avcc: p.data))
        XCTAssertThrowsError(try VideoFrame(timestamp: 1, keyframe: false, discontinuity: false, avcc: Data([0,0,0,255,0x41])))
        XCTAssertThrowsError(try VideoFrame(timestamp: 1, keyframe: false, discontinuity: true, avcc: p.data))
        XCTAssertThrowsError(try VideoFrame(timestamp: .max, keyframe: true, discontinuity: true, avcc: w.data))
        let config = try VideoConfiguration(sps: Data([0x67,0x42,0,0x0A]), pps: Data([0x68,0xCE]))
        XCTAssertEqual(try VideoConfiguration(decoding: config.encoded), config)
        var invalid = config.encoded; invalid[5] = 60
        XCTAssertThrowsError(try VideoConfiguration(decoding: invalid))
    }
}
