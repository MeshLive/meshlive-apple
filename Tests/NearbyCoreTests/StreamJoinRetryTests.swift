import XCTest
@testable import NearbyCore

/// A failed live join: Try again, and one automatic retry when the stream is listed again (Android StreamJoinRetry).
final class StreamJoinRetryTests: XCTestCase {
    func testOneAutomaticRetryPerStreamUntilAJoinWorks() {
        let retry = StreamJoinRetry<String>()
        XCTAssertNotNil(retry.onJoinFailed("a", now: 0))
        XCTAssertEqual(retry.take(now: 1, listed: ["b", "a"], matches: ==), "a", "rejoins when the stream is listed again")
        XCTAssertNil(retry.onJoinFailed("a", now: 2), "only one automatic retry")
        retry.onJoined("a")
        XCTAssertNotNil(retry.onJoinFailed("a", now: 3), "a join that worked makes the retry available again")
    }

    func testRetryWaitsForTheStreamAndExpires() {
        let retry = StreamJoinRetry<String>()
        retry.onJoinFailed("a", now: 0)
        XCTAssertNil(retry.take(now: 5, listed: ["b"], matches: ==), "not listed yet")
        XCTAssertNotNil(retry.pending, "still waiting")
        XCTAssertNil(retry.take(now: StreamJoinRetry<String>.window + 1, listed: ["a"], matches: ==), "too late")
        XCTAssertNil(retry.pending)
    }

    func testTryAgainWorksAfterTheAutomaticRetryWasUsed() {
        let retry = StreamJoinRetry<String>()
        retry.onJoinFailed("a", now: 0)
        _ = retry.take(now: 1, listed: ["a"], matches: ==)
        XCTAssertNil(retry.onJoinFailed("a", now: 2))
        retry.onTryAgain("a", now: 2)
        XCTAssertEqual(retry.take(now: 3, listed: ["a"], matches: ==), "a")
    }

    func testSwitchedOffNeverRetriesByItself() {
        let retry = StreamJoinRetry<String>(enabled: { false })
        XCTAssertNil(retry.onJoinFailed("a", now: 0))
        XCTAssertNil(retry.take(now: 1, listed: ["a"], matches: ==))
    }

    func testAnotherRouteToTheSameStreamMatches() {
        let source = Data(hex: "a1b2c3d4e5f6")!, forwarder = Data(hex: "0102030405a8")!
        let logical: UInt32 = 0x1234
        let direct = DiscoveryAnnouncement(nodeIdPrefix: source, flags: DiscoveryAnnouncement.flagStreamAvailable, capabilitySummary: 1,
                                           streamToken: try! StreamRouteToken.forAdvertiser(logical: logical, prefix: source), routeCost: 0)
        let relayed = DiscoveryAnnouncement(nodeIdPrefix: forwarder, flags: DiscoveryAnnouncement.flagStreamAvailable | DiscoveryAnnouncement.flagRelayCapable,
                                            capabilitySummary: 1, streamToken: try! StreamRouteToken.forAdvertiser(logical: logical, prefix: forwarder), routeCost: 1)
        XCTAssertTrue(LogicalStreamTarget(direct).matches(relayed))
        let other = DiscoveryAnnouncement(nodeIdPrefix: source, flags: DiscoveryAnnouncement.flagStreamAvailable, capabilitySummary: 1,
                                          streamToken: try! StreamRouteToken.forAdvertiser(logical: logical + 1, prefix: source), routeCost: 0)
        XCTAssertFalse(LogicalStreamTarget(direct).matches(other))
    }

    func testAJoinKeepsWaitingOnlyAfterAnUnauthenticatedLinkWithTimeLeft() {
        XCTAssertTrue(StreamJoinWait.keepWaiting(enabled: true, hopAuthenticated: false, joined: false, stoppedByUser: false, ended: false, secondsLeft: 3))
        XCTAssertFalse(StreamJoinWait.keepWaiting(enabled: true, hopAuthenticated: true, joined: false, stoppedByUser: false, ended: false, secondsLeft: 3))
        XCTAssertFalse(StreamJoinWait.keepWaiting(enabled: true, hopAuthenticated: false, joined: false, stoppedByUser: false, ended: false, secondsLeft: 0))
        XCTAssertFalse(StreamJoinWait.keepWaiting(enabled: true, hopAuthenticated: false, joined: false, stoppedByUser: true, ended: false, secondsLeft: 3))
        XCTAssertFalse(StreamJoinWait.keepWaiting(enabled: false, hopAuthenticated: false, joined: false, stoppedByUser: false, ended: false, secondsLeft: 3),
                       "control arm")
    }

    // MARK: The 60 s end of a lost-stream search (C1.2)

    func testASearchWithNoSightingEndsAtTheBoundAndNotBefore() {
        var search = StreamSearchBound()
        search.begin(now: 0)
        let before = try! XCTUnwrap(search.remaining(now: StreamSearchBound.defaultBound - 0.001))
        XCTAssertEqual(before, 0.001, accuracy: 0.0001, "1 ms left")
        XCTAssertFalse(search.expired(now: StreamSearchBound.defaultBound - 0.001))
        XCTAssertEqual(search.remaining(now: StreamSearchBound.defaultBound), 0)
        XCTAssertTrue(search.expired(now: StreamSearchBound.defaultBound), "expired at the bound")
    }

    func testFailedAttemptsInsideTheSearchDoNotRestartItsClock() {
        var search = StreamSearchBound()
        search.begin(now: 0)
        search.begin(now: 20)
        search.begin(now: 45)
        XCTAssertFalse(search.expired(now: StreamSearchBound.defaultBound - 0.001))
        XCTAssertTrue(search.expired(now: StreamSearchBound.defaultBound), "the first loss starts the clock")
    }

    func testAReconnectThatCameBackEndsTheSearchAndTheNextLossGetsAFullBound() {
        var search = StreamSearchBound()
        search.begin(now: 0)
        XCTAssertNotNil(search.remaining(now: 30))
        search.end()
        XCTAssertNil(search.remaining(now: 30), "the stream is back")
        search.begin(now: 100)
        XCTAssertFalse(search.expired(now: 159.999))
        XCTAssertTrue(search.expired(now: 160), "the next loss gets a full bound")
    }

    func testTheControlArmNeverExpires() {
        var search = StreamSearchBound(enabled: { false })
        search.begin(now: 0)
        XCTAssertNil(search.remaining(now: 10 * StreamSearchBound.defaultBound))
        XCTAssertFalse(search.expired(now: 10 * StreamSearchBound.defaultBound), "control arm")
    }

    func testNoSearchMeansNothingToExpire() {
        let search = StreamSearchBound()
        XCTAssertNil(search.remaining(now: 10))
        XCTAssertFalse(search.expired(now: 10))
    }

    func testALostStreamIsNotAFailedJoinSoNoRetryIsQueued() {
        let retry = StreamJoinRetry<String>()
        retry.onJoined("a")
        XCTAssertNil(retry.pending, "a stream that played has no failed join")
        XCTAssertNil(retry.take(now: 1, listed: ["a"], matches: ==), "the lost-stream end queues no rejoin")
    }
}
