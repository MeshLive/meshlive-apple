import XCTest
@testable import NearbyCore

/// Design SI Phase 1, viewer side: a watch session presents a throwaway join key `J` and keys its rotating viewer
/// request with a throwaway salt key `Ks`, so no stream hop, request or opening carries this phone's identity.
final class StreamJoinKeysTests: XCTestCase {
    /// PROTOCOL A.10 `join_rdi` inputs: `J` scalar 32 x 4a, `Ks` = 60..7f, epoch 2,000,000.
    let joinScalar = Data(repeating: 0x4a, count: 32)
    let saltKey = Data(0x60...0x7f)
    let epoch: Int64 = 2_000_000
    /// A default Android version 5 stream offer (the RotatingViewerTests protocol vector).
    let androidOffer = Data(hex: "05bb2d061f64800c0192529fc40001028001680f012c")!

    private func vectorKeys(session: Int = 1) throws -> StreamJoinKeys {
        try StreamJoinKeys(session: session, joinScalar: joinScalar, saltKey: saltKey)
    }

    // MARK: Two sessions, two nodes

    func testTwoWatchSessionsPresentTwoNodesAndNeitherIsThePhonesIdentity() throws {
        let phone = SoftwareSigningIdentity()
        let sessions = StreamJoinSessions()
        let first = sessions.begin()
        let firstNode = first.nodeId, firstRequest = try first.viewerRequestEntry(epoch: epoch)
        let second = sessions.begin()
        XCTAssertTrue(first.isClosed, "selecting another stream ends the earlier watch session")
        XCTAssertTrue(sessions.current === second)
        XCTAssertEqual([first.session, second.session], [1, 2])
        XCTAssertNotEqual(firstNode, second.nodeId)
        XCTAssertNotEqual(first.versionTwoPrefix, second.versionTwoPrefix)
        XCTAssertNotEqual(firstRequest.rdi, try second.viewerRequestEntry(epoch: epoch).rdi, "the same epoch, another session: another ID")
        for keys in [first, second] {
            XCTAssertNotEqual(keys.nodeId, phone.nodeId)
            XCTAssertNotEqual(keys.identity.publicKeyEncoded, phone.publicKeyEncoded)
            XCTAssertEqual(keys.identity.nodeId, keys.nodeId)
        }
    }

    // MARK: The pinned derivation

    /// The expected bytes were computed independently (Python `cryptography`, SHA-256 and HMAC-SHA256 over the PROTOCOL
    /// "Keys and epochs" domains) from the A.10 `join_rdi` inputs.
    func testTheJoinRdiVectorIsTheProtocolDerivationKeyedByTheSaltKey() throws {
        let keys = try vectorKeys()
        XCTAssertEqual(keys.nodeId.hex, "5e6fdad782ef526daeb71e22e253598d")
        XCTAssertEqual(keys.versionTwoPrefix.hex, "5e6fdad782ef")
        let viewer = try keys.viewerRequestEntry(epoch: epoch)
        XCTAssertEqual(viewer.salt.hex, "8a34e8290c63bc5238874571a5b0c3578b0cc0d1da1efe794cc511d1ceca3988")
        XCTAssertEqual(viewer.rdi.hex, "7eb610960aaa")
        XCTAssertEqual(try DiscoveryOpeningCodec.encode([viewer]).hex,
                       "42444f310101" + "7eb610960aaa001e8480028a34e8290c63bc5238874571a5b0c3578b0cc0d1da1efe794cc511d1ceca3988")
        let forwarder = try keys.forwarderOfferEntry(epoch: epoch)
        XCTAssertEqual(forwarder.rdi.hex, "c3a1741c6ab7")
        XCTAssertEqual(forwarder.salt.hex, "3d9a04ca498302c7d61494a0a7e0d3b09525c5cfa46094897ddd95c1b3416a7f")
        // The existing entry function with Ks as the salt key gives the same entry (no new derivation).
        XCTAssertEqual(viewer, RotatingDiscoveryIds.entry(saltKey: saltKey, nodeId: keys.nodeId.bytes, epoch: epoch, role: 2))
        XCTAssertThrowsError(try keys.entry(epoch: epoch, role: RotatingDiscoveryIds.roleCallOffer), "a join key never makes a call offer")
        XCTAssertThrowsError(try StreamJoinKeys(session: 1, joinScalar: joinScalar, saltKey: Data(count: 31)))
    }

    // MARK: Requests

    func testTheRequestsCarryTheJoinKeysIdsAndNoDecodeMask() throws {
        let keys = try vectorKeys()
        let source = SoftwareSigningIdentity()
        let token = try StreamRouteToken.forAdvertiser(logical: 0x1234, prefix: source.nodeId.prefix)
        let offer = DiscoveryAnnouncement(nodeIdPrefix: source.nodeId.prefix, flags: DiscoveryAnnouncement.flagStreamAvailable | DiscoveryAnnouncement.flagGattTransport,
                                          capabilitySummary: NodeCapabilities.codecVP9, streamToken: token, routeCost: 1, streamBitrateKbps: 600)
        let request = try StreamJoinRequest.versionTwo(keys: keys, offer: offer, transport: .gatt)
        XCTAssertEqual(request.nodeIdPrefix, keys.versionTwoPrefix)
        XCTAssertEqual(request.capabilitySummary, 0)
        XCTAssertTrue(request.isViewerRequest(routeToken: token))
        XCTAssertEqual(request.transport, .gatt)
        XCTAssertEqual(request.routeCost, 1)
        XCTAssertEqual(request.streamBitrateKbps, 600)
        let decoded = try DiscoveryAnnouncement(decoding: try request.encoded())
        XCTAssertEqual(decoded.nodeIdPrefix.hex, "5e6fdad782ef", "the version 2 request on air is nodeId(J)'s prefix")
        XCTAssertEqual(try StreamJoinRequest.versionTwo(keys: keys, offer: offer, transport: .l2cap).transport, .l2cap)

        let rotating = try StreamJoinRequest.rotating(keys: keys, epoch: epoch,
                                                      offer: try DiscoveryAnnouncement(decoding: androidOffer, acceptRotating: true), transport: .gatt)
        XCTAssertTrue(rotating.rotating)
        XCTAssertEqual(rotating.nodeIdPrefix.hex, "7eb610960aaa", "a version 5 request carries J's role-2 RDI")
        XCTAssertEqual(rotating.capabilitySummary, 0)
    }

    // MARK: Boundaries and the opening

    func testAnEpochBoundaryGivesANewIdAndTheSameNode() throws {
        let keys = try vectorKeys()
        let request = RotatingViewerRequest()
        let e0 = try keys.viewerRequestEntry(epoch: epoch), e1 = try keys.viewerRequestEntry(epoch: epoch + 1)
        XCTAssertNotEqual(e0.rdi, e1.rdi)
        XCTAssertEqual(request.decide(epoch: epoch, elapsedMs: 0) { _ in e0 }, .advertise(e0))
        XCTAssertEqual(request.decide(epoch: epoch + 1, elapsedMs: 10_000, entryFor: { _ in e1 }, silenceMs: { 2_000 }), .silent(untilMs: 12_000))
        XCTAssertEqual(request.decide(epoch: epoch + 1, elapsedMs: 12_000) { _ in e1 }, .advertise(e1))
        // Both IDs open for the same node: the source that selected either one sees one J.
        let offer = try DiscoveryAnnouncement(decoding: androidOffer, acceptRotating: true)
        for (e, entry) in [(epoch, e0), (epoch + 1, e1)] {
            let selected = try XCTUnwrap(CompactAnnouncement.decode(
                try CompactAnnouncement.encode(try StreamJoinRequest.rotating(keys: keys, epoch: e, offer: offer, transport: .gatt)), acceptRotating: true))
            XCTAssertEqual(DiscoverySelectionCheck.check(selected: selected, expectedRole: RotatingDiscoveryIds.roleViewerRequest, peerNodeId: keys.nodeId.bytes,
                                                         openingEntries: request.acceptedEntries(elapsedMs: 12_000), verifierWallEpoch: epoch + 1), .pass)
            XCTAssertTrue(entry.opens(selected: selected.nodeIdPrefix, nodeId: keys.nodeId.bytes, expectedRole: 2))
        }
    }

    func testTheOpeningVerifiesAgainstTheJoinKeysNodeAndNotThePhonesIdentity() throws {
        let phone = SoftwareSigningIdentity()
        let keys = StreamJoinKeys(session: 1)
        let mine = try keys.viewerRequestEntry(epoch: epoch)
        let offer = try DiscoveryAnnouncement(decoding: androidOffer, acceptRotating: true)
        let selected = try XCTUnwrap(CompactAnnouncement.decode(
            try CompactAnnouncement.encode(try StreamJoinRequest.rotating(keys: keys, epoch: epoch, offer: offer, transport: .gatt)), acceptRotating: true))
        var results: [DiscoverySelectionCheck.Result] = []
        let (source, viewer) = try joinRotating(viewer: keys.identity, entries: [mine], selected: selected) { results.append($0) }
        XCTAssertTrue(source.ready, viewer.closeReason ?? source.closeReason ?? "")
        XCTAssertEqual(results, [.pass], "the source's own role-2 check of the selected request")
        XCTAssertEqual(source.link.peerNodeId, keys.nodeId, "the source authenticated J")
        let check = { (node: NodeId) in
            DiscoverySelectionCheck.check(selected: selected, expectedRole: RotatingDiscoveryIds.roleViewerRequest, peerNodeId: node.bytes,
                                          openingEntries: source.peerOpening, verifierWallEpoch: self.epoch)
        }
        XCTAssertEqual(check(keys.nodeId), .pass, "recomputed from nodeId(J)")
        XCTAssertEqual(check(phone.nodeId), .openingMismatch, "the request does not open for the phone's identity")
        // The phone's identity presenting J's request and opening is refused by the source (a copied request).
        results = []
        let (copier, _) = try joinRotating(viewer: phone, entries: [mine], selected: selected) { results.append($0) }
        XCTAssertFalse(copier.ready)
        XCTAssertEqual(results, [.openingMismatch])
    }

    // MARK: The stream hello

    func testTheStreamHellosCarryJAtBothLayersAndNoBuildTag() throws {
        let phone = SoftwareSigningIdentity()
        let keys = StreamJoinKeys(session: 1)
        let sourceId = SoftwareSigningIdentity()
        let offer = versionTwoOffer(source: sourceId)
        let request = try StreamJoinRequest.versionTwo(keys: keys, offer: offer, transport: .gatt)
        var authenticated: [IdentityFingerprint] = []
        let (source, viewer) = try joinVersionTwo(viewer: keys.identity, source: sourceId, expectedViewerPrefix: request.nodeIdPrefix) { event in
            if case .viewerAuthenticated(_, let fp) = event { authenticated.append(fp) }
        }
        XCTAssertTrue(source.ready, viewer.closeReason ?? source.closeReason ?? "")
        XCTAssertEqual(viewer.header?.width, 640)
        let hello = try XCTUnwrap(source.link.peerHello)
        XCTAssertEqual(hello.identityPublicKey, keys.identity.publicKeyEncoded, "the BMH2 link hello carries J")
        XCTAssertEqual(hello.nodeId, keys.nodeId)
        XCTAssertNotEqual(hello.identityPublicKey, phone.publicKeyEncoded)
        XCTAssertEqual(source.endpoint?.peerNodeId, keys.nodeId, "the end-to-end hello carries the same J")
        XCTAssertEqual(authenticated, [keys.identity.fingerprint])
        XCTAssertNil(source.link.peerBuildTag, "no build tag in a join-key stream hello")
        XCTAssertEqual(hello.capabilities.transportMask & NodeCapabilities.transportBuildTag, 0)
        // A source that expects the phone's fixed prefix refuses J: the request must carry nodeId(J)'s prefix.
        let (strict, _) = try joinVersionTwo(viewer: keys.identity, source: sourceId, expectedViewerPrefix: phone.nodeId.prefix)
        XCTAssertFalse(strict.ready)
    }

    // MARK: Recovery and the end of the session

    func testRecoveryKeepsTheNodeAndOnlyANewSessionChangesIt() throws {
        let sessions = StreamJoinSessions()
        let keys = sessions.begin()
        let sourceId = SoftwareSigningIdentity()
        let (first, _) = try joinVersionTwo(viewer: keys.identity, source: sourceId, expectedViewerPrefix: keys.versionTwoPrefix)
        XCTAssertTrue(first.ready)
        // The link is lost; recovery rejoins through another route of the same stream with the same session's keys.
        let resumed = try XCTUnwrap(sessions.resume(keys))
        XCTAssertTrue(resumed === keys)
        let (second, _) = try joinVersionTwo(viewer: resumed.identity, source: sourceId, expectedViewerPrefix: resumed.versionTwoPrefix)
        XCTAssertTrue(second.ready)
        XCTAssertEqual(second.link.peerNodeId, first.link.peerNodeId, "the source sees the same node after recovery")
        XCTAssertEqual(try resumed.viewerRequestEntry(epoch: epoch + 1).epoch, epoch + 1, "a boundary during recovery keeps the keys")
        // The 60 s give-up ends the session: it never resumes, and the next watch is another node.
        XCTAssertTrue(sessions.end(.lost) === keys)
        XCTAssertNil(sessions.resume(keys))
        XCTAssertNil(sessions.current)
        XCTAssertNotEqual(sessions.begin().nodeId, keys.nodeId)
        XCTAssertNil(sessions.end(.left).flatMap { sessions.resume($0) })
        XCTAssertNil(sessions.end(.wipe), "nothing left to end")
    }

    func testClosingZeroesTheSaltKeyAndJStopsSigning() throws {
        let keys = try vectorKeys()
        XCTAssertEqual(keys.saltKeySnapshot(), saltKey)
        let held = keys.identity
        XCTAssertNoThrow(try held.sign(Data("probe".utf8)))
        keys.close()
        XCTAssertEqual(keys.saltKeySnapshot(), Data(count: StreamJoinKeys.saltKeyBytes), "Ks is overwritten with zeros")
        XCTAssertTrue(keys.isClosed && held.isClosed)
        XCTAssertThrowsError(try held.sign(Data("probe".utf8)), "an engine that still holds J cannot sign with it")
        XCTAssertThrowsError(try keys.viewerRequestEntry(epoch: epoch))
        XCTAssertThrowsError(try keys.forwarderOfferEntry(epoch: epoch))
        XCTAssertThrowsError(try StreamJoinRequest.versionTwo(keys: keys, offer: versionTwoOffer(source: SoftwareSigningIdentity()), transport: .gatt))
        keys.close()
        XCTAssertEqual(keys.saltKeySnapshot(), Data(count: StreamJoinKeys.saltKeyBytes), "closing twice is harmless")
        // A stream hop that starts after the close never authenticates J.
        let (source, viewer) = try joinVersionTwo(viewer: held, source: SoftwareSigningIdentity(), expectedViewerPrefix: keys.versionTwoPrefix)
        XCTAssertFalse(source.ready)
        XCTAssertNil(viewer.header)
        // Fresh keys are random, never the zeroed or a fixed value.
        let fresh = StreamJoinKeys(session: 2)
        XCTAssertNotEqual(fresh.saltKeySnapshot(), Data(count: StreamJoinKeys.saltKeyBytes))
        XCTAssertNotEqual(fresh.saltKeySnapshot(), StreamJoinKeys(session: 3).saltKeySnapshot())
    }

    func testTheKeyLinesFollowTheProtocolAndCarryNoIdentifierInRelease() throws {
        let keys = try vectorKeys(session: 4)
        let fields = { (line: KeyValuePairs<String, String>) in line.map { "\($0.key)=\($0.value)" } }
        XCTAssertEqual(fields(keys.logLine(.open, reason: StreamJoinKeys.OpenReason.watch.rawValue, role: .viewer, debugBuild: true)),
                       ["event=open", "key=join", "reason=watch", "role=viewer", "session=4", "prefix=5e6fdad782ef"])
        XCTAssertEqual(fields(keys.logLine(.close, reason: StreamJoinSessions.EndReason.lost.rawValue, role: .viewer, debugBuild: true)),
                       ["event=close", "key=join", "reason=lost", "role=viewer", "session=4", "prefix=5e6fdad782ef"])
        let release = fields(keys.logLine(.open, reason: "recovery", role: .forwarder, debugBuild: false))
        XCTAssertEqual(release, ["event=open", "key=join", "reason=recovery", "role=forwarder"])
        XCTAssertFalse(release.joined().contains(keys.prefixLabel), "a release build logs no throwaway identifier")
    }

    // MARK: App wiring rules (pure parts)

    func testEveryEndOfAWatchClosesItsKeysWithItsReason() {
        typealias S = StreamJoinSessions
        XCTAssertEqual(S.endReason(sourceEnded: true, recovering: true, stoppedByUser: true), .ended)
        XCTAssertEqual(S.endReason(sourceEnded: false, recovering: true, stoppedByUser: false), .lost, "the 60 s give-up while recovering")
        XCTAssertEqual(S.endReason(sourceEnded: false, recovering: false, stoppedByUser: true), .left)
        XCTAssertEqual(S.endReason(sourceEnded: false, recovering: false, stoppedByUser: false), .stopped, "a join that gave up, a block")
        var closed: [(Int, S.EndReason)] = []
        let sessions = S(onClose: { keys, reason in closed.append((keys.session, reason)) })
        let first = sessions.begin()
        _ = sessions.begin()                                   // another stream: the first ends as switched
        sessions.end(.lost)
        sessions.close(first, reason: .left)                   // already closed: no second line
        let third = sessions.begin()
        let late = StreamJoinKeys(session: 99)
        sessions.close(late, reason: .stopped)                 // keys that are not the open session still close
        sessions.close(third, reason: .wipe)
        XCTAssertEqual(closed.map { $0.0 }, [1, 2, 99, 3])
        XCTAssertEqual(closed.map { $0.1 }, [.switched, .lost, .stopped, .wipe])
        XCTAssertTrue(first.isClosed && late.isClosed && third.isClosed)
        XCTAssertNil(sessions.current)
    }

    func testAWatchsKeysEndSixtySecondsAfterTheFirstLoss() {
        var bound = StreamJoinLostBound()
        XCTAssertNil(bound.remaining(now: 10))
        XCTAssertFalse(bound.expired(now: 10_000), "a stream that was never lost has no deadline")
        bound.onLost(now: 100)
        bound.onLost(now: 130)                                 // a failed rejoin does not restart the count
        XCTAssertEqual(bound.remaining(now: 130), 30)
        XCTAssertFalse(bound.expired(now: 159.9))
        XCTAssertTrue(bound.expired(now: 160))
        bound.onRecovered()
        XCTAssertNil(bound.remaining(now: 170))
        bound.onLost(now: 200)
        XCTAssertEqual(bound.remaining(now: 200), StreamJoinLostBound.seconds, "a later loss counts from its own start")
    }

    func testTheRequestEntryFunctionGivesEachEpochItsOwnIdAndNothingOnceClosed() throws {
        let keys = try vectorKeys()
        let entryFor = try XCTUnwrap(keys.viewerRequestEntries(epoch: epoch))
        XCTAssertEqual(entryFor(epoch), try keys.viewerRequestEntry(epoch: epoch))
        XCTAssertEqual(entryFor(epoch + 1), try keys.viewerRequestEntry(epoch: epoch + 1), "the asked epoch, not the captured one")
        let request = RotatingViewerRequest()
        XCTAssertEqual(request.decide(epoch: epoch, elapsedMs: 0, entryFor: entryFor), .advertise(try keys.viewerRequestEntry(epoch: epoch)))
        keys.close()
        XCTAssertNil(keys.viewerRequestEntries(epoch: epoch), "a closed session advertises nothing")
    }

    func testNoRequestOfAJoinKeyWatchCarriesThePhonesIds() throws {
        let phone = SoftwareSigningIdentity()
        let presenceKey = Data(repeating: 3, count: 32)
        let keys = StreamJoinKeys(session: 1)
        let source = SoftwareSigningIdentity()
        let v2Offer = versionTwoOffer(source: source)
        let rotatingOffer = try DiscoveryAnnouncement(decoding: androidOffer, acceptRotating: true)
        let phoneIds = Set((epoch - 2...epoch + 2).map {
            RotatingDiscoveryIds.ownEntry(presenceKey: presenceKey, nodeId: phone.nodeId.bytes, epoch: $0, role: 2).rdi
        } + [phone.nodeId.prefix])
        for transport in [MeshTransport.gatt, .l2cap] {
            let requests = [try StreamJoinRequest.versionTwo(keys: keys, offer: v2Offer, transport: transport),
                            try StreamJoinRequest.versionTwo(keys: keys, offer: rotatingOffer, transport: transport),
                            try StreamJoinRequest.rotating(keys: keys, epoch: epoch, offer: rotatingOffer, transport: transport)]
            for request in requests {
                XCTAssertFalse(phoneIds.contains(request.nodeIdPrefix))
                XCTAssertEqual(request.capabilitySummary, 0)
                XCTAssertTrue(request.idMayBeJoinKey, "and its ID is never logged")
            }
        }
    }

    func testLogsHideIdsThatMayBeAStreamParticipantsThrowaway() throws {
        let keys = try vectorKeys()
        let source = SoftwareSigningIdentity()
        let fixedRequest = try StreamJoinRequest.versionTwo(keys: keys, offer: versionTwoOffer(source: source), transport: .gatt)
        let rotatingRequest = try StreamJoinRequest.rotating(keys: keys, epoch: epoch,
                                                             offer: try DiscoveryAnnouncement(decoding: androidOffer, acceptRotating: true), transport: .gatt)
        var relayed = versionTwoOffer(source: source); relayed.routeCost = 1
        let sourceOffer = versionTwoOffer(source: source)
        let callOffer = DiscoveryAnnouncement(nodeIdPrefix: source.nodeId.prefix, flags: DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable,
                                              capabilitySummary: 0, streamToken: 0, routeCost: 0)
        for debugBuild in [true, false] {
            for advert in [fixedRequest, rotatingRequest, relayed] {
                XCTAssertEqual(advert.loggablePrefix(debugBuild: debugBuild), "hidden", "a possible join key, in every build")
                XCTAssertEqual(advert.loggableHandle(debugBuild: debugBuild), "hidden")
            }
            XCTAssertEqual(callOffer.loggablePrefix(debugBuild: debugBuild), source.nodeId.prefix.hex, "call adverts are logged as before")
        }
        // A source's own offer: DEBUG only (a release scanner cannot tell it from a forwarder's throwaway offer).
        XCTAssertEqual(sourceOffer.loggablePrefix(debugBuild: true), source.nodeId.prefix.hex)
        XCTAssertEqual(sourceOffer.loggableHandle(debugBuild: true), IdentityHandle.handle(prefix: source.nodeId.prefix) ?? "?")
        XCTAssertEqual(sourceOffer.loggablePrefix(debugBuild: false), "hidden")
        XCTAssertEqual(sourceOffer.loggableHandle(debugBuild: false), "hidden")
        // What a release build's discovery log could hold of this watch's own request: nothing of J.
        let releaseFields = [fixedRequest, rotatingRequest].flatMap { [$0.loggablePrefix(debugBuild: false), $0.loggableHandle(debugBuild: false)] }
        XCTAssertFalse(releaseFields.contains { $0.contains(keys.versionTwoPrefix.hex) || $0.contains(rotatingRequest.nodeIdPrefix.hex) })
    }

    // MARK: Stream hop helpers (BMS1 link, both handshakes, the header)

    private func versionTwoOffer(source: SigningIdentity) -> DiscoveryAnnouncement {
        DiscoveryAnnouncement(nodeIdPrefix: source.nodeId.prefix, flags: DiscoveryAnnouncement.flagStreamAvailable | DiscoveryAnnouncement.flagGattTransport,
                              capabilitySummary: NodeCapabilities.codecVP9,
                              streamToken: (try? StreamRouteToken.forAdvertiser(logical: 0x1234, prefix: source.nodeId.prefix)) ?? 1, routeCost: 0)
    }

    private func pump(_ source: StreamSourceEngine, _ viewer: StreamViewerEngine) {
        for _ in 0..<50 {
            var moved = false
            while let d = source.nextOutgoing(now: 0) { viewer.receive(d, now: 0); moved = true }
            while let d = viewer.nextOutgoing(now: 0) { source.receive(d, now: 0); moved = true }
            if !moved { break }
        }
    }

    private var header: StreamHeader { StreamHeader(width: 640, height: 360, fps: 15, codecId: StreamProtocol.codecVP9, includeAudio: true) }

    private func joinVersionTwo(viewer viewerId: SigningIdentity, source sourceId: SigningIdentity, expectedViewerPrefix: Data,
                                onSourceEvent: ((StreamSourceEngine.Event) -> Void)? = nil) throws -> (StreamSourceEngine, StreamViewerEngine) {
        let source = StreamSourceEngine(transport: .gatt, identity: sourceId, header: header, expectedViewerPrefix: expectedViewerPrefix)
        source.onEvent = onSourceEvent
        let viewer = StreamViewerEngine(transport: .gatt, identity: viewerId, decodeMask: NodeCapabilities.codecVP9,
                                        expectedAdjacentPrefix: sourceId.nodeId.prefix)
        try source.start(now: 0); try viewer.start(now: 0)
        pump(source, viewer)
        return (source, viewer)
    }

    private func joinRotating(viewer viewerId: SigningIdentity, entries: [OpeningEntry], selected: DiscoveryAnnouncement,
                              onChecked: @escaping (DiscoverySelectionCheck.Result) -> Void) throws -> (StreamSourceEngine, StreamViewerEngine) {
        let sourceId = SoftwareSigningIdentity()
        let role1 = RotatingDiscoveryIds.entry(saltKey: Data(repeating: 5, count: 32), nodeId: sourceId.nodeId.bytes, epoch: epoch, role: 1)
        var offer = DiscoveryAnnouncement(nodeIdPrefix: role1.rdi, flags: DiscoveryAnnouncement.flagStreamAvailable | DiscoveryAnnouncement.flagGattTransport,
                                          capabilitySummary: NodeCapabilities.codecVP9,
                                          streamToken: try StreamRouteToken.forAdvertiser(logical: 0x1234, prefix: role1.rdi), routeCost: 0)
        offer.rotating = true
        let source = StreamSourceEngine(transport: .gatt, identity: sourceId, header: header, expectedViewerPrefix: nil, rotatingEntries: { [role1] },
                                        selectedRequest: selected, wallEpoch: { self.epoch })
        source.onOpeningChecked = onChecked
        let viewer = StreamViewerEngine(transport: .gatt, identity: viewerId, decodeMask: NodeCapabilities.codecVP9,
                                        expectedAdjacentPrefix: offer.nodeIdPrefix, rotatingOffer: offer, wallEpoch: { self.epoch },
                                        openingEntries: entries)
        try source.start(now: 0); try viewer.start(now: 0)
        pump(source, viewer)
        return (source, viewer)
    }
}
