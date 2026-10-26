import XCTest
@testable import NearbyCore

/// The presence vault's storage discipline (Android PresenceVault): unreadable stores are never overwritten,
/// revocations are recorded in a durable guard before the vault changes, intents made while the vault cannot be stored
/// are applied when it can, pruning is stored, and resetting or reconciling contacts revokes.
final class PresenceVaultCoreTests: XCTestCase {
    let epoch: Int64 = 1_990_656

    final class Storage: PresenceVaultStorage {
        var data: Data?
        var readFails = false, writeFails = false, deleteFails = false
        var writes = 0
        func read() throws -> Data? { if readFails { throw ProtocolError.state("locked") }; return data }
        func write(_ value: Data) throws { if writeFails { throw ProtocolError.state("locked") }; data = value; writes += 1 }
        func delete() throws { if deleteFails { throw ProtocolError.state("locked") }; data = nil }
        var state: PresenceVaultState? { data.flatMap { try? JSONDecoder().decode(PresenceVaultState.self, from: $0) } }
    }
    final class GuardStore: PresenceVaultGuardStorage {
        var data: Data?
        var readFails = false, writeFails = false
        func read() throws -> Data? { if readFails { throw ProtocolError.state("protected") }; return data }
        func write(_ value: Data) throws { if writeFails { throw ProtocolError.state("protected") }; data = value }
        var record: PresenceVaultGuard? { data.flatMap { try? JSONDecoder().decode(PresenceVaultGuard.self, from: $0) } }
    }
    final class Clock { var now: TimeInterval = 100 }

    private func vault(_ storage: Storage, _ guardStore: GuardStore = GuardStore(), clock: Clock = Clock(), freshInstall: Bool = false,
                       onFresh: @escaping () -> Void = {}) -> PresenceVaultCore {
        PresenceVaultCore(storage: storage, guardStorage: guardStore, epoch: { self.epoch }, uptime: { clock.now },
                          freshInstall: freshInstall, onFreshInstallHandled: onFresh)
    }
    private func node(_ byte: UInt8) throws -> NodeId { try NodeId(bytes: Data(repeating: byte, count: 16)) }
    private func lease() throws -> DiscoveryExchange.PresenceLease {
        try XCTUnwrap(vault(Storage()).deliverLease(to: try node(9), epoch: epoch, verified: true))
    }

    func testAnUnreadableStoreIsNeverOverwrittenAndTheLoadIsRetried() throws {
        let stored = Storage(), guardStore = GuardStore()
        let first = vault(stored, guardStore)
        XCTAssertNotNil(first.deliverLease(to: try node(1), epoch: epoch, verified: true))
        let saved = try XCTUnwrap(stored.data)

        stored.readFails = true
        let writesBefore = stored.writes
        let clock = Clock()
        let locked = vault(stored, guardStore, clock: clock)
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

    func testARevocationIsRecordedInTheGuardBeforeTheVaultSoTheOldCopyCannotReturn() throws {
        let stored = Storage(), guardStore = GuardStore()
        let first = vault(stored, guardStore)
        let contact = try node(1)
        XCTAssertNotNil(first.deliverLease(to: contact, epoch: epoch, verified: true))
        let old = try XCTUnwrap(stored.state)

        stored.writeFails = true
        XCTAssertTrue(first.forget(contact), "the revocation happens even though the vault cannot be stored")
        XCTAssertFalse(first.persistent, "the old keys left memory")
        XCTAssertEqual(guardStore.record?.revokedThrough, old.generation, "the guard says the old generation is revoked")
        XCTAssertEqual(stored.state, old, "the stored copy still holds the revoked keys")

        // After a restart the stored copy is replaced (the record itself goes at the launch reconciliation).
        stored.writeFails = false
        let restarted = vault(stored, guardStore)
        let now = try XCTUnwrap(stored.state)
        XCTAssertTrue(restarted.persistent)
        XCTAssertGreaterThan(now.generation, old.generation)
        XCTAssertTrue(Set(now.dayKeys.values).isDisjoint(with: Set(old.dayKeys.values)), "no revoked key is used again")
        XCTAssertFalse(restarted.deliveredTo(contact))
    }

    /// The upgrade case: an existing vault at generation 2 and no guard yet; a revocation while the vault is
    /// unreadable cannot know the generation, so it is pending and revokes whatever is loaded next.
    func testARevocationWhileUnreadableRevokesTheGenerationLoadedNext() throws {
        let stored = Storage()
        let earlier = vault(stored, GuardStore())
        _ = earlier.deliverLease(to: try node(1), epoch: epoch, verified: true)
        earlier.newGeneration(reason: "test")
        let old = try XCTUnwrap(stored.state)
        XCTAssertEqual(old.generation, 2)

        stored.readFails = true
        let guardStore = GuardStore()                       // no guard file yet (an upgraded install)
        let clock = Clock()
        let locked = vault(stored, guardStore, clock: clock)
        XCTAssertTrue(locked.resetContacts())
        XCTAssertEqual(guardStore.record?.revokePending, true)

        stored.readFails = false
        clock.now += PresenceVaultCore.retryInterval
        locked.maintain(epoch: epoch)
        let now = try XCTUnwrap(stored.state)
        XCTAssertGreaterThan(now.generation, old.generation, "generation 2 is not accepted again")
        XCTAssertTrue(Set(now.dayKeys.values).isDisjoint(with: Set(old.dayKeys.values)))
        XCTAssertEqual(now.contacts, [:], "the reset that waited was applied")
        XCTAssertEqual(guardStore.record?.revokePending, false)
        XCTAssertGreaterThanOrEqual(guardStore.record?.revokedThrough ?? 0, old.generation)
    }

    func testWhenNeitherTheGuardNorTheVaultCanBeWrittenTheRevokedVaultIsDeleted() throws {
        let stored = Storage(), guardStore = GuardStore()
        let mine = vault(stored, guardStore)
        XCTAssertNotNil(mine.deliverLease(to: try node(1), epoch: epoch, verified: true))
        stored.writeFails = true; guardStore.writeFails = true
        XCTAssertTrue(mine.newGeneration(reason: "reset"))
        XCTAssertNil(stored.data, "nothing durable says it is revoked, so it is removed")
    }

    func testASwitchOffThatCouldNotBeStoredIsKeptAndBlocksLeases() throws {
        let stored = Storage(), guardStore = GuardStore()
        let mine = vault(stored, guardStore)
        let contact = try node(1), other = try node(2)
        XCTAssertNotNil(mine.deliverLease(to: contact, epoch: epoch, verified: true))
        let old = try XCTUnwrap(stored.state)

        stored.writeFails = true
        XCTAssertTrue(mine.setCanSeeMe(contact, false), "a holder of the current lease is revoked")
        XCTAssertFalse(mine.persistent)
        XCTAssertEqual(guardStore.record?.switchOffPending.count, 1, "the switch-off is in the guard")
        XCTAssertEqual(stored.state, old)

        stored.writeFails = false
        let restarted = vault(stored, guardStore)
        let now = try XCTUnwrap(stored.state)
        XCTAssertGreaterThan(now.generation, old.generation)
        XCTAssertEqual(now.contacts[contact.hex]?.canSeeMe, false, "the new key window never has the contact visible")
        XCTAssertFalse(restarted.canSeeMe(contact))
        XCTAssertNil(restarted.deliverLease(to: contact, epoch: epoch, verified: true))
        XCTAssertEqual(guardStore.record?.switchOffPending, [], "settled once stored")

        // Without a lease to revoke: a failed write still leaves the switch-off pending, and no lease goes out.
        stored.writeFails = true
        XCTAssertFalse(restarted.setCanSeeMe(other, false))
        XCTAssertFalse(restarted.canSeeMe(other))
        stored.writeFails = false
        XCTAssertNil(restarted.deliverLease(to: other, epoch: epoch, verified: true), "never a lease while a switch-off waits")
        XCTAssertEqual(stored.state?.contacts[other.hex]?.canSeeMe, false, "stored at the next chance")
        XCTAssertEqual(guardStore.record?.switchOffPending, [])
        XCTAssertFalse(restarted.setCanSeeMe(other, true))
        XCTAssertTrue(restarted.canSeeMe(other))
    }

    func testForgetAndReconcileWhileUnreadableApplyOnRecovery() throws {
        let stored = Storage(), guardStore = GuardStore()
        let first = vault(stored, guardStore)
        let forgotten = try node(1), dropped = try node(2), kept = try node(3)
        for peer in [forgotten, dropped, kept] { XCTAssertNotNil(first.deliverLease(to: peer, epoch: epoch, verified: true)) }
        stored.readFails = true
        let clock = Clock()
        let locked = vault(stored, guardStore, clock: clock)
        XCTAssertTrue(locked.forget(forgotten))
        XCTAssertFalse(locked.reconcile(verified: [forgotten.hex, kept.hex]), "waits for the vault")
        stored.readFails = false
        clock.now += PresenceVaultCore.retryInterval
        locked.maintain(epoch: epoch)
        let now = try XCTUnwrap(stored.state)
        XCTAssertEqual(Set(now.contacts.keys), [kept.hex])
        XCTAssertFalse(locked.deliveredTo(kept), "a new generation: every lease of the old one is revoked")
    }

    func testExpiredLeaseDaysArePrunedInTheStore() throws {
        let lease = try lease()
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
        mine.store(try lease(), from: holder, myEpoch: epoch, now: 0)
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
        mine.store(try lease(), from: holderOnly, myEpoch: epoch, now: 0)
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
        XCTAssertNil(stored.data, "the damaged vault is gone")
        XCTAssertNotNil(mine.deliverLease(to: try node(1), epoch: epoch, verified: true))
        XCTAssertNotNil(stored.state, "the new vault is stored at its first change")
    }

    func testANewVaultIsWrittenOnlyWhenItChanges() throws {
        let stored = Storage(), guardStore = GuardStore()
        let mine = vault(stored, guardStore)
        XCTAssertTrue(mine.persistent)
        _ = mine.entry(nodeId: try node(1), epoch: epoch, role: 0)
        XCTAssertNil(stored.data, "a phone that never uses the experiment stores nothing")
        XCTAssertNil(guardStore.data)
        XCTAssertNotNil(mine.deliverLease(to: try node(2), epoch: epoch, verified: true))
        XCTAssertNotNil(stored.data)
        XCTAssertEqual(guardStore.record?.floor, stored.state?.generation, "the floor is recorded with the first stored generation")
    }

    func testAnUnreadableGuardKeepsTheVaultClosedAndItsChangesAreMerged() throws {
        let stored = Storage(), guardStore = GuardStore()
        _ = vault(stored, guardStore).deliverLease(to: try node(1), epoch: epoch, verified: true)
        let old = try XCTUnwrap(stored.state)
        guardStore.readFails = true
        let clock = Clock()
        let locked = vault(stored, guardStore, clock: clock)
        XCTAssertFalse(locked.persistent, "no vault without its guard")
        XCTAssertTrue(locked.setCanSeeMe(try node(1), false))
        XCTAssertFalse(locked.canSeeMe(try node(1)))
        guardStore.readFails = false
        clock.now += PresenceVaultCore.retryInterval
        locked.maintain(epoch: epoch)
        XCTAssertTrue(locked.persistent)
        XCTAssertGreaterThan(try XCTUnwrap(stored.state).generation, old.generation)
        XCTAssertEqual(stored.state?.contacts[try node(1).hex]?.canSeeMe, false)
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

/// Small files replaced atomically and durably (the vault's guard).
final class DurableFileTests: XCTestCase {
    func testWriteReplacesTheFileAndLeavesNoTemporaryFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("durable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("guard.json")
        try DurableFile.write(Data("one".utf8), to: url)
        try DurableFile.write(Data("two".utf8), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("two".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["guard.json"])
        XCTAssertThrowsError(try DurableFile.write(Data("x".utf8), to: dir.appendingPathComponent("missing/guard.json")))
    }
}
