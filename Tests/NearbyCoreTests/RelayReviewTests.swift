import XCTest
@testable import NearbyCore

/// Rules of the Apple relayed-call and route-search port (2026-10-27): admission order and the limiter,
/// the rotating first hop's opening, pseudonymous helpers, copied adverts and search addresses, target consent.
final class RelayReviewTests: XCTestCase {
    let vp9 = NodeCapabilities.codecVP9
    let epoch: Int64 = 1_990_656
    typealias Net = RelayedCallSetupTests.Net

    // MARK: Admission (items 1, 8, 10)

    private func facts(_ change: (inout RelayHelperGate.Facts) -> Void = { _ in }) -> RelayHelperGate.Facts {
        var f = RelayHelperGate.Facts(); f.parentPrefixHex = "aabbccddeeff"; change(&f); return f
    }

    func testCheapRefusalsComeFirstAndNeverSpendARateToken() {
        let limiter = RelaySetupRateLimiter(perParent: 1, overall: 10), budgets = RelaySeekBudgets()
        // The rotating-helper refusal is the first check (FAIL 5), before switches and the limiter.
        XCTAssertEqual(RelayHelperGate.decide(facts { $0.rotatingHelper = true; $0.paused = "thermal" }, remainingMs: 20_000, limiter: limiter,
                                              budgets: budgets, nowMs: 0, routeAvailable: { true }), .refuse(.refused, reason: "rotating_helper"))
        XCTAssertEqual(RelayHelperGate.decide(facts { $0.paused = "thermal" }, remainingMs: 20_000, limiter: limiter, budgets: budgets, nowMs: 0, routeAvailable: { true }),
                       .refuse(.refused, reason: "thermal"))
        XCTAssertEqual(RelayHelperGate.decide(facts { $0.busy = true }, remainingMs: 20_000, limiter: limiter, budgets: budgets, nowMs: 0, routeAvailable: { true }),
                       .refuse(.busy, reason: "busy"))
        // Control-arm parity: without pseudonymous edges a throwaway parent is refused.
        XCTAssertEqual(RelayHelperGate.decide(facts { $0.pseudonymousParent = true; $0.pseudonymousEdges = false }, remainingMs: 20_000, limiter: limiter,
                                              budgets: budgets, nowMs: 0, routeAvailable: { true }), .refuse(.refused, reason: "throwaway_parent"))
        // None of those spent the parent's single token.
        XCTAssertEqual(RelayHelperGate.decide(facts(), remainingMs: 20_000, limiter: limiter, budgets: budgets, nowMs: 0, routeAvailable: { true }),
                       .setup(limiterKey: "aabbccddeeff", admittedAtMs: 0))
    }

    func testOneUnknownStrangerCannotBlockEveryoneAndAGoodRelayIsRefunded() {
        let limiter = RelaySetupRateLimiter(), budgets = RelaySeekBudgets()
        func stranger(_ id: UUID?) -> RelayHelperGate.Facts { facts { $0.pseudonymousParent = true; $0.parentPeerIdentifier = id } }
        // An unknown peer is held only by the overall cap: three of its requests leave room for others.
        for _ in 0..<3 { if case .refuse = RelayHelperGate.decide(stranger(nil), remainingMs: 20_000, limiter: limiter, budgets: budgets, nowMs: 0, routeAvailable: { true }) { XCTFail() } }
        let known = UUID()
        for _ in 0..<3 { if case .refuse = RelayHelperGate.decide(stranger(known), remainingMs: 20_000, limiter: limiter, budgets: budgets, nowMs: 1, routeAvailable: { true }) { XCTFail() } }
        XCTAssertEqual(RelayHelperGate.decide(stranger(known), remainingMs: 20_000, limiter: limiter, budgets: budgets, nowMs: 2, routeAvailable: { true }),
                       .refuse(.refused, reason: "rate"), "per peer identifier: 3 per minute")
        XCTAssertNotEqual(RelayHelperGate.decide(stranger(UUID()), remainingMs: 20_000, limiter: limiter, budgets: budgets, nowMs: 2, routeAvailable: { true }),
                          .refuse(.refused, reason: "rate"), "another stranger is not blocked")
        // A good outcome gives the token back.
        let l2 = RelaySetupRateLimiter(perParent: 1, overall: 10)
        guard case let .setup(key, at) = RelayHelperGate.decide(facts(), remainingMs: 20_000, limiter: l2, budgets: budgets, nowMs: 5, routeAvailable: { true }) else { return XCTFail() }
        l2.refund(key, admittedAtMs: at)
        XCTAssertNotEqual(RelayHelperGate.decide(facts(), remainingMs: 20_000, limiter: l2, budgets: budgets, nowMs: 6, routeAvailable: { true }), .refuse(.refused, reason: "rate"))
    }

    func testSearchesUseTheirBudgetsAndAPlainSetupWithoutARouteBecomesASearch() {
        let limiter = RelaySetupRateLimiter(perParent: 0, overall: 0), budgets = RelaySeekBudgets()
        XCTAssertEqual(RelayHelperGate.decide(facts { $0.isSeek = true; $0.rotatingRequest = true }, remainingMs: 20_000, limiter: limiter,
                                              budgets: budgets, nowMs: 0, routeAvailable: { false }), .refuse(.refused, reason: "searches_off"))
        // A SEEK is not charged to the SETUP limiter (here closed): its allowance is the duty time left.
        XCTAssertEqual(RelayHelperGate.decide(facts { $0.isSeek = true; $0.rotatingRequest = true; $0.onDemand = true }, remainingMs: 20_000,
                                              limiter: limiter, budgets: budgets, nowMs: 0, routeAvailable: { false }), .search(allowanceMs: 20_000))
        budgets.finish(startedAt: 0, scanMs: 0, ready: false, now: 45_000)
        XCTAssertEqual(RelayHelperGate.decide(facts { $0.isSeek = true; $0.rotatingRequest = true; $0.onDemand = true }, remainingMs: 20_000,
                                              limiter: limiter, budgets: budgets, nowMs: 56_000, routeAvailable: { false }), .search(allowanceMs: 15_000),
                       "allowance shortened to the duty time left")
        let open = RelaySetupRateLimiter()
        XCTAssertEqual(RelayHelperGate.decide(facts { $0.rotatingRequest = true; $0.rotatingHelper = true; $0.onDemand = true }, remainingMs: 20_000,
                                              limiter: open, budgets: RelaySeekBudgets(), nowMs: 0, routeAvailable: { false }), .search(allowanceMs: 20_000))
        XCTAssertEqual(RelayHelperGate.decide(facts { $0.rotatingRequest = true; $0.rotatingHelper = true }, remainingMs: 20_000,
                                              limiter: open, budgets: RelaySeekBudgets(), nowMs: 0, routeAvailable: { false }), .refuse(.noRoute, reason: "no_route"))
        let b = RelaySeekBudgets()
        XCTAssertTrue(b.signing(now: 0))
        b.finish(startedAt: 0, scanMs: 0, ready: false, now: 52_000)
        XCTAssertFalse(b.signing(now: 52_000), "below 9 s of duty left: stop signing RELAY_SEEK")
        XCTAssertFalse(b.withdrawHelperFlag(now: 100_000)); XCTAssertTrue(b.withdrawHelperFlag(now: 112_001), "withdraw after 60 s exhausted")
    }

    // MARK: Copied adverts and search addresses (item 2)

    private func offer(_ rdi: Data, helper: Bool = false) -> DiscoveryAnnouncement {
        var flags = DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable | DiscoveryAnnouncement.flagGattTransport
        if helper { flags |= DiscoveryAnnouncement.flagRelayCapable }
        var a = DiscoveryAnnouncement(nodeIdPrefix: rdi, flags: flags, capabilitySummary: vp9 | RelayedCalls.consentBit, streamToken: 0, routeCost: 0)
        a.rotating = true
        return a
    }

    func testACopiedAdvertDoesNotTakeOverAnIdAndBadAddressesAreSkipped() {
        var now: Int64 = 0
        let rdi = Data([7, 7, 7, 7, 7, 7])
        let t = ReachTable<String>(ownPrefix: Data([1, 1, 1, 1, 1, 1]), clock: { now }, rotating: true)
        t.observeOffer(peer: "real", announcement: offer(rdi), address: "A", rssi: -70)
        now = 1_000; t.observeOffer(peer: "real", announcement: offer(rdi), address: "A", rssi: -70)
        now = 1_500; t.observeOffer(peer: "copy", announcement: offer(rdi), address: "B", rssi: -30)
        XCTAssertEqual(t.offer(rdi)?.peer, "real", "heard twice beats a louder single sighting")
        XCTAssertEqual(t.recentOffers(withinMs: 5_000).filter { $0.announcement.nodeIdPrefix == rdi }.count, 2, "both addresses kept")
        for (i, a) in ["C", "D"].enumerated() { now = 2_000 + Int64(i); t.observeOffer(peer: a, announcement: offer(rdi), address: a, rssi: -90) }
        XCTAssertEqual(t.recentOffers(withinMs: 5_000).filter { $0.announcement.nodeIdPrefix == rdi }.count, ReachTable<String>.addressesPerId)
        let nonce = RelaySeek.newNonce()
        let sightings = t.recentOffers(withinMs: 5_000)
        let plan = RelaySeekPlan(offers: sightings, nonce: nonce, token: RelaySeek.token(nonce: nonce, rdi: rdi), skip: [], budget: 1, bearer: .gatt,
                                 ownRdis: [], badAddresses: ["A"])
        XCTAssertFalse(plan.targets.contains { $0.peer == "real" }, "an address that failed the opening this epoch is not dialled")
        let bad = RelaySeekBadAddresses()
        bad.record("B", epoch: epoch)
        XCTAssertEqual(bad.current(epoch: epoch), ["B"]); XCTAssertEqual(bad.current(epoch: epoch + 1), [], "per epoch")
    }

    // MARK: Rotating first hop and pseudonymous helpers (items 2, 9)

    final class Listener {
        let id = SoftwareSigningIdentity()
        let entry: OpeningEntry
        let engine: CallEngine
        var request: RelaySetupMessage?
        init(epoch: Int64, vp9: UInt8, pseudonyms: Bool) {
            entry = RotatingDiscoveryIds.ownEntry(presenceKey: Data(repeating: 9, count: 32), nodeId: id.nodeId.bytes, epoch: epoch, role: 0)
            let e = entry
            engine = CallEngine(role: .callee, transport: .gatt, identity: id, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                rotating: RotatingCallOptions(entries: { [e] }), bmh3: Bmh3CallOptions(pseudonyms: pseudonyms, budget: Bmh3SigningBudget(capacity: 100)),
                                relayed: RelayedCallOptions(featureOn: true, helperActive: true, acceptRdi: true))
            engine.onEvent = { [unowned self] in if case let .relaySetupRequested(m) = $0 { request = m } }
        }
    }

    private func rotatingCaller(helperRdi: Data, rotatingOptions: Bool, edges: Bool = true) -> CallEngine {
        let target = Data([5, 5, 5, 5, 5, 5])
        let hop = offer(helperRdi, helper: true)
        let routed = RelayedCalls.routedAnnouncement(target: target, cost: 1, hop: hop)
        var options = Bmh3CallOptions(pseudonyms: true, selected: routed, budget: Bmh3SigningBudget(capacity: 100), wallEpoch: { [epoch] in epoch })
        options.relayHop = hop
        return CallEngine(role: .caller, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                          expectedPeerPrefix: target, relayHops: 1,
                          rotating: rotatingOptions ? RotatingCallOptions(selected: routed, wallEpoch: { [epoch] in epoch }) : nil, bmh3: options,
                          relayed: RelayedCallOptions(featureOn: true, route: RelayRoute(target: target, helperPrefix: helperRdi, relays: 1, rotating: true),
                                                      pseudonymousEdges: edges, setupStartedAt: 0))
    }

    func testARotatingRealKeyFirstHopMustOpenTheChosenHelper() throws {
        for (case_, rdiOf, options) in [("right", true, true), ("wrong ID", false, true), ("no opening", true, false)] {
            let net = Net()
            let helper = Listener(epoch: epoch, vp9: vp9, pseudonyms: false)
            let caller = rotatingCaller(helperRdi: rdiOf ? helper.entry.rdi : Data([9, 9, 9, 9, 9, 9]), rotatingOptions: options)
            try helper.engine.start(now: 0); try caller.start(now: 0)
            net.pairs = [(caller, helper.engine)]; net.pump()
            if case_ == "right" {
                XCTAssertNotNil(helper.request, "SETUP after the opening opened the chosen helper")
            } else {
                XCTAssertNil(helper.request, "\(case_): no SETUP")
                XCTAssertEqual(caller.relaySetupFailure, .childAuthentication, "\(case_): \(caller.closeReason ?? "-")")
            }
        }
    }

    func testAHelperThatAnswersWithAThrowawayIsAcceptedOnlyWithPseudonymousEdges() throws {
        for edges in [true, false] {
            let net = Net()
            let helper = Listener(epoch: epoch, vp9: vp9, pseudonyms: true)   // pseudonym mode: a throwaway to strangers
            let caller = rotatingCaller(helperRdi: helper.entry.rdi, rotatingOptions: true, edges: edges)
            try helper.engine.start(now: 0); try caller.start(now: 0)
            net.pairs = [(caller, helper.engine)]; net.pump()
            XCTAssertTrue(caller.linkPeerPseudonymous)
            if edges { XCTAssertNotNil(helper.request, caller.closeReason ?? "-") }
            else { XCTAssertNil(helper.request); XCTAssertEqual(caller.relaySetupFailure, .childAuthentication) }
        }
    }

    // MARK: Target consent (item 6)

    func testATargetWithoutConsentClosesUnansweredOnARelaysFirstEndToEndRecord() throws {
        let net = Net()
        let calleeId = SoftwareSigningIdentity()
        let callee = CallEngine(role: .callee, transport: .gatt, identity: calleeId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                relayed: RelayedCallOptions(featureOn: true))
        callee.acceptRelayedCalls = false
        let helper = RelayedCallSetupTests.ScriptedHelper(net: net, callee: callee)
        let caller = CallEngine(role: .caller, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                expectedPeerPrefix: calleeId.nodeId.prefix, relayHops: 1,
                                relayed: RelayedCallOptions(featureOn: true, route: RelayRoute(target: calleeId.nodeId.prefix,
                                                                                               helperPrefix: helper.identity.nodeId.prefix, relays: 1), setupStartedAt: 0))
        try callee.start(now: 0); try helper.parent.start(now: 0); try caller.start(now: 0)
        net.pairs.append((caller, helper.parent)); net.pump()
        XCTAssertEqual(callee.phase, .closed)
        XCTAssertEqual(callee.relayedDecline, .declineRelayingOff)
        XCTAssertNil(callee.endpoint, "the callee never answered the end-to-end handshake: nothing about it left")
        XCTAssertNil(caller.endpoint)
    }
}
