import XCTest
@testable import NearbyCore

/// RV-C: a forwarder that names a blocked source loses only its own route; the watch looks for the stream elsewhere.
final class BlockedSourceClaimTests: XCTestCase {
    private struct Row { let route: String; let stream: Int }

    func testOnlyTheSourcesOwnHandshakeEndsAndHidesTheStream() {
        let source = SoftwareSigningIdentity().nodeId, forwarder = SoftwareSigningIdentity().nodeId
        XCTAssertEqual(BlockedSourceClaim.action(adjacent: source, source: source), .leaveAndHide)
        XCTAssertEqual(BlockedSourceClaim.action(adjacent: forwarder, source: source), .dropRoute, "a forwarder's claim is not proof")
    }

    func testRecoveryTriesTheNextRouteAfterAClaimAndNeverTheDroppedOne() {
        let recovery = ViewerRecoveryRoutes<Int>()
        var exclusions = WatchRouteExclusions()
        let liar = Row(route: "liar", stream: 7), other = Row(route: "other", stream: 7), elsewhere = Row(route: "x", stream: 8)
        exclusions.drop(liar.route)
        recovery.onFailure(target: 7, route: liar.route, now: 100)
        let pick = { (rows: [Row], seenAt: TimeInterval?) in
            recovery.candidate(now: 200, listed: exclusions.usable(rows, route: { $0.route }), matches: { $0 == $1.stream },
                               route: { $0.route }, seenAt: { _ in seenAt })?.route
        }
        XCTAssertEqual(pick([liar, other, elsewhere], 150), "other", "the next route of the same stream")
        XCTAssertNil(pick([liar, elsewhere], 150), "no other route: the watch keeps searching until its bound ends it")
        // Without the exclusion a freshly sighted lying route would be tried again; with it, never in this watch.
        XCTAssertEqual(recovery.candidate(now: 200, listed: [liar], matches: { $0 == $1.stream }, route: { $0.route }, seenAt: { _ in 150 })?.route, "liar")
        XCTAssertNil(pick([liar], 150))
    }

    func testTheExclusionsAreBoundedAndKeepTheNewest() {
        var exclusions = WatchRouteExclusions()
        for i in 0..<(WatchRouteExclusions.maxRoutes + 5) { exclusions.drop("r\(i)") }
        XCTAssertEqual(exclusions.routes.count, WatchRouteExclusions.maxRoutes)
        XCTAssertTrue(exclusions.allows("r0"))
        XCTAssertFalse(exclusions.allows("r\(WatchRouteExclusions.maxRoutes + 4)"))
        exclusions.drop("r10")
        XCTAssertEqual(exclusions.routes.last, "r10", "dropping again refreshes, never duplicates")
        XCTAssertEqual(exclusions.routes.filter { $0 == "r10" }.count, 1)
    }
}
