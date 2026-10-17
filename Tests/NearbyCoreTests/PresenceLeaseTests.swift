import XCTest
@testable import NearbyCore

/// Android PresenceLeasesTest (same vectors; P = 00..1f is a migration input only, node a1b2...8f90, epoch 1990656 =
/// 2026-10-10T00:00Z, day 20736) and the PresenceSession rules.
final class PresenceLeaseTests: XCTestCase {
    let presenceKey = Data((0..<32).map { UInt8($0) })
    let nodeId = Data(hex: "a1b2c3d4e5f60718293a4b5c6d7e8f90")!
    let epoch: Int64 = 1_990_656
    let day: Int64 = 20_736

    private func own(_ key: Data, _ node: Data, _ e: Int64, _ role: UInt8) -> OpeningEntry {
        RotatingDiscoveryIds.entry(saltKey: PresenceLeases.legacyLeaseKey(presenceKey: key, day: PresenceLeases.dayOf(e)), nodeId: node, epoch: e, role: role)
    }
    private func delivery(_ key: Data, _ generation: UInt32, _ e: Int64) -> DiscoveryExchange.PresenceLease {
        PresenceLeases.delivery(dayKeys: DayKeyWindow.migrated(presenceKey: key, epoch: e), generation: generation, epoch: e)!
    }

    func testLeaseKeysAndOwnIdsMatchTheAndroidVectors() {
        XCTAssertEqual(PresenceLeases.leaseDomain.hex, "426c7565746f6f7468566964656f4d6573682f446973636f766572792f4c656173652f3200")
        XCTAssertEqual(PresenceLeases.dayOf(epoch), day)
        XCTAssertEqual(PresenceLeases.dayOf(epoch + 95), day)
        XCTAssertEqual(PresenceLeases.dayOf(epoch + 96), day + 1)
        XCTAssertEqual(PresenceLeases.legacyLeaseKey(presenceKey: presenceKey, day: day).hex, "6484923eb4b0b044dfb4d38feda471b389ec3b18e6fa199a41e22642f7f786b5")
        XCTAssertEqual(PresenceLeases.legacyLeaseKey(presenceKey: presenceKey, day: day + 1).hex, "c32a563c90e92cb68e786a09357ba1b499ae20c8f122be7b10863ae635b016c7")
        let entry = own(presenceKey, nodeId, epoch, 0)
        XCTAssertEqual(entry.salt.hex, "81b9be731a7cdddd1954e543fb9b712dd963a24d08dcf1876ed219d00cab8ae9")
        XCTAssertEqual(entry.rdi.hex, "fecba64983fd")
        XCTAssertEqual(PresenceLeases.ownEntry(dayKeys: DayKeyWindow.migrated(presenceKey: presenceKey, epoch: epoch), nodeId: nodeId, epoch: epoch, role: 0), entry)
    }

    func testBdx1LeaseAndOfferBytes() throws {
        XCTAssertEqual(try DiscoveryExchange.encode(.recognitionOffer).hex, "424458310200")
        XCTAssertEqual(try DiscoveryExchange.encode(.opening([])).hex, "424458310100")
        let lease = DiscoveryExchange.PresenceLease(generation: 1, senderEpoch: UInt32(epoch), firstDay: UInt32(day),
                                                    leases: [PresenceLeases.legacyLeaseKey(presenceKey: presenceKey, day: day),
                                                             PresenceLeases.legacyLeaseKey(presenceKey: presenceKey, day: day + 1)])
        let bytes = try DiscoveryExchange.encode(.presenceLease(lease))
        XCTAssertEqual(bytes.hex, "424458310300000001001e600000005100026484923eb4b0b044dfb4d38feda471b389ec3b18e6fa199a41e22642f7f786b5"
                       + "c32a563c90e92cb68e786a09357ba1b499ae20c8f122be7b10863ae635b016c7")
        XCTAssertEqual(try DiscoveryExchange.decode(bytes), .presenceLease(lease))
        let full = delivery(presenceKey, 1, epoch)
        XCTAssertEqual(full.leases.count, 28)
        XCTAssertEqual(try DiscoveryExchange.encode(.presenceLease(full)).count, 4 + 1 + 13 + 28 * 32)
        for bad in ["424458310500", "424458310201", "42445831020000", "4244583101"] {
            XCTAssertThrowsError(try DiscoveryExchange.decode(Data(hex: bad)!), bad)
        }
    }

    func testReceiverReplacesOnHigherMergesOnEqualAndIgnoresLowerGenerations() {
        let first = ContactPresence.receive(stored: nil, nodeId: nodeId, lease: delivery(presenceKey, 2, epoch), myEpoch: epoch - 3, now: 1)
        XCTAssertEqual(first.skewEpochs, 3)
        XCTAssertEqual(Set(first.leasesByDay.keys), Set(day...(day + 27)))
        let refreshed = ContactPresence.receive(stored: first, nodeId: nodeId, lease: delivery(presenceKey, 2, epoch + 5 * 96), myEpoch: epoch + 5 * 96, now: 2)
        XCTAssertEqual(Set(refreshed.leasesByDay.keys), Set((day + 5)...(day + 32)))
        let other = Data(repeating: 9, count: 32)
        XCTAssertEqual(ContactPresence.receive(stored: refreshed, nodeId: nodeId, lease: delivery(other, 1, epoch), myEpoch: epoch, now: 3), refreshed)
        let reset = ContactPresence.receive(stored: refreshed, nodeId: nodeId, lease: delivery(other, 3, epoch), myEpoch: epoch, now: 4)
        XCTAssertEqual(reset.generation, 3)
        XCTAssertEqual(reset.leasesByDay[day], PresenceLeases.legacyLeaseKey(presenceKey: other, day: day))
        XCTAssertEqual(reset.leasesByDay.count, 28)
        let far = ContactPresence.receive(stored: nil, nodeId: nodeId, lease: delivery(presenceKey, 1, epoch + 10_000), myEpoch: epoch, now: 0)
        XCTAssertEqual(far.skewEpochs, ContactPresence.maxSkewEpochs)
    }

    func testTwoKeysUnderOneGenerationReplaceInsteadOfMixing() {
        let stored = ContactPresence.receive(stored: nil, nodeId: nodeId, lease: delivery(presenceKey, 4, epoch), myEpoch: epoch, now: 1)
        let newKey = Data((0..<32).map { UInt8($0 + 50) })
        let next = ContactPresence.receive(stored: stored, nodeId: nodeId, lease: delivery(newKey, 4, epoch + 96), myEpoch: epoch, now: 2)
        XCTAssertEqual(Set(next.leasesByDay.keys), Set((day + 1)...(day + 28)))
        for (d, key) in next.leasesByDay { XCTAssertEqual(key, PresenceLeases.legacyLeaseKey(presenceKey: newKey, day: d)) }
    }

    func testRecognitionUsesTheLearnedSkewAndAOneEpochWindow() {
        let contact = ContactPresence.receive(stored: nil, nodeId: nodeId, lease: delivery(presenceKey, 1, epoch + 2), myEpoch: epoch, now: 0)
        let table = RecognitionTable()
        table.rebuild([contact], myEpoch: epoch, now: 1)
        XCTAssertEqual(table.size, 6)
        let centre = epoch + 2
        for e in [centre - 1, centre, centre + 1] {
            XCTAssertEqual(table.lookup(own(presenceKey, nodeId, e, 0).rdi), [RecognitionTable.Hit(contact: nodeId, epoch: e, role: 0)])
        }
        XCTAssertTrue(table.lookup(own(presenceKey, nodeId, centre - 2, 0).rdi).isEmpty)
        XCTAssertTrue(table.lookup(own(presenceKey, nodeId, centre, 2).rdi).isEmpty, "role 2 is never recognised")
        table.rebuild([contact], myEpoch: epoch, now: RecognitionTable.staleAfter + 1)
        XCTAssertEqual(table.size, 22)
        XCTAssertEqual(table.lookup(own(presenceKey, nodeId, centre + 8, 1).rdi).count, 1)
        XCTAssertTrue(table.lookup(own(presenceKey, nodeId, centre - 8, 1).rdi).isEmpty)
        // A lease does not resolve IDs before its first day (RD5) and expires after its 28 days.
        let delivered = ContactPresence.receive(stored: nil, nodeId: nodeId, lease: delivery(presenceKey, 1, epoch + 96), myEpoch: epoch + 96, now: 0)
        table.rebuild([delivered], myEpoch: epoch + 96, now: 0)
        XCTAssertTrue(table.lookup(own(presenceKey, nodeId, epoch + 95, 0).rdi).isEmpty)
        XCTAssertEqual(table.lookup(own(presenceKey, nodeId, epoch + 96, 0).rdi).count, 1)
        table.rebuild([contact], myEpoch: epoch + 28 * PresenceLeases.epochsPerDay + 10, now: 0)
        XCTAssertEqual(table.size, 0)
    }

    func testTheDayKeyWindow() {
        var n = 0
        let counter: () -> Data = { n += 1; return Data(repeating: UInt8(n & 0xff), count: 32) }
        let created = DayKeyWindow.fresh(epoch: epoch, newKey: counter)
        XCTAssertEqual(created.keys.sorted(), Array(day...(day + 27)), "today plus 27 (yesterday too only after day 0's first epoch)")
        XCTAssertEqual(DayKeyWindow.roll(created, epoch: epoch + 95, newKey: counter), created)
        let nextDay = DayKeyWindow.roll(created, epoch: epoch + 96, newKey: counter)
        XCTAssertEqual(nextDay.keys.sorted(), Array(day...(day + 28)), "yesterday kept at the first epoch of a day")
        let later = DayKeyWindow.roll(nextDay, epoch: epoch + 97, newKey: counter)
        XCTAssertEqual(later.keys.sorted(), Array((day + 1)...(day + 28)))
        for d in (day + 1)...(day + 27) { XCTAssertEqual(later[d], created[d], "existing keys are never replaced") }
        let back = DayKeyWindow.roll(created, epoch: epoch + 40 * 96 + 5, newKey: counter)
        XCTAssertEqual(back.keys.sorted(), Array((day + 40)...(day + 67)))
        XCTAssertTrue(back.values.allSatisfy { key in !created.values.contains(key) })
        XCTAssertNil(ContactPresence(nodeId: nodeId, generation: 1, leasesByDay: [day: presenceKey], skewEpochs: 0, receivedAt: 0).pruned(myEpoch: epoch + 3 * 96))
    }

    func testPresenceSessionRules() {
        let a = PresenceSession(localEligible: true), b = PresenceSession(localEligible: true)
        XCTAssertEqual(a.start(), [.sendOffer])
        XCTAssertEqual(b.onRecord(.recognitionOffer, peerVerifiedNow: true), [])
        XCTAssertEqual(b.start(), [.sendOffer, .sendLease], "B offered after A: its lease follows at once")
        XCTAssertEqual(a.onRecord(.recognitionOffer, peerVerifiedNow: true), [.sendLease])
        let lease = delivery(presenceKey, 1, epoch)
        XCTAssertEqual(a.onRecord(.presenceLease(lease), peerVerifiedNow: true), [.storeLease(lease)])
        XCTAssertEqual(a.onRecord(.presenceLease(lease), peerVerifiedNow: true), [.reject("duplicate lease")])
        // One-sided verification gives nothing: an ineligible side never offers and refuses to store.
        let stranger = PresenceSession(localEligible: false)
        XCTAssertEqual(stranger.start(), [])
        XCTAssertEqual(stranger.onRecord(.recognitionOffer, peerVerifiedNow: false), [])
        XCTAssertEqual(stranger.onRecord(.presenceLease(lease), peerVerifiedNow: false), [.reject("lease without both offers")])
        let unverified = PresenceSession(localEligible: true)
        _ = unverified.start(); _ = unverified.onRecord(.recognitionOffer, peerVerifiedNow: false)
        XCTAssertEqual(unverified.onRecord(.presenceLease(lease), peerVerifiedNow: false), [.reject("peer is not a verified contact")])
    }
}
