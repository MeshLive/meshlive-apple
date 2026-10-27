import XCTest
@testable import NearbyCore

/// Route searches, caller side, ported from Android RelaySeekTest: selectors, rings, memory, first hops, the planner order.
final class RelaySeekCallerTests: XCTestCase {
    private func d(_ hex: String) -> Data { Data(hex: hex)! }
    private lazy var ids: [Int64: Data] = [99: d("aaaaaaaaa099"), 100: d("aaaaaaaaa100"), 101: d("aaaaaaaaa101")]
    private lazy var hops = [d("a1a1a1a1a1a1"), d("b2b2b2b2b2b2"), d("c3c3c3c3c3c3")]
    private lazy var primary = RelaySeekSelectors.Selector(epoch: 100, rdi: d("aaaaaaaaa100"), kind: .primary)
    private lazy var neighbour = RelaySeekSelectors.Selector(epoch: 101, rdi: d("aaaaaaaaa101"), kind: .neighbour)

    func testThePrimarySelectorIsTheCentreAndTheNeighbourOnlyInsideTheBoundaryWindow() {
        let window = RelaySeekSelectors.Window(centreEpoch: 100, stale: false, ids: ids)
        XCTAssertEqual(RelaySeekSelectors.selectors(window: window, directEpoch: nil, msUntilBoundary: 400_000, msSinceBoundary: 500_000).map(\.epoch), [100])
        let before = RelaySeekSelectors.selectors(window: window, directEpoch: nil, msUntilBoundary: 60_000, msSinceBoundary: 840_000)
        XCTAssertEqual(before.map(\.epoch), [100, 101]); XCTAssertEqual(before[1].kind, .neighbour)
        XCTAssertEqual(RelaySeekSelectors.selectors(window: window, directEpoch: nil, msUntilBoundary: 840_000, msSinceBoundary: 60_000).map(\.epoch), [100, 99])
        let stale = RelaySeekSelectors.Window(centreEpoch: 100, stale: true, ids: ids)
        XCTAssertEqual(RelaySeekSelectors.selectors(window: stale, directEpoch: nil, msUntilBoundary: 60_000, msSinceBoundary: 840_000).map(\.epoch), [100])
        XCTAssertEqual(RelaySeekSelectors.selectors(window: window, directEpoch: 101, msUntilBoundary: 400_000, msSinceBoundary: 500_000).first?.epoch, 101)
        XCTAssertTrue(RelaySeekSelectors.selectors(window: .init(centreEpoch: 200, stale: false, ids: ids), directEpoch: nil, msUntilBoundary: 1, msSinceBoundary: 2).isEmpty)
        XCTAssertEqual(RelaySeekSelectors.boundaryWindowMs(epochSeconds: 900), 120_000)
    }

    private func rings(now: Int64 = 0, selectors: [RelaySeekSelectors.Selector]? = nil, cap: Int = 2, require: Int = 0) -> RelaySeekRings {
        RelaySeekRings(attemptEndMs: now + 45_000, selectors: selectors ?? [primary], firstHops: hops, maxRelays: cap, require: require, connectMs: 4_000)
    }

    func testRingsAskEveryFirstHopForOneRelayFirstThenTwoWithTheMissesSkipped() {
        let plan = rings(selectors: [primary, neighbour])
        var asked: [String] = []
        while let r = plan.next(now: 0) {
            asked.append("\(r.ring):\(r.hop.hex.prefix(2)):\(r.budget):\(r.selector.kind):\(r.skip.map(\.hex).joined(separator: ", "))")
            XCTAssertLessThanOrEqual(r.remainingMs, 20_000)
            plan.record(r, outcome: .noRoute, physicalDials: 1)
        }
        XCTAssertEqual(asked, ["one:a1:1:primary:", "one:b2:1:primary:", "one:c3:1:primary:",
                               "oneB:a1:1:neighbour:", "oneB:b2:1:neighbour:", "oneB:c3:1:neighbour:",
                               "two:a1:2:primary:a1a1, b2b2, c3c3", "two:b2:2:primary:a1a1, b2b2, c3c3", "two:c3:2:primary:a1a1, b2b2, c3c3"])
        XCTAssertEqual(plan.maxRequests, 9); XCTAssertEqual(plan.maxDials, 18); XCTAssertEqual(plan.requests, 9)
    }

    func testBusyRefusedUnboundOrSilentHopsAreNotAskedAgainAndReadyStops() {
        let plan = rings()
        plan.record(plan.next(now: 0)!, outcome: .busyOrRefused, physicalDials: 1)
        plan.record(plan.next(now: 0)!, outcome: .ambiguous, physicalDials: 2)
        let third = plan.next(now: 0)!
        XCTAssertEqual(third.hop.hex.prefix(2), "c3")
        plan.record(third, outcome: .noRoute, physicalDials: 1)
        let two = plan.next(now: 0)!
        XCTAssertEqual(two.ring, .two); XCTAssertEqual(two.hop.hex.prefix(2), "c3", "only the hop that answered is asked again")
        XCTAssertEqual(two.skip.map(\.hex), ["c3c3"])
        plan.record(two, outcome: .ready, physicalDials: 1)
        XCTAssertNil(plan.next(now: 0)); XCTAssertEqual(plan.dials, 5)
    }

    func testARequiredChainAndTheRelayCapChooseTheRingsAndTheAllowanceEndsTheAttempt() {
        XCTAssertEqual(rings(require: 2).next(now: 0)?.ring, .two)
        let oneOnly = rings(cap: 1)
        for _ in 0..<3 { oneOnly.record(oneOnly.next(now: 0)!, outcome: .noRoute, physicalDials: 1) }
        XCTAssertNil(oneOnly.next(now: 0), "no ring 2 under a cap of one relay")
        let plan = rings()
        let r = plan.next(now: 30_000)!
        XCTAssertEqual(r.remainingMs, 13_000)
        plan.record(r, outcome: .noRoute, physicalDials: 1)
        XCTAssertNil(plan.next(now: 30_001), "12.999 s less 4 s is below the 9 s minimum")
        XCTAssertTrue(plan.done)
    }

    func testTheCallerBacksOffAfterCantFindAndRemembersMissesForAMinute() {
        let m = RelaySeekCallerMemory()
        XCTAssertEqual(m.backoffMs(contact: "c1", now: 0), 0)
        m.failed(contact: "c1", now: 0); XCTAssertEqual(m.backoffMs(contact: "c1", now: 0), 30_000)
        m.failed(contact: "c1", now: 0); XCTAssertEqual(m.backoffMs(contact: "c1", now: 0), 60_000)
        m.failed(contact: "c1", now: 0); m.failed(contact: "c1", now: 0); XCTAssertEqual(m.backoffMs(contact: "c1", now: 0), 120_000)
        m.reset(contact: "c1"); XCTAssertEqual(m.backoffMs(contact: "c1", now: 0), 0)
        m.rememberNoRoute(hop: hops[0], selector: primary.rdi, budget: 1, now: 0)
        XCTAssertTrue(m.recentlyNoRoute(hop: hops[0], selector: primary.rdi, budget: 1, now: 59_999))
        XCTAssertFalse(m.recentlyNoRoute(hop: hops[0], selector: primary.rdi, budget: 2, now: 0))
        XCTAssertFalse(m.recentlyNoRoute(hop: hops[0], selector: primary.rdi, budget: 1, now: 60_000))
        m.rememberReached(contact: "c1", epoch: 100, hop: hops[1])
        XCTAssertEqual(m.reachedBy(contact: "c1", epoch: 100), hops[1]); XCTAssertNil(m.reachedBy(contact: "c1", epoch: 101))
    }

    private func offer(_ rdi: Data, helper: Bool, rssi: Int, seen: Int64 = 0, count: Int = 1) -> OfferSighting<String> {
        var flags = DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable | DiscoveryAnnouncement.flagGattTransport
        if helper { flags |= DiscoveryAnnouncement.flagRelayCapable }
        var a = DiscoveryAnnouncement(nodeIdPrefix: rdi, flags: flags, capabilitySummary: 1 | RelayedCalls.consentBit, streamToken: 0, routeCost: 0)
        a.rotating = true
        var s = OfferSighting(peer: rdi.hex, announcement: a, seenMs: seen, address: rdi.hex, rssi: rssi)
        s.count = count
        return s
    }

    func testFirstHopsPreferTheHelperThatReachedTheContactThenSignal() {
        let offers = [offer(hops[0], helper: true, rssi: -80), offer(hops[1], helper: true, rssi: -40), offer(hops[2], helper: true, rssi: -60),
                      offer(d("d4d4d4d4d4d4"), helper: false, rssi: -30), offer(d("e5e5e5e5e5e5"), helper: true, rssi: -20, seen: -20_000)]
        XCTAssertEqual(RelaySeekFirstHops.choose(offers: offers, bearer: .gatt, now: 0, isContact: { _ in false }, reachedBy: nil), [hops[1], hops[2], hops[0]])
        XCTAssertEqual(RelaySeekFirstHops.choose(offers: offers, bearer: .gatt, now: 0, isContact: { _ in false }, reachedBy: hops[0]).first, hops[0])
        XCTAssertEqual(RelaySeekFirstHops.choose(offers: offers, bearer: .gatt, now: 0, isContact: { $0 == self.hops[1] }, reachedBy: nil), [hops[2], hops[0]])
    }

    func testThePlannerTriesAddressesHeardTwiceFirstThenSignal() {
        let nonce = d("0102030405060708"), target = d("974ae410ea91")
        var strong = offer(target, helper: false, rssi: -30); strong.count = 1
        var steady = OfferSighting(peer: "steady", announcement: strong.announcement, seenMs: 0, address: "B", rssi: -70); steady.count = 2
        let plan = RelaySeekPlan(offers: [strong, steady], nonce: nonce, token: RelaySeek.token(nonce: nonce, rdi: target), skip: [], budget: 1,
                                 bearer: .gatt, ownRdis: [])
        XCTAssertEqual(plan.targets.map(\.peer), ["steady", target.hex], "heard twice first, then signal")
    }

    func testRecognitionKeepsEachContactsSearchWindow() {
        let table = RecognitionTable()
        let nodeId = Data(repeating: 0x42, count: 16)
        let lease = Data(repeating: 7, count: 32)
        let myEpoch: Int64 = 1_990_656
        let day = PresenceLeases.dayOf(myEpoch)
        let contact = ContactPresence(nodeId: nodeId, generation: 1, leasesByDay: [day: lease, day - 1: lease, day + 1: lease], skewEpochs: 0, receivedAt: 0)
        table.rebuild([contact], myEpoch: myEpoch, now: 0)
        let w = table.seekWindow(prefixHex: nodeId.prefix(6).hex)
        XCTAssertEqual(w?.centreEpoch, myEpoch); XCTAssertEqual(w?.stale, false); XCTAssertEqual(w?.ids.count, 3)
        XCTAssertEqual(table.lookup(w!.ids[myEpoch]!).first?.epoch, myEpoch, "the window's IDs are the recognition IDs")
        XCTAssertNil(table.seekWindow(prefixHex: "ffffffffffff"))
    }
}
