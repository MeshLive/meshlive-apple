import XCTest
@testable import NearbyCore

/// Design C helper side: a call listener whose first record is SETUP hands its link to a duty, which dials the next
/// hop (the target, or the next helper with a regenerated SETUP) and answers READY or FAIL upstream.
final class RelayHelperDutyTests: XCTestCase {
    let vp9 = NodeCapabilities.codecVP9
    typealias Net = RelayedCallSetupTests.Net

    /// A helper phone: its listener engine (a callee with the helper marks) and, after a SETUP, its duty.
    final class Helper {
        let identity = SoftwareSigningIdentity()
        let listener: CallEngine
        var duty: RelayHelperDuty?
        /// The app's admission: where the next hop goes (nil refuses with `refusal`).
        var route: (RelayHelperDuty.Request) -> (next: RelayHelperDuty.NextHop, peer: MeshConnection)?
        var refusal: RelaySetupFailure = .noRoute
        init(net: Net, vp9: UInt8, route: @escaping (RelayHelperDuty.Request) -> (next: RelayHelperDuty.NextHop, peer: MeshConnection)?) {
            self.route = route
            listener = CallEngine(role: .callee, transport: .gatt, identity: identity, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                  relayed: RelayedCallOptions(featureOn: true, helperActive: true))
            listener.onEvent = { [unowned self, unowned net] event in
                guard case let .relaySetupRequested(message) = event, case let .setup(target, budget, remaining, id, rotating) = message else { return }
                let parent = CallRelayLink(adopting: listener)
                if let i = net.pairs.firstIndex(where: { $0.1 === listener }) { net.pairs[i].1 = parent }
                let duty = RelayHelperDuty(identity: identity, transport: .gatt, parent: parent,
                                           request: .init(target: target, budget: budget, remainingMs: remaining, setupId: id, rotating: rotating), now: net.now)
                self.duty = duty
                guard let (next, peer) = self.route(duty.request) else { duty.refuse(refusal); return }
                let child = duty.makeChildLink(next: next, bmh3: nil)
                try? child.start(now: net.now)
                net.pairs.append((child, peer))
            }
        }
    }

    private func target(consent: Bool = true) throws -> (CallEngine, SoftwareSigningIdentity) {
        let id = SoftwareSigningIdentity()
        let callee = CallEngine(role: .callee, transport: .gatt, identity: id, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                relayed: RelayedCallOptions(featureOn: true))
        callee.acceptRelayedCalls = consent
        try callee.start(now: 0)
        return (callee, id)
    }

    private func caller(target: Data, helper: Data, budget: Int) -> CallEngine {
        CallEngine(role: .caller, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                   expectedPeerPrefix: target, relayHops: UInt8(budget),
                   relayed: RelayedCallOptions(featureOn: true, route: RelayRoute(target: target, helperPrefix: helper, relays: budget), setupStartedAt: 0))
    }

    func testAHelperListenerRelaysACallToTheTargetAfterSetup() throws {
        let net = Net()
        let (callee, calleeId) = try target()
        let helper = Helper(net: net, vp9: vp9) { _ in (.init(hopPrefix: nil, nextBudget: 0), callee) }
        try helper.listener.start(now: 0)
        let caller = caller(target: calleeId.nodeId.prefix, helper: helper.identity.nodeId.prefix, budget: 1)
        try caller.start(now: 0)
        net.pairs.append((caller, helper.listener)); net.pump()
        XCTAssertTrue(helper.listener.handedOver, "the listener handed its link to the duty")
        XCTAssertEqual(helper.duty?.readyRelays, 1)
        XCTAssertEqual(helper.duty?.state, .relaying)
        XCTAssertEqual(caller.relayReadyRelays, 1, caller.closeReason ?? "-")
        XCTAssertEqual(callee.state?.phase, .incomingRinging, callee.closeReason ?? "-")
        XCTAssertTrue(callee.isRelayed)
        try callee.accept(as: .voice); net.pump()
        XCTAssertEqual(caller.state?.phase, .active)
        caller.sendAudio(presentationTimeUs: 0, opus: Data([0xfc, 1])); net.pump()
        XCTAssertEqual(callee.receivedAudioPackets, 1, "media crosses the helper end to end")
    }

    func testTwoHelpersRegenerateSetupAndReadyCountsTheRelays() throws {
        let net = Net()
        let (callee, calleeId) = try target()
        let second = Helper(net: net, vp9: vp9) { _ in (.init(hopPrefix: nil, nextBudget: 0), callee) }
        try second.listener.start(now: 0)
        let first = Helper(net: net, vp9: vp9) { _ in (.init(hopPrefix: second.identity.nodeId.prefix, nextBudget: 1), second.listener) }
        try first.listener.start(now: 0)
        let caller = caller(target: calleeId.nodeId.prefix, helper: first.identity.nodeId.prefix, budget: 2)
        try caller.start(now: 0)
        net.pairs.append((caller, first.listener)); net.pump()
        XCTAssertEqual(second.duty?.request.budget, 1, "the first helper regenerated SETUP with budget - 1")
        XCTAssertNotEqual(second.duty?.request.setupId, first.duty?.request.setupId, "a new setup ID per hop")
        XCTAssertLessThan(second.duty?.request.remainingMs ?? 99_999, first.duty?.request.remainingMs ?? 0)
        XCTAssertEqual(first.duty?.readyRelays, 2); XCTAssertEqual(caller.relayReadyRelays, 2)
        XCTAssertEqual(callee.state?.phase, .incomingRinging, "\(caller.closeReason ?? "-") / \(callee.closeReason ?? "-")")
        XCTAssertEqual(callee.relayHops, 2)
        try callee.accept(as: .voice); net.pump()
        XCTAssertEqual(caller.state?.phase, .active)
    }

    func testAWrongNextHopAnswersFailThreeAndAMissingRouteFailOne() throws {
        let net = Net()
        let (impostor, _) = try target()
        let target = Data([1, 2, 3, 4, 5, 6])
        let helper = Helper(net: net, vp9: vp9) { _ in (.init(hopPrefix: nil, nextBudget: 0), impostor) }
        try helper.listener.start(now: 0)
        let c1 = caller(target: target, helper: helper.identity.nodeId.prefix, budget: 1)
        try c1.start(now: 0)
        net.pairs.append((c1, helper.listener)); net.pump()
        XCTAssertEqual(c1.relaySetupFailure, .childAuthentication, c1.closeReason ?? "-")
        XCTAssertNotEqual(impostor.state?.phase, .incomingRinging)

        let none = Helper(net: net, vp9: vp9) { _ in nil }
        try none.listener.start(now: 0)
        let c2 = caller(target: target, helper: none.identity.nodeId.prefix, budget: 1)
        try c2.start(now: 0)
        net.pairs = [(c2, none.listener)]; net.pump()
        XCTAssertEqual(c2.relaySetupFailure, .noRoute)
    }

    func testANextHopThatNeverConnectsAnswersTimeoutAtTheDeadline() throws {
        let net = Net()
        let target = Data([1, 2, 3, 4, 5, 6])
        let silent = CallRelayLink(role: .responder, transport: .gatt, identity: SoftwareSigningIdentity())
        silent.finish("never answers", error: false)   // a closed link ignores every byte
        let helper = Helper(net: net, vp9: vp9) { _ in (.init(hopPrefix: nil, nextBudget: 0), silent) }
        try helper.listener.start(now: 0)
        let caller = caller(target: target, helper: helper.identity.nodeId.prefix, budget: 1)
        try caller.start(now: 0)
        net.pairs.append((caller, helper.listener)); net.pump()
        net.pairs.removeAll { $0.1 === silent }
        XCTAssertEqual(helper.duty?.state, .waitingForNext)
        net.now = 20.5; helper.duty?.tick(now: 20.5); caller.tick(now: 20.5); net.pump()
        XCTAssertEqual(helper.duty?.failure, .timeout)
        XCTAssertEqual(caller.relaySetupFailure, .timeout, caller.closeReason ?? "-")
    }

    func testAPlainCallToAHelperListenerStillRings() throws {
        let net = Net()
        let helper = Helper(net: net, vp9: vp9) { _ in nil }
        try helper.listener.start(now: 0)
        let caller = CallEngine(role: .caller, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                expectedPeerPrefix: helper.identity.nodeId.prefix, relayed: RelayedCallOptions(featureOn: true))
        try caller.start(now: 0)
        net.pairs.append((caller, helper.listener)); net.pump()
        XCTAssertNil(helper.duty)
        XCTAssertEqual(helper.listener.state?.phase, .incomingRinging)
        XCTAssertFalse(helper.listener.isRelayed)
    }

    func testTheChainGuardNeedsAHandshakeAndTheCalleesAnswer() {
        var guardState = RelayChainGuard(readyAt: 0)
        XCTAssertNil(guardState.violation(now: 9))
        XCTAssertNotNil(guardState.violation(now: 10.1))
        guardState.onRecord(fromCaller: true, type: .endToEndHandshake)
        guardState.onRecord(fromCaller: true, type: .endToEndContent)
        XCTAssertNil(guardState.violation(now: 19))
        XCTAssertNotNil(guardState.violation(now: 20.1), "caller content proves nothing")
        guardState.onRecord(fromCaller: false, type: .endToEndContent)
        XCTAssertTrue(guardState.satisfied)
    }
}
