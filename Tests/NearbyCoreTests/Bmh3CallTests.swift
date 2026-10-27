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

    /// The callee requires the caller's reveal: the caller's media before it ends the call, and without it the callee
    /// hangs up 10 s after Accept.
    func testAnAnsweredStrangerCallEndsWhenTheCallerNeverRevealsItself() throws {
        let callerId = SoftwareSigningIdentity(), calleeId = SoftwareSigningIdentity()
        let (caller, callee, box) = rotatingCall(callerId: callerId, calleeId: calleeId, callerPseudonyms: true, calleePseudonyms: true)
        caller.testingWithholdOwnReveal = true
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        XCTAssertEqual(callee.state?.phase, .incomingRinging)
        try callee.accept(as: .voice)
        XCTAssertTrue(callee.endpoint?.reveal?.peerRevealRequired == true, "the callee now waits for the caller's reveal")
        pump(caller, callee)
        XCTAssertEqual(callee.phase, .closed, "the caller's header arrived without its reveal")
        XCTAssertNotEqual(callee.state?.phase, .active)
        XCTAssertEqual(authenticated(box.callee), [], "the callee never learned who called")
    }

    /// An authenticated link must carry an Invite within 10 s: one that never does is closed, although heartbeats keep
    /// it alive.
    func testACalleeClosesALinkThatNeverCarriesAnInvite() throws {
        let (caller, callee, _) = rotatingCall(callerPseudonyms: nil, calleePseudonyms: nil)
        caller.testingWithholdInvite = true
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        XCTAssertEqual(callee.phase, .open, "\(callee.closeReason ?? "")")
        func step(_ t: TimeInterval) {
            caller.tick(now: t); callee.tick(now: t)
            for _ in 0..<20 {
                var moved = false
                while let d = caller.nextOutgoing(now: t) { callee.receive(d, now: t); moved = true }
                while let d = callee.nextOutgoing(now: t) { caller.receive(d, now: t); moved = true }
                if !moved { break }
            }
        }
        for t in stride(from: 1.0, through: 10.5, by: 0.5) { step(t) }
        XCTAssertEqual(callee.phase, .open, "heartbeats keep the link alive until the deadline")
        step(11.0)
        XCTAssertEqual(callee.phase, .closed)
        XCTAssertEqual(callee.closeReason, CallEngine.inviteTimeoutReason)
    }

    /// the user cancelled while the link was still connecting (the engine ended first); a link that
    /// still arrives later must not start a handshake (no BMH3 msg1 on a closed engine).
    func testAnEngineEndedBeforeItsLinkStartsSendsNothing() throws {
        let (caller, _, _) = rotatingCall(callerPseudonyms: true, calleePseudonyms: true)
        caller.end()
        XCTAssertEqual(caller.phase, .closed)
        try caller.start(now: 1)
        XCTAssertNil(caller.nextOutgoing(now: 1), "nothing goes out on a late link")
        XCTAssertEqual(caller.phase, .closed)
    }

    /// media from the peer before the call was answered ends the call, for either role (the caller
    /// never decodes a callee's video while it rings, before any reveal).
    func testMediaBeforeTheAnswerEndsTheCallOnEitherSide() throws {
        let (caller, callee, box) = rotatingCall(callerPseudonyms: true, calleePseudonyms: true)
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        XCTAssertEqual(callee.state?.phase, .incomingRinging)
        callee.testingSendHeaderEarly(); pump(caller, callee)
        XCTAssertEqual(caller.phase, .closed, "the caller refused the callee's header while it rang")
        XCTAssertFalse(box.caller.contains { if case .remoteHeader = $0 { return true }; return false }, "nothing was decoded")

        let (caller2, callee2, box2) = rotatingCall(callerPseudonyms: nil, calleePseudonyms: nil)
        try caller2.start(now: 0); try callee2.start(now: 0); pump(caller2, callee2)
        caller2.testingSendHeaderEarly(); pump(caller2, callee2)
        XCTAssertEqual(callee2.phase, .closed, "the callee refused the caller's header before answering")
        XCTAssertFalse(box2.callee.contains { if case .remoteHeader = $0 { return true }; return false })
    }

    /// A relayed call is declined before it rings unless the target consented (the relayed-call target rule).
    func testARelayedCallIsDeclinedBeforeRingingWithoutConsent() throws {
        func call(consent: Bool) throws -> CallEngine {
            let callerId = SoftwareSigningIdentity(), calleeId = SoftwareSigningIdentity()
            let caller = CallEngine(role: .caller, transport: .l2cap, identity: callerId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                    expectedPeerPrefix: calleeId.nodeId.prefix, relayHops: 1)
            let callee = CallEngine(role: .callee, transport: .l2cap, identity: calleeId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9)
            callee.acceptRelayedCalls = consent
            try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
            return callee
        }
        let refused = try call(consent: false)
        XCTAssertEqual(refused.phase, .closed)
        XCTAssertNotEqual(refused.state?.phase, .incomingRinging, "it never rang")
        XCTAssertEqual(refused.relayedDecline, .declineRelayingOff)
        let allowed = try call(consent: true)
        XCTAssertEqual(allowed.state?.phase, .incomingRinging)
    }

    /// A direct pseudonym call uses one key at both layers, so it is not taken for a relayed call and still rings.
    func testADirectPseudonymCallIsNotTakenForARelayedCall() throws {
        let (caller, callee, _) = rotatingCall(callerPseudonyms: true, calleePseudonyms: true)
        callee.acceptRelayedCalls = false; callee.acceptRelayedStrangerCalls = false
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        XCTAssertFalse(callee.isRelayed)
        XCTAssertEqual(callee.state?.phase, .incomingRinging, callee.closeReason ?? "")
    }

    func testRelayedCallRules() {
        XCTAssertEqual(RelayedCallPolicy.incoming(viaRelay: false, relayedCallsOn: false, callerPseudonymous: true, strangerCallsOn: false), .ring)
        XCTAssertEqual(RelayedCallPolicy.incoming(viaRelay: true, relayedCallsOn: false, callerPseudonymous: false, strangerCallsOn: true), .declineRelayingOff)
        XCTAssertEqual(RelayedCallPolicy.incoming(viaRelay: true, relayedCallsOn: true, callerPseudonymous: true, strangerCallsOn: false), .declineStranger)
        XCTAssertEqual(RelayedCallPolicy.incoming(viaRelay: true, relayedCallsOn: true, callerPseudonymous: true, strangerCallsOn: true), .ring)
        XCTAssertTrue(RelayedCallPolicy.strangerRingStatus(viaRelay: true).contains("via a phone nearby"))
    }

    /// Runs both engines to `t`: timers, then every queued record each way.
    private func step(_ a: CallEngine, _ b: CallEngine, _ t: TimeInterval) {
        a.tick(now: t); b.tick(now: t)
        for _ in 0..<20 {
            var moved = false
            while let d = a.nextOutgoing(now: t) { b.receive(d, now: t); moved = true }
            while let d = b.nextOutgoing(now: t) { a.receive(d, now: t); moved = true }
            if !moved { break }
        }
    }

    private func startedLocalMedia(_ events: [CallEngine.Event]) -> Bool {
        events.contains { if case .startLocalMedia = $0 { return true }; return false }
    }

    /// The deadline path: a caller that sends neither its reveal nor its header. The callee keeps its own camera and
    /// microphone off, stays up while heartbeats arrive, and hangs up with the gate's reason 10 s after Accept.
    func testACallerThatNeverRevealsIsHungUpAtTheDeadlineWithTheCalleesMediaNeverStarted() throws {
        let (caller, callee, box) = rotatingCall(callerPseudonyms: true, calleePseudonyms: true)
        caller.testingWithholdOwnReveal = true; caller.testingWithholdLocalMedia = true
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        try callee.accept(as: .voice)
        for t in stride(from: 0.5, through: 10.0, by: 0.5) { step(caller, callee, t) }
        XCTAssertEqual(callee.phase, .open, "\(callee.closeReason ?? "")")
        XCTAssertFalse(startedLocalMedia(box.callee), "the callee's own media waits for the caller's reveal")
        step(caller, callee, 10.5)
        XCTAssertEqual(callee.phase, .closed)
        XCTAssertEqual(callee.closeReason, CallerRevealGate.message)
        XCTAssertFalse(startedLocalMedia(box.callee))
        XCTAssertEqual(authenticated(box.callee), [])
    }

    /// A late but valid reveal (about 9 s) disarms the deadline and starts the callee's own media.
    func testALateValidRevealDisarmsTheDeadline() throws {
        let callerId = SoftwareSigningIdentity()
        let (caller, callee, box) = rotatingCall(callerId: callerId, callerPseudonyms: true, calleePseudonyms: true)
        caller.testingWithholdOwnReveal = true; caller.testingWithholdLocalMedia = true
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        try callee.accept(as: .voice)
        for t in stride(from: 0.5, through: 9.0, by: 0.5) { step(caller, callee, t) }
        XCTAssertFalse(startedLocalMedia(box.callee))
        try caller.testingSendHeldReveal()
        step(caller, callee, 9.2)
        XCTAssertEqual(authenticated(box.callee), [callerId.nodeId])
        XCTAssertTrue(startedLocalMedia(box.callee), "the callee's media starts once the caller proved itself")
        for t in stride(from: 9.5, through: 14.0, by: 0.5) { step(caller, callee, t) }
        XCTAssertEqual(callee.phase, .open, "no hang-up after the deadline: \(callee.closeReason ?? "")")
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

    /// Android Bmh3Pins: pins survive a restart for 30 days (one `hex ms` line each), expire from storage, and keep
    /// only the newest `capacity`; damaged lines are ignored.
    func testPinsAreStoredForThirtyDaysAcrossRestarts() {
        final class Store: Bmh3PinStorage {
            var text: String?
            func read() throws -> String? { text }
            func write(_ value: String) { text = value }
        }
        let store = Store(), six = Data([1, 2, 3, 4, 5, 6]), other = Data([10, 11, 12, 13, 14, 15])
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        Bmh3Pins(storage: store).pin(six + Data([7]), now: t0)
        XCTAssertEqual(store.text, "010203040506 1800000000000")
        XCTAssertTrue(Bmh3Pins(storage: store).isPinned(six, now: t0.addingTimeInterval(Bmh3Pins.ttl - 60)), "kept across a restart")
        XCTAssertFalse(Bmh3Pins(storage: store).isPinned(six, now: t0.addingTimeInterval(Bmh3Pins.ttl + 60)))
        XCTAssertEqual(store.text, "", "an expired pin is deleted from storage")
        store.text = "zz 1\n0102030405 5\n0a0b0c0d0e0f 1800000000000"
        let small = Bmh3Pins(capacity: 1, storage: store)
        XCTAssertTrue(small.isPinned(other, now: t0))
        small.pin(six, now: t0)
        XCTAssertFalse(small.isPinned(other, now: t0), "the oldest pin leaves at capacity")
        XCTAssertTrue(Bmh3Pins(storage: store).isPinned(six, now: t0))
        XCTAssertFalse(Bmh3Pins(storage: store).isPinned(Data([1, 2, 3]), now: t0), "a short prefix is never pinned")
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
    /// an unreadable pin store is not empty; nothing is saved over it until a real load succeeded.
    func testAnUnreadablePinStoreIsNeverOverwritten() {
        final class Locked: Bmh3PinStorage {
            var readable = false, text: String? = "a1b2c3d4e5f6 \(Int64(Date().timeIntervalSince1970 * 1000))", writes = 0
            func read() throws -> String? { guard readable else { throw NSError(domain: "keychain", code: -25308) }; return text }
            func write(_ value: String) { writes += 1; text = value }
        }
        let store = Locked(), pins = Bmh3Pins(storage: store)
        pins.pin(Data(hex: "0102030405a8")!)
        XCTAssertEqual(store.writes, 0, "the stored pins survive")
        XCTAssertTrue(pins.isPinned(Data(hex: "0102030405a8")!), "the new pin still counts in this session")
        store.readable = true
        XCTAssertTrue(pins.isPinned(Data(hex: "a1b2c3d4e5f6")!), "the stored pin loads once readable")
        pins.pin(Data(hex: "0102030405a8")!)
        XCTAssertEqual(store.writes, 1)
        XCTAssertTrue(store.text?.contains("a1b2c3d4e5f6") == true && store.text?.contains("0102030405a8") == true)
    }

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
