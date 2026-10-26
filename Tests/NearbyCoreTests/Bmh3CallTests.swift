import XCTest
@testable import NearbyCore

/// BMH3 calls over real sans-I/O engines (Android Bmh3LinkTest / Bmh3PseudonymTest flows): choice, dispatch, the BDX1
/// OPENING of phase 1b, the pseudonym reveal at Accept, and the refusals that fail closed.
final class Bmh3CallTests: XCTestCase {
    let vp9 = NodeCapabilities.codecVP9
    let epoch: Int64 = 1_990_656
    let budget = Bmh3SigningBudget(capacity: 1_000)

    private func pump(_ a: MeshConnection, _ b: MeshConnection) {
        for _ in 0..<80 {
            var moved = false
            while let d = a.nextOutgoing(now: 0) { b.receive(d, now: 0); moved = true }
            while let d = b.nextOutgoing(now: 0) { a.receive(d, now: 0); moved = true }
            if !moved { return }
        }
    }

    private func callOffer(_ six: Data, rotating: Bool, summary: UInt8 = 1) -> DiscoveryAnnouncement {
        var a = DiscoveryAnnouncement(nodeIdPrefix: six, flags: DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable,
                                      capabilitySummary: summary, streamToken: 0, routeCost: 0)
        a.rotating = rotating
        return a
    }

    private struct Pair {
        let caller: CallEngine, callee: CallEngine
        var callerEvents: [CallEngine.Event] = [], calleeEvents: [CallEngine.Event] = []
    }

    private func entry(for id: SigningIdentity) -> OpeningEntry {
        RotatingDiscoveryIds.ownEntry(presenceKey: Data(repeating: 9, count: 32), nodeId: id.nodeId.bytes, epoch: epoch, role: 0)
    }

    /// A rotating call between two iPhones: `callerBmh3`/`calleeBmh3` nil = BMH2 only.
    private func rotatingCall(callerId: SigningIdentity = SoftwareSigningIdentity(), calleeId: SigningIdentity = SoftwareSigningIdentity(),
                              advertisedBy: SigningIdentity? = nil, callerPseudonyms: Bool?, calleePseudonyms: Bool?,
                              labels: Bool = false) -> (CallEngine, CallEngine, Box) {
        let e = entry(for: advertisedBy ?? calleeId)
        let selected = callOffer(e.rdi, rotating: true)
        let caller = CallEngine(role: .caller, transport: .l2cap, identity: callerId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                expectedPeerPrefix: e.rdi, labels: labels ? CallLabelOptions(localName: "Asha", subject: "Hello") : nil,
                                rotating: RotatingCallOptions(selected: selected, wallEpoch: { 1_990_656 }),
                                bmh3: callerPseudonyms.map { Bmh3CallOptions(pseudonyms: $0, selected: selected, wallEpoch: { 1_990_656 }) })
        let callee = CallEngine(role: .callee, transport: .l2cap, identity: calleeId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                labels: labels ? CallLabelOptions(localName: "Ravi", subject: nil) : nil,
                                rotating: RotatingCallOptions(entries: { [e] }),
                                bmh3: calleePseudonyms.map { Bmh3CallOptions(pseudonyms: $0, budget: budget) })
        let box = Box()
        caller.onEvent = { box.caller.append($0) }
        callee.onEvent = { box.callee.append($0) }
        return (caller, callee, box)
    }

    final class Box { var caller: [CallEngine.Event] = []; var callee: [CallEngine.Event] = [] }

    private func authenticated(_ events: [CallEngine.Event]) -> [NodeId] {
        events.compactMap { if case .peerAuthenticated(let id, _) = $0 { return id }; return nil }
    }
    private func strangers(_ events: [CallEngine.Event]) -> Int {
        events.filter { if case .peerStranger = $0 { return true }; return false }.count
    }

    func testRealIdentityBmh3RotatingCallSendsTheOpeningFirstAndConnects() throws {
        let callerId = SoftwareSigningIdentity(), calleeId = SoftwareSigningIdentity()
        let (caller, callee, box) = rotatingCall(callerId: callerId, calleeId: calleeId, callerPseudonyms: false, calleePseudonyms: false)
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        XCTAssertEqual(callee.state?.phase, .incomingRinging, "\(caller.closeReason ?? "")")
        XCTAssertTrue(caller.linkUsedBmh3 && callee.linkUsedBmh3)
        XCTAssertTrue(caller.discoveryNegotiated && callee.discoveryNegotiated)
        XCTAssertEqual(caller.endpoint?.usedBmh3, true)
        try callee.accept(as: .voice); pump(caller, callee)
        XCTAssertEqual(caller.state?.phase, .active)
        XCTAssertEqual(authenticated(box.caller), [calleeId.nodeId])
        XCTAssertEqual(authenticated(box.callee), [callerId.nodeId])
        XCTAssertEqual(strangers(box.caller) + strangers(box.callee), 0)
    }

    func testPseudonymCallRingsAsAStrangerAndRevealsBothIdentitiesOnlyAfterAccept() throws {
        let callerId = SoftwareSigningIdentity(), calleeId = SoftwareSigningIdentity()
        let (caller, callee, box) = rotatingCall(callerId: callerId, calleeId: calleeId, callerPseudonyms: true, calleePseudonyms: true, labels: true)
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        XCTAssertEqual(callee.state?.phase, .incomingRinging, "\(caller.closeReason ?? "") / \(callee.closeReason ?? "")")
        XCTAssertTrue(caller.peerIsStranger && callee.peerIsStranger)
        XCTAssertNotEqual(caller.endpoint?.peerNodeId, calleeId.nodeId, "the callee answered with a throwaway")
        XCTAssertNotEqual(callee.endpoint?.peerNodeId, callerId.nodeId, "the caller presented a throwaway")
        XCTAssertEqual(authenticated(box.caller) + authenticated(box.callee), [], "nobody learned a real identity while ringing")
        XCTAssertNil(callee.labelInbox.text(.personName), "the caller's name is held until the callee proved itself")
        try callee.accept(as: .voice); pump(caller, callee)
        XCTAssertEqual(caller.state?.phase, .active, "\(caller.closeReason ?? "")")
        XCTAssertEqual(authenticated(box.caller), [calleeId.nodeId])
        XCTAssertEqual(authenticated(box.callee), [callerId.nodeId])
        XCTAssertEqual(callee.labelInbox.text(.personName), "Asha")
        XCTAssertFalse(caller.peerIsStranger || callee.peerIsStranger)
    }

    func testAPseudonymCalleeDeclinesWithoutRevealingAnything() throws {
        let calleeId = SoftwareSigningIdentity()
        let (caller, callee, box) = rotatingCall(calleeId: calleeId, callerPseudonyms: true, calleePseudonyms: true)
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        try callee.decline(); pump(caller, callee)
        XCTAssertEqual(caller.phase, .closed)
        XCTAssertEqual(authenticated(box.caller) + authenticated(box.callee), [])
    }

    func testAnImpostorsRevealDoesNotOpenTheSelectedIdAndTheCallerNeverReveals() throws {
        // The impostor advertises (copies) the victim's RDI; its reveal carries its own real key and the victim's entry.
        let victim = SoftwareSigningIdentity()
        let (caller, impostor, box) = rotatingCall(calleeId: SoftwareSigningIdentity(), advertisedBy: victim, callerPseudonyms: true, calleePseudonyms: true)
        try caller.start(now: 0); try impostor.start(now: 0); pump(caller, impostor)
        XCTAssertEqual(impostor.state?.phase, .incomingRinging)
        try impostor.accept(as: .voice); pump(caller, impostor)
        XCTAssertEqual(caller.phase, .closed)
        XCTAssertEqual(authenticated(box.callee), [], "the caller ended the call before revealing itself")
    }

    func testAPseudonymPhoneRefusesBmh2BothWays() throws {
        // Callee in pseudonym mode, caller without hidden identities: a BMH2 hello is a silent close.
        let (caller, callee, _) = rotatingCall(callerPseudonyms: nil, calleePseudonyms: true)
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        XCTAssertEqual(callee.phase, .closed); XCTAssertNil(callee.state)
        // A pseudonym caller never speaks BMH2 either, even toward a fixed (version 2) offer without the hint.
        let calleeId = SoftwareSigningIdentity()
        let offer = callOffer(calleeId.nodeId.prefix, rotating: false)
        let options = Bmh3CallOptions(pseudonyms: true, selected: offer)
        XCTAssertTrue(options.settings(role: .caller, openingEntries: nil)?.speak == true)
    }

    func testChoiceRules() {
        let six = Data([1, 2, 3, 4, 5, 6])
        XCTAssertFalse(Bmh3Choice.decide(enabled: false, only: true, offer: callOffer(six, rotating: true), pinned: true).bmh3)
        XCTAssertEqual(Bmh3Choice.decide(enabled: true, only: false, offer: callOffer(six, rotating: true), pinned: false).reason, .rotating)
        XCTAssertEqual(Bmh3Choice.decide(enabled: true, only: false, offer: callOffer(six, rotating: false, summary: 1 | 0x20), pinned: false).reason, .hint)
        XCTAssertEqual(Bmh3Choice.decide(enabled: true, only: false, offer: callOffer(six, rotating: false), pinned: true).reason, .pin)
        XCTAssertEqual(Bmh3Choice.decide(enabled: true, only: false, offer: callOffer(six, rotating: false), pinned: false).reason, .none)
        let pins = Bmh3Pins()
        pins.pin(six + Data([7]))
        XCTAssertTrue(pins.isPinned(six)); XCTAssertFalse(pins.isPinned(Data(repeating: 0, count: 6)))
        XCTAssertFalse(pins.isPinned(six, now: Date().addingTimeInterval(Bmh3Pins.ttl + 60)))
    }

    func testABmh3CallerToAFixedOfferWithoutHintStillSpeaksBmh2AndAnEveryoneResponderAcceptsIt() throws {
        // Hidden identities on, pseudonyms off: an old (BMH2) callee stays reachable through a version 2 offer.
        let calleeId = SoftwareSigningIdentity()
        let offer = callOffer(calleeId.nodeId.prefix, rotating: false)
        let caller = CallEngine(role: .caller, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                expectedPeerPrefix: calleeId.nodeId.prefix, bmh3: Bmh3CallOptions(pseudonyms: false, selected: offer))
        let callee = CallEngine(role: .callee, transport: .gatt, identity: calleeId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                bmh3: Bmh3CallOptions(pseudonyms: false, budget: budget))
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        XCTAssertEqual(callee.state?.phase, .incomingRinging)
        XCTAssertFalse(caller.linkUsedBmh3)
        // With the hint the same pair speaks BMH3, and a wrong prefix behind the hint fails before the caller reveals.
        let hinted = callOffer(calleeId.nodeId.prefix, rotating: false, summary: 1 | Bmh3Choice.hintBit)
        let caller2 = CallEngine(role: .caller, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                 expectedPeerPrefix: calleeId.nodeId.prefix, bmh3: Bmh3CallOptions(pseudonyms: false, selected: hinted))
        let callee2 = CallEngine(role: .callee, transport: .gatt, identity: calleeId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                 bmh3: Bmh3CallOptions(pseudonyms: false, budget: budget))
        try caller2.start(now: 0); try callee2.start(now: 0); pump(caller2, callee2)
        XCTAssertEqual(callee2.state?.phase, .incomingRinging)
        XCTAssertTrue(caller2.linkUsedBmh3)
        let other = callOffer(Data(repeating: 0xab, count: 6), rotating: false, summary: 1 | Bmh3Choice.hintBit)
        let caller3 = CallEngine(role: .caller, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                 expectedPeerPrefix: other.nodeIdPrefix, bmh3: Bmh3CallOptions(pseudonyms: false, selected: other))
        let callee3 = CallEngine(role: .callee, transport: .gatt, identity: calleeId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                 bmh3: Bmh3CallOptions(pseudonyms: false, budget: budget))
        try caller3.start(now: 0); try callee3.start(now: 0); pump(caller3, callee3)
        XCTAssertEqual(caller3.phase, .closed)
        XCTAssertNil(callee3.peerLinkNodeId, "the callee never learned the caller's link identity")
    }

    func testAPhase1CalleeWithoutTheEndpointOpeningCannotAnswerARotatingCaller() throws {
        // Endpoint bit 3 on both sides makes the OPENING mandatory as the callee's first record.
        let (caller, callee, _) = rotatingCall(callerPseudonyms: nil, calleePseudonyms: nil)
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        XCTAssertEqual(callee.state?.phase, .incomingRinging, "BMH2 with both bits still works")
        XCTAssertTrue(caller.discoveryNegotiated)
    }
}

final class Bmh3BudgetTests: XCTestCase {
    func testTheSigningBudgetRefillsOnePer4Seconds() {
        var clock: TimeInterval = 0
        let budget = Bmh3SigningBudget(capacity: 2, refill: 4, clock: { clock })
        XCTAssertNoThrow(try budget.spend()); XCTAssertNoThrow(try budget.spend())
        XCTAssertThrowsError(try budget.spend())
        clock = 4
        XCTAssertNoThrow(try budget.spend())
        XCTAssertThrowsError(try budget.spend())
    }

    /// Review PR3: a pseudonym-mode responder's replay cache and budget belong to one discovery epoch, so a msg1
    /// replayed across a rotation (or a budget drained before it) cannot tell a prober "same phone".
    func testPseudonymResponderGuardsArePerEpoch() throws {
        let guards = Bmh3EpochGuards(newBudget: { Bmh3SigningBudget(capacity: 1, refill: 1_000, clock: { 0 }) })
        var epoch: Int64 = 100
        var options = Bmh3CallOptions(pseudonyms: true)
        options.epoch = { epoch }; options.epochGuards = guards
        let first = try XCTUnwrap(options.settings(role: .callee, openingEntries: nil))
        let again = try XCTUnwrap(options.settings(role: .callee, openingEntries: nil))
        XCTAssertTrue(first.replayCache === again.replayCache, "one cache per epoch")
        XCTAssertTrue(try XCTUnwrap(first.replayCache).firstUse(Data([1])))
        XCTAssertFalse(try XCTUnwrap(again.replayCache).firstUse(Data([1])), "a replay inside the epoch is refused")
        XCTAssertNoThrow(try XCTUnwrap(first.budget).spend())
        XCTAssertThrowsError(try XCTUnwrap(again.budget).spend(), "one budget per epoch")
        epoch = 101
        let next = try XCTUnwrap(options.settings(role: .callee, openingEntries: nil))
        XCTAssertFalse(next.replayCache === first.replayCache)
        XCTAssertTrue(try XCTUnwrap(next.replayCache).firstUse(Data([1])), "the replayed msg1 looks new after the boundary")
        XCTAssertNoThrow(try XCTUnwrap(next.budget).spend(), "a drained budget does not carry over the boundary")
        epoch = 103
        _ = options.settings(role: .callee, openingEntries: nil)
        XCTAssertEqual(guards.epochs, [103], "pairs older than the previous epoch are dropped")
        // A responder that presents its real key (no pseudonyms) keeps the process-wide pair, as on Android.
        var everyone = Bmh3CallOptions(pseudonyms: false)
        everyone.epoch = { epoch }; everyone.epochGuards = guards
        XCTAssertTrue(try XCTUnwrap(everyone.settings(role: .callee, openingEntries: nil)).replayCache === Bmh3CallSettings.sharedReplayCache)
    }
}
