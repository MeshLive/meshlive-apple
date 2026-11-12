import XCTest
@testable import NearbyCore

/// In-call link renewal (Design SR), the pure parts: the RENEW codec, `K_renew`, the advert UUID, the opening and the two
/// state machines. The known answers are the Windows port's (WP10 step 1a/2), recomputed independently with an RFC 5869
/// HKDF; the inputs are K1 = 00..1f, K2 = 20..3f, callId = 00..0f, ticket = 0102030405060708, challenge = 10 x16,
/// nonce = 20 x16.
final class CallRenewalTests: XCTestCase {
    let k1 = Data(0x00...0x1f)
    let k2 = Data(0x20...0x3f)
    let callId = UUID(uuid: (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15))
    let ticket: UInt64 = 0x0102_0304_0506_0708
    let challenge = Data(repeating: 0x10, count: 16)
    let nonce = Data(repeating: 0x20, count: 16)
    let kRenewHex = "b6871ec67a82939d30a541ae9ddcadd89c3ae8a793b963fa5e6df2108cc88eee"
    let hopHex = "35a81cb71a687b6c107f23142f3e17cab344bf6e35b6f30066e9f27c72b25259" + "8efd2347414e63ca46182f92099abb2d8d688c721c0315d850b2009d5fddf752"

    private func hex(_ s: String) -> Data { Data(hex: s)! }
    private func key() throws -> CallRenewalKey { CallRenewalKey(try CallRenewalCrypto.renewalKey(k1, k2)) }

    // MARK: Wire

    func testRenewRecordsHaveTheirExactLayouts() throws {
        let cases: [(CallRenewalWire.Message, String)] = [
            (.offer(ticket: ticket, role: 0), "01010203040506070800"),
            (.offer(ticket: ticket, role: 1), "01010203040506070801"),
            (.armed(ticket: ticket), "020102030405060708"),
            (.refused(ticket: ticket, reason: .abandoned), "03010203040506070807"),
            (.bind(ticket: ticket, nextSequence: 9), "0401020304050607080000000000000009"),
        ]
        for (message, bytes) in cases {
            XCTAssertEqual(try CallRenewalWire.encode(message), hex(bytes), bytes)
            XCTAssertEqual(try CallRenewalWire.decode(hex(bytes)), message, bytes)
        }
        for reason in CallRenewalWire.Reason.allCases {
            let bytes = try CallRenewalWire.encode(.refused(ticket: ticket, reason: reason))
            XCTAssertEqual(bytes.last, reason.rawValue)
            XCTAssertEqual(try CallRenewalWire.decode(bytes), .refused(ticket: ticket, reason: reason))
        }
    }

    func testMalformedRenewRecordsFailClosed() {
        let bad = [
            "", "01", "0101020304050607080000", "0201020304050607", "02010203040506070800", "04010203040506070800000000000000",
            "01010203040506070802", "03010203040506070800", "03010203040506070808",
            "01000000000000000000", "020000000000000000", "03000000000000000001", "0400000000000000000000000000000001",
            "0401020304050607080000000000000000",
            // A BIND sequence Android reads as a negative Long.
            "040102030405060708ffffffffffffffff",
            "05", "050102030405060708", "00010203040506070800",
        ]
        for bytes in bad {
            XCTAssertThrowsError(try CallRenewalWire.decode(hex(bytes)), bytes)
        }
        XCTAssertThrowsError(try CallRenewalWire.encode(.armed(ticket: 0)))
        XCTAssertThrowsError(try CallRenewalWire.encode(.offer(ticket: ticket, role: 2)))
        XCTAssertThrowsError(try CallRenewalWire.encode(.bind(ticket: ticket, nextSequence: 0)))
    }

    func testTheRenewalBitIsEndToEndAndBothSidesMustSignIt() {
        let base = NodeCapabilities(transportMask: 0x0c, encodeCodecMask: 0, decodeCodecMask: 0, maxBitrateKbps: 0, maxChildren: 0)
        XCTAssertEqual(CallRenewalWire.advertise(base, enabled: false).transportMask, 0x0c)
        let on = CallRenewalWire.advertise(base, enabled: true)
        XCTAssertEqual(on.transportMask, 0x1c)
        XCTAssertTrue(CallRenewalWire.negotiated(enabled: true, peer: on))
        XCTAssertFalse(CallRenewalWire.negotiated(enabled: true, peer: base))
        XCTAssertFalse(CallRenewalWire.negotiated(enabled: false, peer: on))
        XCTAssertTrue(CallRenewalWire.bothSigned(local: on, peer: on))
        XCTAssertFalse(CallRenewalWire.bothSigned(local: on, peer: base))
        XCTAssertFalse(CallRenewalWire.bothSigned(local: base, peer: on))
    }

    // MARK: Crypto known answers

    func testKRenewIsRoleFreeAndBindsBothContentKeys() throws {
        XCTAssertEqual(try CallRenewalCrypto.renewalKey(k1, k2), hex(kRenewHex))
        XCTAssertEqual(try CallRenewalCrypto.renewalKey(k2, k1), hex(kRenewHex), "the same key on both phones")
        XCTAssertNotEqual(try CallRenewalCrypto.renewalKey(k1, k1), hex(kRenewHex))
        XCTAssertThrowsError(try CallRenewalCrypto.renewalKey(Data(count: 31), k2))
    }

    func testTheAdvertUuidIsVersionFourAndNewForEveryTicket() throws {
        let key = hex(kRenewHex)
        let uuid = CallRenewalCrypto.advertUuid(key: key, callId: callId, ticket: ticket)
        XCTAssertEqual(CallRenewalCrypto.uuidBytes(uuid), hex("1cbd9604253146e5971c16182e8a27d4"))
        XCTAssertEqual(uuid.uuidString.lowercased(), "1cbd9604-2531-46e5-971c-16182e8a27d4")
        XCTAssertNotEqual(uuid, CallRenewalCrypto.advertUuid(key: key, callId: callId, ticket: 0x0909_0909_0909_0909))
        XCTAssertNotEqual(uuid, CallRenewalCrypto.advertUuid(key: key, callId: UUID(), ticket: ticket))
    }

    func testTheOpeningMacsAndHopKeysMatchTheKnownAnswers() throws {
        let key = hex(kRenewHex)
        XCTAssertEqual(CallRenewalCrypto.offerMac(key: key, callId: callId, ticket: ticket, challenge: challenge, nonce: nonce),
                       hex("3df605ea7666a5334b26b0e606c4c07f0ae2c96b55e5ff6abaabc41d88c7ea7c"))
        XCTAssertEqual(CallRenewalCrypto.armedMac(key: key, callId: callId, ticket: ticket, challenge: challenge, nonce: nonce),
                       hex("528621dee1790be580515e72d0afece0dc1a1bc562c582491d662794ab3fcd58"))
        let hop = CallRenewalCrypto.hopKeys(key: key, callId: callId, ticket: ticket, challenge: challenge, nonce: nonce)
        XCTAssertEqual(hop.toArmed + hop.toOfferer, hex(hopHex))
        XCTAssertNotEqual(hop.toArmed + hop.toOfferer,
                          { let h = CallRenewalCrypto.hopKeys(key: key, callId: callId, ticket: ticket, challenge: Data(repeating: 0x11, count: 16), nonce: nonce); return h.toArmed + h.toOfferer }())
    }

    // MARK: Opening

    private func pair(armedKey: CallRenewalKey? = nil, offererKey: CallRenewalKey? = nil,
                      admit: @escaping (UInt64, Bool) -> Bool = { _, valid in valid }) throws -> (RenewalOpening, RenewalOpening) {
        let armed = RenewalOpening(armed: try armedKey ?? key(), callId: callId, ticket: ticket, connection: 1, challenge: challenge, admit: admit)
        let offerer = RenewalOpening(offerer: try offererKey ?? key(), callId: callId, ticket: ticket, nonce: nonce)
        return (armed, offerer)
    }

    func testTheOpeningFramesMatchTheKnownAnswersAndProveTheKeyBothWays() throws {
        let (armed, offerer) = try pair()
        let challengeFrame = try XCTUnwrap(armed.start())
        XCTAssertEqual(challengeFrame, Data("SR1C".utf8) + challenge)
        XCTAssertNil(offerer.start(), "the offerer never writes first")
        let proof = try XCTUnwrap(try offerer.receive(challengeFrame))
        XCTAssertEqual(proof.count, 60)
        XCTAssertEqual(proof, Data("SR1P".utf8) + hex("0102030405060708") + nonce + hex("3df605ea7666a5334b26b0e606c4c07f0ae2c96b55e5ff6abaabc41d88c7ea7c"))
        XCTAssertEqual(armed.state, .waiting)
        let confirm = try XCTUnwrap(try armed.receive(proof))
        XCTAssertEqual(confirm, Data("SR1A".utf8) + hex("528621dee1790be580515e72d0afece0dc1a1bc562c582491d662794ab3fcd58"))
        XCTAssertEqual(armed.state, .proved)
        XCTAssertNil(try offerer.receive(confirm))
        XCTAssertEqual(offerer.state, .proved)
        XCTAssertEqual(offerer.sendKey, armed.receiveKey)
        XCTAssertEqual(offerer.receiveKey, armed.sendKey)
        XCTAssertEqual((offerer.sendKey ?? Data()) + (offerer.receiveKey ?? Data()), hex(hopHex))
    }

    func testFramesSplitAnywhereAndTheFirstBms1BytesAreKept() throws {
        let (armed, offerer) = try pair()
        let challengeFrame = try XCTUnwrap(armed.start())
        var proof: Data?
        for byte in challengeFrame { if let out = try offerer.receive(Data([byte])) { proof = out } }
        let proofBytes = try XCTUnwrap(proof)
        let bms1 = Data("BMS1-first-record".utf8)
        XCTAssertNil(try armed.receive(proofBytes.prefix(30)))
        let confirm = try XCTUnwrap(try armed.receive(proofBytes.dropFirst(30) + bms1))
        XCTAssertEqual(armed.takeLeftover(), bms1, "BIND follows the PROOF on the same stream")
        XCTAssertNil(try offerer.receive(confirm + Data([1, 2])))
        XCTAssertEqual(offerer.takeLeftover(), Data([1, 2]))
    }

    func testAPhoneWithoutTheKeyCannotProveOrConfirm() throws {
        let other = CallRenewalKey(try CallRenewalCrypto.renewalKey(k1, k1))
        // A squatter that heard the advert: its PROOF is refused, no CONFIRM leaves the armed phone.
        var admitted: [(UInt64, Bool)] = []
        let (armed, squatter) = try pair(offererKey: other, admit: { admitted.append(($0, $1)); return $1 })
        let proof = try XCTUnwrap(try squatter.receive(try XCTUnwrap(armed.start())))
        XCTAssertNil(try armed.receive(proof))
        XCTAssertEqual(armed.state, .refused)
        XCTAssertNil(armed.sendKey)
        XCTAssertEqual(admitted.map(\.1), [false])
        // A fake armed phone (an advert copied from the air) cannot make a CONFIRM the offerer accepts.
        let (fake, offerer) = try pair(armedKey: other)
        XCTAssertNotNil(try offerer.receive(try XCTUnwrap(fake.start())))
        let forged = CallRenewalFrames.confirm(CallRenewalCrypto.armedMac(key: other.data, callId: callId, ticket: ticket, challenge: challenge, nonce: nonce))
        XCTAssertNil(try offerer.receive(forged))
        XCTAssertEqual(offerer.state, .refused)
        XCTAssertNil(offerer.sendKey)
    }

    func testAReflectedConfirmationOrAWrongMagicIsMalformed() throws {
        let (armed, offerer) = try pair()
        let challengeFrame = try XCTUnwrap(armed.start())
        // The armed phone's own CONFIRM reflected back as a PROOF (wrong magic and length) is a malformed frame.
        let (armed2, _) = try pair()
        _ = armed2.start()
        XCTAssertThrowsError(try armed2.receive(CallRenewalFrames.confirm(Data(count: 32)) + Data(count: 24)))
        XCTAssertThrowsError(try offerer.receive(Data("SR1P".utf8) + challenge), "a PROOF is not a CHALLENGE")
        XCTAssertThrowsError(try CallRenewalFrames.parseProof(Data("SR1P".utf8) + Data(count: 56)), "zero ticket")
        _ = challengeFrame
    }

    func testAConnectionWhoseFirstBytesAreNotTheOpeningIsDroppedAtOnce() throws {
        let (armed, _) = try pair()
        _ = armed.start()
        // A central running an ordinary call (a BMH2 hello starts with its u32 length) is refused on its first byte.
        XCTAssertThrowsError(try armed.receive(Data([0x00])))
        let (armed2, _) = try pair()
        _ = armed2.start()
        XCTAssertNil(try armed2.receive(Data("SR".utf8)), "a split magic waits for more")
        XCTAssertThrowsError(try armed2.receive(Data("1C".utf8)), "SR1C is not a PROOF")
        let (_, offerer) = try pair()
        XCTAssertThrowsError(try offerer.receive(Data("BMS1".utf8)), "the offerer expects the CHALLENGE first")
    }

    func testAnOpeningRetainedPastTheEndOfTheCallCannotUseTheErasedKey() throws {
        let k = try key()
        let armed = RenewalOpening(armed: k, callId: callId, ticket: ticket, connection: 1, challenge: challenge) { _, valid in valid }
        let offerer = RenewalOpening(offerer: k, callId: callId, ticket: ticket, nonce: nonce)
        let challengeFrame = try XCTUnwrap(armed.start())
        k.zero()   // the call ended
        XCTAssertNil(armed.start(), "no challenge after the key was erased")
        XCTAssertThrowsError(try offerer.receive(challengeFrame), "no PROOF can be computed any more")
        let proof = CallRenewalFrames.proof(ticket: ticket, nonce: nonce, mac: Data(count: 32))
        XCTAssertThrowsError(try armed.receive(proof), "no PROOF can be checked any more")
        XCTAssertNil(armed.sendKey)
    }

    func testTheOpeningDropsItsKeysOnceDecided() throws {
        let (armed, offerer) = try pair()
        let proof = try XCTUnwrap(try offerer.receive(try XCTUnwrap(armed.start())))
        let confirm = try XCTUnwrap(try armed.receive(proof))
        _ = try offerer.receive(confirm)
        XCTAssertNotNil(offerer.sendKey)
        offerer.wipe(); armed.wipe()
        XCTAssertNil(offerer.sendKey); XCTAssertNil(offerer.receiveKey); XCTAssertNil(armed.sendKey)
    }

    func testTheArmedMachineDecidesOnAProofForAnotherTicket() throws {
        var seen: [UInt64] = []
        let armed = RenewalOpening(armed: try key(), callId: callId, ticket: ticket, connection: 1, challenge: challenge,
                                   admit: { t, valid in seen.append(t); return valid })
        let offerer = RenewalOpening(offerer: try key(), callId: callId, ticket: ticket + 1, nonce: nonce)
        let proof = try XCTUnwrap(try offerer.receive(try XCTUnwrap(armed.start())))
        XCTAssertNil(try armed.receive(proof))
        XCTAssertEqual(seen, [ticket + 1])
        XCTAssertEqual(armed.state, .refused)
    }

    // MARK: Scope and stall

    private let direct = CallRenewalScope.Facts(gattOnBothEnds: true, relayHops: 0, relayedRoute: false, linkPeerIsEndpointPeer: true, verificationSession: false)

    func testOnlyADirectActiveGattCallMayRenewWithinItsLimits() {
        func refusal(_ facts: CallRenewalScope.Facts? = nil, enabled: Bool = true, negotiated: Bool = true, active: Bool = true,
                     activeFor: TimeInterval = 30, attempts: Int = 0, since: TimeInterval? = nil) -> CallRenewalWire.Reason? {
            CallRenewalScope.refusal(enabled: enabled, negotiated: negotiated, facts: facts ?? direct, phaseActive: active, activeFor: activeFor,
                                     attempts: attempts, sinceLastAttempt: since)
        }
        XCTAssertNil(refusal())
        XCTAssertEqual(refusal(enabled: false), .disabled)
        XCTAssertEqual(refusal(negotiated: false), .disabled)
        var f = direct; f.gattOnBothEnds = false; XCTAssertEqual(refusal(f), .notDirect)
        f = direct; f.relayHops = 1; XCTAssertEqual(refusal(f), .notDirect)
        f = direct; f.relayedRoute = true; XCTAssertEqual(refusal(f), .notDirect)
        f = direct; f.linkPeerIsEndpointPeer = false; XCTAssertEqual(refusal(f), .notDirect)
        f = direct; f.verificationSession = true; XCTAssertEqual(refusal(f), .notDirect)
        XCTAssertEqual(refusal(active: false), .limit)
        XCTAssertEqual(refusal(activeFor: 9.9), .limit)
        XCTAssertNil(refusal(activeFor: 10))
        XCTAssertEqual(refusal(attempts: 2), .limit)
        XCTAssertEqual(refusal(attempts: 1, since: 59.9), .limit)
        XCTAssertNil(refusal(attempts: 1, since: 60))
    }

    func testTheSoftStateIsSilenceWhileOwnWritesComplete() {
        XCTAssertFalse(RenewalStall.soft(now: 10, lastReceived: 7.1, lastSendProgress: 10))
        XCTAssertTrue(RenewalStall.soft(now: 10, lastReceived: 7, lastSendProgress: 9))
        XCTAssertFalse(RenewalStall.soft(now: 10, lastReceived: 7, lastSendProgress: 8), "own writes stalled too")
        XCTAssertEqual(RenewalStall.verdict(enabled: false, now: 10, lastReceived: 2, lastSendProgress: 10), .end)
        XCTAssertEqual(RenewalStall.verdict(enabled: true, now: 10, lastReceived: 2, lastSendProgress: 10), .poor, "tolerated while sending")
        XCTAssertEqual(RenewalStall.verdict(enabled: true, now: 16, lastReceived: 2, lastSendProgress: 16), .end, "14 s at most")
        XCTAssertEqual(RenewalStall.verdict(enabled: true, now: 10, lastReceived: 2, lastSendProgress: 7), .end)
    }

    // MARK: Offerer

    func testTheOffererKeepsTheOldLinkUntilItSeesTheAdvert() {
        let o = RenewalOfferer()
        XCTAssertFalse(o.shouldTrigger(softSince: nil, now: 5))
        XCTAssertFalse(o.shouldTrigger(softSince: 4.5, now: 5))
        XCTAssertTrue(o.shouldTrigger(softSince: 4, now: 5))
        o.offer(ticket: ticket, now: 100)
        XCTAssertTrue(o.ownsLiveness)
        XCTAssertTrue(o.ownOfferPending)
        XCTAssertEqual(o.connectBudget(now: 101), 0, "no budget before the break")
        XCTAssertEqual(o.tick(now: 105.9), .none)
        XCTAssertEqual(o.tick(now: 106), .stopScan, "not found in 6 s: the old link stays")
        XCTAssertFalse(o.ownsLiveness)
        XCTAssertFalse(o.onAdvertFound(now: 106.5), "a sighting after the scan window is ignored")
        XCTAssertEqual(o.tick(now: 113), .none, "the old link is under the normal rules again")
        o.reset()
        XCTAssertEqual(o.phase, .idle)
    }

    func testTheOffererConnectsWithinItsBudgetAndEndsTheCallAtTheBound() {
        let o = RenewalOfferer()
        o.offer(ticket: ticket, now: 0)
        XCTAssertTrue(o.onAdvertFound(now: 2))
        XCTAssertEqual(o.phase, .connecting)
        XCTAssertEqual(o.connectBudget(now: 2), 9)
        XCTAssertTrue(o.mayRetry(now: 10.9))
        XCTAssertFalse(o.mayRetry(now: 11))
        XCTAssertEqual(o.connectBudget(now: 11.5), 0)
        XCTAssertFalse(o.onPeerHeard(), "after the break the old link is gone")
        XCTAssertEqual(o.tick(now: 12), .endCall)
        XCTAssertFalse(o.onBound(now: 12), "a late proof never binds")
    }

    func testTheOffererBindsOnlyBeforeTheBoundAndAbandonsWhenThePeerIsHeard() {
        let o = RenewalOfferer()
        o.offer(ticket: ticket, now: 0)
        XCTAssertTrue(o.onAdvertFound(now: 1))
        XCTAssertTrue(o.onBound(now: 11.9))
        XCTAssertTrue(o.ownsLiveness)
        o.reset()
        XCTAssertEqual(o.phase, .idle)
        let heard = RenewalOfferer()
        heard.offer(ticket: ticket, now: 0)
        XCTAssertTrue(heard.onPeerHeard())
        XCTAssertEqual(heard.phase, .abandoned)
        XCTAssertFalse(heard.onAdvertFound(now: 1))
        let refused = RenewalOfferer()
        refused.offer(ticket: ticket, now: 0)
        XCTAssertTrue(refused.onRefused())
        XCTAssertFalse(refused.ownsLiveness)
        XCTAssertFalse(refused.ownOfferPending, "a refused offer is no longer pending")
    }

    func testOnCollisionTheCallerKeepsItsOfferAndTheCalleeYields() {
        XCTAssertTrue(RenewalCollision.keepOwn(ownRole: 0))
        XCTAssertFalse(RenewalCollision.keepOwn(ownRole: 1))
        let callee = RenewalOfferer()
        callee.offer(ticket: ticket, now: 0)
        XCTAssertTrue(callee.yieldToPeer())
        callee.reset()
        XCTAssertEqual(callee.phase, .idle)
    }

    // MARK: Armed

    func testTheArmedPhoneChallengesAtMostEightConnectionsAndConsumesTheTicketOnce() {
        let a = RenewalArmed()
        XCTAssertTrue(a.onOffer(ticket: ticket, refusal: nil, now: 0))
        XCTAssertFalse(a.onOffer(ticket: ticket + 1, refusal: nil, now: 0.5), "one attempt at a time")
        XCTAssertEqual(a.onConnection(1, now: 0.1), .drop, "not armed yet")
        XCTAssertTrue(a.onServerReady(now: 0.2))
        XCTAssertTrue(a.suspendsLiveness)
        for id in 1...8 { XCTAssertEqual(a.onConnection(id, now: 1), .challenge(id)) }
        XCTAssertEqual(a.onConnection(9, now: 1), .drop, "at most 8 challenged connections per attempt")
        XCTAssertFalse(a.proofOverdue(1, now: 1.9))
        XCTAssertTrue(a.proofOverdue(1, now: 2), "a squatter is dropped 1 s after its challenge")
        XCTAssertEqual(a.onProof(1, ticket: ticket, valid: true, now: 2), .drop, "too late")
        XCTAssertEqual(a.onProof(2, ticket: ticket, valid: false, now: 1.5), .drop)
        XCTAssertEqual(a.onProof(3, ticket: ticket + 1, valid: true, now: 1.5), .drop)
        XCTAssertEqual(a.onProof(4, ticket: ticket, valid: true, now: 1.5), .confirm)
        XCTAssertEqual(a.onProof(5, ticket: ticket, valid: true, now: 1.5), .drop, "the ticket is single use")
        XCTAssertEqual(a.onBind(connection: nil, ticket: ticket, firstRecord: true), .ignore, "old link")
        XCTAssertEqual(a.onBind(connection: 5, ticket: ticket, firstRecord: true), .ignore, "unproved link")
        XCTAssertEqual(a.onBind(connection: 4, ticket: ticket, firstRecord: false), .ignore, "not the first record")
        XCTAssertEqual(a.onBind(connection: 4, ticket: ticket + 1, firstRecord: true), .ignore, "another ticket")
        XCTAssertEqual(a.onBind(connection: 4, ticket: ticket, firstRecord: true), .accept)
        XCTAssertEqual(a.onBind(connection: 4, ticket: ticket, firstRecord: true), .ignore, "once")
        a.reset()
        XCTAssertEqual(a.phase, .idle)
    }

    func testTheArmedWindowStopsTheAdvertAndDisarmsOrEndsAtTheBound() {
        let a = RenewalArmed()
        XCTAssertTrue(a.onOffer(ticket: ticket, refusal: nil, now: 0))
        XCTAssertTrue(a.onServerReady(now: 1))
        XCTAssertEqual(a.tick(oldLinkAlive: true, now: 6.9), .none)
        XCTAssertEqual(a.tick(oldLinkAlive: true, now: 7), .stopAdvert)
        XCTAssertEqual(a.tick(oldLinkAlive: true, now: 8), .none)
        XCTAssertEqual(a.tick(oldLinkAlive: true, now: 12), .disarm, "the offerer kept the old link")
        XCTAssertFalse(a.suspendsLiveness)
        let lost = RenewalArmed()
        XCTAssertTrue(lost.onOffer(ticket: ticket, refusal: nil, now: 0))
        XCTAssertTrue(lost.onServerReady(now: 1))
        XCTAssertEqual(lost.tick(oldLinkAlive: false, now: 12), .endCall)
    }

    func testTheArmedPhoneRefusesOrTimesOutItsRegistrationAndDisarmsWhenAbandoned() {
        let refused = RenewalArmed()
        XCTAssertFalse(refused.onOffer(ticket: ticket, refusal: .limit, now: 0))
        XCTAssertEqual(refused.phase, .idle)
        let slow = RenewalArmed()
        XCTAssertTrue(slow.onOffer(ticket: ticket, refusal: nil, now: 0))
        XCTAssertEqual(slow.tick(oldLinkAlive: true, now: 3), .refuseRegistration)
        XCTAssertFalse(slow.onServerReady(now: 3.1), "a registration that finishes later is closed")
        let abandoned = RenewalArmed()
        XCTAssertTrue(abandoned.onOffer(ticket: ticket, refusal: nil, now: 0))
        XCTAssertTrue(abandoned.onServerReady(now: 0.5))
        XCTAssertFalse(abandoned.onAbandoned(ticket: ticket + 1), "another ticket")
        XCTAssertTrue(abandoned.onAbandoned(ticket: ticket))
        XCTAssertFalse(abandoned.suspendsLiveness)
        XCTAssertEqual(abandoned.onConnection(1, now: 1), .drop)
    }

    func testAttemptsCountAndSpace() {
        var attempts = RenewalAttempts()
        XCTAssertNil(attempts.sinceLast(now: 5))
        attempts.record(now: 10)
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts.sinceLast(now: 40), 30)
    }

    func testTheKeyIsZeroedOnRequest() throws {
        let k = try key()
        XCTAssertEqual(k.data, hex(kRenewHex))
        k.zero()
        XCTAssertTrue(k.zeroed)
        XCTAssertEqual(k.data, Data(count: 32))
    }
}
