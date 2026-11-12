import XCTest
@testable import NearbyCore

/// AB4: rotating discovery IDs phase 1b, source side. An iPhone or Mac that goes live advertises a version 5 / compact v2
/// stream offer with its role-1 RDI, answers version 5 viewer requests (Android's 22-byte scan response and compact v2)
/// through a route-token window, opens its role-1 ID in the stream hop's BDO1 and checks the viewer's role-2 entry
/// (Android `RotatingStreams.kt`, `BluetoothVideoSender`, `BluetoothVideoBroadcaster`; PROTOCOL phase 1b items 1-9).
/// Vectors: the protocol table (node ID a1b2c3d4e5f60718293a4b5c6d7e8f90, key 000102...1f, epoch 0x001e6000) and Android
/// `RotatingStreamsTest`.
final class RotatingSourceTests: XCTestCase {
    let dayKey = Data(0..<32)
    let nodeId = Data(hex: "a1b2c3d4e5f60718293a4b5c6d7e8f90")!
    let epoch: Int64 = 0x001e6000
    let logical: UInt32 = 0x12345678

    private func entry(_ e: Int64, role: UInt8 = RotatingDiscoveryIds.roleStreamOffer, node: Data? = nil) -> OpeningEntry {
        RotatingDiscoveryIds.entry(saltKey: dayKey, nodeId: node ?? nodeId, epoch: e, role: role)
    }

    // MARK: Step 1: Android's version 5 viewer requests decode

    func testAndroidsVersion5ViewerRequestsDecodeWithAndWithoutTheRecoveryHint() throws {
        let plain = try DiscoveryAnnouncement(decoding: Data(hex: "05974ae410ea91090092529fc400000000000000012c")!, acceptRotating: true)
        XCTAssertTrue(plain.rotating)
        XCTAssertTrue(plain.isViewerRequest(routeToken: 0x92529fc4))
        XCTAssertFalse(plain.isStreamOffer)
        XCTAssertFalse(plain.isPrivateCallOffer)
        XCTAssertEqual(plain.nodeIdPrefix.hex, "974ae410ea91", "the role-2 RDI of the vector table")
        XCTAssertEqual(plain.transport, .gatt)
        XCTAssertNil(plain.recoveryFromNodeIdPrefix)
        XCTAssertEqual(try plain.encoded().hex, "05974ae410ea91090092529fc400000000000000012c")
        let recovering = try DiscoveryAnnouncement(decoding: Data(hex: "05974ae410ea91890092529fc4004d832e9d4dc7012c")!, acceptRotating: true)
        XCTAssertTrue(recovering.rotating && recovering.isViewerRequest(routeToken: 0x92529fc4))
        XCTAssertEqual(recovering.recoveryFromNodeIdPrefix?.hex, "4d832e9d4dc7", "the RV18 hint of the vector table")
        XCTAssertEqual(try recovering.encoded().hex, "05974ae410ea91890092529fc4004d832e9d4dc7012c")
        // As Core Bluetooth reports Android's scan response (company ID 0xffff, little-endian, then the value).
        let manufacturerData = Data([0xff, 0xff]) + Data(hex: "05974ae410ea91090092529fc400000000000000012c")!
        XCTAssertEqual(try DiscoveryAnnouncement(manufacturerData: manufacturerData, acceptRotating: true), plain)
    }

    /// Guard (passes at BASE too): rotating IDs off still rejects version 5 as old builds do, and a version 5 announcement
    /// that is no call offer, stream offer or viewer request stays refused.
    func testVersion5StaysRejectedWithRotatingIdsOffAndAKindlessVersion5StaysRefused() {
        XCTAssertThrowsError(try DiscoveryAnnouncement(decoding: Data(hex: "05974ae410ea91090092529fc400000000000000012c")!))
        XCTAssertThrowsError(try DiscoveryAnnouncement(decoding: Data(hex: "05974ae410ea91080092529fc400000000000000012c")!, acceptRotating: true),
                             "flags 0x08 (GATT only): not a kind that rotates")
    }

    // MARK: Step 2: the route-token window (Android RotatingStreamsTest)

    func testTheWindowAcceptsTheCurrentTokenAndTheReplacedOneForSixtySeconds() {
        let window = RouteTokenWindow()
        window.advance(logical: logical, token: 0x8000_0001, nowMs: 0)
        XCTAssertTrue(window.accepts(0x8000_0001, nowMs: 0))
        window.advance(logical: logical, token: 0x8000_0002, nowMs: 1_000)
        XCTAssertTrue(window.accepts(0x8000_0002, nowMs: 1_000))
        XCTAssertTrue(window.accepts(0x8000_0001, nowMs: 1_000 + 59_999))
        XCTAssertFalse(window.accepts(0x8000_0001, nowMs: 1_000 + 60_000))
        XCTAssertFalse(window.accepts(0x8000_0003, nowMs: 1_000))
        XCTAssertFalse(window.accepts(0, nowMs: 1_000))
    }

    func testTheWindowKeepsAtMostTwoReplacedTokens() {
        let window = RouteTokenWindow()
        window.reset(logical: logical, token: 1)
        window.advance(logical: logical, token: 2, nowMs: 10)
        window.advance(logical: logical, token: 3, nowMs: 20)
        window.advance(logical: logical, token: 4, nowMs: 30)
        XCTAssertTrue(window.accepts(4, nowMs: 31))
        XCTAssertTrue(window.accepts(3, nowMs: 31))
        XCTAssertTrue(window.accepts(2, nowMs: 31))
        XCTAssertFalse(window.accepts(1, nowMs: 31))
    }

    func testANewStreamOrAClearDropsEveryOldTokenAndTheSameTokenIsTheOldRule() {
        let window = RouteTokenWindow()
        window.reset(logical: logical, token: 7)
        window.advance(logical: logical, token: 8, nowMs: 5)
        window.advance(logical: logical + 1, token: 9, nowMs: 6)
        XCTAssertTrue(window.accepts(9, nowMs: 7))
        XCTAssertFalse(window.accepts(8, nowMs: 7))
        XCTAssertFalse(window.accepts(7, nowMs: 7))
        window.clear()
        XCTAssertFalse(window.accepts(9, nowMs: 7))
        // A fixed-prefix offer keeps one token for the stream's life: exactly the old single-token test.
        let fixed = RouteTokenWindow()
        fixed.advance(logical: logical, token: 5, nowMs: 0)
        fixed.advance(logical: logical, token: 5, nowMs: 100)
        XCTAssertTrue(fixed.accepts(5, nowMs: 1_000_000))
        XCTAssertEqual(fixed.current, 5)
        XCTAssertFalse(fixed.accepts(6, nowMs: 0))
    }

    // MARK: Step 2: the rotating offer, Android's vectors

    private func fixedOffer(kbps: UInt16 = 300) -> DiscoveryAnnouncement {
        DiscoveryAnnouncement(nodeIdPrefix: Data(repeating: 0, count: 6),
                              flags: DiscoveryAnnouncement.flagStreamAvailable | DiscoveryAnnouncement.flagGattTransport,
                              capabilitySummary: NodeCapabilities.codecVP9, streamToken: 0, routeCost: 0, sequence: 1,
                              streamWidth: 640, streamHeight: 360, streamFps: 15, streamBitrateKbps: kbps)
    }

    func testTheRotatingOfferIsTheProtocolVectorAndAndroidsCompactV2() throws {
        let role1 = entry(epoch)
        XCTAssertEqual(role1.rdi.hex, "bb2d061f6480")
        let offer = try RotatingStreamOffer.announcement(base: fixedOffer(), entry: role1, logicalToken: logical)
        XCTAssertTrue(offer.rotating)
        XCTAssertEqual(offer.streamToken, 0x92529fc4)
        XCTAssertEqual(try offer.encoded().hex, "05bb2d061f64800c0192529fc40001028001680f012c")
        XCTAssertEqual(try CompactAnnouncement.encode(offer), "C8D6ABB2-D061-F648-0840-9294FE200A0C")
        XCTAssertEqual(offer.logicalStreamToken, logical, "anyone recovers the logical token (RV14), the same in every epoch")
        let decoded = try XCTUnwrap(CompactAnnouncement.decode("C8D6ABB2-D061-F648-0840-9294FE200A0C", acceptRotating: true))
        XCTAssertEqual(decoded, offer, "an Android viewer reads the same offer")
    }

    func testTheOfferRoundsItsBitrateLikeAndroidAndKeepsEveryOtherField() throws {
        let offer = try RotatingStreamOffer.announcement(base: fixedOffer(kbps: 487), entry: entry(epoch), logicalToken: logical)
        XCTAssertEqual(offer.streamBitrateKbps, 475)
        var expected = fixedOffer(kbps: 475)
        expected.nodeIdPrefix = offer.nodeIdPrefix
        expected.streamToken = offer.streamToken
        expected.rotating = true
        XCTAssertEqual(offer, expected)
        XCTAssertEqual(RotatingStreamOffer.roundedBitrate(0), 0)
        XCTAssertEqual(RotatingStreamOffer.roundedBitrate(1), 25)
        XCTAssertEqual(RotatingStreamOffer.roundedBitrate(490), 500)
        XCTAssertEqual(RotatingStreamOffer.roundedBitrate(UInt16.max), 65_525)
    }

    func testAnOfferIsBuiltOnlyFromARoleOneEntryForAnLeStreamOffer() {
        XCTAssertThrowsError(try RotatingStreamOffer.announcement(base: fixedOffer(), entry: entry(epoch, role: RotatingDiscoveryIds.roleViewerRequest),
                                                                  logicalToken: logical))
        XCTAssertThrowsError(try RotatingStreamOffer.announcement(base: fixedOffer(), entry: entry(epoch, role: RotatingDiscoveryIds.roleCallOffer),
                                                                  logicalToken: logical))
        var classic = fixedOffer()
        classic.flags |= DiscoveryAnnouncement.flagClassicTransport
        XCTAssertThrowsError(try RotatingStreamOffer.announcement(base: classic, entry: entry(epoch), logicalToken: logical))
        var request = fixedOffer()
        request.flags = DiscoveryAnnouncement.flagAcceptingConnections
        XCTAssertThrowsError(try RotatingStreamOffer.announcement(base: request, entry: entry(epoch), logicalToken: logical))
        XCTAssertThrowsError(try RotatingStreamOffer.announcement(base: fixedOffer(), entry: entry(epoch), logicalToken: 0),
                             "logical tokens are positive")
    }

    func testNoIdOrRouteTokenCarriesAcrossBoundariesOnlyTheLogicalToken() throws {
        var ids = Set<String>()
        var tokens = Set<UInt32>()
        for e in epoch..<(epoch + 5) {
            for role in [RotatingDiscoveryIds.roleCallOffer, RotatingDiscoveryIds.roleStreamOffer, RotatingDiscoveryIds.roleViewerRequest] {
                XCTAssertTrue(ids.insert(entry(e, role: role).rdi.hex).inserted, "an RDI repeated across epochs or roles")
            }
            let offer = try RotatingStreamOffer.announcement(base: fixedOffer(), entry: entry(e), logicalToken: logical)
            XCTAssertTrue(tokens.insert(offer.streamToken).inserted, "a route token repeated across epochs")
            XCTAssertEqual(offer.logicalStreamToken, logical)
        }
    }

    // MARK: Step 2: rotation and role-1 pins

    func testTheOfferRotatesAtTheBoundaryAfterASilenceAndPinsTheOldIdForSixtySeconds() {
        let offer = RotatingStreamOffer()
        let e0 = entry(epoch), e1 = entry(epoch + 1)
        var built: [Int64] = []
        let entryFor: (Int64) -> OpeningEntry = { built.append($0); return self.entry($0) }
        XCTAssertEqual(offer.decide(epoch: epoch, elapsedMs: 0, entryFor: entryFor), .advertise(e0))
        XCTAssertEqual(offer.decide(epoch: epoch, elapsedMs: 5_000, entryFor: entryFor), .advertise(e0),
                       "one ID for the epoch (a pause or a full source re-advertises it)")
        XCTAssertEqual(offer.acceptedEntries(elapsedMs: 5_000), [e0])
        XCTAssertEqual(offer.decide(epoch: epoch + 1, elapsedMs: 10_000, entryFor: entryFor, silenceMs: { 30_000 }), .silent(untilMs: 18_000),
                       "break before make, the silence clamped to 1-8 s")
        XCTAssertEqual(offer.decide(epoch: epoch + 1, elapsedMs: 12_000, entryFor: entryFor), .silent(untilMs: 18_000), "nothing on air")
        XCTAssertEqual(offer.acceptedEntries(elapsedMs: 12_000), [e0], "a viewer that answered the old offer still opens it")
        XCTAssertEqual(offer.decide(epoch: epoch + 1, elapsedMs: 18_000, entryFor: entryFor), .advertise(e1))
        XCTAssertEqual(offer.acceptedEntries(elapsedMs: 18_000), [e1, e0])
        XCTAssertEqual(offer.acceptedEntries(elapsedMs: 10_000 + OpeningPins.previousGraceMs), [e1], "not after 60 s off air")
        XCTAssertEqual(built, [epoch, epoch + 1], "the ID is computed once per epoch")
        let short = RotatingStreamOffer()
        _ = short.decide(epoch: epoch, elapsedMs: 0, entryFor: entryFor)
        XCTAssertEqual(short.decide(epoch: epoch + 1, elapsedMs: 100, entryFor: entryFor, silenceMs: { 0 }), .silent(untilMs: 1_100))
    }

    func testAWindowEndRestartsAfterASilenceAndALongAbsenceGetsNoFreshGrace() {
        let offer = RotatingStreamOffer()
        let e1 = entry(epoch + 1)
        _ = offer.decide(epoch: epoch, elapsedMs: 0) { self.entry($0) }
        offer.offAir(elapsedMs: 1_000)                                  // a Visible-by-handle window: the fixed offer is on air
        XCTAssertEqual(offer.acceptedEntries(elapsedMs: 30_000), [entry(epoch)])
        XCTAssertEqual(offer.acceptedEntries(elapsedMs: 61_000), [], "off air for 60 s: nothing is opened")
        offer.restart(elapsedMs: 600_000, silenceMs: { 3_000 })        // the window ended
        XCTAssertEqual(offer.decide(epoch: epoch + 1, elapsedMs: 601_000) { self.entry($0) }, .silent(untilMs: 603_000))
        XCTAssertEqual(offer.decide(epoch: epoch + 1, elapsedMs: 603_000) { self.entry($0) }, .advertise(e1))
        XCTAssertEqual(offer.acceptedEntries(elapsedMs: 603_000), [e1], "the old ID gets no fresh grace")
    }

    func testAReAdvertisementInALaterEpochStillKeepsTheBoundarySilence() {
        let offer = RotatingStreamOffer()
        _ = offer.decide(epoch: epoch, elapsedMs: 0) { self.entry($0) }
        offer.offAir(elapsedMs: 10_000)                                 // another role took the radio just before the boundary
        XCTAssertEqual(offer.decide(epoch: epoch + 1, elapsedMs: 11_000, entryFor: { self.entry($0) }, silenceMs: { 5_000 }),
                       .silent(untilMs: 15_000))
        XCTAssertEqual(offer.decide(epoch: epoch + 1, elapsedMs: 15_000) { self.entry($0) }, .advertise(entry(epoch + 1)))
    }

    func testOnlyRoleOneEntriesAreEverOpened() {
        let offer = RotatingStreamOffer()
        _ = offer.decide(epoch: epoch, elapsedMs: 0) { self.entry($0, role: RotatingDiscoveryIds.roleViewerRequest) }
        XCTAssertEqual(offer.acceptedEntries(elapsedMs: 0), [])
    }

    // MARK: Step 2: which requests the source answers (Android's source filter and item 5)

    private func request(token: UInt32, rotating: Bool, recovery: Data? = nil) -> DiscoveryAnnouncement {
        var flags = DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagGattTransport
        if recovery != nil { flags |= DiscoveryAnnouncement.flagRouteRecovery }
        var r = DiscoveryAnnouncement(nodeIdPrefix: entry(epoch, role: RotatingDiscoveryIds.roleViewerRequest).rdi, flags: flags,
                                      capabilitySummary: 0, streamToken: token, routeCost: 0, streamBitrateKbps: 300,
                                      recoveryFromNodeIdPrefix: recovery)
        r.rotating = rotating
        return r
    }

    func testTheSourceSelectsByTokenWindowTransportAndItsRotatingArm() {
        let tokens = RouteTokenWindow()
        tokens.advance(logical: logical, token: 0x8000_0001, nowMs: 0)
        tokens.advance(logical: logical, token: 0x8000_0002, nowMs: 1_000)
        typealias P = RotatingSourcePolicy
        XCTAssertTrue(P.selects(request(token: 0x8000_0002, rotating: true), tokens: tokens, transport: .gatt, rotatingArm: true, nowMs: 2_000))
        XCTAssertTrue(P.selects(request(token: 0x8000_0001, rotating: true), tokens: tokens, transport: .gatt, rotatingArm: true, nowMs: 2_000),
                      "a request that copied the token just before the boundary")
        XCTAssertFalse(P.selects(request(token: 0x8000_0001, rotating: true), tokens: tokens, transport: .gatt, rotatingArm: true, nowMs: 61_000),
                       "the grace is 60 s")
        XCTAssertFalse(P.selects(request(token: 0x8000_0002, rotating: true), tokens: tokens, transport: .l2cap, rotatingArm: true, nowMs: 2_000),
                       "another transport's request")
        XCTAssertFalse(P.selects(request(token: 0x8000_0002, rotating: true), tokens: tokens, transport: .gatt, rotatingArm: false, nowMs: 2_000),
                       "the arm off: a rotating request is never answered (the old rule)")
        XCTAssertTrue(P.selects(request(token: 0x8000_0002, rotating: false), tokens: tokens, transport: .gatt, rotatingArm: false, nowMs: 2_000))
        var offer = request(token: 0x8000_0002, rotating: true)
        offer.flags = DiscoveryAnnouncement.flagStreamAvailable | DiscoveryAnnouncement.flagGattTransport
        XCTAssertFalse(P.selects(offer, tokens: tokens, transport: .gatt, rotatingArm: true, nowMs: 2_000), "an offer is not a request")
    }

    func testARotatingRequestsHintIsNeverReadAsAChildPrefix() {
        let child = Data([1, 2, 3, 4, 5, 6])
        typealias P = RotatingSourcePolicy
        XCTAssertNil(P.namedChild(request(token: 0x8000_0002, rotating: true, recovery: child)),
                     "a version 5 request's six bytes are an RV18 hint: an ordinary request here")
        XCTAssertEqual(P.namedChild(request(token: 0x8000_0002, rotating: false, recovery: child)), child)
        XCTAssertFalse(ViewerAdmissionGate.isRecovery(requester: Data(repeating: 9, count: 6),
                                                       namedChild: P.namedChild(request(token: 0x8000_0002, rotating: true, recovery: child)),
                                                       children: [child]), "it never skips the admission bound")
    }

    func testANewRotatingLinkReplacesTheOlderLinkOfTheSameNodeOnly() {
        let a = SoftwareSigningIdentity().nodeId, b = SoftwareSigningIdentity().nodeId
        let sessions: [String: NodeId] = ["old": a, "other": b]
        typealias P = RotatingSourcePolicy
        XCTAssertEqual(P.replacedSessions(newKey: "new", node: a, rotating: true, authenticated: sessions), ["old"])
        XCTAssertEqual(P.replacedSessions(newKey: "new", node: a, rotating: false, authenticated: sessions), [],
                       "a fixed-prefix request replaces nothing (as Android)")
        XCTAssertEqual(P.replacedSessions(newKey: "old", node: a, rotating: true, authenticated: sessions), [], "never itself")
        XCTAssertEqual(Set(P.replacedSessions(newKey: "new", node: b, rotating: true, authenticated: ["x": b, "y": b, "z": a])), ["x", "y"])
    }

    // MARK: Step 3: over the stream hop (BMS1 link, BDO1 both ways)

    private struct Hop {
        let source: StreamSourceEngine
        let viewer: StreamViewerEngine
        let results: [DiscoverySelectionCheck.Result]
    }

    /// A viewer's compact v2 request as an Apple source scans it (`RotatingViewerRequest` with the viewer's role-2 entry).
    private func scannedRequest(of viewer: SigningIdentity, epoch e: Int64, token: UInt32) throws -> DiscoveryAnnouncement {
        var anyOffer = try DiscoveryAnnouncement(decoding: Data(hex: "05bb2d061f64800c0192529fc40001028001680f012c")!, acceptRotating: true)
        anyOffer.streamToken = token
        let mine = entry(e, role: RotatingDiscoveryIds.roleViewerRequest, node: viewer.nodeId.bytes)
        let uuid = try CompactAnnouncement.encode(try RotatingViewerRequest.announcement(entry: mine, offer: anyOffer, transport: .gatt))
        return try XCTUnwrap(CompactAnnouncement.decode(uuid, acceptRotating: true))
    }

    /// An Apple source with a rotating offer dials `viewerId`, which advertised `selected` and opens `viewerEntries`. As the
    /// app does, the source passes the request's announced six bytes as `expectedViewerPrefix`.
    private func hop(viewerId: SigningIdentity, selected: DiscoveryAnnouncement, viewerEntries: [OpeningEntry],
                     viewerBit3: Bool = true) throws -> Hop {
        let sourceId = SoftwareSigningIdentity()
        let role1 = entry(epoch, node: sourceId.nodeId.bytes)
        let base = DiscoveryAnnouncement(nodeIdPrefix: sourceId.nodeId.prefix,
                                         flags: DiscoveryAnnouncement.flagStreamAvailable | DiscoveryAnnouncement.flagGattTransport,
                                         capabilitySummary: NodeCapabilities.codecVP9, streamToken: 0, routeCost: 0, sequence: 1,
                                         streamWidth: 640, streamHeight: 360, streamFps: 15, streamBitrateKbps: 300)
        let offer = try RotatingStreamOffer.announcement(base: base, entry: role1, logicalToken: logical)
        let header = StreamHeader(width: 640, height: 360, fps: 15, codecId: StreamProtocol.codecVP9, includeAudio: true)
        let wall = epoch
        let source = StreamSourceEngine(transport: .gatt, identity: sourceId, header: header, expectedViewerPrefix: selected.nodeIdPrefix,
                                        rotatingEntries: { [role1] }, selectedRequest: selected, wallEpoch: { wall })
        var results: [DiscoverySelectionCheck.Result] = []
        source.onOpeningChecked = { results.append($0) }
        let viewer = StreamViewerEngine(transport: .gatt, identity: viewerId, decodeMask: NodeCapabilities.codecVP9,
                                        expectedAdjacentPrefix: viewerBit3 ? offer.nodeIdPrefix : sourceId.nodeId.prefix,
                                        rotatingOffer: viewerBit3 ? offer : nil, wallEpoch: { wall }, openingEntries: viewerEntries)
        try source.start(now: 0); try viewer.start(now: 0)
        for _ in 0..<50 {
            var moved = false
            while let d = source.nextOutgoing(now: 0) { viewer.receive(d, now: 0); moved = true }
            while let d = viewer.nextOutgoing(now: 0) { source.receive(d, now: 0); moved = true }
            if !moved { break }
        }
        return Hop(source: source, viewer: viewer, results: results)
    }

    func testAnAndroidStyleRotatingRequestIsOpenedByTheViewersRoleTwoEntryAndTheStreamStarts() throws {
        let viewerId = SoftwareSigningIdentity()
        let selected = try scannedRequest(of: viewerId, epoch: epoch, token: 0x8000_1234)
        let mine = entry(epoch, role: RotatingDiscoveryIds.roleViewerRequest, node: viewerId.nodeId.bytes)
        let h = try hop(viewerId: viewerId, selected: selected, viewerEntries: [mine])
        XCTAssertTrue(h.source.ready, "\(h.source.closeReason ?? "") / \(h.viewer.closeReason ?? "")")
        XCTAssertEqual(h.viewer.header?.width, 640, "the viewer opened the source's role-1 ID and got the header")
        XCTAssertEqual(h.results, [.pass])
        XCTAssertEqual(h.source.peerOpening, [mine])
    }

    func testACopiedRequestAWrongRoleAStaleEntryOrNoOpeningFailsAtTheSourceBeforeAnyMedia() throws {
        let victim = SoftwareSigningIdentity(), copier = SoftwareSigningIdentity()
        let copied = try scannedRequest(of: victim, epoch: epoch, token: 0x8000_1234)
        // The copier answers the source's dial for the victim's request: it cannot open the victim's RDI.
        let byCopier = try hop(viewerId: copier, selected: copied,
                               viewerEntries: [entry(epoch, role: RotatingDiscoveryIds.roleViewerRequest, node: copier.nodeId.bytes)])
        XCTAssertFalse(byCopier.source.ready)
        XCTAssertEqual(byCopier.source.phase, .closed)
        XCTAssertNil(byCopier.viewer.header, "no media before the opening passed")
        XCTAssertEqual(byCopier.results, [.openingMismatch])
        // The copier replays the victim's own entry: it does not recompute from the copier's node ID.
        let replayed = try hop(viewerId: copier, selected: copied,
                               viewerEntries: [entry(epoch, role: RotatingDiscoveryIds.roleViewerRequest, node: victim.nodeId.bytes)])
        XCTAssertFalse(replayed.source.ready)
        XCTAssertEqual(replayed.results, [.openingMismatch])
        // A role-1 entry is never sent as the viewer's opening (the viewer engine filters it): nothing opens the request.
        let wrongRole = try hop(viewerId: victim, selected: copied, viewerEntries: [entry(epoch, node: victim.nodeId.bytes)])
        XCTAssertFalse(wrongRole.source.ready)
        XCTAssertEqual(wrongRole.results, [.openingMismatch])
        // Three epochs from the source's clock (RD4).
        let stale = try hop(viewerId: victim, selected: try scannedRequest(of: victim, epoch: epoch - 3, token: 0x8000_1234),
                            viewerEntries: [entry(epoch - 3, role: RotatingDiscoveryIds.roleViewerRequest, node: victim.nodeId.bytes)])
        XCTAssertFalse(stale.source.ready)
        XCTAssertEqual(stale.results, [.openingStale])
        // A viewer without link hello bit 3 sends no opening: fails closed, never falls back to a prefix check.
        let noBit = try hop(viewerId: victim, selected: copied, viewerEntries: [], viewerBit3: false)
        XCTAssertFalse(noBit.source.ready)
        XCTAssertEqual(noBit.source.phase, .closed)
        XCTAssertEqual(noBit.results, [])
    }

    func testAVersionTwoRequestKeepsThePrefixCheckWhateverTheHelloSays() throws {
        let viewerId = SoftwareSigningIdentity()
        var fixed = DiscoveryAnnouncement(nodeIdPrefix: viewerId.nodeId.prefix,
                                          flags: DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagGattTransport,
                                          capabilitySummary: NodeCapabilities.codecVP9, streamToken: 0x8000_1234, routeCost: 0,
                                          streamBitrateKbps: 300)
        // Both hellos carry bit 3 (the viewer joined a rotating offer): the viewer's BDO1 is read and ignored.
        let h = try hop(viewerId: viewerId, selected: fixed,
                        viewerEntries: [entry(epoch, role: RotatingDiscoveryIds.roleViewerRequest, node: viewerId.nodeId.bytes)])
        XCTAssertTrue(h.source.ready, "\(h.source.closeReason ?? "")")
        XCTAssertEqual(h.results, [], "no role-2 check for a version 2 selection")
        fixed.nodeIdPrefix = SoftwareSigningIdentity().nodeId.prefix
        let wrong = try hop(viewerId: viewerId, selected: fixed, viewerEntries: [])
        XCTAssertFalse(wrong.source.ready, "the prefix check still applies")
        XCTAssertEqual(wrong.source.phase, .closed)
    }

    // MARK: Step 4: DEBUG short epoch (Android ShortEpochHarnessTest)

    override func tearDown() {
        DiscoveryEpochLength.resetForTests()
        super.tearDown()
    }

    func testOnlyADebugBuildBeforeStartAcceptsALengthIn60To900() {
        XCTAssertEqual(RotatingDiscoveryIds.epochSeconds, 900)
        XCTAssertFalse(DiscoveryEpochLength.set(60, debugBuild: false, started: false), "release builds never shorten it")
        for bad: Int64 in [Int64.min, -60, 0, 1, 59, 901, 3_600] {
            XCTAssertFalse(DiscoveryEpochLength.set(bad, debugBuild: true, started: false), "value \(bad)")
        }
        XCTAssertEqual(RotatingDiscoveryIds.epochSeconds, 900)
        XCTAssertTrue(DiscoveryEpochLength.set(60, debugBuild: true, started: false))
        XCTAssertEqual(RotatingDiscoveryIds.epochSeconds, 60)
        XCTAssertFalse(DiscoveryEpochLength.set(120, debugBuild: true, started: true), "never changed after start")
        XCTAssertTrue(DiscoveryEpochLength.set(60, debugBuild: true, started: true), "the same value is already in force")
        XCTAssertEqual(RotatingDiscoveryIds.epochSeconds, 60)
    }

    func testAShortEpochScalesTheAdvertEpochButKeepsRealDays() {
        let t0: Int64 = 1_791_590_400   // 2026-10-10T00:00:00Z, a multiple of 900 and of 60
        XCTAssertTrue(DiscoveryEpochLength.set(60, debugBuild: true, started: false))
        XCTAssertEqual(RotatingDiscoveryIds.wallEpoch(unixSeconds: t0), t0 / 60)
        XCTAssertEqual(RotatingDiscoveryIds.wallEpoch(unixSeconds: t0 + 59), t0 / 60)
        XCTAssertEqual(RotatingDiscoveryIds.wallEpoch(unixSeconds: t0 + 60), t0 / 60 + 1)
        XCTAssertEqual(PresenceLeases.epochsPerDay, 1_440)
        XCTAssertEqual(PresenceLeases.dayOf(t0 / 60), t0 / 86_400, "the same real day as at 900 s")
        XCTAssertEqual(PresenceLeases.dayOf(t0 / 60 + 1_439), t0 / 86_400)
        XCTAssertEqual(PresenceLeases.dayOf(t0 / 60 + 1_440), t0 / 86_400 + 1)
        XCTAssertEqual(DiscoveryEpochClock.elapsedTickMs, 120_000)
        XCTAssertEqual(ContactPresence.maxSkewEpochs, 30 * 1_440, "still 30 real days")
    }

    func testTheEpochClockNeverCarriesItsCounterAcrossLengths() {
        let t0: Int64 = 1_791_590_400_000
        let normal = DiscoveryEpochClock(state: EpochClockState(), bootId: "b") { _ in }
        XCTAssertEqual(normal.read(wallMs: t0, elapsedMs: 0).epoch, epoch)
        let stored900 = normal.state
        XCTAssertNil(stored900.epochSeconds, "a release-length state is stored as before")
        XCTAssertTrue(DiscoveryEpochLength.set(60, debugBuild: true, started: false))
        var persisted: [EpochClockState] = []
        let short = DiscoveryEpochClock(state: stored900, bootId: "b") { persisted.append($0) }
        XCTAssertEqual(short.state.epochSeconds, 60)
        XCTAssertEqual(short.state.lastEpoch, -1, "the 900 s counter is not carried into 60 s epochs")
        XCTAssertEqual(short.state.generation, stored900.generation, "the presence generation is kept")
        XCTAssertEqual(persisted.last?.epochSeconds, 60, "the restart is stored at once")
        XCTAssertEqual(short.read(wallMs: t0, elapsedMs: 0).epoch, t0 / 60_000)
        let stored60 = short.state
        DiscoveryEpochLength.resetForTests()
        let back = DiscoveryEpochClock(state: stored60, bootId: "b") { _ in }
        XCTAssertNil(back.state.epochSeconds)
        XCTAssertEqual(back.state.lastEpoch, -1)
        XCTAssertEqual(back.read(wallMs: t0 + 1_000, elapsedMs: 1_000).epoch, epoch, "no forward jump from the 60 s counter")
        // A state stored by an older build (no length field) reads as the release length.
        let old = try? JSONDecoder().decode(EpochClockState.self,
                                            from: Data(#"{"lastEpoch":5,"tickWallEpoch":5,"tickElapsedMs":0,"bootId":"b","generation":3}"#.utf8))
        XCTAssertEqual(old?.lastEpoch, 5)
        XCTAssertEqual(old?.generation, 3)
        XCTAssertNil(old?.epochSeconds)
    }

    /// AB4F (review finding 2): a presence revocation (a new key generation, also while the vault cannot be read)
    /// rebuilds the live role-1 entry at once, not at the next epoch; the old day key no longer resolves the advertised
    /// ID. A refresh in the same generation reuses the entry as before.
    func testARevocationDuringALiveStreamChangesTheRole1IdAtOnce() {
        let firstKey = Data(0..<32), secondKey = Data(1..<33)
        let first = RotatingDiscoveryIds.entry(saltKey: firstKey, nodeId: nodeId, epoch: epoch, role: RotatingDiscoveryIds.roleStreamOffer)
        let second = RotatingDiscoveryIds.entry(saltKey: secondKey, nodeId: nodeId, epoch: epoch, role: RotatingDiscoveryIds.roleStreamOffer)
        XCTAssertNotEqual(first.rdi, second.rdi)
        let offer = RotatingStreamOffer()
        XCTAssertEqual(offer.decide(epoch: epoch, elapsedMs: 0, generation: 1, entryFor: { _ in first }), .advertise(first))
        // A refresh in the same generation keeps the epoch's ID, as at a pause or a re-advertisement.
        XCTAssertEqual(offer.decide(epoch: epoch, elapsedMs: 5_000, generation: 1, entryFor: { _ in second }), .advertise(first))
        // The revocation's new generation is used at once, in the same epoch.
        XCTAssertEqual(offer.decide(epoch: epoch, elapsedMs: 6_000, generation: 2, entryFor: { _ in second }), .advertise(second))
        XCTAssertTrue(second.opens(selected: second.rdi, nodeId: nodeId, expectedRole: RotatingDiscoveryIds.roleStreamOffer))
        XCTAssertNotEqual(RotatingDiscoveryIds.rdi(nodeId: nodeId, epoch: epoch, role: RotatingDiscoveryIds.roleStreamOffer, salt: first.salt),
                          second.rdi, "the old day key no longer resolves the advertised ID")
        XCTAssertEqual(offer.acceptedEntries(elapsedMs: 6_000), [second], "the revoked ID is not left openable")
    }

    // AB4: later steps add their tests above this line.
}
