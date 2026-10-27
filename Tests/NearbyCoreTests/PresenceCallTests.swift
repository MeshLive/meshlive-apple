import XCTest
@testable import NearbyCore

/// Phase 2 over real call engines: mutual verified contacts exchange OFFER + LEASE once the call is answered; a
/// one-sided verification or a stranger moves nothing; a pseudonym call exchanges only after both reveals.
final class PresenceCallTests: XCTestCase {
    let vp9 = NodeCapabilities.codecVP9
    let epoch: Int64 = 1_990_656

    final class Side {
        let id = SoftwareSigningIdentity()
        var verifiedPeers: Set<String> = []
        var dayKeys: [Int64: Data] = [:]
        var stored: [String: DiscoveryExchange.PresenceLease] = [:]
        var delivered: [String] = []
        func hooks(epoch: Int64) -> PresenceCallHooks {
            PresenceCallHooks(
                eligible: { [unowned self] _, fp in verifiedPeers.contains(fp.hex) },
                lease: { [unowned self] id, fp in
                    guard verifiedPeers.contains(fp.hex) else { return nil }
                    delivered.append(id.hex)
                    return PresenceLeases.delivery(dayKeys: dayKeys, generation: 1, epoch: epoch)
                },
                store: { [unowned self] id, lease in stored[id.hex] = lease },
                verified: { [unowned self] fp in verifiedPeers.contains(fp.hex) })
        }
    }

    private func pump(_ a: MeshConnection, _ b: MeshConnection) {
        for _ in 0..<80 {
            var moved = false
            while let d = a.nextOutgoing(now: 0) { b.receive(d, now: 0); moved = true }
            while let d = b.nextOutgoing(now: 0) { a.receive(d, now: 0); moved = true }
            if !moved { return }
        }
    }

    private func call(_ caller: Side, _ callee: Side, pseudonyms: Bool? = nil) throws -> (CallEngine, CallEngine) {
        caller.dayKeys = DayKeyWindow.fresh(epoch: epoch); callee.dayKeys = DayKeyWindow.fresh(epoch: epoch)
        let entry = PresenceLeases.ownEntry(dayKeys: callee.dayKeys, nodeId: callee.id.nodeId.bytes, epoch: epoch, role: 0)!
        var offer = DiscoveryAnnouncement(nodeIdPrefix: entry.rdi, flags: DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable,
                                          capabilitySummary: 1, streamToken: 0, routeCost: 0)
        offer.rotating = true
        let e = epoch
        var callerRotating = RotatingCallOptions(selected: offer, wallEpoch: { e }); callerRotating.presence = caller.hooks(epoch: epoch)
        var calleeRotating = RotatingCallOptions(entries: { [entry] }, wallEpoch: { e }); calleeRotating.presence = callee.hooks(epoch: epoch)
        let budget = Bmh3SigningBudget(capacity: 100)
        let a = CallEngine(role: .caller, transport: .gatt, identity: caller.id, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                           rotating: callerRotating, bmh3: pseudonyms.map { Bmh3CallOptions(pseudonyms: $0, selected: offer, budget: budget, wallEpoch: { e }) })
        let b = CallEngine(role: .callee, transport: .gatt, identity: callee.id, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                           rotating: calleeRotating, bmh3: pseudonyms.map { Bmh3CallOptions(pseudonyms: $0, budget: budget, wallEpoch: { e }) })
        try a.start(now: 0); try b.start(now: 0); pump(a, b)
        XCTAssertEqual(b.state?.phase, .incomingRinging, a.closeReason ?? b.closeReason ?? "")
        XCTAssertTrue(caller.stored.isEmpty && callee.stored.isEmpty, "nothing moves before the call is answered")
        try b.accept(as: .voice); pump(a, b)
        XCTAssertEqual(a.state?.phase, .active, a.closeReason ?? "")
        return (a, b)
    }

    private func mutual() -> (Side, Side) {
        let a = Side(), b = Side()
        a.verifiedPeers = [b.id.fingerprint.hex]; b.verifiedPeers = [a.id.fingerprint.hex]
        return (a, b)
    }

    func testMutualVerifiedContactsExchangeLeasesOnceAnswered() throws {
        for pseudonyms in [nil, false, true] as [Bool?] {
            let (a, b) = mutual()
            let (ea, eb) = try call(a, b, pseudonyms: pseudonyms)
            XCTAssertEqual(a.stored[b.id.nodeId.hex]?.leases.count, 28, "caller stores the callee's lease (\(String(describing: pseudonyms)))")
            XCTAssertEqual(b.stored[a.id.nodeId.hex]?.leases.count, 28, "callee stores the caller's lease (\(String(describing: pseudonyms)))")
            XCTAssertEqual(a.stored[b.id.nodeId.hex]?.leases.first, b.dayKeys[PresenceLeases.dayOf(epoch)])
            XCTAssertEqual(ea.presenceLeasesSent, 1); XCTAssertEqual(eb.presenceLeasesSent, 1)
            XCTAssertTrue(ea.presenceRejections.isEmpty && eb.presenceRejections.isEmpty)
            // The real identities were used, never a throwaway.
            XCTAssertEqual(a.delivered, [b.id.nodeId.hex]); XCTAssertEqual(b.delivered, [a.id.nodeId.hex])
        }
    }

    func testOneSidedVerificationMovesNothing() throws {
        let a = Side(), b = Side()
        a.verifiedPeers = [b.id.fingerprint.hex]          // only the caller verified the callee
        _ = try call(a, b)
        XCTAssertTrue(a.stored.isEmpty && b.stored.isEmpty)
        XCTAssertTrue(a.delivered.isEmpty && b.delivered.isEmpty, "an offer that is not answered by an offer gets no lease")
    }
}

/// Phase 2 + BMH3: a recognised contact is called with the lease-derived tag, so both sides present real keys even in
/// pseudonym mode (no stranger, no reveal); someone else answering the contact's ID fails before the caller reveals.
final class PresenceTagCallTests: XCTestCase {
    let vp9 = NodeCapabilities.codecVP9
    let epoch: Int64 = 1_990_656

    private func pump(_ a: MeshConnection, _ b: MeshConnection) {
        for _ in 0..<80 {
            var moved = false
            while let d = a.nextOutgoing(now: 0) { b.receive(d, now: 0); moved = true }
            while let d = b.nextOutgoing(now: 0) { a.receive(d, now: 0); moved = true }
            if !moved { return }
        }
    }

    private func run(answerer: SoftwareSigningIdentity, contact: SoftwareSigningIdentity, delivered: Bool) throws -> (CallEngine, CallEngine, [CallEngine.Event]) {
        let e = epoch
        let contactKeys = DayKeyWindow.fresh(epoch: epoch)
        let entry = PresenceLeases.ownEntry(dayKeys: contactKeys, nodeId: contact.nodeId.bytes, epoch: epoch, role: 0)!
        var offer = DiscoveryAnnouncement(nodeIdPrefix: entry.rdi, flags: DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable,
                                          capabilitySummary: 1, streamToken: 0, routeCost: 0)
        offer.rotating = true
        // The caller holds the contact's lease (recognition table) and tags its msg1.
        let presence = ContactPresence(nodeId: contact.nodeId.bytes, generation: 1, leasesByDay: contactKeys, skewEpochs: 0, receivedAt: 0)
        let table = RecognitionTable(); table.rebuild([presence], myEpoch: epoch, now: 0)
        let tag = PresenceContactTags.initiatorTag(selected: offer, recognition: table) { node, day in node == contact.nodeId.bytes ? contactKeys[day] : nil }
        XCTAssertNotNil(tag)
        let budget = Bmh3SigningBudget(capacity: 100)
        let callerId = SoftwareSigningIdentity()
        var callerBmh3 = Bmh3CallOptions(pseudonyms: true, selected: offer, budget: budget, wallEpoch: { e }); callerBmh3.contactTag = tag
        var calleeBmh3 = Bmh3CallOptions(pseudonyms: true, budget: budget, wallEpoch: { e })
        // The answerer checks its own day keys (the contact's when it is the contact; its own otherwise).
        let answererKeys = answerer === contact ? contactKeys : DayKeyWindow.fresh(epoch: epoch)
        calleeBmh3.tagChecks = { PresenceContactTags.responderChecks(entries: [entry]) { answererKeys[PresenceLeases.dayOf($0)] } }
        calleeBmh3.admitTagged = { node in delivered && node == callerId.nodeId }
        var events: [CallEngine.Event] = []
        let caller = CallEngine(role: .caller, transport: .gatt, identity: callerId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                rotating: RotatingCallOptions(selected: offer, wallEpoch: { e }), bmh3: callerBmh3)
        caller.onEvent = { events.append($0) }
        let callee = CallEngine(role: .callee, transport: .gatt, identity: answerer, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                rotating: RotatingCallOptions(entries: { [entry] }, wallEpoch: { e }), bmh3: calleeBmh3)
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        return (caller, callee, events)
    }

    func testATaggedContactCallIsRealRealInPseudonymMode() throws {
        let contact = SoftwareSigningIdentity()
        let (caller, callee, events) = try run(answerer: contact, contact: contact, delivered: true)
        XCTAssertEqual(callee.state?.phase, .incomingRinging, caller.closeReason ?? callee.closeReason ?? "")
        XCTAssertFalse(caller.peerIsStranger || callee.peerIsStranger, "contacts meet with real keys")
        XCTAssertNil(caller.endpoint?.reveal)
        XCTAssertTrue(events.contains(.peerAuthenticated(contact.nodeId, contact.fingerprint)))
    }

    func testAnotherKeyAnsweringTheContactsIdFailsAndALeakedTagIsRefused() throws {
        let contact = SoftwareSigningIdentity()
        // An impostor replaying the contact's advert (and opening) with its own key: the expected-contact check fails.
        let (impostorCaller, _, events) = try run(answerer: SoftwareSigningIdentity(), contact: contact, delivered: true)
        XCTAssertEqual(impostorCaller.phase, .closed)
        XCTAssertFalse(events.contains { if case .peerAuthenticated = $0 { return true }; return false })
        // The real contact, but the caller is not a lease recipient: the responder closes after msg3.
        let (_, refusingCallee, _) = try run(answerer: contact, contact: contact, delivered: false)
        XCTAssertNil(refusingCallee.state)
    }
}
