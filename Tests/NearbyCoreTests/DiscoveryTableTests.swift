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
