import XCTest
@testable import NearbyCore

/// The presence vault's storage discipline (Android PresenceVault): unreadable stores are never overwritten, the
/// generation floor keeps revocations final, pruning is stored, and resetting or reconciling contacts revokes.
final class PresenceVaultCoreTests: XCTestCase {
    let epoch: Int64 = 1_990_656

    final class Storage: PresenceVaultStorage {
        var data: Data?
        var readFails = false, writeFails = false
        var writes = 0
        func read() throws -> Data? { if readFails { throw ProtocolError.state("locked") }; return data }
        func write(_ value: Data) throws { if writeFails { throw ProtocolError.state("locked") }; data = value; writes += 1 }
        func delete() throws { data = nil }
        var state: PresenceVaultState? { data.flatMap { try? JSONDecoder().decode(PresenceVaultState.self, from: $0) } }
    }
    final class Floor: PresenceGenerationFloor {
        var value: UInt32 = 0
        func raise(to value: UInt32) { self.value = max(self.value, value) }
    }
    final class Clock { var now: TimeInterval = 100 }

    private func vault(_ storage: Storage, _ floor: Floor = Floor(), clock: Clock = Clock(), freshInstall: Bool = false,
                       onFresh: @escaping () -> Void = {}) -> PresenceVaultCore {
        PresenceVaultCore(storage: storage, floor: floor, epoch: { self.epoch }, uptime: { clock.now },
                          freshInstall: freshInstall, onFreshInstallHandled: onFresh)
    }
    private func node(_ byte: UInt8) throws -> NodeId { try NodeId(bytes: Data(repeating: byte, count: 16)) }

    func testAnUnreadableStoreIsNeverOverwrittenAndTheLoadIsRetried() throws {
        let stored = Storage()
        let first = vault(stored)
        XCTAssertNotNil(first.deliverLease(to: try node(1), epoch: epoch, verified: true))
        let saved = try XCTUnwrap(stored.data)

        stored.readFails = true
        let writesBefore = stored.writes
        let clock = Clock()
        let locked = vault(stored, clock: clock)
        XCTAssertFalse(locked.persistent)
        XCTAssertEqual(locked.loadState, .unreadable)
        XCTAssertNotNil(locked.dayKey(idEpoch: epoch, currentEpoch: epoch), "an ephemeral key keeps the phone advertising")
        XCTAssertNil(locked.deliverLease(to: try node(2), epoch: epoch, verified: true), "no lease from a vault that is not stored")
        XCTAssertFalse(locked.setCanSeeMe(try node(2), true))
        locked.maintain(epoch: epoch)
        XCTAssertEqual(stored.writes, writesBefore, "nothing is written over the unreadable store")
        XCTAssertEqual(stored.data, saved)

        stored.readFails = false
        clock.now += 1
        _ = locked.dayKey(idEpoch: epoch, currentEpoch: epoch)
        XCTAssertFalse(locked.persistent, "retried at most every 5 s")
        clock.now += PresenceVaultCore.retryInterval
        _ = locked.dayKey(idEpoch: epoch, currentEpoch: epoch)
        XCTAssertTrue(locked.persistent)
        XCTAssertTrue(locked.deliveredTo(try node(1)), "the stored vault came back intact")
    }

    func testARevocationThatCouldNotBeStoredCannotBeUndoneByTheOldCopy() throws {
        let stored = Storage(), floor = Floor()
        let first = vault(stored, floor)
        let contact = try node(1)
        XCTAssertNotNil(first.deliverLease(to: contact, epoch: epoch, verified: true))
        let old = try XCTUnwrap(stored.state)

        stored.writeFails = true
        XCTAssertTrue(first.forget(contact), "the revocation happens even though it cannot be stored")
        XCTAssertFalse(first.persistent, "the old keys left memory")
        XCTAssertGreaterThan(floor.value, old.generation)
        XCTAssertEqual(stored.state, old, "the stored copy still holds the revoked keys")

        stored.writeFails = false
        let restarted = vault(stored, floor)
        let now = try XCTUnwrap(stored.state)
        XCTAssertTrue(restarted.persistent)
        XCTAssertGreaterThanOrEqual(now.generation, floor.value)
        XCTAssertGreaterThan(now.generation, old.generation)
        XCTAssertTrue(Set(now.dayKeys.values).isDisjoint(with: Set(old.dayKeys.values)), "no revoked key is used again")
        XCTAssertFalse(restarted.deliveredTo(contact))
    }

    func testRevokingWhileUnreadableRaisesTheFloor() throws {
        let stored = Storage(), floor = Floor()
        _ = vault(stored, floor).deliverLease(to: try node(1), epoch: epoch, verified: true)
        let old = try XCTUnwrap(stored.state)
        stored.readFails = true
        let locked = vault(stored, floor)
        XCTAssertTrue(locked.resetContacts())
        XCTAssertTrue(locked.newGeneration(reason: "reset"))
        stored.readFails = false
        _ = vault(stored, floor)
        XCTAssertGreaterThan(try XCTUnwrap(stored.state).generation, old.generation + 1)
    }

    func testExpiredLeaseDaysArePrunedInTheStore() throws {
        let sender = vault(Storage())
        let lease = try XCTUnwrap(sender.deliverLease(to: try node(9), epoch: epoch, verified: true))
        let stored = Storage()
        let mine = vault(stored)
        let contact = try node(2)
        XCTAssertTrue(mine.store(lease, from: contact, myEpoch: epoch, now: 0))
        XCTAssertEqual(stored.state?.contacts[contact.hex]?.leases.count, PresenceLeases.daysPerDelivery)
        let tenDaysLater = epoch + 10 * PresenceLeases.epochsPerDay
        XCTAssertTrue(mine.maintain(epoch: tenDaysLater))
        let kept = try XCTUnwrap(stored.state?.contacts[contact.hex]?.leases)
        XCTAssertLessThan(kept.count, PresenceLeases.daysPerDelivery, "finished days are deleted from the store, not just from memory")
        XCTAssertTrue(kept.keys.allSatisfy { $0 >= PresenceLeases.dayOf(tenDaysLater) - 1 })
        XCTAssertTrue(mine.maintain(epoch: epoch + 40 * PresenceLeases.epochsPerDay))
        XCTAssertEqual(stored.state?.contacts[contact.hex]?.leases, [:])
        XCTAssertTrue(mine.leaseHolders(myEpoch: epoch + 40 * PresenceLeases.epochsPerDay).isEmpty)
    }

    func testResettingContactsDropsRecordsAndRevokesDeliveredLeases() throws {
        let stored = Storage()
        let mine = vault(stored)
        let delivered = try node(1), holder = try node(2)
        XCTAssertNotNil(mine.deliverLease(to: delivered, epoch: epoch, verified: true))
        let lease = try XCTUnwrap(vault(Storage()).deliverLease(to: try node(9), epoch: epoch, verified: true))
        mine.store(lease, from: holder, myEpoch: epoch, now: 0)
        XCTAssertEqual(mine.leaseHolders(myEpoch: epoch).count, 1)
        let generation = mine.generation
        XCTAssertTrue(mine.resetContacts())
        XCTAssertEqual(mine.generation, generation + 1, "a former contact's lease no longer matches")
        XCTAssertEqual(mine.contactCount, 0)
        XCTAssertTrue(mine.leaseHolders(myEpoch: epoch).isEmpty, "this phone stops recognising former contacts")
        XCTAssertEqual(stored.state?.contacts, [:])
        XCTAssertFalse(mine.resetContacts(), "nothing delivered: no new generation")
    }

    func testReconcileDropsContactsThatAreNoLongerVerified() throws {
        let mine = vault(Storage())
        let kept = try node(1), forgotten = try node(2), holderOnly = try node(3)
        XCTAssertNotNil(mine.deliverLease(to: kept, epoch: epoch, verified: true))
        let lease = try XCTUnwrap(vault(Storage()).deliverLease(to: try node(9), epoch: epoch, verified: true))
        mine.store(lease, from: holderOnly, myEpoch: epoch, now: 0)
        let generation = mine.generation
        XCTAssertFalse(mine.reconcile(verified: [kept.hex]), "a dropped record without a delivered lease starts nothing")
        XCTAssertEqual(mine.generation, generation)
        XCTAssertTrue(mine.leaseHolders(myEpoch: epoch).isEmpty)
        XCTAssertTrue(mine.deliveredTo(kept))
        XCTAssertNotNil(mine.deliverLease(to: forgotten, epoch: epoch, verified: true))
        XCTAssertTrue(mine.reconcile(verified: [kept.hex]), "a forgotten lease holder is revoked")
        XCTAssertEqual(mine.generation, generation + 1)
        XCTAssertFalse(mine.deliveredTo(forgotten))
    }

    func testACorruptStoreIsLatchedUntilResetPresenceKey() throws {
        let stored = Storage(); stored.data = Data("not a vault".utf8)
        let mine = vault(stored)
        XCTAssertEqual(mine.loadState, .corrupt)
        XCTAssertNil(mine.deliverLease(to: try node(1), epoch: epoch, verified: true))
        XCTAssertEqual(stored.data, Data("not a vault".utf8), "never overwritten implicitly")
        XCTAssertTrue(mine.resetKey())
        XCTAssertTrue(mine.persistent)
        XCTAssertNotNil(stored.state)
    }

    func testAFreshInstallDropsContactsOnceTheVaultCanBeRead() throws {
        let stored = Storage()
        _ = vault(stored).deliverLease(to: try node(1), epoch: epoch, verified: true)
        let old = try XCTUnwrap(stored.state)
        stored.readFails = true
        var handled = 0
        let clock = Clock()
        let fresh = vault(stored, clock: clock, freshInstall: true) { handled += 1 }
        XCTAssertEqual(handled, 0, "an unreadable vault is not marked as handled")
        stored.readFails = false
        clock.now += PresenceVaultCore.retryInterval
        fresh.maintain(epoch: epoch)
        XCTAssertEqual(handled, 1)
        XCTAssertEqual(stored.state?.contacts, [:])
        XCTAssertGreaterThan(fresh.generation, old.generation)
    }
}
