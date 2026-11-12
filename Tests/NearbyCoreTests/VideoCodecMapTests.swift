import XCTest
@testable import NearbyCore

/// AB5 step 1: the Design HC numbers and the one mapping table (PROTOCOL "Draft: HEVC and H.264 video codecs", Numbers;
/// Android `HcCodecNegotiationTest.codecIdHelloAndSummaryVectors` and the old-reader cases).
final class VideoCodecMapTests: XCTestCase {
    private let vp9 = NodeCapabilities.codecVP9, av1 = NodeCapabilities.codecAV1
    private let h264 = NodeCapabilities.codecH264, hevc = NodeCapabilities.codecHEVC
    private let bit4 = NodeCapabilities.decodeAV1Software, bit7 = NodeCapabilities.decodePrefersVP9

    override func tearDown() {
        StreamProtocol.hevcEnabled = false
        StreamProtocol.h264Enabled = false
        super.tearDown()
    }

    func testCodecIdHelloAndSummaryVectorsMatchAndroid() {
        let rows: [(codecId: UInt8, hello: UInt8, summary: UInt8)] = [(2, 0x01, 0x01), (3, 0x02, 0x02), (4, 0x04, 0x04), (5, 0x08, 0x80)]
        for row in rows {
            XCTAssertEqual(StreamProtocol.capabilityMask(codecId: row.codecId), row.hello, "codec \(row.codecId)")
            XCTAssertEqual(VideoCodecMap.helloBit(codecId: row.codecId), row.hello, "codec \(row.codecId)")
            XCTAssertEqual(VideoCodecMap.summaryBit(codecId: row.codecId), row.summary, "codec \(row.codecId)")
            XCTAssertEqual(VideoCodecMap.helloMaskToSummary(row.hello), row.summary, "codec \(row.codecId)")
            XCTAssertEqual(VideoCodecMap.summaryToHelloMask(row.summary), row.hello, "codec \(row.codecId)")
        }
        XCTAssertEqual(VideoCodecMap.summaryCodecBits, 0x87)
        XCTAssertEqual(VideoCodecMap.helloCodecBits, 0x0f)
        XCTAssertEqual(StreamProtocol.codecH264, 4)
        XCTAssertEqual(StreamProtocol.codecHEVC, 5)
        XCTAssertEqual(bit4, 0x10)
        XCTAssertEqual(VideoCodecMap.label(codecId: StreamProtocol.codecVP9), "VP9")
        XCTAssertEqual(VideoCodecMap.label(codecId: StreamProtocol.codecAV1), "AV1")
        XCTAssertEqual(VideoCodecMap.label(codecId: StreamProtocol.codecHEVC), "HEVC")
        XCTAssertEqual(VideoCodecMap.label(codecId: StreamProtocol.codecH264), "H264")
    }

    /// Old readers intersect a summary with a two-codec decode mask: summary bits 2 and 7 read as "no common codec", and
    /// the dual-listening hint (bit 3) and relay consent (bit 4) never read as HEVC or anything else.
    func testOldReadersSeeSummaryBits2And7AsNoCommonCodec() {
        for summary: UInt8 in [0x04, 0x80, 0x84] {
            XCTAssertEqual(summary & (vp9 | av1), 0)
            XCTAssertFalse(VideoCodecMap.summaryDecodable(summary, localDecodeHelloMask: vp9 | av1))
        }
        XCTAssertFalse(VideoCodecMap.summaryDecodable(0x08 | 0x10, localDecodeHelloMask: vp9 | av1 | hevc | h264))
        XCTAssertTrue(VideoCodecMap.summaryDecodable(0x80, localDecodeHelloMask: vp9 | hevc))
    }

    /// A call offer summary built from hello masks never sets the dual-listening bit 3 or relay consent, and preference
    /// bits never reach a summary; the compact form keeps VP9 and AV1 only while Q-HC2 is open.
    func testSummariesBuiltFromHelloMasksNeverSetBit3() {
        let encode = vp9 | hevc | h264, decode = vp9 | av1 | hevc | h264
        let summary = VideoCodecMap.helloMaskToSummary(encode & decode)
        XCTAssertEqual(summary, 0x01 | 0x80 | 0x04)
        XCTAssertEqual(summary & 0x08, 0)
        XCTAssertEqual(summary & CompactAnnouncement.relayConsent, 0)
        XCTAssertEqual(VideoCodecMap.helloMaskToSummary(vp9 | av1 | bit4 | bit7), 0x03)
        XCTAssertEqual(VideoCodecMap.compactSummary(helloMask: encode & decode), 0x01)
        XCTAssertEqual(VideoCodecMap.compactSummary(helloMask: vp9 | av1 | hevc), 0x03)
    }

    /// A video stream row plays only when its summary names a codec this device decodes, through the table.
    func testStreamRowsPlayAnHevcOfferOnlyWithHevcDecode() {
        func offer(_ summary: UInt8) -> DiscoveryAnnouncement {
            DiscoveryAnnouncement(nodeIdPrefix: Data([1, 2, 3, 4, 5, 6]), flags: DiscoveryAnnouncement.flagStreamAvailable, capabilitySummary: summary,
                                  streamToken: 0x8123_4567, routeCost: 0, streamWidth: 640, streamHeight: 360, streamFps: 15, streamBitrateKbps: 400)
        }
        XCTAssertFalse(StreamPlayability.playable(offer: offer(0x80), decodeMask: vp9 | av1, audioLive: false))
        XCTAssertTrue(StreamPlayability.playable(offer: offer(0x80), decodeMask: vp9 | hevc, audioLive: false))
        XCTAssertFalse(StreamPlayability.playable(offer: offer(0x08), decodeMask: vp9 | av1 | hevc | h264, audioLive: false))
        XCTAssertTrue(StreamPlayability.playable(offer: offer(0x09), decodeMask: vp9, audioLive: false), "VP9 with Android's dual-listening hint, as before")
        XCTAssertTrue(StreamPlayability.playable(offer: offer(0x04), decodeMask: h264, audioLive: false))
    }

    /// The `BTV3` header accepts codec 4 or 5 only while its master is on; VP9 and AV1 always.
    func testHeaderCodecIdsFollowTheMasters() throws {
        for codec in [StreamProtocol.codecH264, StreamProtocol.codecHEVC] {
            let encoded = try StreamHeader(width: 240, height: 426, fps: 15, codecId: codec, includeAudio: true).encoded()
            XCTAssertThrowsError(try StreamHeader(decoding: encoded), "codec \(codec) with its master off")
        }
        StreamProtocol.hevcEnabled = true
        XCTAssertEqual(try StreamHeader(decoding: try StreamHeader(width: 240, height: 426, fps: 15, codecId: 5, includeAudio: true).encoded()).codecId, 5)
        XCTAssertThrowsError(try StreamHeader(decoding: try StreamHeader(width: 240, height: 426, fps: 15, codecId: 4, includeAudio: true).encoded()))
        StreamProtocol.h264Enabled = true
        XCTAssertEqual(try StreamHeader(decoding: try StreamHeader(width: 240, height: 426, fps: 15, codecId: 4, includeAudio: true).encoded()).codecId, 4)
        XCTAssertThrowsError(try StreamHeader(decoding: try StreamHeader(width: 240, height: 426, fps: 15, codecId: 6, includeAudio: true).encoded()))
        XCTAssertTrue(StreamProtocol.accepts(codecId: StreamProtocol.codecVP9) && StreamProtocol.accepts(codecId: StreamProtocol.codecAV1))
    }

    /// The compact encoder never sends bit 56 while Q-HC2 is open, even with the H.264 master on; HEVC (summary 0x80)
    /// cannot be represented and is refused, never truncated into another bit.
    func testTheCompactEncoderNeverSendsBit56AndRefusesHevc() throws {
        StreamProtocol.h264Enabled = true
        let call = DiscoveryAnnouncement(nodeIdPrefix: Data([1, 2, 3, 4, 5, 6]),
                                         flags: DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable,
                                         capabilitySummary: 0x05, streamToken: 0, routeCost: 0)
        let decoded = try XCTUnwrap(CompactAnnouncement.decode(try CompactAnnouncement.encode(call)))
        XCTAssertEqual(decoded.capabilitySummary, 0x01)
        var hevcCall = call
        hevcCall.capabilitySummary = 0x81
        XCTAssertThrowsError(try CompactAnnouncement.encode(hevcCall))
    }

    /// Link and end-to-end hellos carry the HEVC bit (hello bit 3) unchanged; the relay keeps its summary mask.
    func testHellosCarryTheHevcBitAndTheRelaySummaryMaskIsUnchanged() throws {
        let caps = NodeCapabilities(transportMask: NodeCapabilities.transportGATT, encodeCodecMask: vp9 | hevc | h264,
                                    decodeCodecMask: vp9 | av1 | hevc | h264 | bit4 | bit7, maxBitrateKbps: 1100, maxChildren: 0)
        XCTAssertEqual(try NodeCapabilities(decoding: caps.encoded), caps)
        XCTAssertEqual(NodeCapabilities.helloCodecMask, 0x0f)
        XCTAssertEqual(CallRelayChain.relayedSummaryMask, 0x17)
    }
}
