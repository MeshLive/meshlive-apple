import XCTest
import CryptoKit
@testable import NearbyCore

/// Experimental audio-only live streams: the Android vectors of Android's protocol reference (AudioLiveProtocolTest) and the
/// rejection cases, plus sign/verify round trips through the receiver guard.
final class AudioLiveTests: XCTestCase {
    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    func testFixedHeaderVectors() {
        XCTAssertEqual(hex(AudioLive.fixedHeader(preset: AudioLive.presetVoice)), "42544c3101bb8001140200")
        XCTAssertEqual(hex(AudioLive.fixedHeader(preset: AudioLive.presetLowData)), "42544c3101bb8001140100")
        XCTAssertEqual(hex(AudioLive.fixedHeader(preset: AudioLive.presetMusic)), "42544c3101bb8001140300")
    }

    func testCompactAudioOnlyVector() throws {
        var offer = DiscoveryAnnouncement(nodeIdPrefix: Data(hex: "010203040506")!,
                                          flags: DiscoveryAnnouncement.flagStreamAvailable | DiscoveryAnnouncement.flagGattTransport,
                                          capabilitySummary: AudioLive.summaryAudioOnly, streamToken: 0xdead_beef, routeCost: 1, sequence: 5)
        offer.streamBitrateKbps = 25
        XCTAssertEqual(try CompactAnnouncement.encode(offer), "C8D66010-2030-4050-6806-F56DF7782F81")
        let decoded = try XCTUnwrap(CompactAnnouncement.decode("C8D66010-2030-4050-6806-F56DF7782F81"))
        XCTAssertEqual(decoded.capabilitySummary, AudioLive.summaryAudioOnly)
        XCTAssertEqual(decoded.streamWidth, 0); XCTAssertEqual(decoded.streamHeight, 0); XCTAssertEqual(decoded.streamFps, 0)
        XCTAssertTrue(decoded.isAudioOnlyOffer)
        XCTAssertEqual(decoded.sequence, 5); XCTAssertEqual(decoded.routeCost, 1); XCTAssertEqual(decoded.streamToken, 0xdead_beef)
        // An audio-only offer with geometry cannot be encoded.
        offer.streamWidth = 640
        XCTAssertThrowsError(try CompactAnnouncement.encode(offer))
    }

    func testMarkerRules() {
        func offer(_ summary: UInt8, stream: Bool = true) -> DiscoveryAnnouncement {
            DiscoveryAnnouncement(nodeIdPrefix: Data(count: 6), flags: stream ? DiscoveryAnnouncement.flagStreamAvailable : DiscoveryAnnouncement.flagAcceptingConnections,
                                  capabilitySummary: summary, streamToken: 0x8000_0001, routeCost: 0)
        }
        XCTAssertEqual(offer(0x40).streamOfferKind, .audioOnly)
        for summary: UInt8 in [0x41, 0x42, 0x60, 0xc0] { XCTAssertEqual(offer(summary).streamOfferKind, .malformed, "\(summary)") }
        XCTAssertEqual(offer(0x40, stream: false).streamOfferKind, .malformed)
        XCTAssertEqual(offer(0x01).streamOfferKind, .video)
        var withGeometry = offer(0x40); withGeometry.streamWidth = 426
        XCTAssertEqual(withGeometry.streamOfferKind, .malformed)
    }

    private func signer(_ identity: SoftwareSigningIdentity = SoftwareSigningIdentity(), streamId: UUID = UUID()) throws -> AudioLiveSigner {
        try AudioLiveSigner(identity: identity, streamId: streamId, preset: AudioLive.presetVoice)
    }

    func testHeaderRoundTripAndRejections() throws {
        let s = try signer()
        let bytes = s.header.encoded
        XCTAssertEqual(bytes.prefix(11), AudioLive.fixedHeader(preset: AudioLive.presetVoice))
        XCTAssertEqual(hex(bytes.subdata(in: 11..<13)), "005b", "91-byte SPKI stream key")
        XCTAssertEqual(try AudioLiveHeader(decoding: bytes), s.header)
        var rate = bytes; rate[5] = 0xac; rate[6] = 0x44  // 44100
        XCTAssertThrowsError(try AudioLiveHeader(decoding: rate))
        var reserved = bytes; reserved[10] = 1
        XCTAssertThrowsError(try AudioLiveHeader(decoding: reserved))
        XCTAssertThrowsError(try AudioLiveHeader(decoding: bytes + Data([0])))
        var zeroKey = AudioLive.fixedHeader(preset: 2); zeroKey.append(contentsOf: [0, 0])
        XCTAssertThrowsError(try AudioLiveHeader(decoding: zeroKey))
        XCTAssertThrowsError(try AudioLiveHeader(decoding: Data("BTV3".utf8) + bytes.dropFirst(4)))
    }

    func testCertificateBindsSourceAndStream() throws {
        let identity = SoftwareSigningIdentity(), id = UUID()
        let s = try signer(identity, streamId: id)
        XCTAssertNoThrow(try AudioLiveVerifier(header: s.header, streamId: id, expectedSource: identity.nodeId))
        XCTAssertThrowsError(try AudioLiveVerifier(header: s.header, streamId: id, expectedSource: SoftwareSigningIdentity().nodeId), "other source")
        XCTAssertThrowsError(try AudioLiveVerifier(header: s.header, streamId: UUID(), expectedSource: identity.nodeId), "other stream")
    }

    // MARK: Guard

    private final class Clock { var ms: Int64 = 1_000_000 }

    private func setup() throws -> (AudioLiveSigner, AudioLiveStreamGuard, Clock) {
        let identity = SoftwareSigningIdentity(), id = UUID()
        let s = try signer(identity, streamId: id)
        let clock = Clock()
        let g = AudioLiveStreamGuard(verifier: try AudioLiveVerifier(header: s.header, streamId: id, expectedSource: identity.nodeId),
                                     clockMs: { clock.ms })
        return (s, g, clock)
    }

    private func units(_ count: Int, at pts: Int64, toc: UInt8 = 0x08, size: Int = 40) -> [MediaPacket] {
        (0..<count).map { MediaPacket(flags: StreamProtocol.flagAudio, presentationTimeUs: pts + Int64($0) * 20_000,
                                      payload: Data([toc]) + Data(repeating: 0x11, count: size - 1)) }
    }

    private func record(_ s: AudioLiveSigner, _ packets: [MediaPacket]) throws -> MediaPacket {
        let body = packets.count == 1 ? packets[0] : try MediaPacket.combineAudio(packets)
        return try s.sign(flags: body.flags, presentationTimeUs: body.presentationTimeUs, body: body.payload)
    }

    func testSignedRecordsPassAndUnwrap() throws {
        let (s, g, clock) = try setup()
        let config = try s.sign(flags: StreamProtocol.flagAudio | StreamProtocol.flagCodecConfig, presentationTimeUs: 0, body: OpusHead.make())
        XCTAssertEqual(try g.open(config).payload, OpusHead.make())
        XCTAssertEqual(g.opusHead, OpusHead.make())
        let first = try g.open(try record(s, units(10, at: 0)))
        XCTAssertEqual(try first.splitAudio().count, 10)
        clock.ms += 200
        XCTAssertNoThrow(try g.open(try record(s, units(10, at: 200_000))))
        // A shed record leaves a sequence gap: allowed with its time.
        _ = try record(s, units(10, at: 400_000))
        clock.ms += 400
        XCTAssertNoThrow(try g.open(try record(s, units(10, at: 600_000))))
        XCTAssertNoThrow(try g.open(try record(s, units(1, at: 800_000))), "a single unit")
    }

    func testRejections() throws {
        do { // a record signed by another key
            let (_, g, _) = try setup()
            let other = try signer()
            XCTAssertThrowsError(try g.open(try record(other, units(10, at: 0))))
        }
        do { // an edited record
            let (s, g, _) = try setup()
            var rec = try record(s, units(10, at: 0)); rec.payload[8] ^= 1
            XCTAssertThrowsError(try g.open(rec))
        }
        do { // a replayed seq
            let (s, g, _) = try setup()
            let rec = try record(s, units(10, at: 0))
            XCTAssertNoThrow(try g.open(rec))
            XCTAssertThrowsError(try g.open(rec))
        }
        do { // a video packet and a keyframe flag
            let (s, g, _) = try setup()
            XCTAssertThrowsError(try g.open(try s.sign(flags: 0, presentationTimeUs: 0, body: Data([1, 2, 3]))))
            XCTAssertThrowsError(try g.open(try s.sign(flags: StreamProtocol.flagAudio | StreamProtocol.flagKeyFrame, presentationTimeUs: 0, body: Data([0x08, 1]))))
        }
        for toc: UInt8 in [0xF9, 0xFC, 0xF0] { // two frames, stereo, 10 ms
            let (s, g, _) = try setup()
            XCTAssertThrowsError(try g.open(try record(s, units(1, at: 0, toc: toc))), String(format: "toc %02x", toc))
        }
        do { // a 1276-byte unit
            let (s, g, _) = try setup()
            XCTAssertThrowsError(try g.open(try record(s, units(1, at: 0, size: 1276))))
        }
        do { // 5 s jump with consecutive sequence numbers
            let (s, g, clock) = try setup()
            XCTAssertNoThrow(try g.open(try record(s, units(10, at: 0))))
            clock.ms += 200
            XCTAssertThrowsError(try g.open(try record(s, units(10, at: 5_200_000))))
        }
        do { // non-contiguous units
            let (s, g, _) = try setup()
            var u = units(3, at: 0); u[2].presentationTimeUs += 1_000
            XCTAssertThrowsError(try g.open(try record(s, u)))
        }
        do { // a changed or stereo configuration
            let (s, g, _) = try setup()
            let flags = StreamProtocol.flagAudio | StreamProtocol.flagCodecConfig
            XCTAssertNoThrow(try g.open(try s.sign(flags: flags, presentationTimeUs: 0, body: OpusHead.make())))
            XCTAssertThrowsError(try g.open(try s.sign(flags: flags, presentationTimeUs: 0, body: OpusHead.make(preSkip: 100))))
            let (s2, g2, _) = try setup()
            XCTAssertThrowsError(try g2.open(try s2.sign(flags: flags, presentationTimeUs: 0, body: OpusHead.make(channels: 2))))
        }
    }

    /// A source-signed record with a timestamp at the 64-bit limits ends the stream with an error instead of trapping.
    func testTimestampsAtTheLimitsAreRejectedNotTrapped() throws {
        do { // the record's end time does not fit
            let (s, g, _) = try setup()
            XCTAssertThrowsError(try g.open(try record(s, units(1, at: Int64.max))))
            XCTAssertThrowsError(try g.open(try record(s, units(1, at: Int64.max - 10_000))))
        }
        do { // the gap from the previous record does not fit
            let (s, g, _) = try setup()
            XCTAssertNoThrow(try g.open(try record(s, units(1, at: Int64.min))))
            XCTAssertThrowsError(try g.open(try record(s, units(1, at: Int64.max - 20_000))))
        }
        do { // a lifecycle record restarts the baseline: a far time is then accepted, and still fits
            let (s, g, _) = try setup()
            XCTAssertNoThrow(try g.open(try record(s, units(1, at: Int64.min))))
            try g.onLifecycleRecord()
            XCTAssertNoThrow(try g.open(try record(s, units(1, at: Int64.max - 20_000))))
        }
        // A call peer's paired audio near the limit is rejected by the batch reader.
        let pair = try MediaPacket.combineAudio(units(2, at: 0))
        var far = pair; far.presentationTimeUs = Int64.max - 1
        XCTAssertThrowsError(try far.splitAudio())
        // The playout buffer resets on a jump that does not fit instead of trapping.
        var playout = AudioPlayout(targetFrames: 1)
        playout.push(presentationTimeUs: Int64.min + 5, payload: Data([1]))
        playout.push(presentationTimeUs: Int64.max, payload: Data([2]))
        playout.push(presentationTimeUs: Int64.min, payload: Data([3]))
        XCTAssertEqual(playout.bufferedFrames, 1)
    }

    func testLifecycleRestartsTheClockBaseline() throws {
        let (s, g, clock) = try setup()
        XCTAssertNoThrow(try g.open(try record(s, units(10, at: 0))))
        try g.onLifecycleRecord()
        clock.ms += 120_000
        XCTAssertNoThrow(try g.open(try record(s, units(10, at: 120_000_000))), "resume after a pause")
    }

    func testAndroidMarkerConfigBlock() {
        // MediaCodec csd: AOPUSHDR <len LE 8> OpusHead ...
        var block = Data("AOPUSHDR".utf8)
        let head = OpusHead.make()
        var length = UInt64(head.count)
        block.append(Data(bytes: &length, count: 8))
        block.append(head)
        XCTAssertTrue(AudioLiveOpus.isMonoConfig(block))
        XCTAssertFalse(AudioLiveOpus.isMonoConfig(OpusHead.make(channels: 2)))
    }
}

/// Android StreamRoutePenalties: route-local hints, authenticated-node scope, expiry and bounded storage.
final class StreamRoutePenaltyTests: XCTestCase {
    /// PROTOCOL "Penalties are scoped to the attempted route" (QV R1): a marker mismatch seen over an authenticated
    /// link costs only that route; the honest source behind it stays reachable on its other routes for 10 minutes.
    func testAMarkerMismatchNeverPenalisesTheAuthenticatedNode() throws {
        let p = StreamRoutePenalties()
        let node = try NodeId(bytes: Data(repeating: 7, count: 16))
        p.onMarkerMismatch(route("route-a"), now: 0)
        XCTAssertTrue(p.isPenalized(route("route-a"), authenticatedNode: node, now: 1))
        XCTAssertFalse(p.isPenalized(route("route-b"), authenticatedNode: node, now: 1), "no node penalty")
        XCTAssertFalse(p.isPenalized(route("route-a"), authenticatedNode: node, now: StreamRoutePenalties.routeTTL))
    }

    private func route(_ address: String, token: UInt32 = 1) -> StreamRoutePenalties.Route {
        .init(address: address, prefixHex: "010203040506", routeToken: token)
    }
    func testUnauthenticatedMismatchNeverPoisonsAnotherRouteOfTheSameStream() {
        let p = StreamRoutePenalties()
        p.onMismatch(route("route-a"), authenticatedNode: nil, now: 0)
        XCTAssertTrue(p.isPenalized(route("route-a"), now: 119))
        XCTAssertFalse(p.isPenalized(route("route-b"), now: 1))
        XCTAssertFalse(p.isPenalized(route("route-a", token: 2), now: 1))
        XCTAssertFalse(p.isPenalized(route("route-a"), now: 120))
    }
    func testOnlyAnAuthenticatedNodeGetsTheLongerPenalty() throws {
        let p = StreamRoutePenalties(), node = try NodeId(bytes: Data(repeating: 7, count: 16))
        p.onMismatch(route("route-a"), authenticatedNode: node, now: 0)
        XCTAssertFalse(p.isPenalized(route("route-b"), now: 1), "an advert alone never identifies that node")
        XCTAssertTrue(p.isPenalized(route("route-b"), authenticatedNode: node, now: 599))
        XCTAssertFalse(p.isPenalized(route("route-b"), authenticatedNode: node, now: 600))
    }
    func testOldestEntriesAreBoundedAndWipeResetsBothTables() throws {
        let p = StreamRoutePenalties()
        for i in 0...64 {
            p.onMismatch(route("route-\(i)"), authenticatedNode: try NodeId(bytes: Data(repeating: UInt8(i), count: 16)), now: 0)
        }
        XCTAssertFalse(p.isPenalized(route("route-0"), authenticatedNode: try NodeId(bytes: Data(count: 16)), now: 1))
        XCTAssertTrue(p.isPenalized(route("route-64"), now: 1))
        p.reset()
        XCTAssertFalse(p.isPenalized(route("route-64"), authenticatedNode: try NodeId(bytes: Data(repeating: 64, count: 16)), now: 1))
    }
}
