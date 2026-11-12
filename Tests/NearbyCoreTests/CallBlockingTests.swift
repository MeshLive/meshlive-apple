import XCTest
@testable import NearbyCore

/// Call blocking policy, list and Live-list hiding (Android CallBlockingTest, PersonPolicyTest, LocalReportingTest).
final class CallBlockingTests: XCTestCase {
    private let someone = SoftwareSigningIdentity().fingerprint

    func testABlockedRealKeyCallerNeverRingsAndBlockedPeopleWinOverContacts() {
        for unknown in [true, false] {
            XCTAssertEqual(CallBlockingPolicy.decide(blockUnknown: unknown, pseudonymous: false, blocked: true, standing: .verified), .declineBlockedPerson)
        }
    }

    func testWithoutBlockUnknownCallersEveryoneElseRings() {
        for pseudonymous in [true, false] {
            for standing in [ContactStanding.verified, .notVerified, .unknown] {
                XCTAssertEqual(CallBlockingPolicy.decide(blockUnknown: false, pseudonymous: pseudonymous, blocked: false, standing: standing), .ring)
            }
        }
        XCTAssertEqual(CallBlockingPolicy.decide(blockUnknown: false, pseudonymous: true, blocked: true, standing: .notVerified), .ring,
                       "a throwaway key cannot be matched against the block list")
    }

    func testBlockUnknownCallersLetsOnlyARealKeyVerifiedContactRingAndFailsOpen() {
        XCTAssertEqual(CallBlockingPolicy.decide(blockUnknown: true, pseudonymous: true, blocked: false, standing: .verified), .declineUnknown)
        XCTAssertEqual(CallBlockingPolicy.decide(blockUnknown: true, pseudonymous: false, blocked: false, standing: .notVerified), .declineUnknown)
        XCTAssertEqual(CallBlockingPolicy.decide(blockUnknown: true, pseudonymous: false, blocked: false, standing: .verified), .ring)
        XCTAssertEqual(CallBlockingPolicy.decide(blockUnknown: true, pseudonymous: false, blocked: false, standing: .unknown), .ring,
                       "an unreadable contact store never makes someone unknown")
    }

    func testTheDeclineDelayLooksHuman() {
        XCTAssertEqual(CallBlockingPolicy.declineDelay(random: 0), 3)
        XCTAssertEqual(CallBlockingPolicy.declineDelay(random: 1), 7)
        for _ in 0..<50 { XCTAssertTrue((3...7).contains(CallBlockingPolicy.declineDelay())) }
    }

    func testTheListKeysOnTheFullFingerprintAndTheNodeIdOfItsFirstSixteenBytes() throws {
        var list = BlockList()
        XCTAssertEqual(list.add(someone, at: Date()), .blocked)
        XCTAssertEqual(list.add(someone, at: Date()), .alreadyBlocked)
        XCTAssertTrue(list.contains(someone))
        XCTAssertTrue(list.containsNode(someone.nodeId))
        XCTAssertFalse(list.contains(SoftwareSigningIdentity().fingerprint))
        XCTAssertFalse(list.containsNode(SoftwareSigningIdentity().fingerprint.nodeId))
        XCTAssertTrue(list.remove(someone))
        XCTAssertFalse(list.contains(someone))
        XCTAssertFalse(list.remove(someone))
    }

    func testTheListIsBoundedAndSurvivesARoundTrip() throws {
        var list = BlockList()
        for _ in 0..<BlockList.maxPeople { XCTAssertEqual(list.add(SoftwareSigningIdentity().fingerprint, at: Date()), .blocked) }
        XCTAssertEqual(list.add(someone, at: Date()), .full)
        XCTAssertEqual(list.report(someone, at: Date()), .full, "a full list records no report either")
        XCTAssertFalse(list.reported(node: someone.nodeId))
        XCTAssertEqual(try BlockList.decode(try list.encoded()), list)
    }

    func testASealedBlockListReadIsClassifiedForTheGate() throws {
        var list = BlockList()
        XCTAssertEqual(list.add(someone, at: Date()), .blocked)
        let encoded = try list.encoded()
        XCTAssertEqual(BlockListLoad.classify(.absent), .loaded(BlockList()))
        XCTAssertEqual(BlockListLoad.classify(.value(encoded)), .loaded(list))
        XCTAssertEqual(BlockListLoad.classify(.value(Data("garbage".utf8))), .damaged)
        XCTAssertEqual(BlockListLoad.classify(.unreadable("open")), .damaged)
        XCTAssertEqual(BlockListLoad.classify(.unreadable("file")), .unavailable, "a file read failure may be temporary")
        XCTAssertEqual(BlockListLoad.classify(.unreadable("key")), .unavailable, "a locked Keychain is not a damaged list")
        XCTAssertEqual(BlockListLoad.classify(.unreadable("key_missing")), .damaged, "a missing key beside a stored file needs a reset")
    }

    func testAHolderFailsOpenUntilAListLoadsAndThenDeclinesTheBlockedCaller() {
        var holder = BlockListHolder(save: { _ in true })
        holder.reloadIfNeeded { .unavailable }
        let caller = CallGateCaller(pseudonymous: false, fingerprint: someone)
        XCTAssertEqual(holder.gateDecision(blockUnknown: false, caller: caller, standing: .verified), .ring)
        var list = BlockList()
        list.add(someone, at: Date())
        XCTAssertTrue(holder.reloadIfNeeded { .loaded(list) })
        XCTAssertEqual(holder.gateDecision(blockUnknown: false, caller: caller, standing: .verified), .declineBlockedPerson)
    }

    func testABlockListHolderNeverSavesWithoutAReadableListAndResetsOnlyDamage() {
        var saves = 0
        var holder = BlockListHolder(save: { _ in saves += 1; return true })
        holder.reloadIfNeeded { .unavailable }
        XCTAssertEqual(holder.block(someone, at: Date()), .unavailable)
        XCTAssertFalse(holder.damaged)
        holder.reloadIfNeeded { .damaged }
        XCTAssertTrue(holder.damaged)
        XCTAssertEqual(holder.block(someone, at: Date()), .unavailable)
        XCTAssertEqual(saves, 0, "an unreadable or damaged list is never overwritten")
        XCTAssertTrue(holder.canReset)
        XCTAssertTrue(holder.reset())
        XCTAssertEqual(holder.list, BlockList())
        XCTAssertFalse(holder.damaged)
        XCTAssertFalse(holder.reset(), "a readable list is not reset")
    }

    /// Decision 2026-11-06 ("Unreadable block list"): a damaged list keeps failing open, the screens show the note
    /// with Reset (never "No one is blocked"), a Block is not saved and offers Reset, and Reset makes blocking work again.
    func testAnUnreadableListRingsEveryoneShowsTheNoteAndResetMakesBlockingWorkAgain() {
        var saves = 0
        var holder = BlockListHolder(save: { _ in saves += 1; return true })
        holder.reloadIfNeeded { .damaged }
        let caller = CallGateCaller(pseudonymous: false, fingerprint: someone)
        for _ in 0..<3 {
            XCTAssertEqual(holder.gateDecision(blockUnknown: false, caller: caller, standing: .verified), .ring, "fail open, call after call")
        }
        let shown = BlockListView.of(list: holder.list, damaged: holder.damaged)
        XCTAssertTrue(shown.showUnreadableNote)
        XCTAssertFalse(shown.showEmptyState, "never 'No one is blocked' while people may be on it")
        XCTAssertFalse(shown.showLockedNote)
        XCTAssertEqual(holder.block(someone, at: Date()), .unavailable)
        XCTAssertTrue(holder.canReset, "a Block that could not be saved offers Reset")
        XCTAssertEqual(saves, 0, "the damaged list is never overwritten")

        XCTAssertTrue(holder.reset())
        let afterReset = BlockListView.of(list: holder.list, damaged: holder.damaged)
        XCTAssertFalse(afterReset.showUnreadableNote)
        XCTAssertTrue(afterReset.showEmptyState)
        XCTAssertEqual(holder.block(someone, at: Date()), .blocked)
        XCTAssertEqual(holder.gateDecision(blockUnknown: false, caller: caller, standing: .verified), .declineBlockedPerson)
    }

    /// Apple only: a list the Keychain keeps locked is not damaged. It shows its own note, blocks nobody and is never
    /// reset (it is still good and loads once the device is unlocked).
    func testALockedListShowsItsOwnNoteAndNeverOffersReset() {
        var holder = BlockListHolder(save: { _ in true })
        holder.reloadIfNeeded { .unavailable }
        let shown = BlockListView.of(list: holder.list, damaged: holder.damaged)
        XCTAssertTrue(shown.showLockedNote)
        XCTAssertFalse(shown.showUnreadableNote)
        XCTAssertFalse(shown.showEmptyState)
        XCTAssertFalse(holder.canReset)
        XCTAssertFalse(holder.reset())
        let caller = CallGateCaller(pseudonymous: false, fingerprint: someone)
        XCTAssertEqual(holder.gateDecision(blockUnknown: false, caller: caller, standing: .verified), .ring)
    }

    func testAReadableListShowsItsPeopleWithoutANote() {
        var list = BlockList()
        list.add(someone, at: Date())
        let shown = BlockListView.of(list: list, damaged: false)
        XCTAssertFalse(shown.showUnreadableNote)
        XCTAssertFalse(shown.showLockedNote)
        XCTAssertFalse(shown.showEmptyState)
        XCTAssertTrue(BlockListView.of(list: BlockList(), damaged: false).showEmptyState)
    }

    func testABlockListHolderKeepsABlockOnlyAfterSavingIt() {
        var saves = 0
        var holder = BlockListHolder(save: { _ in saves += 1; return true })
        holder.reloadIfNeeded { .loaded(BlockList()) }
        XCTAssertEqual(holder.block(someone, at: Date()), .blocked)
        XCTAssertEqual(saves, 1)
        XCTAssertTrue(holder.list?.contains(someone) ?? false)

        var failing = BlockListHolder(save: { _ in false })
        failing.reloadIfNeeded { .loaded(BlockList()) }
        XCTAssertEqual(failing.block(someone, at: Date()), .unavailable)
        XCTAssertFalse(failing.list?.contains(someone) ?? true, "a failed save leaves the list as it was")
    }

    func testAMalformedListIsUnreadableRatherThanEmpty() {
        XCTAssertThrowsError(try BlockList.decode(Data("not json".utf8)))
        XCTAssertThrowsError(try BlockList.decode(Data(#"{"people":[{"fingerprintHex":"ABC","blockedAt":0}],"reportedPeople":[],"reportedStreams":[]}"#.utf8)))
        XCTAssertThrowsError(try BlockList.decode(Data(#"{"people":[],"reportedPeople":[],"reportedStreams":["7:A1B2C3D4E5F6"]}"#.utf8)),
                             "a reported stream is a route key, not a bare token or uppercase hex")
        XCTAssertThrowsError(try BlockList.decode(Data(#"{"people":[],"reportedPeople":[],"reportedStreams":["42"]}"#.utf8)))
    }

    /// AB3 (the rule AB1 applied to blocks): a report keeps hiding the person after an unblock (their attributed direct
    /// route, and any route whose source authenticates as them), never a route by itself.
    func testAReportKeepsHidingThePersonAfterAnUnblockButKeepsNoRoute() {
        var list = BlockList()
        XCTAssertEqual(list.report(someone, at: Date()), .blocked)
        XCTAssertTrue(list.contains(someone))
        list.remove(someone)
        XCTAssertFalse(list.contains(someone), "unblocked: calls ring again")
        XCTAssertTrue(list.reported(node: someone.nodeId), "the report keeps hiding their streams")
        XCTAssertTrue(list.hiddenPrefixes.contains(someone.nodePrefixHex))
        XCTAssertTrue(list.reportedRoutes.isEmpty, "a report keeps no route of its own")

        let reportedDirect = offer(Data(hex: someone.nodePrefixHex)!, logical: 42, cost: 0)
        let genuine = offer(Data(hex: "bbbbbbbbbbbb")!, logical: 42, cost: 0)
        let shown = BlockedStreams.hide([reportedDirect, genuine], offer: { $0 }, blockedPrefixes: list.hiddenPrefixes,
                                        hiddenRoutes: list.reportedRoutes, recognised: { _ in nil }, hiddenRoute: { _ in false })
        XCTAssertEqual(shown.map(\.nodeIdPrefix), [genuine.nodeIdPrefix], "their direct route goes, another sender's stays")
    }

    /// AB3 spoof hole: a person reported while heard through a relay, who copied a genuine stream's token, cannot make
    /// the list hide the genuine stream on that relay or on any other route.
    func testAReportMadeThroughARelayCannotHideAGenuineStreamWithTheSameToken() {
        var list = BlockList()
        _ = list.report(someone, at: Date())
        let relay = Data(hex: "0102030405aa")!
        let genuineViaSameRelay = offer(relay, logical: 42, cost: 1)    // the route key the report was made on
        let genuineDirect = offer(Data(hex: "a1b2c3d4e5f6")!, logical: 42, cost: 0)
        let shown = BlockedStreams.hide([genuineViaSameRelay, genuineDirect], offer: { $0 }, blockedPrefixes: list.hiddenPrefixes,
                                        hiddenRoutes: list.reportedRoutes, recognised: { _ in nil }, hiddenRoute: { _ in false })
        XCTAssertEqual(shown.map(\.nodeIdPrefix), [relay, genuineDirect.nodeIdPrefix])
    }

    /// AB3: "Hide this livestream" keeps a route only when the viewer's hop proved the advertised fixed ID; an unproven or
    /// rotating route is hidden by its advertiser's radio address for this run, so a copy cannot hide the genuine stream.
    func testAHiddenLivestreamIsKeptOnlyForAProvenRouteElseOnlyThatAdvertiserIsHidden() {
        let fixed = offer(Data(hex: "a1b2c3d4e5f6")!, logical: 7, cost: 0)
        let rotating = offer(Data(hex: "776655443322")!, logical: 7, cost: 0, rotating: true)
        XCTAssertEqual(BlockedStreams.keptRoute(fixed, hopAuthenticated: true), BlockedStreams.routeKey(fixed))
        XCTAssertNil(BlockedStreams.keptRoute(fixed, hopAuthenticated: false), "an unproven ID could be a copy")
        XCTAssertNil(BlockedStreams.keptRoute(rotating, hopAuthenticated: true), "a rotating ID can be replayed")

        // A copy of the genuine route (same token, same advertised ID) heard from another radio address.
        struct Row { let offer: DiscoveryAnnouncement; let address: String }
        let copy = Row(offer: fixed, address: "copy"), genuine = Row(offer: fixed, address: "genuine")
        let shown = BlockedStreams.hide([copy, genuine], offer: { $0.offer }, blockedPrefixes: [], hiddenRoutes: [],
                                        recognised: { _ in nil }, hiddenRoute: { _ in false },
                                        hiddenAddresses: ["copy"], address: { $0.address })
        XCTAssertEqual(shown.map(\.address), ["genuine"])
    }

    /// A stream offer of logical stream `logical` as advertised by `prefix` (each route masks the token with its own ID).
    private func offer(_ prefix: Data, logical: UInt32, cost: UInt8, rotating: Bool = false) -> DiscoveryAnnouncement {
        var a = DiscoveryAnnouncement(nodeIdPrefix: prefix, flags: DiscoveryAnnouncement.flagAcceptingConnections, capabilitySummary: 1,
                                      streamToken: try! StreamRouteToken.forAdvertiser(logical: logical, prefix: prefix), routeCost: cost)
        a.rotating = rotating
        return a
    }

    /// Review 2026-11-06 (Windows ea07386, Android AP2 A1): the token and the advertised prefix are chosen by the
    /// advertiser, so only the cost-0 route attributed to a blocked person is hidden. A relayed copy stays listed; watching
    /// it leaves as soon as its source authenticates as the blocked person.
    func testABlockedPersonsOwnDirectRouteIsHiddenAndARelayedCopyStaysListed() {
        let blocked = Data(hex: someone.nodePrefixHex)!
        let other = Data(hex: "a1b2c3d4e5f6")!
        let direct = offer(blocked, logical: 9, cost: 0)
        let relayedSameStream = offer(Data(hex: "0102030405aa")!, logical: 9, cost: 1)
        let unrelated = offer(other, logical: 5, cost: 0)
        let rows = [direct, relayedSameStream, unrelated]
        let shown = BlockedStreams.hide(rows, offer: { $0 }, blockedPrefixes: [someone.nodePrefixHex], hiddenRoutes: [],
                                        recognised: { _ in nil }, hiddenRoute: { _ in false })
        XCTAssertEqual(shown.map(\.nodeIdPrefix), [relayedSameStream.nodeIdPrefix, other], "only the attributed direct route goes")
        let relayedOnly = BlockedStreams.hide([relayedSameStream], offer: { $0 }, blockedPrefixes: [someone.nodePrefixHex], hiddenRoutes: [],
                                              recognised: { _ in nil }, hiddenRoute: { _ in false })
        XCTAssertEqual(relayedOnly.count, 1, "a stream with no cost-0 route in range cannot be attributed")
    }

    /// A blocked person who copies a genuine broadcast's token hides only its own direct route, never the genuine one.
    func testASpoofedAttributedRouteCannotHideAnotherAdvertisersRoutesOfTheSameToken() {
        let spoofer = offer(Data(hex: someone.nodePrefixHex)!, logical: 42, cost: 0)
        let spooferRelay = offer(Data(hex: "0102030405aa")!, logical: 42, cost: 1)
        let genuine = offer(Data(hex: "a1b2c3d4e5f6")!, logical: 42, cost: 0)
        let genuineRelay = offer(Data(hex: "0102030405bb")!, logical: 42, cost: 1)
        XCTAssertEqual(spoofer.logicalStreamToken, genuine.logicalStreamToken, "the spoofer copied the genuine token")
        let shown = BlockedStreams.hide([spoofer, spooferRelay, genuine, genuineRelay], offer: { $0 }, blockedPrefixes: [someone.nodePrefixHex],
                                        hiddenRoutes: [], recognised: { _ in nil }, hiddenRoute: { _ in false })
        XCTAssertEqual(shown.map(\.nodeIdPrefix), [spooferRelay.nodeIdPrefix, genuine.nodeIdPrefix, genuineRelay.nodeIdPrefix])
    }

    func testUnblockingBringsTheAttributedRouteBack() {
        let blocked = offer(Data(hex: someone.nodePrefixHex)!, logical: 7, cost: 0)
        let other = offer(Data(hex: "a1b2c3d4e5f6")!, logical: 8, cost: 0)
        let hiddenWhileBlocked = BlockedStreams.hide([blocked, other], offer: { $0 }, blockedPrefixes: [someone.nodePrefixHex], hiddenRoutes: [],
                                                     recognised: { _ in nil }, hiddenRoute: { _ in false })
        XCTAssertEqual(hiddenWhileBlocked.map(\.nodeIdPrefix), [other.nodeIdPrefix])
        let afterUnblock = BlockedStreams.hide([blocked, other], offer: { $0 }, blockedPrefixes: [], hiddenRoutes: [],
                                               recognised: { _ in nil }, hiddenRoute: { _ in false })
        XCTAssertEqual(afterUnblock.map(\.nodeIdPrefix), [blocked.nodeIdPrefix, other.nodeIdPrefix])
    }

    /// The relayed copy the list could not attribute: once a viewer joined it and its source authenticated as the blocked
    /// person (WatchController hides that route), that route leaves the list; another relay's route of the same token stays.
    func testARelayedCopyLeavesTheListOnceItsSourceAuthenticatedAsTheBlockedPerson() {
        let blockedSource = offer(Data(hex: someone.nodePrefixHex)!, logical: 9, cost: 0)
        let relayOfBlocked = offer(Data(hex: "0102030405aa")!, logical: 9, cost: 1)
        let otherRelaySameToken = offer(Data(hex: "0102030405bb")!, logical: 9, cost: 1)
        let rows = [blockedSource, relayOfBlocked, otherRelaySameToken]
        var authenticatedAsBlocked: Set<String> = []
        func visible() -> [Data] {
            BlockedStreams.hide(rows, offer: { $0 }, blockedPrefixes: [someone.nodePrefixHex], hiddenRoutes: [], recognised: { _ in nil },
                                hiddenRoute: { authenticatedAsBlocked.contains(BlockedStreams.routeKey($0)) }).map(\.nodeIdPrefix)
        }
        XCTAssertEqual(visible(), [relayOfBlocked.nodeIdPrefix, otherRelaySameToken.nodeIdPrefix])
        authenticatedAsBlocked.insert(BlockedStreams.routeKey(relayOfBlocked))
        XCTAssertEqual(visible(), [otherRelaySameToken.nodeIdPrefix])
    }

    func testARotatingSourceIsHiddenOnlyWhenRecognisedAsTheBlockedContact() {
        let rotating = offer(Data(hex: "776655443322")!, logical: 3, cost: 0, rotating: true)
        let hiddenWhenRecognised = BlockedStreams.hide([rotating], offer: { $0 }, blockedPrefixes: [someone.nodePrefixHex], hiddenRoutes: [],
                                                       recognised: { _ in self.someone.nodePrefixHex }, hiddenRoute: { _ in false })
        XCTAssertTrue(hiddenWhenRecognised.isEmpty)
        let shownOtherwise = BlockedStreams.hide([rotating], offer: { $0 }, blockedPrefixes: [someone.nodePrefixHex], hiddenRoutes: [],
                                                 recognised: { _ in nil }, hiddenRoute: { _ in false })
        XCTAssertEqual(shownOtherwise.count, 1)
    }

    func testAnAuthenticatedHiddenRouteDoesNotHideAnotherBroadcasterWithTheSameToken() {
        let blockedRoute = offer(Data(hex: "aaaaaaaaaaaa")!, logical: 11, cost: 0)
        let genuine = offer(Data(hex: "bbbbbbbbbbbb")!, logical: 11, cost: 0)
        let key = BlockedStreams.routeKey(blockedRoute)
        let shown = BlockedStreams.hide([blockedRoute, genuine], offer: { $0 }, blockedPrefixes: [], hiddenRoutes: [key],
                                        recognised: { _ in nil }, hiddenRoute: { _ in false })
        XCTAssertEqual(shown.map(\.nodeIdPrefix), [genuine.nodeIdPrefix])
    }
}
