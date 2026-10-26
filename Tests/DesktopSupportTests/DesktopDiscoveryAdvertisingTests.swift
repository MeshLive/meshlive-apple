import XCTest
import NearbyCore
@testable import DesktopSupport

final class DesktopDiscoveryAdvertisingTests: XCTestCase {
    private final class Radio {
        let identity = SoftwareSigningIdentity()
        let pins = OpeningPins()
        var now: Int64 = 0
        var delay: Int64 = 3_000
        var published: [DiscoveryAnnouncement?] = []
        var jobs: [(at: Int64, run: () -> Void)] = []
        var desired: DiscoveryAnnouncement?
        var presence: DesktopDiscoveryAdvertising.CallPresence?
        lazy var advertising: DesktopDiscoveryAdvertising = DesktopDiscoveryAdvertising(
            pins: pins, nowMs: { [unowned self] in self.now }, silenceMs: { [unowned self] in self.delay },
            schedule: { [unowned self] delay, run in self.jobs.append((self.now + delay, run)) },
            publish: { [unowned self] in self.published.append($0) },
            refresh: { [unowned self] in self.advertising.advertise(self.desired, callPresence: self.presence) })

        var current: DiscoveryAnnouncement? { published.last ?? nil }
        func show(_ announcement: DiscoveryAnnouncement?, _ presence: DesktopDiscoveryAdvertising.CallPresence? = nil) {
            desired = announcement; self.presence = presence
            advertising.advertise(announcement, callPresence: presence)
        }
        func advance(to time: Int64) {
            now = time
            let due = jobs.filter { $0.at <= time }
            jobs.removeAll { $0.at <= time }
            due.forEach { $0.run() }
        }
        func entry(_ epoch: Int64) -> OpeningEntry {
            RotatingDiscoveryIds.ownEntry(presenceKey: Data(repeating: 9, count: 32), nodeId: identity.nodeId.bytes,
                                         epoch: epoch, role: RotatingDiscoveryIds.roleCallOffer)
        }
        func call(_ entry: OpeningEntry? = nil) -> DiscoveryAnnouncement {
            var offer = DiscoveryAnnouncement(nodeIdPrefix: entry?.rdi ?? identity.nodeId.prefix,
                                               flags: DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable | DiscoveryAnnouncement.flagGattTransport,
                                               capabilitySummary: NodeCapabilities.codecVP9, streamToken: 0, routeCost: 0)
            offer.rotating = entry != nil
            return offer
        }
        func media(viewer: Bool = false, relay: Bool = false) -> DiscoveryAnnouncement {
            DiscoveryAnnouncement(nodeIdPrefix: identity.nodeId.prefix,
                                  flags: (viewer ? DiscoveryAnnouncement.flagAcceptingConnections : DiscoveryAnnouncement.flagStreamAvailable)
                                    | DiscoveryAnnouncement.flagGattTransport | (relay ? DiscoveryAnnouncement.flagRelayCapable : 0),
                                  capabilitySummary: NodeCapabilities.codecVP9, streamToken: 0x92345678, routeCost: relay ? 1 : 0,
                                  streamWidth: viewer ? 0 : 426, streamHeight: viewer ? 0 : 240,
                                  streamFps: viewer ? 0 : 15, streamBitrateKbps: 200)
        }
    }

    func testBroadcastViewerAndForwarderStayAdvertisedAcrossRepeatedBoundaryChecks() {
        for (viewer, relay) in [(false, false), (true, false), (false, true)] {
            let radio = Radio(), offer: DiscoveryAnnouncement
            let entry = radio.entry(10)
            radio.show(radio.call(entry), .rotating(entry))
            offer = radio.media(viewer: viewer, relay: relay)
            radio.show(offer)
            for epoch in 11...14 {
                radio.advance(to: Int64(epoch - 10) * 900_000)
                radio.show(offer)
                XCTAssertEqual(radio.current, offer)
            }
            XCTAssertFalse(radio.published.contains { $0 == nil }, "A call-ID boundary must not blank a media role")
            XCTAssertTrue(radio.pins.pinned(elapsedMs: radio.now).isEmpty)
        }
    }

    func testCallRotationStopsFirstAndPinsTheNewOpeningOnlyAfterSilence() {
        let radio = Radio(), first = radio.entry(10)
        let next = radio.entry(11)
        radio.show(radio.call(first), .rotating(first))
        radio.now = 900_000
        radio.show(radio.call(next), .rotating(next))
        XCTAssertNil(radio.current)
        XCTAssertFalse(radio.pins.pinned(elapsedMs: radio.now).contains(next))
        radio.advance(to: 901_000)
        radio.show(radio.call(next), .rotating(next))
        radio.advance(to: 902_999)
        XCTAssertNil(radio.current)
        radio.advance(to: 903_000)
        XCTAssertEqual(radio.current, radio.call(next))
        XCTAssertTrue(radio.pins.pinned(elapsedMs: radio.now).contains(next))
        radio.show(radio.call(next), .rotating(next))
        XCTAssertEqual(radio.current, radio.call(next), "An in-epoch refresh must not start another silence")
    }

    func testFirstVisibleByHandleWindowReturnsToRotatingPresence() {
        let radio = Radio()
        radio.show(radio.call(), .fixed)
        let next = radio.entry(11)
        radio.show(radio.call(next), .rotating(next))
        XCTAssertNil(radio.current, "No earlier rotating advert is needed to expire the fixed-ID window")
        radio.advance(to: radio.delay)
        XCTAssertEqual(radio.current, radio.call(next))
    }

    func testEnteringAndRestartingVisibleWindowUsesBreakBeforeMake() {
        let radio = Radio(), entry = radio.entry(10)
        radio.show(radio.call(entry), .rotating(entry))
        radio.advertising.requestCallRestart()
        radio.show(radio.call(), .fixed)
        XCTAssertNil(radio.current)
        radio.advance(to: 3_000)
        XCTAssertEqual(radio.current, radio.call())
        radio.advertising.requestCallRestart()
        radio.show(radio.call(), .fixed)
        XCTAssertNil(radio.current)
        radio.advance(to: 6_000)
        XCTAssertEqual(radio.current, radio.call())
    }

    func testPendingCallRotationCannotReplaceAStreamOrViewerRequest() {
        for viewer in [false, true] {
            let radio = Radio(), first = radio.entry(10)
            let next = radio.entry(11)
            radio.show(radio.call(first), .rotating(first))
            radio.show(radio.call(next), .rotating(next))
            let media = radio.media(viewer: viewer)
            radio.show(media)
            let before = radio.published
            radio.advance(to: 8_000)
            XCTAssertEqual(radio.published, before)
            XCTAssertEqual(radio.current, media)
            XCTAssertFalse(radio.pins.pinned(elapsedMs: radio.now).contains(next))
        }
    }

    func testPendingCallbackUsesLatestEpochAndPrivacyChoice() {
        let radio = Radio(), first = radio.entry(10)
        let neverAdvertised = radio.entry(11), latest = radio.entry(12)
        radio.show(radio.call(first), .rotating(first))
        radio.show(radio.call(neverAdvertised), .rotating(neverAdvertised))
        radio.show(radio.call(latest), .rotating(latest))
        radio.advance(to: 3_000)
        XCTAssertEqual(radio.current, radio.call(latest))
        XCTAssertFalse(radio.pins.pinned(elapsedMs: radio.now).contains(neverAdvertised))
        radio.show(radio.call(radio.entry(13)), .rotating(radio.entry(13)))
        radio.show(radio.call(), .fixed)
        radio.advance(to: 6_000)
        XCTAssertEqual(radio.current, radio.call())
    }

    func testAnOldCallbackCannotShortenANewerRotationAfterAMediaRole() {
        let radio = Radio(), first = radio.entry(10)
        let next = radio.entry(11)
        radio.show(radio.call(first), .rotating(first))
        radio.show(radio.call(next), .rotating(next))
        radio.advance(to: 1_000)
        radio.show(radio.media())
        radio.advance(to: 1_100)
        radio.show(radio.call(next), .rotating(next))
        radio.advance(to: 3_000)
        XCTAssertNil(radio.current, "The first rotation's callback must not publish the newer request early")
        radio.advance(to: 4_100)
        XCTAssertEqual(radio.current, radio.call(next))
    }

    func testQuitInvalidatesDelayedAdvertisingAndOpeningPublication() {
        let radio = Radio(), first = radio.entry(10)
        let next = radio.entry(11)
        radio.show(radio.call(first), .rotating(first))
        radio.show(radio.call(next), .rotating(next))
        radio.advertising.stop()
        let stopped = radio.published
        radio.advance(to: 100_000)
        XCTAssertEqual(radio.published, stopped)
        XCTAssertNil(radio.current)
        XCTAssertTrue(radio.pins.pinned(elapsedMs: radio.now).isEmpty)
    }

    func testReturningFromLongMediaSessionDoesNotRenewAnOldOpeningGracePeriod() {
        let radio = Radio(), first = radio.entry(10)
        let next = radio.entry(11)
        radio.show(radio.call(first), .rotating(first))
        radio.advance(to: 1_000)
        radio.show(radio.media())
        radio.advance(to: 70_000)
        radio.show(radio.call(next), .rotating(next))
        radio.advance(to: 73_000)
        XCTAssertEqual(radio.pins.pinned(elapsedMs: radio.now), [next])
    }

    func testSilenceIncludesBothProtocolBounds() {
        for delay: Int64 in [1_000, 8_000] {
            let radio = Radio(), first = radio.entry(10)
            radio.delay = delay
            let next = radio.entry(11)
            radio.show(radio.call(first), .rotating(first))
            radio.show(radio.call(next), .rotating(next))
            radio.advance(to: delay - 1)
            XCTAssertNil(radio.current)
            radio.advance(to: delay)
            XCTAssertEqual(radio.current, radio.call(next))
        }
    }

    func testAnOpeningThatDoesNotMatchTheAdvertFailsClosed() {
        let radio = Radio(), first = radio.entry(10)
        let next = radio.entry(11)
        radio.show(radio.call(first), .rotating(first))
        radio.show(radio.call(next), .rotating(first))
        XCTAssertNil(radio.current)
        radio.advance(to: 100_000)
        XCTAssertNil(radio.current)
        XCTAssertFalse(radio.pins.pinned(elapsedMs: radio.now).contains(next))
    }
}
