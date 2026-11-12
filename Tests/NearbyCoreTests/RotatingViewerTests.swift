import XCTest
@testable import NearbyCore

/// Rotating discovery IDs phase 1b, viewer side: an iPhone or Mac joins a default Android (version 5) stream with a
/// compact v2 viewer request carrying its role-2 RDI, opens it in the stream hop's BDO1 and rotates it at the boundary.
/// Every expected byte string below was produced by Android's own compiled codec (`CompactDiscoveryAnnouncement.encode`,
/// `DiscoveryAnnouncementCodec`, `RotatingDiscoveryIds.entry`, `DiscoveryOpeningCodec.encode`) and its source-side
/// check (`DiscoverySelectionCheck.check`, role 2) from the shared protocol inputs: node ID
/// a1b2c3d4e5f60718293a4b5c6d7e8f90, day key 000102...1f, epoch 0x001e6000.
final class RotatingViewerTests: XCTestCase {
    let dayKey = Data(0..<32)
    let nodeId = Data(hex: "a1b2c3d4e5f60718293a4b5c6d7e8f90")!
    let epoch: Int64 = 0x001e6000
    /// Protocol vector: version 5 stream offer, role-1 RDI bb2d061f6480, GATT, VP9, token 0x92529fc4, 640x360 15 FPS 300 kbps.
    let androidOffer = Data(hex: "05bb2d061f64800c0192529fc40001028001680f012c")!

    private func offer(_ hex: String) throws -> DiscoveryAnnouncement {
        try DiscoveryAnnouncement(decoding: Data(hex: hex)!, acceptRotating: true)
    }
    private func entry(_ e: Int64, role: UInt8 = RotatingDiscoveryIds.roleViewerRequest, node: Data? = nil) -> OpeningEntry {
        RotatingDiscoveryIds.entry(saltKey: dayKey, nodeId: node ?? nodeId, epoch: e, role: role)
    }

    // MARK: Compact v2 codec, Android vectors byte for byte

    func testTheViewerRequestForAnAndroidOfferIsTheProtocolVectorAndAndroidsCompactV2() throws {
        let selected = try offer(androidOffer.hex)
        let vectors: [(MeshTransport, UInt8, UInt16, String, String)] = [
            (.gatt, 0, 300, "05974ae410ea91090092529fc400000000000000012c", "C8D69974-AE41-0EA9-1800-9294FE20C000"),
            (.l2cap, 0, 300, "05974ae410ea91010092529fc400000000000000012c", "C8D69974-AE41-0EA9-1000-9294FE20C000"),
            (.gatt, 2, 1500, "05974ae410ea91090092529fc40200000000000005dc", "C8D69974-AE41-0EA9-1808-9294FE23C000"),
        ]
        for (transport, cost, kbps, android22, androidUuid) in vectors {
            var source = selected
            source.routeCost = cost; source.streamBitrateKbps = kbps
            let request = try RotatingViewerRequest.announcement(entry: entry(epoch), offer: source, transport: transport)
            XCTAssertEqual(request.nodeIdPrefix.hex, "974ae410ea91", "the role-2 RDI of the vector table")
            XCTAssertEqual(request.capabilitySummary, 0, "a version 5 request advertises no decode mask")
            XCTAssertNil(request.recoveryFromNodeIdPrefix)
            XCTAssertEqual(try request.encoded().hex, android22)
            let uuid = try CompactAnnouncement.encode(request)
            XCTAssertEqual(uuid, androidUuid)
            let decoded = try XCTUnwrap(CompactAnnouncement.decode(uuid, acceptRotating: true))
            XCTAssertTrue(decoded.rotating)
            XCTAssertEqual(try decoded.encoded().hex, android22, "Android decodes the same UUID to the same announcement")
            XCTAssertNil(CompactAnnouncement.decode(uuid), "compact v2 is rejected with rotating IDs off")
            XCTAssertTrue(decoded.isViewerRequest(routeToken: selected.streamToken), "the request carries the offer's route token")
        }
    }

    func testCompactV2StreamOffersMatchAndroid() throws {
        // (version 5 input, Android's compact v2 UUID, what Android decodes that UUID back to)
        let vectors: [(String, String, String)] = [
            ("05bb2d061f64800c0192529fc40001028001680f012c", "C8D6ABB2-D061-F648-0840-9294FE200A0C", "05bb2d061f64800c0192529fc40001028001680f012c"),
            // Audio-only live: summary 0x40, no geometry; 64 kbps quantises down to 50 (the compact unit is 25 kbps).
            ("05bb2d061f64800c4092529fc4000100000000000040", "C8D6ABB2-D061-F648-0800-9294FE200F82", "05bb2d061f64800c4092529fc4000100000000000032"),
            // Forwarder-like: relay capable, paused, AV1, cost 1, sequence 0x85, 854x480 30 FPS 1500 kbps.
            ("05bb2d061f6480260292529fc40185035601e01e05dc", "C8D6ABB2-D061-F648-0684-9294FE242D3C", "05bb2d061f6480260292529fc40185035601e01e05dc"),
        ]
        for (input, androidUuid, androidBack) in vectors {
            let a = try offer(input)
            XCTAssertEqual(try CompactAnnouncement.encode(a), androidUuid)
            let decoded = try XCTUnwrap(CompactAnnouncement.decode(androidUuid, acceptRotating: true))
            XCTAssertTrue(decoded.rotating && decoded.isStreamOffer)
            XCTAssertEqual(try decoded.encoded().hex, androidBack)
            XCTAssertNil(CompactAnnouncement.decode(androidUuid))
        }
    }

    func testCompactV2DecodingStaysStrict() throws {
        let good = "C8D69974-AE41-0EA9-1800-9294FE20C000"
        XCTAssertNotNil(CompactAnnouncement.decode(good, acceptRotating: true))
        XCTAssertNil(CompactAnnouncement.decode("C8D69974-AE41-0EA9-1800-9294FE20C001", acceptRotating: true), "viewer reserved bit")
        XCTAssertNil(CompactAnnouncement.decode("C8D69974-AE41-0EA9-1A00-9294FE20C000", acceptRotating: true), "a paused viewer request")
        XCTAssertNil(CompactAnnouncement.decode("C8D6D974-AE41-0EA9-1800-9294FE20C000", acceptRotating: true), "version 3")
        XCTAssertNil(CompactAnnouncement.decode("C8D6B974-AE41-0EA9-1800-9294FE20C000", acceptRotating: true), "kind 3")
        // Not representable: a rotating request with a recovery hint (an iPhone viewer sends none).
        var withHint = try RotatingViewerRequest.announcement(entry: entry(epoch), offer: try offer(androidOffer.hex), transport: .gatt)
        withHint.flags |= DiscoveryAnnouncement.flagRouteRecovery; withHint.recoveryFromNodeIdPrefix = Data(repeating: 7, count: 6)
        XCTAssertThrowsError(try CompactAnnouncement.encode(withHint))
    }

    func testARequestIsBuiltOnlyFromARoleTwoEntryForARotatingOffer() throws {
        let selected = try offer(androidOffer.hex)
        XCTAssertThrowsError(try RotatingViewerRequest.announcement(entry: entry(epoch, role: 0), offer: selected, transport: .gatt))
        XCTAssertThrowsError(try RotatingViewerRequest.announcement(entry: entry(epoch, role: 1), offer: selected, transport: .gatt))
        var fixed = selected; fixed.rotating = false
        XCTAssertThrowsError(try RotatingViewerRequest.announcement(entry: entry(epoch), offer: fixed, transport: .gatt),
                             "a version 2 offer gets the fixed-prefix request, never a rotating one")
    }

    // MARK: BDO1, Android vectors and Android's source-side check

    func testTheViewersOpeningIsAndroidsBytesAndPassesItsRoleTwoCheck() throws {
        let current = entry(epoch), next = entry(epoch + 1)
        XCTAssertEqual(current.salt.hex, "e59970c8523f23a6b1b16a858daf75320e3291d6c86d0329df89a62899804335")
        XCTAssertEqual(next.rdi.hex, "e4d1180b03b1")
        XCTAssertEqual(try DiscoveryOpeningCodec.encode([current]).hex,
                       "42444f310101974ae410ea91001e600002e59970c8523f23a6b1b16a858daf75320e3291d6c86d0329df89a62899804335")
        XCTAssertEqual(try DiscoveryOpeningCodec.encode([next, current]).hex,
                       "42444f310102e4d1180b03b1001e60010266bcd779328e875e55f45752f0465c01e5de14731fc63de3ec2ce228cb7c50c9"
                       + "974ae410ea91001e600002e59970c8523f23a6b1b16a858daf75320e3291d6c86d0329df89a62899804335")
        // The Android source selects the compact v2 request and checks role 2 (Android results: PASS, then
        // OPENING_MISMATCH for a role-1 entry and for another node, OPENING_STALE three epochs later).
        let selected = try XCTUnwrap(CompactAnnouncement.decode("C8D69974-AE41-0EA9-1800-9294FE20C000", acceptRotating: true))
        let check = { (entries: [OpeningEntry], node: Data, wall: Int64) in
            DiscoverySelectionCheck.check(selected: selected, expectedRole: RotatingDiscoveryIds.roleViewerRequest, peerNodeId: node,
                                          openingEntries: entries, verifierWallEpoch: wall)
        }
        XCTAssertEqual(check([current], nodeId, epoch), .pass)
        XCTAssertEqual(check([entry(epoch, role: 1)], nodeId, epoch), .openingMismatch)
        var other = nodeId; other[15] ^= 1
        XCTAssertEqual(check([current], other, epoch), .openingMismatch)
        XCTAssertEqual(check([current], nodeId, epoch + 3), .openingStale)
        XCTAssertEqual(check([], nodeId, epoch), .openingMismatch)
    }

    // MARK: Rotation and pins

    func testTheRequestRotatesAtTheBoundaryAfterASilenceAndPinsTheOldIdForSixtySeconds() {
        let request = RotatingViewerRequest()
        let e0 = entry(epoch), e1 = entry(epoch + 1)
        var built: [Int64] = []
        let entryFor: (Int64) -> OpeningEntry = { built.append($0); return self.entry($0) }
        XCTAssertEqual(request.decide(epoch: epoch, elapsedMs: 0, entryFor: entryFor), .advertise(e0))
        XCTAssertEqual(request.decide(epoch: epoch, elapsedMs: 5_000, entryFor: entryFor), .advertise(e0), "one ID for the epoch")
        XCTAssertEqual(request.acceptedEntries(elapsedMs: 5_000), [e0])
        // Boundary: break before make, with the silence clamped to 1-8 s.
        XCTAssertEqual(request.decide(epoch: epoch + 1, elapsedMs: 10_000, entryFor: entryFor, silenceMs: { 30_000 }), .silent(untilMs: 18_000))
        XCTAssertEqual(request.decide(epoch: epoch + 1, elapsedMs: 12_000, entryFor: entryFor), .silent(untilMs: 18_000), "nothing on air")
        XCTAssertEqual(request.acceptedEntries(elapsedMs: 12_000), [e0], "a source that dials during the silence still opens the old ID")
        XCTAssertEqual(request.decide(epoch: epoch + 1, elapsedMs: 18_000, entryFor: entryFor), .advertise(e1))
        XCTAssertEqual(request.acceptedEntries(elapsedMs: 18_000), [e1, e0])
        XCTAssertEqual(request.acceptedEntries(elapsedMs: 10_000 + OpeningPins.previousGraceMs), [e1], "the old ID is not opened after 60 s off air")
        XCTAssertEqual(built, [epoch, epoch + 1], "the ID is computed once per epoch")
        let short = RotatingViewerRequest()
        _ = short.decide(epoch: epoch, elapsedMs: 0, entryFor: entryFor)
        XCTAssertEqual(short.decide(epoch: epoch + 1, elapsedMs: 100, entryFor: entryFor, silenceMs: { 0 }), .silent(untilMs: 1_100))
    }

    func testARestartInsideTheEpochReusesItsIdAndALongAbsenceGetsNoFreshGrace() {
        let request = RotatingViewerRequest()
        let e0 = entry(epoch), e1 = entry(epoch + 1)
        _ = request.decide(epoch: epoch, elapsedMs: 0) { self.entry($0) }
        request.offAir(elapsedMs: 1_000)                          // a source connected
        XCTAssertEqual(request.acceptedEntries(elapsedMs: 30_000), [e0])
        XCTAssertEqual(request.acceptedEntries(elapsedMs: 61_000), [], "off air for more than 60 s: nothing is opened")
        XCTAssertEqual(request.decide(epoch: epoch, elapsedMs: 70_000) { self.entry($0) }, .advertise(e0), "the link failed: the same epoch's ID")
        request.offAir(elapsedMs: 80_000)
        XCTAssertEqual(request.decide(epoch: epoch + 1, elapsedMs: 500_000) { self.entry($0) }, .advertise(e1))
        XCTAssertEqual(request.acceptedEntries(elapsedMs: 500_000), [e1], "an ID that left the air long ago gets no fresh grace")
    }

    /// Review: a link accepted before the boundary that drops after it must not let the connecting party choose when the
    /// next epoch's ID appears; the new ID follows the boundary silence counted from when the old one left.
    func testAReWaitInALaterEpochStillKeepsTheBoundarySilence() {
        let request = RotatingViewerRequest()
        let e1 = entry(epoch + 1)
        _ = request.decide(epoch: epoch, elapsedMs: 0) { self.entry($0) }
        request.offAir(elapsedMs: 10_000)                          // a source connected in epoch E
        XCTAssertEqual(request.decide(epoch: epoch + 1, elapsedMs: 11_000, entryFor: { self.entry($0) }, silenceMs: { 5_000 }),
                       .silent(untilMs: 15_000), "the link dropped 1 s after it was accepted, past the boundary")
        XCTAssertEqual(request.decide(epoch: epoch + 1, elapsedMs: 15_000) { self.entry($0) }, .advertise(e1))
        // A re-wait long after the old ID left needs no extra wait.
        let later = RotatingViewerRequest()
        _ = later.decide(epoch: epoch, elapsedMs: 0) { self.entry($0) }
        later.offAir(elapsedMs: 1_000)
        XCTAssertEqual(later.decide(epoch: epoch + 1, elapsedMs: 120_000, entryFor: { self.entry($0) }, silenceMs: { 8_000 }), .advertise(e1))
    }

    /// Review: entries pinned for one stream's request are never opened to another stream's source.
    func testANewJoinDoesNotOpenTheRequestOfAnEarlierStream() {
        let request = RotatingViewerRequest()
        _ = request.decide(epoch: epoch, elapsedMs: 0) { self.entry($0) }
        request.startJoin(elapsedMs: 5_000)
        XCTAssertEqual(request.acceptedEntries(elapsedMs: 6_000), [], "the earlier request is not pinned for the new join")
        XCTAssertEqual(request.decide(epoch: epoch, elapsedMs: 6_000) { self.entry($0) }, .advertise(entry(epoch)))
        XCTAssertEqual(request.acceptedEntries(elapsedMs: 6_000), [entry(epoch)])
    }

    /// Review: viewer recovery and the automatic join retry never move a rotating join to a version 2 route (a decoy
    /// version 2 offer can carry any stream's logical token); a version 2 join may move anywhere.
    func testAutomaticRouteChangesNeverDowngradeARotatingJoin() throws {
        let rotatingOffer = try offer(androidOffer.hex)
        var fixedOffer = rotatingOffer; fixedOffer.rotating = false
        typealias P = RotatingStreamPolicy
        XCTAssertFalse(P.mayRouteAutomatically(from: rotatingOffer, to: fixedOffer, rotatingIds: true))
        XCTAssertTrue(P.mayRouteAutomatically(from: rotatingOffer, to: rotatingOffer, rotatingIds: true))
        XCTAssertTrue(P.mayRouteAutomatically(from: fixedOffer, to: rotatingOffer, rotatingIds: true))
        XCTAssertTrue(P.mayRouteAutomatically(from: fixedOffer, to: fixedOffer, rotatingIds: true))
        XCTAssertTrue(P.mayRouteAutomatically(from: rotatingOffer, to: fixedOffer, rotatingIds: false))
    }

    func testOnlyRoleTwoEntriesAreEverOpened() {
        let request = RotatingViewerRequest()
        _ = request.decide(epoch: epoch, elapsedMs: 0) { self.entry($0, role: RotatingDiscoveryIds.roleCallOffer) }
        XCTAssertEqual(request.acceptedEntries(elapsedMs: 0), [])
    }

    // MARK: Over the stream hop (BMS1 link, BDO1 both ways)

    private func join(viewerId: SigningIdentity, viewerEntries: [OpeningEntry]) throws -> (StreamSourceEngine, StreamViewerEngine) {
        let sourceId = SoftwareSigningIdentity()
        let role1 = RotatingDiscoveryIds.entry(saltKey: Data(repeating: 5, count: 32), nodeId: sourceId.nodeId.bytes, epoch: epoch, role: 1)
        var offer = DiscoveryAnnouncement(nodeIdPrefix: role1.rdi, flags: DiscoveryAnnouncement.flagStreamAvailable | DiscoveryAnnouncement.flagGattTransport,
                                          capabilitySummary: NodeCapabilities.codecVP9,
                                          streamToken: try StreamRouteToken.forAdvertiser(logical: 0x1234, prefix: role1.rdi), routeCost: 0)
        offer.rotating = true
        let header = StreamHeader(width: 640, height: 360, fps: 15, codecId: StreamProtocol.codecVP9, includeAudio: true)
        let source = StreamSourceEngine(transport: .gatt, identity: sourceId, header: header, expectedViewerPrefix: viewerId.nodeId.prefix,
                                        rotatingEntries: { [role1] })
        let viewer = StreamViewerEngine(transport: .gatt, identity: viewerId, decodeMask: NodeCapabilities.codecVP9,
                                        expectedAdjacentPrefix: offer.nodeIdPrefix, rotatingOffer: offer, wallEpoch: { self.epoch },
                                        openingEntries: viewerEntries)
        try source.start(now: 0); try viewer.start(now: 0)
        for _ in 0..<50 {
            var moved = false
            while let d = source.nextOutgoing(now: 0) { viewer.receive(d, now: 0); moved = true }
            while let d = viewer.nextOutgoing(now: 0) { source.receive(d, now: 0); moved = true }
            if !moved { break }
        }
        return (source, viewer)
    }

    private func request(for viewer: SigningIdentity, epoch e: Int64) throws -> DiscoveryAnnouncement {
        let mine = entry(e, node: viewer.nodeId.bytes)
        let anyOffer = try offer(androidOffer.hex)
        let uuid = try CompactAnnouncement.encode(try RotatingViewerRequest.announcement(entry: mine, offer: anyOffer, transport: .gatt))
        return try XCTUnwrap(CompactAnnouncement.decode(uuid, acceptRotating: true))
    }

    private func sourceCheck(_ selected: DiscoveryAnnouncement, _ source: StreamSourceEngine, linkPeer: NodeId) -> DiscoverySelectionCheck.Result {
        DiscoverySelectionCheck.check(selected: selected, expectedRole: RotatingDiscoveryIds.roleViewerRequest, peerNodeId: linkPeer.bytes,
                                      openingEntries: source.peerOpening, verifierWallEpoch: epoch)
    }

    func testTheSourceReceivesTheViewersPinnedRoleTwoEntriesAndTheyOpenItsRequest() throws {
        let viewerId = SoftwareSigningIdentity()
        let mine = entry(epoch, node: viewerId.nodeId.bytes)
        let (source, viewer) = try join(viewerId: viewerId, viewerEntries: [mine])
        XCTAssertTrue(source.ready, viewer.closeReason ?? "")
        XCTAssertEqual(viewer.header?.width, 640)
        XCTAssertEqual(source.peerOpening, [mine], "the listener sends its role-2 entries")
        XCTAssertEqual(sourceCheck(try request(for: viewerId, epoch: epoch), source, linkPeer: viewerId.nodeId), .pass)
    }

    func testAJoinAcrossTheBoundaryOpensTheRequestTheSourceSelected() throws {
        let viewerId = SoftwareSigningIdentity()
        let old = entry(epoch, node: viewerId.nodeId.bytes), new = entry(epoch + 1, node: viewerId.nodeId.bytes)
        let (source, _) = try join(viewerId: viewerId, viewerEntries: [new, old])
        XCTAssertEqual(sourceCheck(try request(for: viewerId, epoch: epoch), source, linkPeer: viewerId.nodeId), .pass,
                       "the source selected the old request just before the boundary")
        let (late, _) = try join(viewerId: viewerId, viewerEntries: [new])
        XCTAssertEqual(sourceCheck(try request(for: viewerId, epoch: epoch), late, linkPeer: viewerId.nodeId), .openingMismatch,
                       "more than 60 s after the old request left the air the join fails as identity changed (and is retried)")
    }

    func testACopiedRequestOrAWrongOpeningFailsTheSourcesCheck() throws {
        // A bystander copies the victim's request: the source connects to the copier, who cannot open the victim's RDI.
        let victim = SoftwareSigningIdentity(), copier = SoftwareSigningIdentity()
        let copied = try request(for: victim, epoch: epoch)
        let (source, _) = try join(viewerId: copier, viewerEntries: [entry(epoch, node: copier.nodeId.bytes)])
        XCTAssertEqual(sourceCheck(copied, source, linkPeer: copier.nodeId), .openingMismatch)
        // The copier replays the victim's own opening entry: it does not recompute from the copier's node ID.
        let (replayed, _) = try join(viewerId: copier, viewerEntries: [entry(epoch, node: victim.nodeId.bytes)])
        XCTAssertEqual(sourceCheck(copied, replayed, linkPeer: copier.nodeId), .openingMismatch)
        // A role-1 entry is never sent as the viewer's opening (the engine filters it), so nothing opens the request.
        let (wrongRole, _) = try join(viewerId: victim, viewerEntries: [entry(epoch, role: 1, node: victim.nodeId.bytes)])
        XCTAssertEqual(wrongRole.peerOpening, [])
        XCTAssertEqual(sourceCheck(copied, wrongRole, linkPeer: victim.nodeId), .openingMismatch)
        // A stale entry (three epochs from the source's clock).
        let (stale, _) = try join(viewerId: victim, viewerEntries: [entry(epoch - 3, node: victim.nodeId.bytes)])
        XCTAssertEqual(sourceCheck(try request(for: victim, epoch: epoch - 3), stale, linkPeer: victim.nodeId), .openingStale)
    }

    // MARK: Policy: no downgrade

    func testARotatingOfferIsJoinedOnlyWithARotatingRequest() throws {
        let rotatingOffer = try offer(androidOffer.hex)
        var fixedOffer = rotatingOffer; fixedOffer.rotating = false
        typealias P = RotatingStreamPolicy
        XCTAssertEqual(P.viewerRequest(offer: rotatingOffer, rotatingIds: true, privateViewer: true), .rotating)
        XCTAssertNil(P.joinRefusal(offer: rotatingOffer, rotatingIds: true, privateViewer: true))
        XCTAssertEqual(P.viewerRequest(offer: rotatingOffer, rotatingIds: true, privateViewer: false), .refused,
                       "the control arm refuses; it never falls back to the fixed prefix")
        XCTAssertEqual(P.joinRefusal(offer: rotatingOffer, rotatingIds: true, privateViewer: false), P.joinRefusal)
        XCTAssertEqual(P.viewerRequest(offer: fixedOffer, rotatingIds: true, privateViewer: true), .fixedPrefix,
                       "a version 2 source cannot decode a rotating request")
        XCTAssertTrue(P.showsFixedId(offer: fixedOffer, rotatingIds: true), "and the user is told so")
        XCTAssertFalse(P.showsFixedId(offer: rotatingOffer, rotatingIds: true))
        XCTAssertEqual(P.viewerRequest(offer: rotatingOffer, rotatingIds: false, privateViewer: true), .fixedPrefix,
                       "DEBUG run with rotating IDs off: the fixed prefix is public anyway")
        XCTAssertFalse(P.mayForward(offer: rotatingOffer, rotatingIds: true), "forwarder offers do not rotate yet")
    }
}
