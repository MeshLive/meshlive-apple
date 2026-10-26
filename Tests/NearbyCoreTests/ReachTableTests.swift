import XCTest
@testable import NearbyCore

/// Reach table (ported from Android ReachTableTest): admission, aging, caps, flood resistance, route choice, advertising.
final class ReachTableTests: XCTestCase {
    private var now: Int64 = 1_000
    private let own = Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
    private let d = Data([1, 2, 3, 4, 5, 6])
    private let r1 = Data([0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f])
    private let r2 = Data([0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f])

    private func table(_ configure: (inout ReachConfig) -> Void = { _ in }) -> ReachTable<String> {
        var config = ReachConfig(); configure(&config)
        var seed = 1
        return ReachTable<String>(ownPrefix: own, config: config, clock: { [unowned self] in self.now }, random: { seed = seed &* 1103515245 &+ 12345; return seed })
    }

    private func offer(_ prefix: Data, consent: Bool = true, helper: Bool = false, cost: UInt8 = 0, gatt: Bool = false,
                       accepting: Bool = true, rotating: Bool = false, classic: Bool = false) -> DiscoveryAnnouncement {
        var flags = DiscoveryAnnouncement.flagPrivateCallAvailable
        if accepting { flags |= DiscoveryAnnouncement.flagAcceptingConnections }
        if helper { flags |= DiscoveryAnnouncement.flagRelayCapable }
        if gatt { flags |= DiscoveryAnnouncement.flagGattTransport }
        if classic { flags |= DiscoveryAnnouncement.flagClassicTransport }
        var a = DiscoveryAnnouncement(nodeIdPrefix: prefix, flags: flags, capabilitySummary: NodeCapabilities.codecVP9 | (consent ? RelayedCalls.consentBit : 0),
                                      streamToken: 0, routeCost: cost)
        a.rotating = rotating
        return a
    }

    private func page(_ relay: Data, _ entries: ReachPageEntry...) -> ReachPage {
        ReachPage(relayPrefix: relay, relayFlags: ReachPageCodec.flagCoc | ReachPageCodec.flagIdle, index: 0, count: 1, entries: entries)
    }
    private func entry(_ target: Data, _ cost: Int, age: Int = 0, via: Data? = nil) -> ReachPageEntry {
        try! ReachPageEntry(target: target, cost: cost, ageUnits: age, via: via ?? target.prefix(2).rebased)
    }
    private func seenTwice(_ block: () -> Void) { block(); now += 2_000; block() }
    private func helper(_ t: ReachTable<String>, _ name: String, _ prefix: Data, _ address: String, rssi: Int? = nil) {
        t.observeOffer(peer: name, announcement: offer(prefix, consent: false, helper: true), address: address, rssi: rssi)
    }

    func testAConsentingOfferBecomesAnEntryOnlyAfterTwoSightingsFromTheSameAddress() {
        let t = table()
        t.observeOffer(peer: "d", announcement: offer(d), address: "AA:01"); XCTAssertEqual(t.size, 0)
        now += 1_999; t.observeOffer(peer: "d", announcement: offer(d), address: "AA:01"); XCTAssertEqual(t.size, 0)
        now += 1; t.observeOffer(peer: "d", announcement: offer(d), address: "AA:01"); XCTAssertEqual(t.size, 1)
        let u = table()
        u.observeOffer(peer: "d", announcement: offer(d), address: "AA:01")
        now += 2_500; u.observeOffer(peer: "d", announcement: offer(d), address: "AA:02")
        XCTAssertEqual(u.size, 0, "two addresses never add up")
    }

    func testUnusableOffersAreNeverEntriesButANonConsentingOfferIsStillDialable() {
        let t = table()
        for a in [offer(d, consent: false), offer(d, rotating: true), offer(d, cost: 1), offer(d, classic: true), offer(d, accepting: false), offer(own)] {
            seenTwice { t.observeOffer(peer: "d", announcement: a, address: "AA:01") }
            now += 1_000
        }
        XCTAssertEqual(t.size, 0)
        let direct = table()
        direct.observeOffer(peer: "d", announcement: offer(d, consent: false), address: "AA:01")
        XCTAssertNotNil(direct.directOffer(d)); XCTAssertNil(direct.directOffer(r1))
        now += RelayedCalls.offerFreshMs + 1
        XCTAssertNil(direct.directOffer(d), "an offer ages out of dialability")
    }

    func testPageEntriesCostOneMoreForAHelperAndRespectTheCap() {
        let t = table()
        helper(t, "r1", r1, "AA:10")
        seenTwice { t.observePage(page(r1, entry(d, 1)), address: "BB:10") }
        let routes = t.callerRoutes(d)
        XCTAssertEqual(routes.count, 1); XCTAssertEqual(routes.first?.relays, 1); XCTAssertEqual(routes.first?.hop.peer, "r1")
        now += 6_000
        helper(t, "r1", r1, "AA:10"); t.observePage(page(r1, entry(d, 1)), address: "BB:10")
        let advertised = t.advertisable()
        XCTAssertEqual(advertised.count, 1); XCTAssertEqual(advertised.first?.entry.cost, 2)
        XCTAssertEqual(advertised.first?.relay, true); XCTAssertEqual(advertised.first?.entry.via, Data([0x0a, 0x0b]))
        let u = table()
        helper(u, "r1", r1, "AA:10")
        seenTwice { u.observePage(page(r1, entry(d, 2)), address: "BB:10") }
        now += 6_000
        helper(u, "r1", r1, "AA:10"); u.observePage(page(r1, entry(d, 2)), address: "BB:10")
        XCTAssertEqual(u.callerRoutes(d).count, 1, "two relays are usable by a caller")
        XCTAssertEqual(u.advertisable().count, 0, "but cost 3 is never advertised")
        let v = table()
        seenTwice { v.observePage(page(r1, entry(d, 3)), address: "BB:10") }
        XCTAssertEqual(v.size, 0, "a page above the cap is ignored")
    }

    func testPoisonReverseAndSelfEntriesAreIgnored() {
        let t = table()
        helper(t, "r1", r1, "AA:10")
        seenTwice { t.observePage(page(r1, entry(d, 1, via: own.prefix(2).rebased)), address: "BB:10") }
        seenTwice { t.observePage(page(r1, entry(own, 1)), address: "BB:10") }
        seenTwice { t.observePage(page(own, entry(d, 1)), address: "BB:11") }
        XCTAssertEqual(t.size, 0)
    }

    func testEntriesAgeAndExpireAndALostRouteIsHeldDown() {
        let t = table { $0.maxRelays = 4 }
        helper(t, "r1", r1, "AA:10")
        seenTwice { t.observePage(page(r1, entry(d, 1, age: 5)), address: "BB:10") }
        now += 8_000; helper(t, "r1", r1, "AA:10")
        XCTAssertTrue((17_000...19_000).contains(t.callerRoutes(d)[0].ageMs))
        now += 30_001; helper(t, "r1", r1, "AA:10")
        XCTAssertEqual(t.callerRoutes(d).count, 0); XCTAssertEqual(t.size, 0)
        seenTwice { t.observePage(page(r2, entry(d, 3)), address: "BB:11") }
        XCTAssertEqual(t.size, 0, "a worse route to a lost target is held down for 10 s")
        now += 10_001
        seenTwice { t.observePage(page(r2, entry(d, 3)), address: "BB:11") }
        XCTAssertEqual(t.size, 1)
    }

    func testFloodIntakeIsCappedAtEightPerWindowAndOneRelayTeachesAtMostFour() {
        let t = table()
        func round() { for i in 0..<20 { t.observeOffer(peer: "p\(i)", announcement: offer(Data([0x50, UInt8(i), 1, 1, 1, 1])), address: String(format: "CC:%02x", i)) } }
        round(); now += 2_000; round()
        XCTAssertEqual(t.size, 8)
        now += 30_000; round(); now += 2_000; round()
        XCTAssertGreaterThan(t.size, 8)
        let u = table()
        let entries = (1...6).map { entry(Data([0x40, UInt8($0), 1, 1, 1, 1]), 1) }
        func pages() { for i in stride(from: 0, to: 6, by: 2) { u.observePage(ReachPage(relayPrefix: r1, relayFlags: 1, index: 0, count: 1, entries: [entries[i], entries[i + 1]]), address: "BB:10") } }
        pages(); now += 2_000; pages()
        XCTAssertEqual(u.size, 4)
    }

    func testRoutesPreferDirectThenFewerRelaysThenFreshThenStrongerSignal() {
        let t = table { $0.maxRelays = 4 }
        let r3 = Data([0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f])
        helper(t, "r1", r1, "AA:10", rssi: -90); helper(t, "r2", r2, "AA:20", rssi: -50); helper(t, "r3", r3, "AA:30", rssi: -60)
        seenTwice {
            t.observePage(page(r1, entry(d, 2)), address: "BB:10")
            t.observePage(page(r2, entry(d, 2)), address: "BB:20")
            t.observePage(page(r3, entry(d, 1)), address: "BB:30")
        }
        XCTAssertEqual(t.callerRoutes(d).map(\.hop.peer), ["r3", "r2", "r1"])
        t.observeOffer(peer: "direct", announcement: offer(d, consent: false), address: "AA:01")
        XCTAssertEqual(t.callerRoutes(d).first?.hop.peer, "direct"); XCTAssertEqual(t.callerRoutes(d).first?.relays, 0)
        XCTAssertEqual(t.callerRoutes(d, requireRelays: 2).map(\.hop.peer), ["r2", "r1"])
    }

    func testARouteNeedsTheRelaysOwnFreshHelperOffer() {
        let t = table()
        seenTwice { t.observePage(page(r1, entry(d, 1)), address: "BB:10") }
        XCTAssertEqual(t.callerRoutes(d).count, 0, "no offer of r1 heard")
        t.observeOffer(peer: "r1", announcement: offer(r1, helper: false), address: "AA:10")
        XCTAssertEqual(t.callerRoutes(d).count, 0, "not a helper offer")
        t.observeOffer(peer: "r1", announcement: offer(r1, helper: true, gatt: true), address: "AA:10")
        t.observePage(page(r1, entry(d, 1)), address: "BB:10")
        XCTAssertEqual(t.callerRoutes(d).count, 1)
        XCTAssertEqual(t.callerRoutes(d, accept: { $0.transport == .l2cap }).count, 0)
    }

    func testFailedPairsAreSkippedAndNoRouteDropsTheEntry() {
        let t = table()
        func refresh() {
            helper(t, "r1", r1, "AA:10"); helper(t, "r2", r2, "AA:20")
            t.observePage(page(r1, entry(d, 1)), address: "BB:10"); t.observePage(page(r2, entry(d, 1)), address: "BB:20")
        }
        seenTwice(refresh)
        XCTAssertEqual(t.callerRoutes(d).count, 2)
        t.markFailed(relay: r1, target: d, noRoute: false)
        XCTAssertEqual(t.callerRoutes(d).map(\.hop.peer), ["r2"])
        for _ in 0..<3 { now += 10_001; refresh() }
        XCTAssertEqual(t.callerRoutes(d).count, 2, "the skip lasts 30 s")
        t.markFailed(relay: r2, target: d, noRoute: true)
        for _ in 0..<29 { now += 10_000; refresh() }
        XCTAssertEqual(t.callerRoutes(d).map(\.hop.peer), ["r1"], "no route drops the pair for 5 minutes")
        for _ in 0..<2 { now += 10_000; refresh() }
        XCTAssertEqual(t.callerRoutes(d).count, 2)
    }

    func testRelayedTargetsListsOnlyTargetsWithoutADirectOfferAndSetupRoutesFitTheBudget() {
        let t = table()
        helper(t, "r1", r1, "AA:10")
        seenTwice { t.observePage(page(r1, entry(d, 1)), address: "BB:10") }
        XCTAssertEqual(t.relayedTargets(), [d])
        XCTAssertNil(t.setupRoute(d, budget: 1), "budget 1 needs the target's own offer")
        XCTAssertEqual(t.setupRoute(d, budget: 2)?.nextHop, r1)
        t.observeOffer(peer: "d", announcement: offer(d), address: "AA:01")
        XCTAssertEqual(t.relayedTargets(), [])
        XCTAssertNil(t.setupRoute(d, budget: 1)?.nextHop, "a consenting direct offer is the next hop whatever the budget")
        XCTAssertNotNil(t.setupRoute(d, budget: 1))
    }
}
