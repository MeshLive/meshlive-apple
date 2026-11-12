import XCTest
@testable import NearbyCore

/// SEC-B2 on Apple: a stream hop's end-to-end peer must be its authenticated link peer. The attacks below use real
/// BMH2 handshakes and a relaying middle M: two link-only hops with M's own key that copy the end-to-end records
/// between the source side and the viewer side, as a phone that posted its own request (or offer) and dialled the
/// other side would.
final class StreamHopPeerBindingTests: XCTestCase {
    let epoch: Int64 = 0x001e6000
    private var lines: [String] = []

    override func setUp() {
        super.setUp()
        lines = []
        StreamHopPeerBinding.debugLog = { [weak self] fields in self?.lines.append(fields.map { "\($0.key)=\($0.value)" }.joined(separator: " | ")) }
    }

    override func tearDown() {
        StreamHopPeerBinding.debugLog = nil
        super.tearDown()
    }

    private var header: StreamHeader { StreamHeader(width: 640, height: 360, fps: 15, codecId: StreamProtocol.codecVP9, includeAudio: true) }

    // MARK: The rule

    func testOnlyTheSameNodeIsBound() throws {
        let a = SoftwareSigningIdentity().nodeId
        var sameprefix = a.bytes; sameprefix[15] ^= 1
        let twin = try NodeId(bytes: sameprefix)
        XCTAssertEqual(twin.prefix, a.prefix)
        XCTAssertEqual(StreamHopPeerBinding.check(link: a, endpoint: a), .bound)
        XCTAssertEqual(StreamHopPeerBinding.check(link: a, endpoint: twin), .mismatch, "a shared 6-byte prefix is not the same peer")
        XCTAssertEqual(StreamHopPeerBinding.check(link: nil, endpoint: a), .mismatch)
        XCTAssertThrowsError(try StreamHopPeerBinding.require(role: .viewer, rotating: false, link: a, endpoint: twin))
        XCTAssertNoThrow(try StreamHopPeerBinding.require(role: .source, rotating: true, link: a, endpoint: a))
        XCTAssertEqual(lines, ["result=mismatch | role=viewer | version=2"])
    }

    // MARK: Version 2, a relaying middle

    func testASourceRefusesAViewerRelayedThroughAnotherLinkPeer() throws {
        let s = SoftwareSigningIdentity(), m = SoftwareSigningIdentity(), v = SoftwareSigningIdentity()
        let source = StreamSourceEngine(transport: .gatt, identity: s, header: header, expectedViewerPrefix: nil)
        let viewer = UnboundEndpoint(identity: v)
        let relay = try relayed(upstream: source, middle: m, downstream: viewer)
        XCTAssertFalse(source.ready)
        XCTAssertEqual(source.link.peerNodeId, m.nodeId, "the link was M's")
        XCTAssertNotNil(source.closeReason)
        XCTAssertEqual(source.phase, .closed, "the hop is closed before any content")
        XCTAssertTrue(lines.contains("result=mismatch | role=source | version=2"), "\(lines)")
        XCTAssertGreaterThan(relay.upCopied + relay.downCopied, 0, "the middle really relayed the handshake")
    }

    func testAViewerRefusesASourceRelayedThroughAnotherLinkPeer() throws {
        let s = SoftwareSigningIdentity(), m = SoftwareSigningIdentity(), v = SoftwareSigningIdentity()
        let source = StreamSourceEngine(transport: .gatt, identity: s, header: header, expectedViewerPrefix: nil)
        let viewer = StreamViewerEngine(transport: .gatt, identity: v, decodeMask: NodeCapabilities.codecVP9, expectedAdjacentPrefix: nil)
        _ = try relayed(upstream: source, middle: m, downstream: viewer)
        XCTAssertNil(viewer.header)
        XCTAssertNil(viewer.mediaSourceNodeId, "the relayed source is never authenticated")
        XCTAssertNotNil(viewer.closeReason)
        XCTAssertTrue(lines.contains("result=mismatch | role=viewer | version=2"), "\(lines)")
    }

    /// The attack as a phone can mount it: M posts its own request to the source and its own (copied) offer to the
    /// viewer, so each side's selected prefix is M's. The end-to-end peer is never M, so both sides fail.
    func testTheRelayFailsWhenEachSideSelectedTheMiddlesOwnAdvert() throws {
        let s = SoftwareSigningIdentity(), m = SoftwareSigningIdentity(), v = SoftwareSigningIdentity()
        let source = StreamSourceEngine(transport: .gatt, identity: s, header: header, expectedViewerPrefix: m.nodeId.prefix)
        let viewer = StreamViewerEngine(transport: .gatt, identity: v, decodeMask: NodeCapabilities.codecVP9, expectedAdjacentPrefix: m.nodeId.prefix)
        _ = try relayed(upstream: source, middle: m, downstream: viewer)
        XCTAssertFalse(source.ready)
        XCTAssertNil(viewer.header)
        XCTAssertNil(viewer.mediaSourceNodeId)
    }

    func testAViewerChecksTheLinkPeerAgainstTheSelectedOfferBeforeAnyHandshake() throws {
        let s = SoftwareSigningIdentity(), m = SoftwareSigningIdentity(), v = SoftwareSigningIdentity()
        let source = StreamSourceEngine(transport: .gatt, identity: s, header: header, expectedViewerPrefix: nil)
        let viewer = StreamViewerEngine(transport: .gatt, identity: v, decodeMask: NodeCapabilities.codecVP9, expectedAdjacentPrefix: s.nodeId.prefix)
        let relay = try relayed(upstream: source, middle: m, downstream: viewer)
        XCTAssertNotNil(viewer.closeReason)
        XCTAssertEqual(relay.upCopied, 0, "the viewer sent no end-to-end record: it failed at M's link hello")
        XCTAssertFalse(source.ready)
    }

    func testAForwarderRefusesAChildRelayedThroughAnotherLinkPeer() throws {
        let f = SoftwareSigningIdentity(), m = SoftwareSigningIdentity(), v = SoftwareSigningIdentity()
        let grant = ForwardedStreamGrant(sourceNodeId: SoftwareSigningIdentity().nodeId, streamId: UUID(), key: Data(repeating: 9, count: 32))
        let forwarder = StreamForwarderEngine(transport: .gatt, identity: f, grant: grant, codecId: StreamProtocol.codecVP9, expectedChildPrefix: nil)
        _ = try relayed(upstream: forwarder, middle: m, downstream: UnboundEndpoint(identity: v))
        XCTAssertFalse(forwarder.ready)
        XCTAssertEqual(forwarder.phase, .closed)
        XCTAssertTrue(lines.contains("result=mismatch | role=forwarder | version=2"), "\(lines)")
    }

    // MARK: Version 5, a relaying middle that opens its own rotating advert

    func testARotatingSourceRefusesAViewerRelayedBehindTheMiddlesOwnRequest() throws {
        let s = SoftwareSigningIdentity(), m = SoftwareSigningIdentity(), v = SoftwareSigningIdentity()
        let key = Data(repeating: 4, count: 32)
        let mEntry = RotatingDiscoveryIds.entry(saltKey: key, nodeId: m.nodeId.bytes, epoch: epoch, role: RotatingDiscoveryIds.roleViewerRequest)
        let offer = try rotatingOffer(source: s)
        let mRequest = try XCTUnwrap(CompactAnnouncement.decode(
            try CompactAnnouncement.encode(try RotatingViewerRequest.announcement(entry: mEntry, offer: offer.announcement, transport: .gatt)), acceptRotating: true))
        var checked: [DiscoverySelectionCheck.Result] = []
        let source = StreamSourceEngine(transport: .gatt, identity: s, header: header, expectedViewerPrefix: nil, rotatingEntries: { [offer.entry] },
                                        selectedRequest: mRequest, wallEpoch: { self.epoch })
        source.onOpeningChecked = { checked.append($0) }
        _ = try relayed(upstream: source, middle: m, downstream: UnboundEndpoint(identity: v), upOpening: [mEntry], announcement: offer.announcement)
        XCTAssertEqual(checked, [.pass], "M opened its own request legitimately")
        XCTAssertFalse(source.ready)
        XCTAssertTrue(lines.contains("result=mismatch | role=source | version=5"), "\(lines)")
    }

    func testARotatingViewerRefusesASourceRelayedBehindTheMiddlesOwnOffer() throws {
        let s = SoftwareSigningIdentity(), m = SoftwareSigningIdentity(), v = SoftwareSigningIdentity()
        let decoy = try rotatingOffer(source: m)   // M's own rotating offer (it copied the stream's fields)
        let source = StreamSourceEngine(transport: .gatt, identity: s, header: header, expectedViewerPrefix: m.nodeId.prefix)
        let viewer = StreamViewerEngine(transport: .gatt, identity: v, decodeMask: NodeCapabilities.codecVP9, expectedAdjacentPrefix: decoy.announcement.nodeIdPrefix,
                                        rotatingOffer: decoy.announcement, wallEpoch: { self.epoch })
        _ = try relayed(upstream: source, middle: m, downstream: viewer, downOpening: [decoy.entry], announcement: decoy.announcement)
        XCTAssertNil(viewer.mediaSourceNodeId)
        XCTAssertNil(viewer.header)
        XCTAssertTrue(lines.contains("result=mismatch | role=viewer | version=5"), "\(lines)")
    }

    // MARK: Legitimate hops still join

    func testDirectAndForwardedJoinsStillPass() throws {
        let s = SoftwareSigningIdentity(), v = SoftwareSigningIdentity()
        // Version 2, direct.
        let source = StreamSourceEngine(transport: .gatt, identity: s, header: header, expectedViewerPrefix: v.nodeId.prefix)
        let viewer = StreamViewerEngine(transport: .gatt, identity: v, decodeMask: NodeCapabilities.codecVP9, expectedAdjacentPrefix: s.nodeId.prefix)
        try pump(source, viewer)
        XCTAssertTrue(source.ready, viewer.closeReason ?? source.closeReason ?? "")
        XCTAssertEqual(viewer.header?.width, 640)
        // Version 5, direct.
        let offer = try rotatingOffer(source: s)
        let vEntry = RotatingDiscoveryIds.entry(saltKey: Data(repeating: 6, count: 32), nodeId: v.nodeId.bytes, epoch: epoch, role: RotatingDiscoveryIds.roleViewerRequest)
        let vRequest = try XCTUnwrap(CompactAnnouncement.decode(
            try CompactAnnouncement.encode(try RotatingViewerRequest.announcement(entry: vEntry, offer: offer.announcement, transport: .gatt)), acceptRotating: true))
        let rotatingSource = StreamSourceEngine(transport: .gatt, identity: s, header: header, expectedViewerPrefix: nil, rotatingEntries: { [offer.entry] },
                                                selectedRequest: vRequest, wallEpoch: { self.epoch })
        let rotatingViewer = StreamViewerEngine(transport: .gatt, identity: v, decodeMask: NodeCapabilities.codecVP9, expectedAdjacentPrefix: offer.announcement.nodeIdPrefix,
                                                rotatingOffer: offer.announcement, wallEpoch: { self.epoch }, openingEntries: [vEntry])
        try pump(rotatingSource, rotatingViewer)
        XCTAssertTrue(rotatingSource.ready, rotatingViewer.closeReason ?? rotatingSource.closeReason ?? "")
        XCTAssertEqual(rotatingViewer.header?.width, 640)
        // A forwarder toward its child: the child's end-to-end peer is the forwarder itself.
        let f = SoftwareSigningIdentity()
        let grant = ForwardedStreamGrant(sourceNodeId: s.nodeId, streamId: UUID(), key: Data(repeating: 9, count: 32))
        let forwarder = StreamForwarderEngine(transport: .gatt, identity: f, grant: grant, codecId: StreamProtocol.codecVP9, expectedChildPrefix: v.nodeId.prefix)
        let child = StreamViewerEngine(transport: .gatt, identity: v, decodeMask: NodeCapabilities.codecVP9, expectedAdjacentPrefix: f.nodeId.prefix)
        try pump(forwarder, child)
        XCTAssertTrue(forwarder.ready, child.closeReason ?? forwarder.closeReason ?? "")
        XCTAssertEqual(child.mediaSourceNodeId, s.nodeId, "the child authenticated the forwarder and took the grant")
        XCTAssertEqual(lines, [], "no mismatch on a legitimate hop")
    }

    // MARK: Helpers

    /// A plain responder endpoint without the stream engines' checks (the far side of an attack seen from one engine).
    final class UnboundEndpoint: MeshConnection {
        init(identity: SigningIdentity) {
            let caps = NodeCapabilities(transportMask: MeshTransport.gatt.capabilityBit, encodeCodecMask: 0, decodeCodecMask: NodeCapabilities.codecVP9,
                                        maxBitrateKbps: MeshTransport.gatt.maxVideoBitrateKbps, maxChildren: 0)
            super.init(role: .responder, transport: .gatt, identity: identity, linkCapabilities: caps, endpointCapabilities: caps)
        }
        override func handleOpenRecord(_ record: SecureRecord) throws {}
    }

    private func rotatingOffer(source: SigningIdentity) throws -> (announcement: DiscoveryAnnouncement, entry: OpeningEntry) {
        let entry = RotatingDiscoveryIds.entry(saltKey: Data(repeating: 5, count: 32), nodeId: source.nodeId.bytes, epoch: epoch, role: RotatingDiscoveryIds.roleStreamOffer)
        var offer = DiscoveryAnnouncement(nodeIdPrefix: entry.rdi, flags: DiscoveryAnnouncement.flagStreamAvailable | DiscoveryAnnouncement.flagGattTransport,
                                          capabilitySummary: NodeCapabilities.codecVP9, streamToken: 0x9252_9fc4, routeCost: 0)
        offer.rotating = true
        return (offer, entry)
    }

    private func pump(_ a: MeshConnection, _ b: MeshConnection) throws {
        try a.start(now: 0); try b.start(now: 0)
        for _ in 0..<50 {
            var moved = false
            while let d = a.nextOutgoing(now: 0) { b.receive(d, now: 0); moved = true }
            while let d = b.nextOutgoing(now: 0) { a.receive(d, now: 0); moved = true }
            if !moved { break }
        }
    }

    /// `upstream` (the dialling source or forwarder) -> M -> `downstream` (the answering viewer), M copying every
    /// end-to-end record both ways. `upOpening`/`downOpening`: M's own BDO1 entries toward each side (its own adverts).
    @discardableResult
    private func relayed(upstream: MeshConnection, middle m: SigningIdentity, downstream: MeshConnection,
                         upOpening: [OpeningEntry]? = nil, downOpening: [OpeningEntry]? = nil,
                         announcement: DiscoveryAnnouncement? = nil) throws -> (upCopied: Int, downCopied: Int) {
        let up = CallRelayLink(role: .responder, transport: .gatt, identity: m, openingCheck: upOpening != nil ? announcement : nil)
        let down = CallRelayLink(role: .initiator, transport: .gatt, identity: m, openingCheck: downOpening != nil ? announcement : nil)
        for (hop, entries) in [(up, upOpening), (down, downOpening)] {
            guard let entries else { continue }
            hop.discoveryOpeningEntries = { entries }
            hop.onDiscoveryOpening = { _ in }   // M ignores the other side's opening
        }
        up.onRecord = { down.copy($0) }
        down.onRecord = { up.copy($0) }
        try upstream.start(now: 0); try up.start(now: 0); try down.start(now: 0); try downstream.start(now: 0)
        for _ in 0..<80 {
            var moved = false
            while let d = upstream.nextOutgoing(now: 0) { up.receive(d, now: 0); moved = true }
            while let d = up.nextOutgoing(now: 0) { upstream.receive(d, now: 0); moved = true }
            while let d = down.nextOutgoing(now: 0) { downstream.receive(d, now: 0); moved = true }
            while let d = downstream.nextOutgoing(now: 0) { down.receive(d, now: 0); moved = true }
            if !moved { break }
        }
        return (up.copiedRecords, down.copiedRecords)
    }
}
