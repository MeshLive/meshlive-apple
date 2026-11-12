import XCTest
@testable import NearbyCore

/// Live and viewer behaviours as Android: recovery after a lost stream, the relayed-child parent-link watch, the relay
/// battery pause, streams this device cannot play, End live with viewers, the broadcaster status and Hide this livestream.
final class LiveViewerTests: XCTestCase {
    private typealias Row = (stream: String, route: String)
    private func pick(_ routes: ViewerRecoveryRoutes<String>, _ now: TimeInterval, _ listed: [Row]) -> String? {
        routes.candidate(now: now, listed: listed, matches: { $0 == $1.stream }, route: { $0.route })?.route
    }

    func testALostStreamIsRetriedAtOnceThenBacksOffOnThatRoute() {
        let routes = ViewerRecoveryRoutes<String>()
        let listed: [Row] = [("s", "a")]
        routes.onFailure(target: "s", route: "a", now: 100)
        XCTAssertEqual(pick(routes, 100, listed), "a", "the first loss retries the same route at once")
        var now: TimeInterval = 100
        for wait in [1.0, 2, 4, 8, 8] {
            routes.onFailure(target: "s", route: "a", now: now)
            XCTAssertNil(pick(routes, now + wait - 0.1, listed), "waits \(wait) s")
            XCTAssertEqual(pick(routes, now + wait, listed), "a")
            now += wait
        }
    }

    func testAnotherRouteOfTheSameStreamIsTriedWhileTheFailedOneWaits() {
        let routes = ViewerRecoveryRoutes<String>()
        routes.onFailure(target: "s", route: "a", now: 0)
        routes.onFailure(target: "s", route: "a", now: 0)
        XCTAssertEqual(pick(routes, 0.5, [("s", "a"), ("s", "b")]), "b", "a relay or the source on another route")
        XCTAssertNotNil(routes.nextOpening(now: 0.5), "the waiting route opens again later")
    }

    func testRecoveryNeverJoinsAnotherStreamAndStopsWhenCancelled() {
        let routes = ViewerRecoveryRoutes<String>()
        routes.onFailure(target: "s", route: "a", now: 0)
        XCTAssertNil(pick(routes, 10, [("other", "x")]))
        routes.cancel()
        XCTAssertNil(pick(routes, 10, [("s", "a")]))
        XCTAssertNil(routes.nextOpening(now: 10))
    }

    func testOnlyAnActiveStreamLostWithoutItsEndRecovers() {
        XCTAssertTrue(ViewerRecovery.recovers(enabled: true, joined: true, sourceEnded: false, stoppedByUser: false, ended: false))
        XCTAssertFalse(ViewerRecovery.recovers(enabled: true, joined: false, sourceEnded: false, stoppedByUser: false, ended: false), "a join that never started")
        XCTAssertFalse(ViewerRecovery.recovers(enabled: true, joined: true, sourceEnded: true, stoppedByUser: false, ended: false), "the source ended it")
        XCTAssertFalse(ViewerRecovery.recovers(enabled: true, joined: true, sourceEnded: false, stoppedByUser: true, ended: false), "the user left")
        XCTAssertFalse(ViewerRecovery.recovers(enabled: false, joined: true, sourceEnded: false, stoppedByUser: false, ended: false), "control arm")
    }

    func testASilentRelayedParentIsClosedAfterFiveSecondsButNotWhilePaused() {
        var watch = RelayParentWatch(streamKbps: 300, now: 0)
        XCTAssertEqual(watch.tick(now: 4.9, bytes: 0, paused: false, armed: false, trickle: true), .fine)
        XCTAssertEqual(watch.tick(now: 5, bytes: 0, paused: false, armed: false, trickle: true), .silent)
        var paused = RelayParentWatch(streamKbps: 300, now: 0)
        XCTAssertEqual(paused.tick(now: 9, bytes: 0, paused: true, armed: true, trickle: true), .fine)
    }

    private func feed(_ watch: inout RelayParentWatch, kbps: Int, seconds: Double, paused: (Double) -> Bool = { _ in false },
                      armed: Bool = true, trickle: Bool = true) -> [RelayParentWatch.Verdict] {
        var verdicts: [RelayParentWatch.Verdict] = []
        var bytes: UInt64 = 0
        var t = 0.5
        while t <= seconds {
            bytes += UInt64(kbps * 1000 / 8 / 2)
            verdicts.append(watch.tick(now: t, bytes: bytes, paused: paused(t), armed: armed, trickle: trickle))
            t += 0.5
        }
        return verdicts
    }

    func testATrickleUnderAnEighthOfTheBitrateIsClosedAndAHealthyLinkIsNot() {
        var starved = RelayParentWatch(streamKbps: 300, now: 0)
        XCTAssertTrue(feed(&starved, kbps: 12, seconds: 5).contains { if case .trickle = $0 { return true }; return false })
        var healthy = RelayParentWatch(streamKbps: 300, now: 0)
        XCTAssertTrue(feed(&healthy, kbps: 300, seconds: 15).allSatisfy { $0 == .fine })
    }

    func testATrickleIsNotJudgedBeforeTheHeaderInAPausedWindowOrWithTheTestOff() {
        var early = RelayParentWatch(streamKbps: 300, now: 0)
        XCTAssertTrue(feed(&early, kbps: 12, seconds: 15, armed: false).allSatisfy { $0 == .fine }, "setup is not media")
        var paused = RelayParentWatch(streamKbps: 300, now: 0)
        XCTAssertTrue(feed(&paused, kbps: 12, seconds: 5, paused: { $0 == 2 }).allSatisfy { $0 == .fine }, "the window saw a pause")
        var off = RelayParentWatch(streamKbps: 300, now: 0)
        XCTAssertTrue(feed(&off, kbps: 12, seconds: 15, trickle: false).allSatisfy { $0 == .fine }, "control arm")
    }

    func testRelayingPausesOnALowUnpluggedBatteryOrLowPowerMode() {
        XCTAssertTrue(RelayBatteryPause.paused(batteryPercent: 19, charging: false, lowPowerMode: false))
        XCTAssertFalse(RelayBatteryPause.paused(batteryPercent: 20, charging: false, lowPowerMode: false))
        XCTAssertFalse(RelayBatteryPause.paused(batteryPercent: 19, charging: true, lowPowerMode: false))
        XCTAssertTrue(RelayBatteryPause.paused(batteryPercent: 100, charging: true, lowPowerMode: true))
        XCTAssertFalse(RelayBatteryPause.paused(batteryPercent: -1, charging: false, lowPowerMode: false), "unknown level")
    }

    private func offer(_ summary: UInt8, audioOnly: Bool = false) -> DiscoveryAnnouncement {
        DiscoveryAnnouncement(nodeIdPrefix: Data([1, 2, 3, 4, 5, 6]), flags: DiscoveryAnnouncement.flagStreamAvailable,
                              capabilitySummary: summary, streamToken: 0x8000_0001, routeCost: 0,
                              streamWidth: audioOnly ? 0 : 426, streamHeight: audioOnly ? 0 : 240, streamFps: audioOnly ? 0 : 15,
                              streamBitrateKbps: 200)
    }

    func testOnlyStreamsThisDeviceCanDecodeArePlayable() {
        let vp9 = NodeCapabilities.codecVP9, av1 = NodeCapabilities.codecAV1
        XCTAssertTrue(StreamPlayability.playable(offer: offer(vp9), decodeMask: vp9, audioLive: true))
        XCTAssertFalse(StreamPlayability.playable(offer: offer(av1), decodeMask: vp9, audioLive: true), "AV1 without an AV1 decoder")
        XCTAssertTrue(StreamPlayability.playable(offer: offer(av1), decodeMask: vp9 | av1, audioLive: true))
        XCTAssertFalse(StreamPlayability.playable(offer: offer(0), decodeMask: vp9 | av1, audioLive: true), "no codec advertised")
        XCTAssertTrue(StreamPlayability.playable(offer: offer(AudioLive.summaryAudioOnly, audioOnly: true), decodeMask: 0, audioLive: true))
        XCTAssertFalse(StreamPlayability.playable(offer: offer(AudioLive.summaryAudioOnly, audioOnly: true), decodeMask: 0, audioLive: false))
        XCTAssertFalse(StreamPlayability.playable(offer: offer(AudioLive.summaryAudioOnly | vp9), decodeMask: vp9, audioLive: true), "malformed")
    }

    func testEndLiveAsksOnlyWhileSomeoneWatches() {
        XCTAssertFalse(LiveEndConfirm.asks(viewers: 0, enabled: true))
        XCTAssertTrue(LiveEndConfirm.asks(viewers: 1, enabled: true))
        XCTAssertFalse(LiveEndConfirm.asks(viewers: 3, enabled: false), "control arm")
    }

    func testTheBroadcasterIsToldWhenNobodyWatchesWhilePausedAndWithBluetoothOff() {
        XCTAssertNil(LiveStatusLine.video(running: false, paused: false, viewers: 0, bluetoothOff: false))
        XCTAssertNotNil(LiveStatusLine.video(running: true, paused: false, viewers: 0, bluetoothOff: false), "waiting")
        XCTAssertNil(LiveStatusLine.video(running: true, paused: false, viewers: 2, bluetoothOff: false), "watched: the top bar says it")
        XCTAssertNotNil(LiveStatusLine.video(running: true, paused: true, viewers: 2, bluetoothOff: false), "paused")
        XCTAssertNotEqual(LiveStatusLine.video(running: true, paused: true, viewers: 2, bluetoothOff: true),
                          LiveStatusLine.video(running: true, paused: true, viewers: 2, bluetoothOff: false), "Bluetooth off comes first")
    }

    func testAHiddenLivestreamStaysHiddenAfterRereadingAndBlocksNobody() throws {
        let shown = offer(NodeCapabilities.codecVP9)
        var other = offer(NodeCapabilities.codecVP9); other.nodeIdPrefix = Data([9, 9, 9, 9, 9, 9])
        var list = BlockList()
        XCTAssertTrue(list.hideStream(route: BlockedStreams.routeKey(shown)))
        XCTAssertFalse(list.hideStream(route: BlockedStreams.routeKey(shown)), "once")
        let reread = try BlockList.decode(list.encoded())
        XCTAssertTrue(reread.people.isEmpty, "hiding blocks nobody")
        let left = BlockedStreams.hide([shown, other], offer: { $0 }, blockedPrefixes: reread.hiddenPrefixes, hiddenRoutes: reread.reportedRoutes,
                                       recognised: { _ in nil }, hiddenRoute: { _ in false })
        XCTAssertEqual(left.map(BlockedStreams.routeKey), [BlockedStreams.routeKey(other)])
    }

    private func streamOffer(_ prefix: UInt8, cost: UInt8, gatt: Bool) -> DiscoveryAnnouncement {
        DiscoveryAnnouncement(nodeIdPrefix: Data(repeating: prefix, count: 6),
                              flags: DiscoveryAnnouncement.flagStreamAvailable | (gatt ? DiscoveryAnnouncement.flagGattTransport : 0),
                              capabilitySummary: 1, streamToken: 7, routeCost: cost)
    }

    func testRecoveryTriesTheFewestRelaysFirstThenTheLostRoutesTransport() {
        let source = streamOffer(9, cost: 0, gatt: false)
        let relayGatt = streamOffer(1, cost: 1, gatt: true), relayL2cap = streamOffer(2, cost: 1, gatt: false)
        let farRelay = streamOffer(3, cost: 2, gatt: true)
        let order = ViewerRecovery.ordered([farRelay, relayL2cap, relayGatt, source], offer: { $0 }, preferredTransport: .gatt)
        XCTAssertEqual(order.compactMap { $0.nodeIdPrefix.first }, [9, 1, 2, 3])
    }

    func testAFailedRouteIsTriedAgainOnlyAfterItsOfferIsSeenAgain() {
        let routes = ViewerRecoveryRoutes<String>()
        routes.onFailure(target: "s", route: "a", now: 100)
        func pickSeen(_ route: String, seen: TimeInterval) -> String? {
            routes.candidate(now: 100.5, listed: [("s", route)] as [Row], matches: { $0 == $1.stream }, route: { $0.route },
                             seenAt: { _ in seen })?.route
        }
        XCTAssertNil(pickSeen("a", seen: 99.8), "the cached offer from before the loss")
        XCTAssertEqual(pickSeen("a", seen: 100.2), "a", "a fresh sighting after the loss")
        XCTAssertEqual(pickSeen("b", seen: 1), "b", "a route that never failed needs no fresh sighting")
    }

    func testAWithdrawnRouteWaitsThirtySecondsUnlessItsCapacityGenerationMovesOn() {
        let routes = ViewerRecoveryRoutes<String>()
        routes.onFailure(target: "s", route: "a", now: 0)
        routes.onWithdrawn(target: "s", route: "a", generation: 5, now: 0)
        func pickAfter(_ table: ViewerRecoveryRoutes<String>, _ now: TimeInterval, generation: UInt8) -> String? {
            table.candidate(now: now, listed: [("s", "a")] as [Row], matches: { $0 == $1.stream }, route: { $0.route },
                             generation: { _ in generation })?.route
        }
        XCTAssertNil(pickAfter(routes, 1, generation: 5), "not the 0 s retry of a first loss")
        XCTAssertNil(pickAfter(routes, 29.9, generation: 5))
        XCTAssertEqual(pickAfter(routes, 30, generation: 5), "a")
        let freed = ViewerRecoveryRoutes<String>()
        freed.onFailure(target: "s", route: "a", now: 0)
        freed.onWithdrawn(target: "s", route: "a", generation: 5, now: 0)
        XCTAssertNil(pickAfter(freed, 2, generation: 5))
        XCTAssertEqual(pickAfter(freed, 2, generation: 6), "a", "the parent's capacity changed: retried at once")
        XCTAssertTrue(ViewerRecovery.capacityAdvanced(from: 127, to: 0), "the 7-bit generation wraps")
        XCTAssertFalse(ViewerRecovery.capacityAdvanced(from: 5, to: 4), "an older generation")
    }

    func testAWithdrawnRouteLooksForAnotherWayEvenBeforeTheStreamStarted() {
        XCTAssertTrue(ViewerRecovery.recovers(enabled: true, joined: false, sourceEnded: false, stoppedByUser: false, ended: false,
                                              routeWithdrawn: true))
        XCTAssertFalse(ViewerRecovery.recovers(enabled: true, joined: false, sourceEnded: true, stoppedByUser: false, ended: false,
                                               routeWithdrawn: true), "the source ended it")
        XCTAssertFalse(ViewerRecovery.recovers(enabled: true, joined: false, sourceEnded: false, stoppedByUser: true, ended: false,
                                               routeWithdrawn: true), "the user left")
        XCTAssertFalse(ViewerRecovery.recovers(enabled: false, joined: false, sourceEnded: false, stoppedByUser: false, ended: false,
                                               routeWithdrawn: true), "control arm")
    }
}
