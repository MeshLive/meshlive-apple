import XCTest
@testable import NearbyCore

/// Android's real BTA1/BTA2 audio bytes (android-vectors.json, produced by Android's own EndToEndStreamProtocol)
/// through the iPhone's receive path: unit split, microsecond timestamps and playout order.
final class AndroidAudioPathTests: XCTestCase {
    func testAndroidAudioPacketsPairsAndBatchesPlayInOrder() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "android-vectors", withExtension: "json", subdirectory: "Fixtures"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let contents = try XCTUnwrap(json["bme1Contents"] as? [[String: Any]])
        func packet(_ label: String) throws -> MediaPacket {
            let entry = try XCTUnwrap(contents.first { $0["label"] as? String == label }, label)
            let bytes = try XCTUnwrap(Data(hex: try XCTUnwrap(entry["plaintext"] as? String)))
            return try MediaPacket(decoding: bytes, authenticatedFlags: UInt8(try XCTUnwrap(entry["flags"] as? Int)))
        }
        let config = try packet("audioConfig")
        XCTAssertTrue(config.isCodecConfig); XCTAssertEqual(try OpusHead.parse(config.payload).preSkip, 312)
        var units: [MediaPacket] = []
        for label in ["audio", "audioPair", "audioBatch"] { units += try packet(label).splitAudio() }
        // Timestamps are microseconds on a 20 ms grid (Android MediaCodec PTS), not samples or milliseconds.
        XCTAssertEqual(units.map(\.presentationTimeUs), [20_000, 40_000, 60_000, 80_000, 100_000, 120_000])
        for order in [units, units.reversed()] {
            var playout = AudioPlayout(targetFrames: 4)
            for unit in order { playout.push(presentationTimeUs: unit.presentationTimeUs, payload: unit.payload) }
            var played: [Data] = []
            for _ in 0..<8 { if case .packet(let data) = playout.pop() { played.append(data) } }
            XCTAssertEqual(played, units.map(\.payload), "every Android unit plays once, in timestamp order (also when reordered before playback)")
            XCTAssertEqual(playout.late, 0)
        }
    }
}
