import XCTest
@testable import NearbyCore

/// Experimental iPhone call relay: Android PrivateCallRelayChainTest rules and in-memory chains
/// caller -> iPhone relay(s) -> callee with unchanged end-to-end records.
final class CallRelayTests: XCTestCase {
    let vp9 = NodeCapabilities.codecVP9

    private func move(_ from: MeshConnection, _ to: MeshConnection, now: TimeInterval) -> Bool {
        var moved = false
        while let bytes = from.nextOutgoing(now: now) { to.receive(bytes, now: now); moved = true }
        return moved
    }
    private func pump(_ pairs: [(MeshConnection, MeshConnection)], now: TimeInterval = 0) {
        for _ in 0..<200 {
            var moved = false
            for (a, b) in pairs { if move(a, b, now: now) { moved = true }; if move(b, a, now: now) { moved = true } }
            if !moved { return }
        }
    }
    private func callOffer(_ prefix: Data, cost: UInt8 = 0, relay: Bool = false) -> DiscoveryAnnouncement {
        var flags = DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable
        if relay { flags |= DiscoveryAnnouncement.flagRelayCapable }
        return DiscoveryAnnouncement(nodeIdPrefix: prefix, flags: flags, capabilitySummary: 0x01, streamToken: 0, routeCost: cost)
    }

    func testChainRulesMatchAndroid() throws {
        let me = SoftwareSigningIdentity().nodeId, callee = SoftwareSigningIdentity().nodeId, next = SoftwareSigningIdentity().nodeId
        XCTAssertTrue(CallRelayChain.admitsOffer(callOffer(callee.prefix, cost: 3), ownPrefix: me.prefix))
        XCTAssertFalse(CallRelayChain.admitsOffer(callOffer(callee.prefix, cost: 4), ownPrefix: me.prefix), "at most 4 relays")
        XCTAssertFalse(CallRelayChain.admitsOffer(callOffer(me.prefix), ownPrefix: me.prefix))
        var rotatingOffer = callOffer(callee.prefix); rotatingOffer.rotating = true
        XCTAssertFalse(CallRelayChain.admitsOffer(rotatingOffer, ownPrefix: me.prefix), "rotating-ID offers are not relayed in phase 1")
        let plain = NodeCapabilities(transportMask: NodeCapabilities.transportGATT, encodeCodecMask: 0, decodeCodecMask: 0, maxBitrateKbps: 500, maxChildren: 0)
        let relayCaps = NodeCapabilities(transportMask: NodeCapabilities.transportGATT | NodeCapabilities.transportCallRelay, encodeCodecMask: 0, decodeCodecMask: 0, maxBitrateKbps: 500, maxChildren: 1)
        XCTAssertNil(CallRelayChain.childProblem(childRouteCost: 0, calleePrefix: callee.prefix, ownNodeId: me, child: callee, caps: plain))
        XCTAssertNotNil(CallRelayChain.childProblem(childRouteCost: 0, calleePrefix: callee.prefix, ownNodeId: me, child: next, caps: relayCaps))
        XCTAssertNil(CallRelayChain.childProblem(childRouteCost: 1, calleePrefix: callee.prefix, ownNodeId: me, child: next, caps: relayCaps))
        XCTAssertNotNil(CallRelayChain.childProblem(childRouteCost: 1, calleePrefix: callee.prefix, ownNodeId: me, child: next, caps: plain), "next relay must sign bit 6")
        XCTAssertNotNil(CallRelayChain.childProblem(childRouteCost: 1, calleePrefix: callee.prefix, ownNodeId: me, child: callee, caps: relayCaps))
        XCTAssertNotNil(CallRelayChain.parentProblem(parent: me, ownNodeId: me, child: callee, calleePrefix: callee.prefix))
        XCTAssertNotNil(CallRelayChain.parentProblem(parent: callee, ownNodeId: me, child: next, calleePrefix: callee.prefix))
        XCTAssertNil(CallRelayChain.parentProblem(parent: SoftwareSigningIdentity().nodeId, ownNodeId: me, child: callee, calleePrefix: callee.prefix))
        for cost in 0...4 { XCTAssertEqual(CallRelayChain.inviteHops(routeCost: UInt8(cost)), UInt8(cost)) }
        XCTAssertNil(CallRelayChain.inviteHops(routeCost: 5))
        // The relayed offer: callee prefix, call + relay flags, cost + 1, representable as an iPhone compact call offer.
        let offer = CallRelayChain.parentOffer(childOffer: callOffer(callee.prefix, cost: 1, relay: true), transport: .gatt)
        XCTAssertEqual(offer.nodeIdPrefix, callee.prefix); XCTAssertEqual(offer.routeCost, 2)
        XCTAssertTrue(offer.isPrivateCallOffer); XCTAssertNotEqual(offer.flags & DiscoveryAnnouncement.flagRelayCapable, 0)
        let decoded = try XCTUnwrap(CompactAnnouncement.decode(try CompactAnnouncement.encode(offer)))
        XCTAssertEqual(decoded.routeCost, 2); XCTAssertEqual(decoded.nodeIdPrefix, callee.prefix)
    }

    /// PROTOCOL "Experimental dual listening": a child offer may carry capabilitySummary bit 3 (0x08, dual-listening
    /// hint) and bit 4 (0x10, relay consent). The relayed offer keeps the codec bits and the consent bit and clears
    /// everything else, so the compact encoder (which throws on an unrepresentable bit) still advertises it.
    func testRelayedOfferMasksTheDualHintAndKeepsConsent() throws {
        let callee = SoftwareSigningIdentity().nodeId
        func relayed(_ summary: UInt8) -> DiscoveryAnnouncement {
            var child = callOffer(callee.prefix)
            child.capabilitySummary = summary
            return CallRelayChain.parentOffer(childOffer: child, transport: .gatt)
        }
        XCTAssertEqual(CallRelayChain.relayedSummaryMask, 0x17)
        // Dual hint with VP9 + AV1 (the Android vector 0x0b): bit 3 cleared, codecs kept.
        XCTAssertEqual(relayed(0x0b).capabilitySummary, 0x03)
        // Dual hint, both codecs and consent (0x1b): codecs and consent kept.
        let withConsent = relayed(0x1b)
        XCTAssertEqual(withConsent.capabilitySummary, 0x13)
        let decoded = try XCTUnwrap(CompactAnnouncement.decode(try CompactAnnouncement.encode(withConsent)), "the masked offer must stay encodable")
        XCTAssertEqual(decoded.capabilitySummary, 0x13); XCTAssertEqual(decoded.routeCost, 1)
        // Reserved bits 5-7 never pass; the dual hint alone leaves a plain (summary 0) offer that still encodes.
        XCTAssertEqual(relayed(0xe3).capabilitySummary, 0x03)
        XCTAssertEqual(relayed(0x08).capabilitySummary, 0x00)
        XCTAssertNoThrow(try CompactAnnouncement.encode(relayed(0x08)))
        // Without the mask the encoder refuses the hint, which is what stopped the relay advertising.
        var unmasked = relayed(0x0b); unmasked.capabilitySummary = 0x0b
        XCTAssertThrowsError(try CompactAnnouncement.encode(unmasked))
    }

    /// caller -> R1 -> ... -> callee over GATT-capability links; returns the engines after the call is active.
    private func chain(relays: Int) throws -> (caller: CallEngine, callee: CallEngine, hops: [CallRelayHop], pairs: [(MeshConnection, MeshConnection)],
                                              callerEvents: () -> [CallEngine.Event], calleeEvents: () -> [CallEngine.Event]) {
        let callerId = SoftwareSigningIdentity(), calleeId = SoftwareSigningIdentity()
        var cEvents: [CallEngine.Event] = [], eEvents: [CallEngine.Event] = []
        let callee = CallEngine(role: .callee, transport: .gatt, identity: calleeId, requestedType: .video, encodeMask: vp9, decodeMask: vp9)
        callee.onEvent = { eEvents.append($0) }
        try callee.start(now: 0)
        var pairs: [(MeshConnection, MeshConnection)] = []
        var hops: [CallRelayHop] = []
        var downstream: MeshConnection = callee
        var offer = callOffer(calleeId.nodeId.prefix)
        for _ in 0..<relays {
            let hop = CallRelayHop(identity: SoftwareSigningIdentity(), transport: .gatt, childOffer: offer)
            try hop.child.start(now: 0)
            pairs.append((hop.child, downstream))
            pump(pairs)
            XCTAssertEqual(hop.state, .waitingForParent)
            offer = try XCTUnwrap(hop.parentOffer)
            let parentLink = try XCTUnwrap(hop.attachParent())
            try parentLink.start(now: 0)
            downstream = parentLink
            hops.append(hop)
        }
        let caller = CallEngine(role: .caller, transport: .gatt, identity: callerId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                expectedPeerPrefix: offer.nodeIdPrefix, relayHops: try XCTUnwrap(CallRelayChain.inviteHops(routeCost: offer.routeCost)))
        caller.onEvent = { cEvents.append($0) }
        try caller.start(now: 0)
        pairs.append((caller, downstream))
        pump(pairs)
        return (caller, callee, hops, pairs, { cEvents }, { eEvents })
    }

    func testCallThroughOneIPhoneRelay() throws {
        let c = try chain(relays: 1)
        XCTAssertEqual(c.hops[0].state, .relaying)
        XCTAssertNil(c.caller.closeReason, "caller"); XCTAssertNil(c.callee.closeReason, "callee")
        XCTAssertEqual(c.caller.phase, .open, "caller phase"); XCTAssertEqual(c.callee.phase, .open, "callee phase")
        XCTAssertEqual(c.callee.state?.phase, .incomingRinging)
        XCTAssertEqual(c.callee.relayHops, 1, "the callee learns the hop count from Invite")
        try c.callee.accept(as: .voice); pump(c.pairs)
        XCTAssertEqual(c.caller.state?.phase, .active); XCTAssertEqual(c.callee.state?.phase, .active)
        for i in 0..<5 { c.caller.sendAudio(presentationTimeUs: Int64(i) * 20_000, opus: Data([0xfc, UInt8(i)])) }
        c.callee.sendAudio(presentationTimeUs: 0, opus: Data([0xfc, 9]))
        pump(c.pairs)
        XCTAssertEqual(c.callee.receivedAudioPackets, 5); XCTAssertEqual(c.caller.receivedAudioPackets, 1)
        // Heartbeats are replaced hop by hop; the call outlives the 8 s silent-link timeout.
        for second in 1...12 {
            let now = Double(second)
            c.caller.tick(now: now); c.callee.tick(now: now); c.hops.forEach { $0.tick(now: now) }
            pump(c.pairs, now: now)
        }
        XCTAssertEqual(c.caller.phase, .open); XCTAssertEqual(c.callee.phase, .open)
        XCTAssertGreaterThan(c.hops[0].child.copiedRecords, 3)
        c.caller.end(); pump(c.pairs, now: 12)
        XCTAssertTrue(c.calleeEvents().contains(.ended("Peer ended the call", error: false)), "hang-up copied end to end")
    }

    func testCallThroughTwoRelaysKeepsEndToEndIdentity() throws {
        let c = try chain(relays: 2)
        XCTAssertEqual(c.hops.map(\.state), [.relaying, .relaying])
        XCTAssertEqual(c.callee.relayHops, 2)
        try c.callee.accept(as: .voice); pump(c.pairs)
        XCTAssertEqual(c.caller.state?.phase, .active)
        XCTAssertEqual(c.caller.endpoint?.peerNodeId, c.callee.identity.nodeId, "the caller authenticated the callee, not a relay")
        XCTAssertEqual(c.callee.endpoint?.peerNodeId, c.caller.identity.nodeId)
        c.caller.sendAudio(presentationTimeUs: 0, opus: Data([0xfc, 7])); pump(c.pairs)
        XCTAssertEqual(c.callee.receivedAudioPackets, 1)
    }

    /// Android's blocking copy loop: the relay stops parsing one hop's records while the other hop is behind, then
    /// resumes once it drains, delivering everything in order; the held input is bounded.
    func testARelayAppliesBackpressureAndResumesInOrder() throws {
        let c = try chain(relays: 1)
        try c.callee.accept(as: .voice); pump(c.pairs)
        XCTAssertEqual(c.caller.state?.phase, .active)
        let hop = c.hops[0], parent = try XCTUnwrap(hop.parent)
        var resumable = 0
        hop.onIngressResumable = { resumable += 1 }
        let count = 40
        for i in 0..<count { c.caller.sendAudio(presentationTimeUs: Int64(i) * 20_000, opus: Data([0xfc]) + Data(repeating: UInt8(i), count: 8_000)) }
        // The callee's hop is stalled: only the caller -> relay direction moves.
        _ = move(c.caller, parent, now: 0)
        XCTAssertTrue(parent.ingressHeld, "the relay stopped parsing the caller's records")
        XCTAssertTrue(hop.child.isBehind)
        XCTAssertLessThan(hop.child.orderedBytes, CallRelayLink.highWaterBytes + 9_000, "at most one record beyond the high-water mark")
        XCTAssertEqual(parent.phase, .open)
        for _ in 0..<100 where parent.ingressHeld {
            _ = move(hop.child, c.callee, now: 0)
            XCTAssertGreaterThan(resumable, 0, "draining below the low-water mark asks the app to resume")
            resumable = 0
            hop.resumeIngress(now: 0)
        }
        pump(c.pairs)
        XCTAssertFalse(parent.ingressHeld)
        let times = c.calleeEvents().compactMap { event -> Int64? in if case .remoteAudio(let p) = event { return p.presentationTimeUs }; return nil }
        XCTAssertEqual(times, (0..<count).map { Int64($0) * 20_000 }, "every record arrives, in order")
    }

    /// A heartbeat that crosses the high-water mark must still produce the drained signal, or ingress stays paused.
    func testAHeartbeatCrossingTheHighWaterMarkStillResumes() throws {
        let c = try chain(relays: 1)
        try c.callee.accept(as: .voice); pump(c.pairs)
        let child = c.hops[0].child
        var drained = 0
        child.onDrained = { drained += 1 }
        let filler = CallRelayLink.highWaterBytes - child.orderedBytes - 1
        child.copy(SecureRecord(type: .endToEndContent, payload: Data(repeating: 1, count: filler)))
        XCTAssertFalse(child.isBehind)
        child.sendLiveness()
        XCTAssertTrue(child.isBehind, "the heartbeat crossed the mark")
        while child.nextOutgoing(now: 0) != nil {}
        XCTAssertEqual(drained, 1)
        XCTAssertFalse(child.isBehind)
    }

    func testARelayHopThatNeverDrainsEndsTheRelayInsteadOfBufferingWithoutLimit() throws {
        let c = try chain(relays: 1)
        try c.callee.accept(as: .voice); pump(c.pairs)
        let hop = c.hops[0], parent = try XCTUnwrap(hop.parent)
        for i in 0..<100 {
            c.caller.sendAudio(presentationTimeUs: Int64(i) * 20_000, opus: Data([0xfc]) + Data(repeating: UInt8(i), count: 8_000))
            _ = move(c.caller, parent, now: 0)
        }
        XCTAssertEqual(parent.phase, .closed)
        XCTAssertLessThanOrEqual(hop.child.orderedBytes, CallRelayLink.highWaterBytes + 9_000)
        if case .closed = hop.state {} else { XCTFail("the relay closes: \(hop.state)") }
    }

    func testWrongChildEndsTheHop() throws {
        let impostor = CallEngine(role: .callee, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9)
        try impostor.start(now: 0)
        let hop = CallRelayHop(identity: SoftwareSigningIdentity(), transport: .gatt, childOffer: callOffer(SoftwareSigningIdentity().nodeId.prefix))
        try hop.child.start(now: 0)
        pump([(hop.child, impostor)])
        if case .closed = hop.state {} else { XCTFail("a child that is not the advertised callee closes the relay: \(hop.state)") }
        XCTAssertNil(hop.parentOffer)
    }

    func testParentWaitIsBounded() throws {
        let callee = CallEngine(role: .callee, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9)
        try callee.start(now: 0)
        let hop = CallRelayHop(identity: SoftwareSigningIdentity(), transport: .gatt, childOffer: callOffer(callee.identity.nodeId.prefix))
        try hop.child.start(now: 0); pump([(hop.child, callee)])
        XCTAssertEqual(hop.state, .waitingForParent)
        hop.tick(now: CallRelayChain.parentWait + 1)
        if case .closed = hop.state {} else { XCTFail("no caller within the parent wait closes the relay") }
    }

    // MARK: BMH3 on the relay hops (a pseudonym-mode caller speaks only BMH3, with a throwaway link key toward a relay)

    private func bmh3Chain(calleeHint: Bool) throws -> (caller: CallEngine, callee: CallEngine, hop: CallRelayHop, pairs: [(MeshConnection, MeshConnection)],
                                                       callerId: SigningIdentity, callerEvents: () -> [CallEngine.Event]) {
        let budget = Bmh3SigningBudget(capacity: 100)
        let callerId = SoftwareSigningIdentity(), calleeId = SoftwareSigningIdentity()
        let callee = CallEngine(role: .callee, transport: .gatt, identity: calleeId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                bmh3: Bmh3CallOptions(pseudonyms: false, budget: budget))
        try callee.start(now: 0)
        var offer = callOffer(calleeId.nodeId.prefix)
        if calleeHint { offer.capabilitySummary |= Bmh3Choice.hintBit }
        let hop = CallRelayHop(identity: SoftwareSigningIdentity(), transport: .gatt, childOffer: offer, hiddenIdentities: true, budget: budget)
        try hop.child.start(now: 0)
        var pairs: [(MeshConnection, MeshConnection)] = [(hop.child, callee)]
        pump(pairs)
        XCTAssertEqual(hop.state, .waitingForParent, hop.child.closeReason ?? "")
        let relayed = try XCTUnwrap(hop.parentOffer)
        let parentLink = try XCTUnwrap(hop.attachParent())
        try parentLink.start(now: 0)
        var events: [CallEngine.Event] = []
        let caller = CallEngine(role: .caller, transport: .gatt, identity: callerId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                expectedPeerPrefix: relayed.nodeIdPrefix, relayHops: relayed.routeCost,
                                bmh3: Bmh3CallOptions(pseudonyms: true, selected: relayed, budget: budget))
        caller.onEvent = { events.append($0) }
        try caller.start(now: 0)
        pairs.append((caller, parentLink))
        pump(pairs)
        return (caller, callee, hop, pairs, callerId, { events })
    }

    func testAPseudonymModeCallerCallsThroughAnIPhoneRelayOverBmh3() throws {
        for hint in [false, true] {
            let c = try bmh3Chain(calleeHint: hint)
            XCTAssertEqual(c.hop.state, .relaying, "hint \(hint): \(c.caller.closeReason ?? "")")
            XCTAssertTrue(c.hop.parent?.linkUsedBmh3 == true, "the parent hop answered BMH3")
            XCTAssertEqual(c.hop.child.linkUsedBmh3, hint, "the child hop speaks BMH3 only with the hint (or a pin)")
            XCTAssertNotEqual(c.hop.parent?.peerLinkNodeId, c.callerId.nodeId, "toward a relay the caller presents a throwaway link key")
            XCTAssertEqual(c.callee.state?.phase, .incomingRinging, c.callee.closeReason ?? "")
            XCTAssertEqual(c.caller.endpoint?.usedBmh3, true, "end-to-end BMH3 through the relay, copied unchanged")
            XCTAssertTrue(c.callee.peerIsStranger, "the callee meets the caller's attempt pseudonym")
            try c.callee.accept(as: .voice); pump(c.pairs)
            XCTAssertEqual(c.caller.state?.phase, .active, c.caller.closeReason ?? "")
        }
    }

    // MARK: Amendment CP: pseudonymous relay edges

    private func pseudonymousCalleeChain(edges: Bool, consent: Bool = true) throws -> (caller: CallEngine, callee: CallEngine, hop: CallRelayHop,
                                                                                         pairs: [(MeshConnection, MeshConnection)]) {
        let budget = Bmh3SigningBudget(capacity: 100)
        let calleeId = SoftwareSigningIdentity()
        // Pseudonym mode runs with rotating discovery IDs on both ends: the callee's reveal travels in BDX1.
        let callee = CallEngine(role: .callee, transport: .gatt, identity: calleeId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                rotating: RotatingCallOptions(entries: { [] }), bmh3: Bmh3CallOptions(pseudonyms: true, budget: budget))
        callee.acceptRelayedCalls = consent
        try callee.start(now: 0)
        let hop = CallRelayHop(identity: SoftwareSigningIdentity(), transport: .gatt, childOffer: callOffer(calleeId.nodeId.prefix),
                               hiddenIdentities: true, budget: budget, pseudonymousEdges: edges)
        try hop.child.start(now: 0)
        var pairs: [(MeshConnection, MeshConnection)] = [(hop.child, callee)]
        pump(pairs)
        let caller = CallEngine(role: .caller, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                expectedPeerPrefix: calleeId.nodeId.prefix, relayHops: 1,
                                rotating: RotatingCallOptions(selected: hop.parentOffer),
                                bmh3: Bmh3CallOptions(pseudonyms: true, selected: hop.parentOffer, budget: budget))
        if let parent = hop.attachParent() {
            try parent.start(now: 0); try caller.start(now: 0)
            pairs.append((caller, parent)); pump(pairs)
        }
        return (caller, callee, hop, pairs)
    }

    func testARelayReachesAPseudonymModeCalleeOnlyWithPseudonymousEdges() throws {
        let control = try pseudonymousCalleeChain(edges: false)
        XCTAssertNotEqual(control.hop.state, .waitingForParent, "control arm: a real relay key meets the callee's throwaway and fails")
        XCTAssertNotEqual(control.hop.state, .relaying)

        let c = try pseudonymousCalleeChain(edges: true)
        XCTAssertEqual(c.hop.state, .relaying, c.hop.child.closeReason ?? c.caller.closeReason ?? "")
        XCTAssertTrue(c.hop.child.linkUsedBmh3 && c.hop.child.linkPeerPseudonymous, "the callee answered its own throwaway")
        XCTAssertTrue(c.hop.parent?.linkPeerPseudonymous == true, "toward a relay the caller's link key declares PSEUDONYM")
        XCTAssertTrue(c.callee.isRelayed)
        XCTAssertEqual(c.callee.state?.phase, .incomingRinging,
                       "callee \(c.callee.phase) \(c.callee.closeReason ?? "-") caller \(c.caller.phase) \(c.caller.closeReason ?? "-") \(String(describing: c.caller.state?.phase))")
        try c.callee.accept(as: .voice); pump(c.pairs)
        XCTAssertEqual(c.caller.state?.phase, .active, c.caller.closeReason ?? "")
    }

    func testATargetWithoutRelayedCallsDeclinesARelayedCallBeforeItRings() throws {
        let c = try pseudonymousCalleeChain(edges: true, consent: false)
        XCTAssertEqual(c.callee.relayedDecline, .declineRelayingOff)
        XCTAssertNotEqual(c.callee.state?.phase, .incomingRinging)
        XCTAssertNotEqual(c.caller.state?.phase, .outgoingRinging, "the caller never heard ringing")
    }

    func testARelayWithoutHiddenIdentitiesCannotCarryAPseudonymCaller() throws {
        let calleeId = SoftwareSigningIdentity()
        let callee = CallEngine(role: .callee, transport: .gatt, identity: calleeId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9)
        try callee.start(now: 0)
        let hop = CallRelayHop(identity: SoftwareSigningIdentity(), transport: .gatt, childOffer: callOffer(calleeId.nodeId.prefix))
        try hop.child.start(now: 0)
        var pairs: [(MeshConnection, MeshConnection)] = [(hop.child, callee)]
        pump(pairs)
        let relayed = try XCTUnwrap(hop.parentOffer)
        let parent = try XCTUnwrap(hop.attachParent()); try parent.start(now: 0)
        let caller = CallEngine(role: .caller, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                expectedPeerPrefix: relayed.nodeIdPrefix, relayHops: relayed.routeCost,
                                bmh3: Bmh3CallOptions(pseudonyms: true, selected: relayed, budget: Bmh3SigningBudget(capacity: 100)))
        try caller.start(now: 0)
        pairs.append((caller, parent)); pump(pairs)
        XCTAssertNotEqual(hop.state, .relaying, "a BMH2-only relay cannot read a BMH3 msg1")
        XCTAssertNil(callee.state)
    }
}
