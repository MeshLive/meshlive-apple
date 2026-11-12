import XCTest
@testable import NearbyCore

/// B1.4 (Android `test_callee_name_after_reveal`, CALL-06): a callee behind a throwaway key whose caller also used one
/// sends its name only after the caller's reveal passed the block check, when the hold is on. With the hold off every
/// moment is BASE's; a verified contact still gets the name at Ringing.
final class CalleeNameAfterRevealTests: XCTestCase {
    private let vp9 = NodeCapabilities.codecVP9
    private let epoch: Int64 = 1_990_656
    private let budget = Bmh3SigningBudget(capacity: 1_000)

    private func pump(_ a: MeshConnection, _ b: MeshConnection) {
        for _ in 0..<80 {
            var moved = false
            while let d = a.nextOutgoing(now: 0) { b.receive(d, now: 0); moved = true }
            while let d = b.nextOutgoing(now: 0) { a.receive(d, now: 0); moved = true }
            if !moved { return }
        }
    }

    /// Delivers one direction only, so a name queued with Accept can be told apart from one held for the reveal.
    private func drain(_ from: CallEngine, _ to: CallEngine) {
        while let d = from.nextOutgoing(now: 0) { to.receive(d, now: 0) }
    }

    private func step(_ a: CallEngine, _ b: CallEngine, _ t: TimeInterval) {
        a.tick(now: t); b.tick(now: t)
        for _ in 0..<20 {
            var moved = false
            while let d = a.nextOutgoing(now: t) { b.receive(d, now: t); moved = true }
            while let d = b.nextOutgoing(now: t) { a.receive(d, now: t); moved = true }
            if !moved { break }
        }
    }

    private func callOffer(_ six: Data) -> DiscoveryAnnouncement {
        var a = DiscoveryAnnouncement(nodeIdPrefix: six, flags: DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable,
                                      capabilitySummary: 1, streamToken: 0, routeCost: 0)
        a.rotating = true
        return a
    }

    private func entry(for id: SigningIdentity) -> OpeningEntry {
        RotatingDiscoveryIds.ownEntry(presenceKey: Data(repeating: 9, count: 32), nodeId: id.nodeId.bytes, epoch: epoch, role: 0)
    }

    private func rotatingCall(callerId: SigningIdentity = SoftwareSigningIdentity(),
                              calleeId: SigningIdentity = SoftwareSigningIdentity(),
                              callerPseudonyms: Bool? = true, calleePseudonyms: Bool? = true,
                              calleeAudience: NamesAudience = .everyone,
                              calleeAudienceNow: (() -> NamesAudience)? = nil,
                              calleeVerifies: ((IdentityFingerprint) -> Bool)? = nil,
                              hold: Bool = true) -> (CallEngine, CallEngine, Box) {
        let e = entry(for: calleeId)
        let selected = callOffer(e.rdi)
        let caller = CallEngine(role: .caller, transport: .l2cap, identity: callerId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                expectedPeerPrefix: e.rdi, labels: CallLabelOptions(localName: "Asha"),
                                rotating: RotatingCallOptions(selected: selected, wallEpoch: { 1_990_656 }),
                                bmh3: callerPseudonyms.map { Bmh3CallOptions(pseudonyms: $0, selected: selected, wallEpoch: { 1_990_656 }) })
        let callee = CallEngine(role: .callee, transport: .l2cap, identity: calleeId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                labels: CallLabelOptions(localName: "Ravi", audience: calleeAudience,
                                                         calleeNameAfterReveal: hold,
                                                         isVerifiedPeer: calleeVerifies ?? { _ in false },
                                                         currentAudience: calleeAudienceNow),
                                rotating: RotatingCallOptions(entries: { [e] }),
                                bmh3: calleePseudonyms.map { Bmh3CallOptions(pseudonyms: $0, budget: budget) })
        let box = Box()
        caller.onEvent = { box.caller.append($0) }
        callee.onEvent = { box.callee.append($0) }
        return (caller, callee, box)
    }

    final class Box { var caller: [CallEngine.Event] = []; var callee: [CallEngine.Event] = [] }

    func testEveryoneCalleeHoldsTheNameForTheRevealWhenBothSidesUseThrowawayKeysAndTheHoldIsOn() throws {
        let (caller, callee, _) = rotatingCall(hold: true)
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        XCTAssertEqual(callee.state?.phase, .incomingRinging, "\(caller.closeReason ?? "") / \(callee.closeReason ?? "")")
        XCTAssertNil(caller.labelInbox.text(.personName), "nothing while it rings")
        try callee.accept(as: .voice)
        drain(callee, caller)
        XCTAssertNil(caller.labelInbox.text(.personName), "the name waits for the caller's reveal")
        for _ in 0..<4 { drain(caller, callee); drain(callee, caller) }
        XCTAssertEqual(caller.labelInbox.text(.personName), "Ravi")
    }

    func testTheControlArmKeepsTheNameWithAcceptAsBefore() throws {
        let (caller, callee, _) = rotatingCall(hold: false)
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        XCTAssertNil(caller.labelInbox.text(.personName), "nothing while it rings")
        try callee.accept(as: .voice)
        drain(callee, caller)
        XCTAssertEqual(caller.labelInbox.text(.personName), "Ravi", "BASE: with Accept")
    }

    func testAVerifiedContactCallerStillGetsTheNameAtRinging() throws {
        let callerId = SoftwareSigningIdentity()
        let (caller, callee, _) = rotatingCall(callerId: callerId, callerPseudonyms: false, calleePseudonyms: false,
                                               calleeVerifies: { $0 == callerId.fingerprint }, hold: true)
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        XCTAssertEqual(callee.state?.phase, .incomingRinging)
        XCTAssertEqual(caller.labelInbox.text(.personName), "Ravi", "a verified contact gets it at Ringing")
    }

    func testARealKeyStrangerCallerGetsTheNameWithAcceptEvenWithTheHoldOn() throws {
        let (caller, callee, _) = rotatingCall(callerPseudonyms: false, calleePseudonyms: false, hold: true)
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        XCTAssertNil(caller.labelInbox.text(.personName), "nothing while it rings")
        try callee.accept(as: .voice)
        drain(callee, caller)
        XCTAssertEqual(caller.labelInbox.text(.personName), "Ravi", "a real-key stranger gets it with Accept")
    }

    func testOnlyMyContactsIsUnchangedByTheHold() throws {
        for verified in [true, false] {
            let callerId = SoftwareSigningIdentity()
            let callerFingerprint = callerId.fingerprint
            let (caller, callee, _) = rotatingCall(callerId: callerId, calleeAudience: .verified,
                                                   calleeVerifies: { verified && $0 == callerFingerprint }, hold: true)
            try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
            XCTAssertEqual(callee.state?.phase, .incomingRinging, "\(caller.closeReason ?? "")")
            XCTAssertNil(caller.labelInbox.text(.personName), "nothing while it rings")
            try callee.accept(as: .voice); pump(caller, callee)
            XCTAssertEqual(caller.state?.phase, .active, "\(caller.closeReason ?? "")")
            XCTAssertEqual(caller.labelInbox.text(.personName), verified ? "Ravi" : nil, "verified contact: \(verified)")
        }
    }

    func testTheHeldNameGoesOnlyAfterTheRevealPassesTheBlockCheck() throws {
        let (caller, callee, _) = rotatingCall(hold: true)
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        try callee.accept(as: .voice)
        drain(callee, caller)
        XCTAssertNil(caller.labelInbox.text(.personName))
        XCTAssertFalse(callee.blockedAfterReveal)
        pump(caller, callee)
        XCTAssertEqual(caller.labelInbox.text(.personName), "Ravi")
    }

    func testABlockedCallerNeverReceivesTheHeldName() throws {
        let callerId = SoftwareSigningIdentity()
        let (caller, callee, _) = rotatingCall(callerId: callerId, hold: true)
        callee.personBlocked = { $0 == callerId.fingerprint }
        callee.blockedEndDelay = { 4 }
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        try callee.accept(as: .voice)
        step(caller, callee, 0.5)
        XCTAssertTrue(callee.blockedAfterReveal)
        XCTAssertNil(caller.labelInbox.text(.personName), "the blocked caller never receives the held name")
        step(caller, callee, 4.6)
    }

    func testADeclinedCallNeverRevealsTheHeldName() throws {
        let (caller, callee, _) = rotatingCall(hold: true)
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        try callee.decline(); pump(caller, callee)
        XCTAssertNil(caller.labelInbox.text(.personName))
    }

    func testTheNewestAudienceIsAppliedWhenTheHeldNameIsReleased() throws {
        var audience: NamesAudience = .everyone
        let (caller, callee, _) = rotatingCall(calleeAudience: .everyone, calleeAudienceNow: { audience }, hold: true)
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        try callee.accept(as: .voice)
        drain(callee, caller)
        audience = .nobody
        for _ in 0..<4 { drain(caller, callee); drain(callee, caller) }
        XCTAssertNil(caller.labelInbox.text(.personName), "the audience read at release says nobody")
    }
}
