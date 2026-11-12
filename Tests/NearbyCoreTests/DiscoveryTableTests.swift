import XCTest
@testable import NearbyCore

/// Discovery rows are keyed by node prefix + kind + route token, not by the rotating radio address.
final class DiscoveryTableTests: XCTestCase {
    let prefix = Data([0x10, 0x0f, 0x3e, 0x37, 0xbf, 0x04])
    private func callOffer(_ p: Data? = nil) -> DiscoveryAnnouncement {
        DiscoveryAnnouncement(nodeIdPrefix: p ?? prefix, flags: DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable,
                              capabilitySummary: 3, streamToken: 0, routeCost: 0)
    }
    private func streamOffer(token: UInt32, cost: UInt8 = 0) -> DiscoveryAnnouncement {
        DiscoveryAnnouncement(nodeIdPrefix: prefix, flags: DiscoveryAnnouncement.flagStreamAvailable, capabilitySummary: 1, streamToken: token, routeCost: cost)
    }

    func testNewAddressForTheSamePrefixReplacesTheRowInsteadOfAddingOne() {
        let table = DiscoveryTable(window: 8)
        let oldAddress = UUID(), newAddress = UUID()
        XCTAssertTrue(table.observe(handle: oldAddress, announcement: callOffer(), rssi: -60, isIPhone: false, now: 0).isNew)
        let change = table.observe(handle: newAddress, announcement: callOffer(), rssi: -58, isIPhone: false, now: 2)
        XCTAssertFalse(change.isNew); XCTAssertTrue(change.handleReplaced); XCTAssertFalse(change.listChanged)
        XCTAssertEqual(table.entries.count, 1)
        let row = DiscoveryKey(callOffer()).rowId
        XCTAssertEqual(table.entry(rowId: row)?.handle, newAddress, "connect uses the most recent peripheral")
        XCTAssertEqual(table.entry(rowId: row)?.firstSeen, 0)
        // A late report from the old address takes the row back only as the most recent sighting.
        table.observe(handle: oldAddress, announcement: callOffer(), rssi: -70, isIPhone: false, now: 3)
        XCTAssertEqual(table.entries.count, 1); XCTAssertEqual(table.entry(rowId: row)?.handle, oldAddress)
    }

    func testRowsExpireWhenNotReSeen() {
        let table = DiscoveryTable(window: 8)
        table.observe(handle: UUID(), announcement: callOffer(), rssi: -60, isIPhone: false, now: 0)
        let other = Data([1, 2, 3, 4, 5, 6])
        table.observe(handle: UUID(), announcement: callOffer(other), rssi: -60, isIPhone: false, now: 5)
        XCTAssertTrue(table.expire(now: 8).isEmpty)
        XCTAssertEqual(table.expire(now: 8.5), [DiscoveryKey(callOffer()).rowId])
        XCTAssertEqual(table.entries.count, 1)
        XCTAssertEqual(table.expire(now: 14).count, 1)
        XCTAssertTrue(table.entries.isEmpty); XCTAssertTrue(table.liveHandles.isEmpty)
    }

    func testRowIdIsStableAndDistinguishesKindAndToken() {
        let call = DiscoveryKey(callOffer()), s1 = DiscoveryKey(streamOffer(token: 0x80000001)), s2 = DiscoveryKey(streamOffer(token: 0x80000002))
        XCTAssertEqual(call.rowId, DiscoveryKey(callOffer()).rowId)
        XCTAssertEqual(Set([call.rowId, s1.rowId, s2.rowId]).count, 3)
        XCTAssertEqual(s1.rowId, DiscoveryKey(streamOffer(token: 0x80000001, cost: 2)).rowId, "route cost changes keep the row")
        XCTAssertEqual(call.kind, .call); XCTAssertEqual(s1.kind, .stream)
    }

    func testAnnouncementChangesUpdateTheRowAndAnAddressSwitchingRolesDropsItsOldRow() {
        let table = DiscoveryTable(window: 8)
        let address = UUID()
        table.observe(handle: address, announcement: streamOffer(token: 7), rssi: -60, isIPhone: false, now: 0)
        XCTAssertTrue(table.observe(handle: address, announcement: streamOffer(token: 7, cost: 1), rssi: -60, isIPhone: false, now: 1).announcementChanged)
        XCTAssertEqual(table.entries.count, 1)
        // The same address now advertises a call offer: one advertisement per address, so the stream row goes.
        let change = table.observe(handle: address, announcement: callOffer(), rssi: -60, isIPhone: false, now: 2)
        XCTAssertTrue(change.isNew); XCTAssertEqual(change.removedRows, [DiscoveryKey(streamOffer(token: 7)).rowId])
        XCTAssertEqual(table.entries.count, 1)
        // ...but a row already taken over by another address is kept.
        let a = UUID(), b = UUID()
        table.observe(handle: a, announcement: streamOffer(token: 9), rssi: -60, isIPhone: false, now: 3)
        table.observe(handle: b, announcement: streamOffer(token: 9), rssi: -60, isIPhone: false, now: 4)
        XCTAssertTrue(table.observe(handle: a, announcement: callOffer(Data([9, 9, 9, 9, 9, 9])), rssi: -60, isIPhone: false, now: 5).removedRows.isEmpty)
        XCTAssertNotNil(table.entry(rowId: DiscoveryKey(streamOffer(token: 9)).rowId))
    }
}

/// Android's copied-ID warning (CopiedIdTracker, Design G): two phones sending one rotating ID at the same time.
final class CopiedIdTrackerTests: XCTestCase {
    private let id = Data([0x44, 0xe6, 0x9c, 0x0a, 0x7a, 0x7d])
    private let pcServices = ["180A", "C8D5A101-0000-1000-8000-00805F9B34FB"]

    private func hear(_ tracker: CopiedIdTracker, _ address: UUID, at ms: Int64, cost: UInt8 = 0,
                      form: CopiedIdTracker.TwinForm? = nil) {
        tracker.observe(id: id, address: address, routeCost: cost, nowMs: ms, form: form)
    }

    /// Two addresses taking turns every 100 ms from `from` until `until`.
    private func alternate(_ tracker: CopiedIdTracker, _ a: UUID, _ b: UUID, from: Int64 = 0, until: Int64,
                           costB: UInt8 = 0, formA: CopiedIdTracker.TwinForm? = nil, formB: CopiedIdTracker.TwinForm? = nil) {
        for t in stride(from: from, to: until, by: 200) {
            hear(tracker, a, at: t, form: formA)
            hear(tracker, b, at: t + 100, cost: costB, form: formB)
        }
    }

    /// One address after another, each heard for 1 s, 100 ms apart (an advertising restart each time).
    private func handOver(_ tracker: CopiedIdTracker, addresses: Int) {
        for index in 0..<addresses {
            let address = UUID(), start = Int64(index) * 1_100
            for t in stride(from: start, to: start + 1_000, by: 100) { hear(tracker, address, at: t) }
        }
    }

    func testTwoPhonesSendingOneIDAtOnceAreFlaggedOnTheSecondOccasion() {
        let tracker = CopiedIdTracker(), a = UUID(), b = UUID()
        alternate(tracker, a, b, until: 1_000)
        XCTAssertFalse(tracker.warned(id), "one occasion can be a coincidence")
        alternate(tracker, a, b, from: 1_000, until: 3_000)
        XCTAssertTrue(tracker.warned(id))
    }

    func testAPhoneMovingToANewAddressIsNotACopy() {
        let tracker = CopiedIdTracker()
        handOver(tracker, addresses: 4)
        XCTAssertFalse(tracker.warned(id), "each address stops before the next starts: a handover never interleaves")
    }

    func testTheOverlapControlArmRestoresTheTwoSecondRule() {
        let tracker = CopiedIdTracker()
        tracker.requireOverlap = false
        handOver(tracker, addresses: 4)
        XCTAssertTrue(tracker.warned(id), "without the overlap rule a quick handover counts")
    }

    func testARelaysMirrorOneHopFurtherIsNotACopy() {
        let tracker = CopiedIdTracker()
        alternate(tracker, UUID(), UUID(), until: 3_000, costB: 1)
        XCTAssertFalse(tracker.warned(id))
    }

    func testAPCsTwoAdvertisingSetsAreOneSender() {
        let form = CopiedIdTracker.twinForm(serviceUUIDs: pcServices)
        XCTAssertNotNil(form)
        let tracker = CopiedIdTracker()
        alternate(tracker, UUID(), UUID(), until: 3_000, formA: form, formB: form)
        XCTAssertFalse(tracker.warned(id), "identical sets with Device Information are the PC's twin")
        let control = CopiedIdTracker()
        control.pcPairExempt = false
        alternate(control, UUID(), UUID(), until: 3_000, formA: form, formB: form)
        XCTAssertTrue(control.warned(id), "the control arm warns for the twin too")
    }

    func testOnlyAnIdenticalPairWithDeviceInformationIsExempt() {
        XCTAssertNil(CopiedIdTracker.twinForm(serviceUUIDs: ["C8D5A101-0000-1000-8000-00805F9B34FB"]),
                     "a phone's compact offer carries no 0x180A")
        let form = CopiedIdTracker.twinForm(serviceUUIDs: pcServices)
        let different = CopiedIdTracker.twinForm(serviceUUIDs: pcServices + ["FEAA"])
        let tracker = CopiedIdTracker()
        alternate(tracker, UUID(), UUID(), until: 3_000, formA: form, formB: different)
        XCTAssertTrue(tracker.warned(id), "different lists are two senders")
        let three = CopiedIdTracker()
        let a = UUID(), b = UUID(), c = UUID()
        for t in stride(from: Int64(0), to: 3_000, by: 300) {
            hear(three, a, at: t, form: form); hear(three, b, at: t + 100, form: form); hear(three, c, at: t + 200, form: form)
        }
        XCTAssertTrue(three.warned(id), "a third address is never part of a twin")
    }

    func testAPCRestartingOneSetWithANewAddressStaysOneSender() {
        let form = CopiedIdTracker.twinForm(serviceUUIDs: pcServices)
        let tracker = CopiedIdTracker(), a = UUID()
        alternate(tracker, a, UUID(), until: 3_000, formA: form, formB: form)
        alternate(tracker, a, UUID(), from: 3_000, until: 6_000, formA: form, formB: form)
        XCTAssertFalse(tracker.warned(id), "the replaced address is superseded, not a third sender")
    }

    func testAnIDThatLeftTheAirIsForgotten() {
        let tracker = CopiedIdTracker()
        alternate(tracker, UUID(), UUID(), until: 3_000)
        XCTAssertTrue(tracker.warned(id))
        tracker.prune(nowMs: 3_000 + CopiedIdTracker.staleMs + 1)
        XCTAssertFalse(tracker.warned(id))
    }
}
