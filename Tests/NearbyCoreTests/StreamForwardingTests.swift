import XCTest
@testable import NearbyCore

/// Experimental iPhone stream forwarding: ports of Android RelayColdStartTest, RelayChildHealthPolicyTest and
/// ForwardedStreamSecurityTest cases, plus a source -> iPhone relay -> child loopback.
final class RelayAdmissionTests: XCTestCase {
    let now: Int64 = 1_000_000_000
    let perLink = MeshBandwidth.perLinkKbps(videoKbps: 300, fps: 15)

    func testPerLinkLoadMatchesAndroid() {
        XCTAssertEqual(perLink, 403.392, accuracy: 1e-9)
        XCTAssertEqual(2 * perLink, 806.784, accuracy: 1e-9)
    }

    func testAFreshInstallMayRelayExactlyOneChildOfA300KbpsStream() {
        let fresh = LearnedLinkCapacity()
        let measured = LinkCapacityPolicy.budgetKbps(fresh, priorKbps: MeshBandwidth.leSafeAggregateKbps, perLinkKbps: perLink, nowMs: now)
        XCTAssertFalse(LinkCapacityPolicy.relayFits(budgetKbps: measured, perLinkKbps: perLink))
        XCTAssertTrue(LinkCapacityPolicy.relayColdStart(fresh, nowMs: now))
        let budget = LinkCapacityPolicy.relayBudgetKbps(measured: measured, perLinkKbps: perLink, coldStart: true)
        XCTAssertEqual(budget, 2 * perLink, accuracy: 1e-9)
        XCTAssertTrue(LinkCapacityPolicy.relayFits(budgetKbps: budget, perLinkKbps: perLink))
        XCTAssertFalse(budget >= 3 * perLink)
        let decision = RelayAdmission.evaluate(learned: fresh, advertisedKbps: 300, fps: 15, nowMs: now)
        XCTAssertTrue(decision.fits && decision.coldStart)
        XCTAssertFalse(RelayAdmission.evaluate(learned: fresh, advertisedKbps: 300, fps: 15, nowMs: now, coldStartRule: false).fits)
    }

    func testRelayEvidenceEitherWayEndsTheColdStart() {
        let failed = LearnedLinkCapacity(provenKbps: 0, ceilingKbps: 450, ceilingMeasuredAtMs: now - 60_000)
        XCTAssertFalse(LinkCapacityPolicy.relayColdStart(failed, nowMs: now))
        let measured = LinkCapacityPolicy.budgetKbps(failed, priorKbps: 700, perLinkKbps: perLink, nowMs: now)
        XCTAssertFalse(LinkCapacityPolicy.relayFits(budgetKbps: LinkCapacityPolicy.relayBudgetKbps(measured: measured, perLinkKbps: perLink, coldStart: false), perLinkKbps: perLink))
        let proven = LearnedLinkCapacity(provenKbps: 714)
        XCTAssertFalse(LinkCapacityPolicy.relayColdStart(proven, nowMs: now))
        XCTAssertTrue(LinkCapacityPolicy.relayFits(budgetKbps: LinkCapacityPolicy.budgetKbps(proven, priorKbps: 700, perLinkKbps: perLink, nowMs: now), perLinkKbps: perLink))
        var expired = failed; expired.ceilingMeasuredAtMs = now - LinkCapacityPolicy.ceilingTtlMs
        XCTAssertTrue(LinkCapacityPolicy.relayColdStart(expired, nowMs: now))
    }

    func testTheControlArmKeepsTheMeasuredBudgetAndUnknownBitrateAdmits() {
        XCTAssertEqual(LinkCapacityPolicy.relayBudgetKbps(measured: 700, perLinkKbps: perLink, coldStart: false), 700)
        XCTAssertEqual(LinkCapacityPolicy.relayBudgetKbps(measured: 1264, perLinkKbps: perLink, coldStart: true), 1264)
        XCTAssertTrue(RelayAdmission.evaluate(learned: LearnedLinkCapacity(provenKbps: 0, ceilingKbps: 100, ceilingMeasuredAtMs: now), advertisedKbps: 0, fps: 15, nowMs: now).fits)
    }
}

final class RelayChildHealthPolicyTests: XCTestCase {
    func testABurstTheChildCanAbsorbIsNeverWithdrawn() {
        var p = RelayChildHealthPolicy()
        for t in 0..<20 { XCTAssertFalse(p.shouldWithdraw(backlog: 1.8, now: Double(t))) }
    }
    func testAChildStayingBehindLongerThanItsBufferIsWithdrawn() {
        var p = RelayChildHealthPolicy()
        XCTAssertFalse(p.shouldWithdraw(backlog: 2.6, now: 0)); XCTAssertFalse(p.shouldWithdraw(backlog: 2.9, now: 2))
        XCTAssertTrue(p.shouldWithdraw(backlog: 3.2, now: 3))
    }
    func testRecoveringResetsAndAHugeBacklogWithdrawsAtOnce() {
        var p = RelayChildHealthPolicy()
        _ = p.shouldWithdraw(backlog: 2.6, now: 0)
        XCTAssertFalse(p.shouldWithdraw(backlog: 1.0, now: 2)); XCTAssertFalse(p.shouldWithdraw(backlog: 1.2, now: 3)); XCTAssertFalse(p.shouldWithdraw(backlog: 1.3, now: 5))
        var q = RelayChildHealthPolicy(); XCTAssertTrue(q.shouldWithdraw(backlog: 6, now: 0))
    }
    func testSheddingDisablesTheTrendRuleOnly() {
        let growth: [TimeInterval] = [0.3, 0.7, 1.1, 1.4, 1.64]
        var noLoss = RelayChildHealthPolicy()
        XCTAssertTrue(growth.enumerated().contains { noLoss.shouldWithdraw(backlog: $0.element, now: Double($0.offset)) })
        var shedding = RelayChildHealthPolicy(sheddingActive: true)
        XCTAssertFalse(growth.enumerated().contains { shedding.shouldWithdraw(backlog: $0.element, now: Double($0.offset)) })
        XCTAssertFalse(shedding.shouldWithdraw(backlog: 2.6, now: 10)); XCTAssertTrue(shedding.shouldWithdraw(backlog: 3.0, now: 13))
    }
    func testAJoinKeyframeThatDrainsIsKeptAndAFallingLinkIsWithdrawnEarly() {
        var p = RelayChildHealthPolicy()
        for (t, b) in [0.2, 1.0, 1.8, 1.5, 1.0, 0.6, 0.3, 0.2].enumerated() { XCTAssertFalse(p.shouldWithdraw(backlog: b, now: Double(t))) }
        var q = RelayChildHealthPolicy()
        XCTAssertFalse(q.shouldWithdraw(backlog: 1.0, now: 0)); XCTAssertFalse(q.shouldWithdraw(backlog: 1.5, now: 2))
        XCTAssertTrue(q.shouldWithdraw(backlog: 1.9, now: 3))
    }
}

final class StreamForwardingCoreTests: XCTestCase {
    let source = SoftwareSigningIdentity().nodeId, relay = SoftwareSigningIdentity().nodeId, parent = SoftwareSigningIdentity().nodeId
    let child = SoftwareSigningIdentity().nodeId
    let streamId = UUID(uuidString: "c7da2c06-e0de-4d7b-98ed-4916c2f208a3")!
    let sealer = EndToEndContentSealer(key: .init(data: Data(repeating: 3, count: 32)))

    private func envelope(_ seq: UInt64, _ type: EndToEndContentType, flags: UInt8 = 0, ttl: UInt8 = 8, src: NodeId? = nil) throws -> MeshEnvelope {
        MeshEnvelope(streamId: streamId, sourceNodeId: src ?? source, sequence: seq, ttl: ttl, flags: flags, payload: try sealer.seal(type, flags: flags & 0x0f, Data([UInt8(seq)])))
    }

    func testGrantRoundTripMatchesAndroidLayout() throws {
        let grant = ForwardedStreamGrant(sourceNodeId: source, streamId: streamId, key: Data((0..<32).map { UInt8($0 + 9) }))
        let encoded = grant.encoded
        XCTAssertEqual(encoded.count, 68)
        XCTAssertEqual(encoded.prefix(4), Data("BFG1".utf8))
        XCTAssertEqual(encoded[20..<36].hex, "c7da2c06e0de4d7b98ed4916c2f208a3")
        XCTAssertEqual(try ForwardedStreamGrant(decoding: encoded), grant)
        XCTAssertThrowsError(try ForwardedStreamGrant(decoding: encoded + Data([0])))
    }

    func testLateChildGetsBootstrapThenWaitsForAKeyframe() throws {
        let core = StreamForwardingCore(localNodeId: relay, upstreamPeerNodeId: parent, streamId: streamId, sourceNodeId: source)
        XCTAssertEqual(try core.receive(try envelope(0, .streamHeader, flags: 0)), .rejected(.noChild))
        for i in 1...10 { _ = try core.receive(try envelope(UInt64(i), .mediaPacket, flags: MeshEnvelope.flagCodecConfig)) }
        _ = try core.receive(try envelope(11, .streamState, flags: MeshEnvelope.flagControl))
        _ = try core.receive(try envelope(12, .mediaPacket, flags: MeshEnvelope.flagKeyFrame))
        _ = try core.receive(try envelope(13, .mediaPacket))
        let bootstrap = try core.addChild(child)
        // Header, the newest 8 codec configs and the latest state, in sequence order, TTL - 1.
        XCTAssertEqual(bootstrap.map(\.sequence), [0, 3, 4, 5, 6, 7, 8, 9, 10, 11])
        XCTAssertTrue(bootstrap.allSatisfy { $0.ttl == 7 })
        XCTAssertThrowsError(try core.addChild(SoftwareSigningIdentity().nodeId), "one child only")
        XCTAssertEqual(try core.receive(try envelope(14, .mediaPacket)), .waitingForJoinKeyFrame)
        guard case .forward(let audio, false) = try core.receive(try envelope(15, .mediaPacket, flags: MeshEnvelope.flagAudio)) else { return XCTFail("audio passes") }
        XCTAssertEqual(audio.ttl, 7)
        guard case .forward(let key, true) = try core.receive(try envelope(16, .mediaPacket, flags: MeshEnvelope.flagKeyFrame)) else { return XCTFail("keyframe starts") }
        XCTAssertEqual(key.payload, try envelope(16, .mediaPacket, flags: MeshEnvelope.flagKeyFrame).payload.count == key.payload.count ? key.payload : Data(), "ciphertext unchanged")
        guard case .forward = try core.receive(try envelope(17, .mediaPacket)) else { return XCTFail("then everything flows") }
    }

    func testDuplicatesTtlLoopsAndSourceChanges() throws {
        let core = StreamForwardingCore(localNodeId: relay, upstreamPeerNodeId: parent, streamId: streamId, sourceNodeId: source)
        _ = try core.addChild(child)
        let e = try envelope(1, .mediaPacket, flags: MeshEnvelope.flagAudio)
        guard case .forward = try core.receive(e) else { return XCTFail() }
        XCTAssertEqual(try core.receive(e), .rejected(.duplicate))
        XCTAssertEqual(try core.receive(try envelope(2, .mediaPacket, flags: MeshEnvelope.flagAudio, ttl: 1)), .rejected(.ttlExpired))
        XCTAssertEqual(try core.receive(try envelope(3, .mediaPacket, src: relay)), .rejected(.localLoop))
        XCTAssertThrowsError(try core.receive(try envelope(4, .mediaPacket, src: SoftwareSigningIdentity().nodeId)))
        XCTAssertThrowsError(try core.addChild(parent))
    }
}

/// Source -> iPhone relay (viewer with maxChildren 1 + forwarder) -> child viewer, over GATT-framed pipes.
final class StreamForwardingLoopbackTests: XCTestCase {
    private func move(_ from: MeshConnection, _ to: MeshConnection, now: TimeInterval) -> Bool {
        var moved = false
        while let bytes = from.nextOutgoing(now: now) { to.receive(bytes, now: now); moved = true }
        return moved
    }
    private func pump(_ pairs: [(MeshConnection, MeshConnection)], now: TimeInterval = 0) {
        for _ in 0..<100 {
            var moved = false
            for (a, b) in pairs { if move(a, b, now: now) { moved = true }; if move(b, a, now: now) { moved = true } }
            if !moved { return }
        }
    }

    func testChildReceivesTheOriginalSourceThroughTheIPhoneRelay() throws {
        let sourceId = SoftwareSigningIdentity(), relayId = SoftwareSigningIdentity(), childId = SoftwareSigningIdentity()
        let header = StreamHeader(width: 360, height: 640, fps: 15, codecId: StreamProtocol.codecVP9, includeAudio: true)
        let source = StreamSourceEngine(transport: .gatt, identity: sourceId, header: header, expectedViewerPrefix: relayId.nodeId.prefix)
        let upstream = StreamViewerEngine(transport: .gatt, identity: relayId, decodeMask: NodeCapabilities.codecVP9,
                                          expectedAdjacentPrefix: sourceId.nodeId.prefix, maxChildren: 1)
        upstream.holdEndAck = true
        var sourceEvents: [StreamSourceEngine.Event] = []
        source.onEvent = { sourceEvents.append($0) }
        var core: StreamForwardingCore?
        var forwarder: StreamForwarderEngine?
        var upstreamKeyFrameRequests = 0
        upstream.onEvent = { event in
            switch event {
            case .envelope(let e):
                if core == nil {   // the header envelope itself arrives before the .header event
                    core = StreamForwardingCore(localNodeId: relayId.nodeId, upstreamPeerNodeId: sourceId.nodeId, streamId: e.streamId, sourceNodeId: e.sourceNodeId)
                }
                switch try? core!.receive(e) {
                case .forward(let copy, _)?: forwarder?.forward(copy)
                case .waitingForJoinKeyFrame?: upstreamKeyFrameRequests += 1; upstream.requestKeyFrame()
                default: break
                }
            default: break
            }
        }
        try source.start(now: 0); try upstream.start(now: 0); pump([(source, upstream)])
        XCTAssertTrue(source.useMeshEnvelope, "the relay signed maxChildren 1, so the source sends BMV1")
        source.sendAudioConfig()
        source.sendVideo(flags: StreamProtocol.flagKeyFrame, presentationTimeUs: 0, payload: Data(repeating: 1, count: 900))
        source.sendVideo(flags: 0, presentationTimeUs: 66_666, payload: Data(repeating: 2, count: 300))
        pump([(source, upstream)])
        XCTAssertNotNil(upstream.header)

        // A child joins mid-stream.
        let grant = ForwardedStreamGrant(sourceNodeId: upstream.mediaSourceNodeId!, streamId: upstream.meshStreamId!, key: upstream.mediaOpenKey!)
        let fwd = StreamForwarderEngine(transport: .gatt, identity: relayId, grant: grant, codecId: header.codecId, expectedChildPrefix: childId.nodeId.prefix)
        forwarder = fwd
        let childViewer = StreamViewerEngine(transport: .gatt, identity: childId, decodeMask: NodeCapabilities.codecVP9, expectedAdjacentPrefix: relayId.nodeId.prefix)
        var childEvents: [StreamViewerEngine.Event] = []
        childViewer.onEvent = { childEvents.append($0) }
        var forwarderEvents: [StreamForwarderEngine.Event] = []
        fwd.onEvent = { event in
            forwarderEvents.append(event)
            switch event {
            case .childAuthenticated(let id, _): for e in (try? core!.addChild(id)) ?? [] { fwd.forward(e) }
            case .keyFrameRequested: upstream.requestKeyFrame()
            case .endAcknowledged: upstream.releaseEndAck()
            default: break
            }
        }
        try fwd.start(now: 0); try childViewer.start(now: 0)
        pump([(source, upstream), (fwd, childViewer)])
        XCTAssertTrue(childEvents.contains { if case .sourceAuthenticated(_, let src, _) = $0 { return src == sourceId.nodeId }; return false }, "the child learns the original source")
        XCTAssertEqual(childViewer.header, header)
        // Mid-GOP: non-key video waits; audio passes; the next keyframe starts the child.
        source.sendVideo(flags: 0, presentationTimeUs: 133_333, payload: Data(repeating: 3, count: 300))
        source.sendAudio(presentationTimeUs: 140_000, opus: Data([0xfc, 1]))
        pump([(source, upstream), (fwd, childViewer)])
        XCTAssertGreaterThan(upstreamKeyFrameRequests, 0)
        XCTAssertTrue(sourceEvents.contains(.keyFrameRequested), "the join asked the source for a keyframe")
        XCTAssertEqual(childViewer.videoPackets, 0); XCTAssertEqual(childViewer.audioPackets, 1)
        source.sendVideo(flags: StreamProtocol.flagKeyFrame, presentationTimeUs: 200_000, payload: Data(repeating: 4, count: 900))
        source.sendVideo(flags: 0, presentationTimeUs: 266_666, payload: Data(repeating: 5, count: 300))
        pump([(source, upstream), (fwd, childViewer)])
        XCTAssertEqual(childViewer.videoPackets, 2)
        // A child keyframe request is regenerated upstream (hop by hop).
        let before = sourceEvents.filter { $0 == .keyFrameRequested }.count
        childViewer.requestKeyFrame(); pump([(source, upstream), (fwd, childViewer)])
        XCTAssertEqual(sourceEvents.filter { $0 == .keyFrameRequested }.count, before + 1)
        // End: the relay acknowledges upstream only after its child did.
        source.endStream(); pump([(source, upstream), (fwd, childViewer)])
        XCTAssertTrue(childEvents.contains(.state(.ended)))
        XCTAssertTrue(forwarderEvents.contains(.endAcknowledged))
        XCTAssertTrue(sourceEvents.contains(.endAcknowledged))
    }

    func testRouteWithdrawalAndOneChildOnly() throws {
        let relayId = SoftwareSigningIdentity(), childId = SoftwareSigningIdentity(), sourceNode = SoftwareSigningIdentity().nodeId
        let grant = ForwardedStreamGrant(sourceNodeId: sourceNode, streamId: UUID(), key: Data(repeating: 1, count: 32))
        let fwd = StreamForwarderEngine(transport: .l2cap, identity: relayId, grant: grant, codecId: StreamProtocol.codecVP9, expectedChildPrefix: nil)
        let child = StreamViewerEngine(transport: .l2cap, identity: childId, decodeMask: NodeCapabilities.codecVP9, expectedAdjacentPrefix: nil)
        var childEvents: [StreamViewerEngine.Event] = [], fwdEvents: [StreamForwarderEngine.Event] = []
        child.onEvent = { childEvents.append($0) }; fwd.onEvent = { fwdEvents.append($0) }
        try fwd.start(now: 0); try child.start(now: 0); pump([(fwd, child)])
        XCTAssertTrue(fwd.ready)
        XCTAssertEqual(child.grant, grant)
        fwd.withdrawRoute(); pump([(fwd, child)])
        XCTAssertTrue(childEvents.contains(.routeWithdrawn(.localCapacity)))
        XCTAssertTrue(fwdEvents.contains(.routeWithdrawalAcknowledged))
        // A child signing group relay (maxChildren 2) is refused, as on Android.
        let groupChild = StreamViewerEngine(transport: .l2cap, identity: SoftwareSigningIdentity(), decodeMask: NodeCapabilities.codecVP9, expectedAdjacentPrefix: nil, maxChildren: 2)
        let fwd2 = StreamForwarderEngine(transport: .l2cap, identity: relayId, grant: grant, codecId: StreamProtocol.codecVP9, expectedChildPrefix: nil)
        try fwd2.start(now: 0); try groupChild.start(now: 0); pump([(fwd2, groupChild)])
        XCTAssertFalse(fwd2.ready)
    }
}

final class ForwarderRouteTokenTests: XCTestCase {
    /// Android StreamDiscoveryTest values: logical 0x12345678 through parent 010203040506 to child 060504030201.
    func testDownstreamTokenKeepsTheLogicalStreamAndBit31() throws {
        let parent = Data([1, 2, 3, 4, 5, 6]), own = Data([6, 5, 4, 3, 2, 1])
        let upstream = try StreamRouteToken.forAdvertiser(logical: 0x12345678, prefix: parent)
        let downstream = StreamRouteToken.downstream(upstreamRouteToken: upstream, parentPrefix: parent, ownPrefix: own)
        XCTAssertEqual(StreamRouteToken.logical(routeToken: downstream, prefix: own), 0x12345678)
        XCTAssertNotEqual(downstream, upstream)
        XCTAssertEqual(downstream & 0x8000_0000, 0x8000_0000, "compact offers need bit 31")
        // The forwarder's offer is representable as an iPhone compact stream offer with the relay bit and cost.
        let offer = DiscoveryAnnouncement(nodeIdPrefix: own, flags: DiscoveryAnnouncement.flagStreamAvailable | DiscoveryAnnouncement.flagRelayCapable,
                                          capabilitySummary: NodeCapabilities.codecVP9, streamToken: downstream, routeCost: 1,
                                          streamWidth: 360, streamHeight: 640, streamFps: 15, streamBitrateKbps: 300)
        let uuid = try CompactAnnouncement.encode(offer)
        let decoded = try XCTUnwrap(CompactAnnouncement.decode(uuid))
        XCTAssertEqual(decoded.streamToken, downstream); XCTAssertEqual(decoded.routeCost, 1)
        XCTAssertNotEqual(decoded.flags & DiscoveryAnnouncement.flagRelayCapable, 0)
    }
}

/// Relay-child media age (Android BoundedMediaAgeTest / RelayChildQueue cases, default ON on Android).
final class RelayMediaAgeTests: XCTestCase {
    let source = SoftwareSigningIdentity().nodeId
    let streamId = UUID()
    let sealer = EndToEndContentSealer(key: .init(data: Data(repeating: 3, count: 32)))
    private func env(_ seq: UInt64, _ type: EndToEndContentType = .mediaPacket, flags: UInt8 = 0) throws -> MeshEnvelope {
        MeshEnvelope(streamId: streamId, sourceNodeId: source, sequence: seq, ttl: 7, flags: flags, payload: try sealer.seal(type, flags: type == .mediaPacket ? flags & 0x0f : 0, Data(repeating: 1, count: 200)))
    }

    func testBudgetPlanBackoffAndClassification() throws {
        XCTAssertEqual(BoundedMediaAge.streamQueueBudgetMs(viewerAddedDelayMs: 0), 1_750)
        XCTAssertEqual(BoundedMediaAge.streamQueueBudgetMs(viewerAddedDelayMs: 1_500), 400, "never below the congestion backlog")
        // A usable keyframe: drop the video before the newest usable one; keep everything else.
        let plan = planCodecSafeShed([.video, .keep, .keyFrame, .video, .keyFrame, .video], usable: [true, true, true, true, true, true])
        XCTAssertEqual(plan, ShedPlan(drop: [0, 2, 3], awaitKeyFrame: false))
        let stale = planCodecSafeShed([.keyFrame, .video, .keep], usable: [false, true, true])
        XCTAssertEqual(stale, ShedPlan(drop: [0, 1], awaitKeyFrame: true), "a keyframe older than the budget does not help")
        var backoff = RelayRecoveryBackoff()
        XCTAssertTrue(backoff.tryRequest(now: 0))
        XCTAssertFalse(backoff.tryRequest(now: 1))
        XCTAssertTrue(backoff.tryRequest(now: 1.5)); XCTAssertEqual(backoff.interval, 3)
        XCTAssertTrue(backoff.tryRequest(now: 4.5)); XCTAssertEqual(backoff.interval, 6)
        for t in stride(from: 10.5, through: 80, by: 15) { _ = backoff.tryRequest(now: t) }
        XCTAssertEqual(backoff.interval, BoundedMediaAge.relayRecoveryMaxInterval, "capped at 15 s")
        XCTAssertTrue(backoff.tryRequest(now: 200)); XCTAssertEqual(backoff.interval, BoundedMediaAge.keyFrameRerequest, "reset after a calm minute")
        XCTAssertEqual(relayEnvelopeShedClass(try env(1, flags: MeshEnvelope.flagAudio)), .keep)
        XCTAssertEqual(relayEnvelopeShedClass(try env(2, flags: MeshEnvelope.flagCodecConfig)), .keep)
        XCTAssertEqual(relayEnvelopeShedClass(try env(3, .streamState)), .keep)
        XCTAssertEqual(relayEnvelopeShedClass(try env(4, flags: MeshEnvelope.flagKeyFrame)), .keyFrame)
        XCTAssertEqual(relayEnvelopeShedClass(try env(5)), .video)
    }

    private func pump(_ a: MeshConnection, _ b: MeshConnection, now: TimeInterval) {
        for _ in 0..<50 {
            var moved = false
            while let d = a.nextOutgoing(now: now) { b.receive(d, now: now); moved = true }
            while let d = b.nextOutgoing(now: now) { a.receive(d, now: now); moved = true }
            if !moved { return }
        }
    }

    func testASlowChildSkipsStaleVideoToAKeyframeAndKeepsItsAudio() throws {
        let grant = ForwardedStreamGrant(sourceNodeId: source, streamId: streamId, key: Data(repeating: 3, count: 32))
        let fwd = StreamForwarderEngine(transport: .gatt, identity: SoftwareSigningIdentity(), grant: grant, codecId: StreamProtocol.codecVP9, expectedChildPrefix: nil)
        fwd.mediaAge = true
        let child = StreamViewerEngine(transport: .gatt, identity: SoftwareSigningIdentity(), decodeMask: NodeCapabilities.codecVP9, expectedAdjacentPrefix: nil)
        try fwd.start(now: 0); try child.start(now: 0); pump(fwd, child, now: 0)
        XCTAssertTrue(fwd.ready)
        // The child link stalls: 3 s of video and audio pile up (nothing is pulled from the forwarder).
        var seq: UInt64 = 10
        func offer(_ flags: UInt8, at t: TimeInterval) throws -> StreamForwarderEngine.ForwardOutcome { seq += 1; return fwd.forward(try env(seq, flags: flags), now: t) }
        XCTAssertEqual(try offer(MeshEnvelope.flagKeyFrame, at: 0), .queued)
        for i in 1...30 {
            let t = Double(i) * 0.1
            XCTAssertEqual(try offer(MeshEnvelope.flagAudio, at: t), .queued, "audio is never shed")
            let outcome = try offer(0, at: t)
            if t <= 1.75 { XCTAssertEqual(outcome, .queued, "inside the 1.75 s budget at \(t)") }
            if t > 1.8 && fwd.shedder.shedEvents == 1 && fwd.shedder.awaitingKeyFrame { XCTAssertNotEqual(outcome, .queued) }
        }
        XCTAssertEqual(fwd.shedder.shedEvents, 1, "one codec-safe shed past the budget")
        XCTAssertTrue(fwd.shedder.awaitingKeyFrame, "the only keyframe was stale: wait for the next")
        XCTAssertEqual(fwd.recovery.requests, 1, "one recovery request, the rest backed off or not needed yet")
        XCTAssertFalse(fwd.queuedAudio == false, "the queued audio stayed")
        // The next keyframe ends the wait and is queued.
        XCTAssertEqual(try offer(MeshEnvelope.flagKeyFrame, at: 3.1), .queued)
        XCTAssertFalse(fwd.shedder.awaitingKeyFrame)
        XCTAssertEqual(try offer(0, at: 3.2), .queued)
        // Off (no-loss): nothing is ever shed.
        let lossless = StreamForwarderEngine(transport: .gatt, identity: SoftwareSigningIdentity(), grant: grant, codecId: StreamProtocol.codecVP9, expectedChildPrefix: nil)
        let child2 = StreamViewerEngine(transport: .gatt, identity: SoftwareSigningIdentity(), decodeMask: NodeCapabilities.codecVP9, expectedAdjacentPrefix: nil)
        try lossless.start(now: 0); try child2.start(now: 0); pump(lossless, child2, now: 0)
        for i in 0..<40 { XCTAssertEqual(lossless.forward(try env(UInt64(100 + i)), now: Double(i) * 0.1), .queued) }
        XCTAssertEqual(lossless.queuedEnvelopes, 40)
    }
}
