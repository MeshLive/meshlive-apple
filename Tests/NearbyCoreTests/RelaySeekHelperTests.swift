import XCTest
@testable import NearbyCore

/// Design OR helper side: a listener that signed RELAY_SEEK reads a SEEK as its first record, matches the token against
/// offers it heard, and dials the target (whose opening must open the matched RDI) or, for budget 2, a next helper
/// that gets a regenerated SEEK.
final class RelaySeekHelperTests: XCTestCase {
    let vp9 = NodeCapabilities.codecVP9
    let epoch: Int64 = 1_990_656
    typealias Net = RelayedCallSetupTests.Net
    let budget = Bmh3SigningBudget(capacity: 1_000)

    private func entry(_ id: SigningIdentity) -> OpeningEntry {
        RotatingDiscoveryIds.ownEntry(presenceKey: Data(repeating: 9, count: 32), nodeId: id.nodeId.bytes, epoch: epoch, role: 0)
    }

    private func offer(rdi: Data, helper: Bool) -> DiscoveryAnnouncement {
        var flags = DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable | DiscoveryAnnouncement.flagGattTransport
        if helper { flags |= DiscoveryAnnouncement.flagRelayCapable }
        var a = DiscoveryAnnouncement(nodeIdPrefix: rdi, flags: flags, capabilitySummary: vp9 | RelayedCalls.consentBit, streamToken: 0, routeCost: 0)
        a.rotating = true
        return a
    }

    /// A rotating phone's call listener: real key, BDO1 with its role-0 entry, helper marks and RELAY_SEEK when helping.
    final class Phone {
        let id = SoftwareSigningIdentity()
        let entry: OpeningEntry
        let listener: CallEngine
        var duty: RelayHelperDuty?
        var offers: [OfferSighting<String>] = []
        var peers: [String: MeshConnection] = [:]
        init(test: RelaySeekHelperTests, net: Net, helping: Bool) {
            entry = RotatingDiscoveryIds.ownEntry(presenceKey: Data(repeating: 9, count: 32), nodeId: id.nodeId.bytes, epoch: test.epoch, role: 0)
            var options = Bmh3CallOptions(pseudonyms: false, budget: test.budget)
            if helping { options.relaySeek = RelaySeek.featureSeekV1 }
            let e = entry
            listener = CallEngine(role: .callee, transport: .gatt, identity: id, requestedType: .voice, encodeMask: test.vp9, decodeMask: test.vp9,
                                  rotating: RotatingCallOptions(entries: { [e] }), bmh3: options,
                                  relayed: RelayedCallOptions(featureOn: true, helperActive: helping, acceptRdi: true))
            let epochValue = test.epoch
            listener.onEvent = { [unowned self, unowned net] event in
                guard case let .relaySetupRequested(message) = event, let request = RelayHelperDuty.Request(message) else { return }
                let parent = CallRelayLink(adopting: listener)
                if let i = net.pairs.firstIndex(where: { $0.1 === listener }) { net.pairs[i].1 = parent }
                let duty = RelayHelperDuty(identity: id, transport: .gatt, parent: parent, request: request, now: net.now)
                self.duty = duty
                guard let seek = request.seek else { duty.refuse(.refused); return }
                let plan = RelaySeekPlan(offers: offers, nonce: seek.nonce, token: seek.token, skip: seek.skip, budget: request.budget,
                                         bearer: .gatt, ownRdis: [entry.rdi])
                var candidates: [(peer: String, next: RelayHelperDuty.NextHop, rdi: Data)] =
                    plan.targets.map { ($0.peer, .init(hopPrefix: nil, nextBudget: 0), $0.rdi) }
                if plan.targets.isEmpty { candidates += plan.helpers.map { ($0.peer, .init(hopPrefix: $0.rdi, nextBudget: request.budget - 1), $0.rdi) } }
                func tryNext() -> Bool {
                    guard !candidates.isEmpty, let peer = peers[candidates[0].peer] else { return false }
                    let c = candidates.removeFirst()
                    if c.next.hopPrefix == nil { duty.setSearchTarget(c.rdi) }
                    let child = duty.makeChildLink(next: c.next, bmh3: Bmh3CallSettings(speak: true), wallEpoch: { epochValue })
                    try? child.start(now: net.now)
                    net.pairs.append((child, peer))
                    return true
                }
                duty.onChildAttemptFailed = { _ in tryNext() }
                if !tryNext() { duty.searchFailed(.noRoute) }
            }
        }
    }

    private func caller(helper: Phone, target: Data, budget: Int, nonce: Data) -> CallEngine {
        let hop = offer(rdi: helper.entry.rdi, helper: true)
        let routed = RelayedCalls.routedAnnouncement(target: target, cost: budget, hop: hop)
        var options = Bmh3CallOptions(pseudonyms: true, selected: routed, budget: self.budget, wallEpoch: { [epoch] in epoch })
        options.relayHop = hop
        let seek = RelayHelperDuty.Request.Seek(nonce: nonce, token: RelaySeek.token(nonce: nonce, rdi: target), skip: [])
        return CallEngine(role: .caller, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                          expectedPeerPrefix: target, relayHops: UInt8(budget),
                          rotating: RotatingCallOptions(selected: routed, wallEpoch: { [epoch] in epoch }), bmh3: options,
                          relayed: RelayedCallOptions(featureOn: true, route: RelayRoute(target: target, helperPrefix: helper.entry.rdi, relays: budget,
                                                                                         rotating: true, seek: seek), setupStartedAt: 0))
    }

    func testASearchFindsTheTargetByTokenAndTheCallRings() throws {
        let net = Net()
        let target = Phone(test: self, net: net, helping: false)
        let helper = Phone(test: self, net: net, helping: true)
        helper.offers = [OfferSighting(peer: "target", announcement: offer(rdi: target.entry.rdi, helper: false), seenMs: 0, address: "A", rssi: -50),
                         OfferSighting(peer: "decoy", announcement: offer(rdi: Data([9, 9, 9, 9, 9, 9]), helper: false), seenMs: 0, address: "B", rssi: -40)]
        helper.peers = ["target": target.listener]
        try target.listener.start(now: 0); try helper.listener.start(now: 0)
        let caller = caller(helper: helper, target: target.entry.rdi, budget: 1, nonce: RelaySeek.newNonce())
        try caller.start(now: 0)
        net.pairs.append((caller, helper.listener)); net.pump()
        XCTAssertNotNil(helper.duty?.request.seek, "the helper read a SEEK")
        XCTAssertEqual(helper.duty?.request.target, target.entry.rdi, "the token matched the target, not the decoy")
        XCTAssertEqual(caller.relayReadyRelays, 1, caller.closeReason ?? "-")
        XCTAssertEqual(target.listener.state?.phase, .incomingRinging, target.listener.closeReason ?? "-")
        XCTAssertTrue(target.listener.isRelayed)
    }

    func testABudgetTwoSearchFansOutToANextHelper() throws {
        let net = Net()
        let target = Phone(test: self, net: net, helping: false)
        let second = Phone(test: self, net: net, helping: true)
        let first = Phone(test: self, net: net, helping: true)
        second.offers = [OfferSighting(peer: "target", announcement: offer(rdi: target.entry.rdi, helper: false), seenMs: 0, address: "A", rssi: -50)]
        second.peers = ["target": target.listener]
        first.offers = [OfferSighting(peer: "second", announcement: offer(rdi: second.entry.rdi, helper: true), seenMs: 0, address: "C", rssi: -60)]
        first.peers = ["second": second.listener]
        for p in [target, second, first] { try p.listener.start(now: 0) }
        let caller = caller(helper: first, target: target.entry.rdi, budget: 2, nonce: RelaySeek.newNonce())
        try caller.start(now: 0)
        net.pairs.append((caller, first.listener)); net.pump()
        XCTAssertEqual(second.duty?.request.budget, 1, "a regenerated SEEK with budget 1")
        XCTAssertEqual(second.duty?.request.seek?.token, first.duty?.request.seek?.token, "the token travels unchanged")
        XCTAssertEqual(first.duty?.readyRelays, 2)
        XCTAssertEqual(caller.relayReadyRelays, 2, caller.closeReason ?? "-")
        XCTAssertEqual(target.listener.state?.phase, .incomingRinging, target.listener.closeReason ?? "-")
    }

    func testNoMatchAnswersNoRouteAndAHelperWithoutSeekIsNeverAsked() throws {
        let net = Net()
        let helper = Phone(test: self, net: net, helping: true)
        try helper.listener.start(now: 0)
        let c1 = caller(helper: helper, target: Data([1, 2, 3, 4, 5, 6]), budget: 1, nonce: RelaySeek.newNonce())
        try c1.start(now: 0)
        net.pairs = [(c1, helper.listener)]; net.pump()
        XCTAssertEqual(c1.relaySetupFailure, .noRoute)
        let notHelping = Phone(test: self, net: net, helping: false)
        try notHelping.listener.start(now: 0)
        let c2 = caller(helper: notHelping, target: Data([1, 2, 3, 4, 5, 6]), budget: 1, nonce: RelaySeek.newNonce())
        try c2.start(now: 0)
        net.pairs = [(c2, notHelping.listener)]; net.pump()
        XCTAssertNil(notHelping.duty)
        XCTAssertTrue(c2.relaySetupInvalid || c2.relaySetupFailure == .refused, c2.closeReason ?? "-")
    }

    func testPlannerAndBudgets() {
        let nonce = RelaySeek.newNonce(), rdi = Data([7, 7, 7, 7, 7, 7])
        let offers = [OfferSighting(peer: "h1", announcement: offer(rdi: Data([0xc3, 0xc3, 1, 1, 1, 1]), helper: true), seenMs: 0, address: "1", rssi: -40),
                      OfferSighting(peer: "h2", announcement: offer(rdi: Data([0xd4, 0xd4, 1, 1, 1, 1]), helper: true), seenMs: 0, address: "2", rssi: -70)]
        let plan = RelaySeekPlan(offers: offers, nonce: nonce, token: RelaySeek.token(nonce: nonce, rdi: rdi), skip: [Data([0xc3, 0xc3])], budget: 2,
                                 bearer: .gatt, ownRdis: [])
        XCTAssertTrue(plan.targets.isEmpty)
        XCTAssertEqual(plan.helpers.map(\.peer), ["h2"], "a skip prefix is never asked")
        let budgets = RelaySeekBudgets()
        XCTAssertNil(budgets.refusal(budget: 2, now: 0))
        budgets.finish(startedAt: 0, scanMs: 3_000, ready: false, now: 52_000)
        XCTAssertEqual(budgets.refusal(budget: 1, now: 61_000), "gap", "10 s between searches")
        XCTAssertEqual(budgets.refusal(budget: 1, now: 62_001), "duty", "52 s of a 60 s duty budget used: under the 9 s minimum")
        let ready = RelaySeekBudgets()
        ready.finish(startedAt: 0, scanMs: 3_000, ready: true, now: 52_000)
        XCTAssertNil(ready.refusal(budget: 2, now: 62_001), "a search that reached READY gets its duty time back")
        let cache = RelaySeekFailCache()
        cache.store(budget: 1, nonce: nonce, token: Data([1, 2, 3, 4, 5, 6]), skip: [], reason: .noRoute, now: 0)
        XCTAssertEqual(cache.lookup(budget: 1, nonce: nonce, token: Data([1, 2, 3, 4, 5, 6]), skip: [], now: 59_999), .noRoute)
        XCTAssertNil(cache.lookup(budget: 1, nonce: nonce, token: Data([1, 2, 3, 4, 5, 6]), skip: [], now: 60_000))
    }
}
