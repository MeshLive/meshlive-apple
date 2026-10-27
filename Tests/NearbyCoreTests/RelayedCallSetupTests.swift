import XCTest
@testable import NearbyCore

/// Relayed calls, caller side: the caller dials a helper, sends SETUP after the link handshake, starts the endpoint handshake
/// only after READY, and fails cleanly on FAIL, a wrong helper, a helper without the marks, an invalid READY or silence.
/// The helper here is scripted from `CallRelayLink`s (a parent that reads SETUP, a child it dials, records copied).
final class RelayedCallSetupTests: XCTestCase {
    let vp9 = NodeCapabilities.codecVP9

    /// In-memory pipes between connection pairs; pairs can be added while pumping.
    final class Net {
        var pairs: [(MeshConnection, MeshConnection)] = []
        var now: TimeInterval = 0
        func pump() {
            for _ in 0..<200 {
                var moved = false
                var i = 0
                while i < pairs.count {
                    let (a, b) = pairs[i]
                    while let bytes = a.nextOutgoing(now: now) { b.receive(bytes, now: now); moved = true }
                    while let bytes = b.nextOutgoing(now: now) { a.receive(bytes, now: now); moved = true }
                    i += 1
                }
                if !moved { return }
            }
        }
        func tick(_ t: TimeInterval, _ all: [MeshConnection]) { now = t; all.forEach { $0.tick(now: t) }; pump() }
    }

    /// A scripted helper: answers SETUP with `reply` (nil: dial the callee and answer READY 1 once it authenticated).
    final class ScriptedHelper {
        let identity = SoftwareSigningIdentity()
        let parent: CallRelayLink
        var child: CallRelayLink?
        var receivedSetup: RelaySetupMessage?
        init(net: Net, callee: CallEngine?, marks: Bool = true, reply: ((Data) -> RelaySetupMessage)? = nil, readyRelays: Int = 1,
             bmh3: Bmh3CallSettings? = nil) {
            parent = marks ? CallRelayLink(role: .responder, transport: .gatt, identity: identity, bmh3: bmh3, relaySetup: true)
                           : CallRelayLink(role: .responder, transport: .gatt, identity: identity, bmh3: bmh3)
            parent.acceptRelaySetup = true
            parent.onRelaySetup = { [unowned self] message in
                receivedSetup = message
                guard case let .setup(target, _, _, id, _) = message else { throw ProtocolError.state("not a setup") }
                if let reply { try parent.sendRelaySetup(reply(id)); return }
                guard let callee else { return }
                let child = CallRelayLink(role: .initiator, transport: .gatt, identity: identity)
                child.expectedPeerPrefix = target
                child.onAuthenticated = { [unowned self] _, _ in try parent.sendRelaySetup(.ready(setupId: id, relays: readyRelays)) }
                parent.onRecord = { [unowned child] r in if r.type == .linkHeartbeat { child.sendLiveness() } else { child.copy(r) } }
                child.onRecord = { [unowned self] r in if r.type == .linkHeartbeat { parent.sendLiveness() } else { parent.copy(r) } }
                self.child = child
                try child.start(now: net.now)
                net.pairs.append((child, callee))
            }
        }
    }

    private func callee(consent: Bool = true, bmh3: Bmh3CallOptions? = nil) throws -> (CallEngine, SoftwareSigningIdentity) {
        let id = SoftwareSigningIdentity()
        let callee = CallEngine(role: .callee, transport: .gatt, identity: id, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                bmh3: bmh3, relayed: RelayedCallOptions(featureOn: true))
        callee.acceptRelayedCalls = consent
        try callee.start(now: 0)
        return (callee, id)
    }

    private func caller(target: Data, helperPrefix: Data, budget: Int = 1, bmh3: Bmh3CallOptions? = nil, edges: Bool = true) -> CallEngine {
        CallEngine(role: .caller, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                   expectedPeerPrefix: target, relayHops: UInt8(budget), bmh3: bmh3,
                   relayed: RelayedCallOptions(featureOn: true, route: RelayRoute(target: target, helperPrefix: helperPrefix, relays: budget),
                                               pseudonymousEdges: edges, setupStartedAt: 0))
    }

    func testACallerReachesTheCalleeThroughAHelperAfterReady() throws {
        let net = Net()
        let (callee, calleeId) = try callee()
        let helper = ScriptedHelper(net: net, callee: callee)
        let caller = caller(target: calleeId.nodeId.prefix, helperPrefix: helper.identity.nodeId.prefix, budget: 2)
        var events: [CallEngine.Event] = []
        caller.onEvent = { events.append($0) }
        try helper.parent.start(now: 0); try caller.start(now: 0)
        net.pairs.append((caller, helper.parent)); net.pump()
        guard case let .setup(target, budget, remaining, _, rotating)? = helper.receivedSetup else { return XCTFail("no SETUP: \(caller.closeReason ?? "-")") }
        XCTAssertEqual(target, calleeId.nodeId.prefix); XCTAssertEqual(budget, 2); XCTAssertFalse(rotating)
        XCTAssertEqual(remaining, RelayedCalls.setupDeadlineMs)
        XCTAssertEqual(caller.relayReadyRelays, 1); XCTAssertEqual(caller.relayHops, 1, "the Invite carries READY's count")
        XCTAssertTrue(events.contains(.relayReady(1)))
        XCTAssertEqual(callee.state?.phase, .incomingRinging, callee.closeReason ?? "-")
        XCTAssertTrue(callee.isRelayed); XCTAssertEqual(callee.relayHops, 1)
        XCTAssertEqual(caller.endpoint?.peerNodeId, calleeId.nodeId, "the end-to-end peer is the callee, not the helper")
        try callee.accept(as: .voice); net.pump()
        XCTAssertEqual(caller.state?.phase, .active, caller.closeReason ?? "-")
    }

    func testFailEndsTheCallWithTheReasonAndNoEndpointHello() throws {
        let net = Net()
        let target = Data([1, 2, 3, 4, 5, 6])
        let helper = ScriptedHelper(net: net, callee: nil, reply: { .fail(setupId: $0, reason: .noRoute) })
        let caller = caller(target: target, helperPrefix: helper.identity.nodeId.prefix)
        try helper.parent.start(now: 0); try caller.start(now: 0)
        net.pairs.append((caller, helper.parent)); net.pump()
        XCTAssertEqual(caller.relaySetupFailure, .noRoute); XCTAssertTrue(caller.relayedRouteFailed)
        XCTAssertEqual(caller.phase, .closed)
        XCTAssertTrue(caller.closeReason?.contains(RelaySetupFailure.noRoute.userText) == true, caller.closeReason ?? "-")
        XCTAssertNil(caller.endpoint)
    }

    func testAWrongOrUnmarkedHelperNeverReceivesSetup() throws {
        let net = Net()
        let target = Data([1, 2, 3, 4, 5, 6])
        let wrong = ScriptedHelper(net: net, callee: nil)
        let c1 = caller(target: target, helperPrefix: Data([9, 9, 9, 9, 9, 9]))
        try wrong.parent.start(now: 0); try c1.start(now: 0)
        net.pairs = [(c1, wrong.parent)]; net.pump()
        XCTAssertNil(wrong.receivedSetup); XCTAssertEqual(c1.relaySetupFailure, .childAuthentication)
        let unmarked = ScriptedHelper(net: net, callee: nil, marks: false)
        let c2 = caller(target: target, helperPrefix: unmarked.identity.nodeId.prefix)
        try unmarked.parent.start(now: 0); try c2.start(now: 0)
        net.pairs = [(c2, unmarked.parent)]; net.pump()
        XCTAssertNil(unmarked.receivedSetup); XCTAssertEqual(c2.relaySetupFailure, .refused)
    }

    func testAReadyAboveTheBudgetIsInvalidAndSilenceTimesOut() throws {
        let net = Net()
        let target = Data([1, 2, 3, 4, 5, 6])
        let over = ScriptedHelper(net: net, callee: nil, reply: { .ready(setupId: $0, relays: 2) })
        let c1 = caller(target: target, helperPrefix: over.identity.nodeId.prefix, budget: 1)
        try over.parent.start(now: 0); try c1.start(now: 0)
        net.pairs = [(c1, over.parent)]; net.pump()
        XCTAssertTrue(c1.relaySetupInvalid); XCTAssertNil(c1.relayReadyRelays); XCTAssertEqual(c1.phase, .closed)
        let silent = ScriptedHelper(net: net, callee: nil, reply: nil)   // reads SETUP, never answers
        let c2 = caller(target: target, helperPrefix: silent.identity.nodeId.prefix)
        try silent.parent.start(now: 0); try c2.start(now: 0)
        net.pairs = [(c2, silent.parent)]; net.pump()
        XCTAssertNotNil(silent.receivedSetup)
        net.tick(21.9, [c2])
        XCTAssertNotEqual(c2.phase, .closed, "the deadline plus 2 s grace is not over")
        net.tick(22.1, [c2])
        XCTAssertEqual(c2.relaySetupFailure, .timeout)
    }

    func testATargetWithoutRelayedCallsDeclinesTheRelayedCallBeforeRinging() throws {
        let net = Net()
        let (callee, calleeId) = try callee(consent: false)
        let helper = ScriptedHelper(net: net, callee: callee)
        let caller = caller(target: calleeId.nodeId.prefix, helperPrefix: helper.identity.nodeId.prefix)
        try helper.parent.start(now: 0); try caller.start(now: 0)
        net.pairs.append((caller, helper.parent)); net.pump()
        XCTAssertEqual(caller.relayReadyRelays, 1)
        XCTAssertEqual(callee.relayedDecline, .declineRelayingOff)
        XCTAssertNotEqual(caller.state?.phase, .active)
    }

    /// Pseudonymous relay edges: in pseudonym mode the caller's link toward the helper is BMH3 with a declared throwaway (not its
    /// end-to-end attempt key); the helper answers with its real key, which must be the helper that was chosen.
    func testThePseudonymModeCallerDeclaresAThrowawayTowardTheHelper() throws {
        let net = Net()
        let budget = Bmh3SigningBudget(capacity: 100)
        let (callee, calleeId) = try callee(bmh3: Bmh3CallOptions(pseudonyms: false, budget: budget))
        let helper = ScriptedHelper(net: net, callee: callee,
                                    bmh3: Bmh3CallSettings(speak: false, acceptBmh2: true, replayCache: Bmh3CallSettings.sharedReplayCache, budget: budget))
        var options = Bmh3CallOptions(pseudonyms: true, selected: RelayedCalls.routedAnnouncement(target: calleeId.nodeId.prefix, cost: 1,
                                                                                                   hop: RelayedCalls.helperOfferFor(helper.identity.nodeId.prefix, rotating: false)),
                                      budget: budget)
        options.relayHop = RelayedCalls.helperOfferFor(helper.identity.nodeId.prefix, rotating: false)
        let callerId = SoftwareSigningIdentity()
        let caller = CallEngine(role: .caller, transport: .gatt, identity: callerId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                expectedPeerPrefix: calleeId.nodeId.prefix, relayHops: 1, bmh3: options,
                                relayed: RelayedCallOptions(featureOn: true, route: RelayRoute(target: calleeId.nodeId.prefix,
                                                                                               helperPrefix: helper.identity.nodeId.prefix, relays: 1),
                                                            setupStartedAt: 0))
        try helper.parent.start(now: 0); try caller.start(now: 0)
        net.pairs.append((caller, helper.parent)); net.pump()
        XCTAssertTrue(helper.parent.linkUsedBmh3)
        XCTAssertTrue(helper.parent.linkPeerPseudonymous, "the helper met a declared throwaway")
        XCTAssertNotEqual(helper.parent.peerLinkNodeId, callerId.nodeId)
        XCTAssertNotNil(helper.receivedSetup)
        XCTAssertEqual(callee.state?.phase, .incomingRinging, "\(caller.closeReason ?? "-") / \(callee.closeReason ?? "-")")
        XCTAssertNotEqual(callee.endpoint?.peerNodeId, helper.parent.peerLinkNodeId, "the link throwaway is not the end-to-end key")
    }
}
