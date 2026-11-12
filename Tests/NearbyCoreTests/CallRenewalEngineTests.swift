import XCTest
import CryptoKit
@testable import NearbyCore

/// In-call link renewal (Design SR) between two real call engines over an in-memory fake radio: the old link, the armed
/// phone's advert, the offerer's scan and connect, the opening on a new link and the switch. The end-to-end session, the
/// call ID and the call state continue; only the hop link is new.
private final class RenewalRadio {
    let a: CallEngine, b: CallEngine
    var now: TimeInterval = 0
    /// The old link carries bytes (false once the offerer broke it).
    var oldLinkUp = true
    /// Bytes on the old link from this engine are held (a one-way stall: delayed, never lost).
    var stalled: Set<ObjectIdentifier> = []
    private var held: [ObjectIdentifier: [Data]] = [:]
    /// A stalled engine whose held bytes still trickle out one byte per second (never a complete record).
    var dribble: Set<ObjectIdentifier> = []
    private var lastDribble: [ObjectIdentifier: TimeInterval] = [:]
    /// The armed advert is visible to scanners (false: the offerer never sees it).
    var advertVisible = true
    /// A connect to the advertiser succeeds (false: the GATT connection fails every time).
    var connectWorks = true
    private(set) var scans: [ObjectIdentifier: UUID] = [:]
    private(set) var adverts: [ObjectIdentifier: UUID] = [:]
    private(set) var requests: [ObjectIdentifier: [CallRenewalAgent.Request]] = [:]
    private(set) var logs: [(String, [String: String])] = []
    /// The renewed link: who is on it, and the armed side's connection while its BIND is pending.
    private(set) var newLink: (offerer: CallEngine, armed: CallEngine, connection: Int, armedSwitched: Bool)?
    /// The armed side's renewal connections the radio holds (as the app's radio: one is out of this set while the engine
    /// decides on its input). `.endAttempt` closes every one still in it.
    private var openCandidates: Set<Int> = []
    /// The armed side's renewal connection was closed by the radio.
    private(set) var armedLinkClosed = false

    init(_ a: CallEngine, _ b: CallEngine) {
        self.a = a; self.b = b
        for engine in [a, b] {
            let id = ObjectIdentifier(engine)
            engine.onRenewalRequest = { [unowned self] request in self.handle(request, from: engine, id: id) }
            engine.onRenewalLog = { [unowned self] event, fields in self.logs.append((event, fields)) }
        }
    }

    private func handle(_ request: CallRenewalAgent.Request, from engine: CallEngine, id: ObjectIdentifier) {
        requests[id, default: []].append(request)
        switch request {
        case .startScan(let uuid): scans[id] = uuid
        case .stopScan: scans[id] = nil
        case .breakOldLink: oldLinkUp = false
        case .startAdvert(let uuid):
            adverts[id] = uuid
            engine.renewalArmReady(true, now: now)
        case .stopAdvert: adverts[id] = nil
        case .endAttempt:
            adverts[id] = nil
            if let link = newLink, link.armed === engine, openCandidates.contains(link.connection) { armedLinkClosed = true }
            openCandidates = []
        }
    }

    func other(_ e: CallEngine) -> CallEngine { e === a ? b : a }

    private func deliver(from: CallEngine) {
        let to = other(from)
        let id = ObjectIdentifier(from)
        if let link = newLink, link.offerer === from || link.armed === from {
            if armedLinkClosed {
                // The renewal connection was closed under the call: nothing crosses it any more.
                while from.nextOutgoing(now: now) != nil {}
                return
            }
            // On the renewed link: the armed side reads BIND as a candidate first, then everything as the call's link.
            let fromArmedBeforeSwitch = from === link.armed && !link.armedSwitched
            if fromArmedBeforeSwitch {
                // The armed phone still sends on its old link (stalled or broken): nothing reaches the new one.
                while let bytes = from.nextOutgoing(now: now) { if oldLinkUp { hold(bytes, id) } }
                return
            }
            while let bytes = from.nextOutgoing(now: now) {
                if to === link.armed && !(newLink?.armedSwitched ?? true) {
                    openCandidates.remove(link.connection)
                    switch to.renewalCandidateReceive(link.connection, bytes, now: now) {
                    case .switched: newLink?.armedSwitched = true
                    case .pending: openCandidates.insert(link.connection)
                    case .refused: XCTFail("BIND refused")
                    }
                } else {
                    to.receive(bytes, now: now)
                }
            }
            return
        }
        while let bytes = from.nextOutgoing(now: now) {
            guard oldLinkUp else { continue }
            hold(bytes, id)
        }
        if !stalled.contains(id), oldLinkUp {
            for bytes in held[id] ?? [] { to.receive(bytes, now: now) }
            held[id] = []
        } else if dribble.contains(id), oldLinkUp, now - (lastDribble[id] ?? 0) >= 1, var queue = held[id], let first = queue.first {
            lastDribble[id] = now
            to.receive(first.prefix(1), now: now)
            if first.count > 1 { queue[0] = first.dropFirst().rebased } else { queue.removeFirst() }
            held[id] = queue
        }
    }

    private func hold(_ bytes: Data, _ id: ObjectIdentifier) { held[id, default: []].append(bytes) }

    /// The offerer scans for exactly the UUID the other phone advertises.
    private func radio() {
        guard newLink == nil, advertVisible else { return }
        for offerer in [a, b] {
            let armed = other(offerer)
            guard let scan = scans[ObjectIdentifier(offerer)], adverts[ObjectIdentifier(armed)] == scan else { continue }
            guard offerer.renewalAdvertSeen(now: now) else { continue }
            guard connectWorks else { offerer.renewalConnectFailed("connect", now: now); continue }
            guard let armedOpening = armed.renewalAcceptConnection(now: now), let offererOpening = offerer.renewalOffererOpening(now: now) else {
                XCTFail("no opening"); return
            }
            do {
                let proof = try XCTUnwrap(try offerer.renewalOpeningReceive(offererOpening, try XCTUnwrap(armedOpening.start()), now: now))
                let confirm = try XCTUnwrap(try armed.renewalOpeningReceive(armedOpening, proof, now: now))
                XCTAssertEqual(armed.renewalArmedProved(armedOpening, now: now), .pending)
                openCandidates.insert(armedOpening.connection)
                XCTAssertNil(try offererOpening.receive(confirm))
                XCTAssertTrue(offerer.renewalOffererProved(offererOpening, now: now))
                newLink = (offerer, armed, armedOpening.connection, false)
            } catch { XCTFail("\(error)") }
            return
        }
    }

    func step(_ seconds: TimeInterval = 0.1) {
        now += seconds
        a.tick(now: now); b.tick(now: now)
        radio()
        for _ in 0..<20 { deliver(from: a); deliver(from: b) }
    }

    func run(for seconds: TimeInterval, every: TimeInterval = 0.1) {
        let end = now + seconds
        while now < end - 1e-9 { step(every) }
    }

    func requests(of e: CallEngine) -> [CallRenewalAgent.Request] { requests[ObjectIdentifier(e)] ?? [] }
    func phases(_ role: String) -> [String] { logs.filter { $0.0 == "call_renewal" && $0.1["role"] == role }.compactMap { $0.1["phase"] } }
    func stall(_ e: CallEngine) { stalled.insert(ObjectIdentifier(e)) }
    func unstall(_ e: CallEngine) { stalled.remove(ObjectIdentifier(e)) }
}

final class CallRenewalEngineTests: XCTestCase {
    let vp9 = NodeCapabilities.codecVP9

    private func makeCall(transport: MeshTransport = .gatt, callerRenewal: Bool = true, calleeRenewal: Bool = true) throws -> (CallEngine, CallEngine, RenewalRadio) {
        let callerId = SoftwareSigningIdentity(), calleeId = SoftwareSigningIdentity()
        let caller = CallEngine(role: .caller, transport: transport, identity: callerId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                expectedPeerPrefix: calleeId.nodeId.prefix, linkRenewal: callerRenewal)
        let callee = CallEngine(role: .callee, transport: transport, identity: calleeId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                linkRenewal: calleeRenewal)
        let radio = RenewalRadio(caller, callee)
        try caller.start(now: 0); try callee.start(now: 0)
        radio.step()
        try callee.accept(as: .voice)
        radio.step()
        XCTAssertEqual(caller.state?.phase, .active, caller.closeReason ?? "")
        XCTAssertEqual(callee.state?.phase, .active, callee.closeReason ?? "")
        return (caller, callee, radio)
    }

    private func audio(_ engine: CallEngine, _ radio: RenewalRadio, count: Int) {
        for i in 0..<count {
            engine.sendAudio(presentationTimeUs: Int64(radio.now * 1_000_000) + Int64(i) * 20_000, opus: Data([0xf8, 0xff, 0xfe, UInt8(i & 0xff)]))
        }
    }

    /// A one-way stall (the armed phone's writes stop): the phone that stopped hearing offers, the stalled phone arms,
    /// the offerer breaks only after it saw the advert, and both continue the same call on the renewed link.
    private func renewsAndKeepsTheCall(offererIsCaller: Bool) throws {
        let (caller, callee, radio) = try makeCall()
        XCTAssertTrue(caller.renewalNegotiated && callee.renewalNegotiated)
        let offerer = offererIsCaller ? caller : callee, armed = offererIsCaller ? callee : caller
        let session = (caller.endpoint?.sealer, callee.endpoint?.opener)
        let callId = caller.state?.callId
        radio.run(for: 11)   // ACTIVE for at least 10 s
        radio.stall(armed)   // the armed phone's sending stalls; it still hears its peer
        radio.run(for: 2.5)
        XCTAssertEqual(offerer.renewal?.offerer.phase, .idle, "3 s of silence plus 1 s of the soft state before an offer")
        radio.run(for: 2.0)
        XCTAssertNotNil(radio.newLink, "offered, armed, found, proved: \(radio.logs)")
        XCTAssertFalse(radio.oldLinkUp, "the offerer broke the old link only after it saw the advert")
        radio.run(for: 2)
        XCTAssertEqual(radio.newLink?.armedSwitched, true, "BIND accepted as the first record of the proved link")
        XCTAssertFalse(radio.armedLinkClosed, "ending the attempt never closes the connection that just became the call's link")
        XCTAssertEqual(offerer.renewal?.bound, 1)
        XCTAssertEqual(armed.renewal?.bound, 1)
        XCTAssertEqual(radio.phases("offerer"), ["offer", "scan", "found", "connecting", "proved", "bound"])
        XCTAssertEqual(radio.phases("armed"), ["offer", "armed", "proved", "bound"])
        XCTAssertEqual(radio.logs.filter { $0.0 == "call_renewal_silence" }.count, 2, "each side logs the cost of the renewal once")
        XCTAssertEqual(Set(radio.logs.filter { $0.0 == "call_renewal_silence" }.compactMap { $0.1["role"] }), ["offerer", "armed"])
        // The same end-to-end session and call: the content sealer and opener are the same objects, the call ID too.
        XCTAssertTrue(caller.endpoint?.sealer === session.0 && callee.endpoint?.opener === session.1)
        XCTAssertEqual(caller.state?.callId, callId)
        XCTAssertEqual(callee.state?.callId, callId)
        // Media flows both ways on the renewed link, and the call outlives every liveness bound.
        let before = (caller.receivedAudioPackets, callee.receivedAudioPackets)
        audio(caller, radio, count: 5); audio(callee, radio, count: 5)
        radio.run(for: 20)
        XCTAssertEqual(caller.receivedAudioPackets, before.0 + 5)
        XCTAssertEqual(callee.receivedAudioPackets, before.1 + 5)
        XCTAssertEqual(caller.state?.phase, .active, caller.closeReason ?? "")
        XCTAssertEqual(callee.state?.phase, .active, callee.closeReason ?? "")
        XCTAssertNotEqual(caller.phase, .closed)
    }

    func testTheCallerRenewsTheLinkWhenTheCalleeStopsSending() throws { try renewsAndKeepsTheCall(offererIsCaller: true) }

    func testTheCalleeRenewsTheLinkWhenTheCallerStopsSending() throws { try renewsAndKeepsTheCall(offererIsCaller: false) }

    func testTheDebugWriteStallInducesARenewalOnTheFirstLinkOnly() throws {
        let (caller, callee, radio) = try makeCall()
        var stalls = 0
        callee.onDebugTxStall = { stalls += 1 }
        callee.debugTxStallAfter = 12
        radio.run(for: 20)
        XCTAssertEqual(stalls, 1)
        XCTAssertEqual(caller.renewal?.bound, 1, "\(radio.logs)")
        XCTAssertEqual(callee.renewal?.bound, 1)
        radio.run(for: 20)
        XCTAssertEqual(caller.state?.phase, .active, caller.closeReason ?? "")
        XCTAssertEqual(callee.state?.phase, .active)
        XCTAssertEqual(caller.renewal?.attempts.count, 1, "the renewed link is not stalled")
    }

    func testAnAdvertNeverSeenKeepsTheOldLinkUnderTheNormalLivenessRules() throws {
        let (caller, callee, radio) = try makeCall()
        radio.advertVisible = false
        radio.run(for: 11)
        radio.stall(callee)
        radio.run(for: 4.5)
        XCTAssertEqual(caller.renewal?.offerer.phase, .scanning)
        XCTAssertEqual(callee.renewal?.armed.phase, .armed)
        radio.run(for: 6)
        XCTAssertEqual(caller.renewal?.offerer.phase, .waitingOldLink, "not found in 6 s: the old link stays")
        XCTAssertTrue(radio.oldLinkUp)
        XCTAssertFalse(radio.requests(of: caller).contains(.breakOldLink))
        XCTAssertNil(radio.scans[ObjectIdentifier(caller)])
        XCTAssertNotEqual(caller.phase, .closed, "the old link is kept up to 14 s of silence while this phone still sends")
        radio.run(for: 4)
        XCTAssertEqual(caller.phase, .closed)
        XCTAssertEqual(caller.closeReason, "Call peer stopped responding", "the normal liveness close, not the renewal's")
    }

    func testThePeerHeardAgainBeforeTheBreakAbandonsTheRenewal() throws {
        let (caller, callee, radio) = try makeCall()
        radio.advertVisible = false
        radio.run(for: 11)
        radio.stall(callee)
        radio.run(for: 4.2)
        XCTAssertEqual(callee.renewal?.armed.phase, .armed)
        radio.unstall(callee)
        radio.run(for: 0.5)
        XCTAssertTrue(radio.phases("offerer").contains("abandoned"))
        XCTAssertEqual(caller.renewal?.offerer.phase, .idle)
        XCTAssertEqual(callee.renewal?.armed.phase, .idle, "REFUSED abandoned disarms the armed phone")
        XCTAssertTrue(radio.phases("armed").contains("disarmed"))
        XCTAssertNil(radio.scans[ObjectIdentifier(caller)])
        XCTAssertNil(radio.adverts[ObjectIdentifier(callee)])
        radio.run(for: 10)
        XCTAssertEqual(caller.state?.phase, .active)
    }

    func testAnOffererThatCannotConnectEndsTheCallTwelveSecondsAfterItsOffer() throws {
        let (caller, callee, radio) = try makeCall()
        radio.connectWorks = false
        radio.run(for: 11)
        radio.stall(callee)
        radio.run(for: 4.5)
        XCTAssertFalse(radio.oldLinkUp)
        XCTAssertEqual(caller.renewal?.offerer.phase, .connecting)
        // The armed phone's old link closes under it: its renewal owns its liveness.
        callee.linkLost("The peer closed the link")
        XCTAssertNotEqual(callee.phase, .closed, "the armed phone's renewal owns its liveness")
        radio.run(for: 12)
        XCTAssertEqual(caller.phase, .closed)
        XCTAssertEqual(caller.closeReason, "Call link lost: the link renewal did not complete")
        radio.run(for: 1)
        XCTAssertEqual(callee.phase, .closed)
        XCTAssertEqual(callee.closeReason, "Call link lost: the link renewal did not complete")
    }

    func testARenewalIsNotOfferedOnACocCallWhichEndsAtItsLivenessBound() throws {
        let (caller, callee, radio) = try makeCall(transport: .l2cap)
        XCTAssertTrue(caller.renewalNegotiated, "negotiated, but out of scope")
        radio.run(for: 11)
        radio.stall(callee)
        radio.run(for: 5)
        XCTAssertEqual(radio.phases("offerer"), ["not_offered"])
        XCTAssertEqual(radio.logs.first { $0.1["phase"] == "not_offered" }?.1["reason"], "not_direct")
        radio.run(for: 4)
        XCTAssertEqual(caller.phase, .closed, "8 s of silence ends a call that cannot renew")
        _ = callee
    }

    func testOneSideWithoutTheSwitchNegotiatesNothingAndRefusesType12() throws {
        let (caller, callee, radio) = try makeCall(calleeRenewal: false)
        XCTAssertFalse(caller.renewalNegotiated)
        XCTAssertFalse(callee.renewalNegotiated)
        XCTAssertNil(callee.renewal)
        XCTAssertEqual((callee.endpoint?.peerCapabilities.transportMask ?? 0) & CallRenewalWire.capabilityBit, CallRenewalWire.capabilityBit)
        XCTAssertEqual((caller.endpoint?.peerCapabilities.transportMask ?? 0x10) & CallRenewalWire.capabilityBit, 0)
        XCTAssertNil(caller.endpoint?.renewalKey.flatMap { $0.zeroed ? nil : $0 }, "no K_renew without both bits")
        XCTAssertEqual(caller.endpoint?.opener.acceptRenewal, false)
        // A RENEW record to an endpoint that did not negotiate it is an unknown type: the opener fails closed.
        let key = SymmetricKey(size: .bits256)
        let sealer = EndToEndContentSealer(key: key), opener = EndToEndContentOpener(key: key)
        XCTAssertThrowsError(try opener.open(try sealer.seal(.renew, try CallRenewalWire.encode(.armed(ticket: 1)))))
        opener.acceptRenewal = true
        XCTAssertEqual(try opener.open(try sealer.seal(.renew, try CallRenewalWire.encode(.armed(ticket: 1)))).type, .renew)
        radio.run(for: 11)
        radio.stall(callee)
        radio.run(for: 6)
        XCTAssertTrue(radio.requests(of: caller).isEmpty, "no renewal without negotiation")
        radio.run(for: 3)
        XCTAssertEqual(caller.phase, .closed, "the call ends as before")
    }

    func testBothSessionsDeriveTheSameRenewalKeyAndZeroItWhenTheCallEnds() throws {
        let (caller, callee, radio) = try makeCall()
        let a = try XCTUnwrap(caller.endpoint?.renewalKey), b = try XCTUnwrap(callee.endpoint?.renewalKey)
        XCTAssertEqual(a.data, b.data)
        XCTAssertEqual(a.data.count, 32)
        caller.end()
        radio.run(for: 1)
        XCTAssertTrue(a.zeroed)
        XCTAssertTrue(b.zeroed)
    }

    /// Review finding 8: partial bytes of a record (a valid header, never a whole record) must not postpone the renewal
    /// or the silence close; only complete authenticated records count.
    func testADribbleOfPartialRecordBytesPostponesNeitherTheRenewalNorTheSilenceClose() throws {
        let (caller, callee, radio) = try makeCall()
        radio.advertVisible = false
        radio.run(for: 11)
        radio.stall(callee); radio.dribble.insert(ObjectIdentifier(callee))
        radio.run(for: 4.5)
        XCTAssertEqual(caller.renewal?.offerer.phase, .scanning, "offered 4 s after the last complete record")
        radio.run(for: 11)
        XCTAssertEqual(caller.phase, .closed)
        XCTAssertEqual(caller.closeReason, "Call peer stopped responding", "14 s after the last complete record at most")
    }

    /// Review finding 3: records handed to a transport whose writes never complete are not "own writes complete": no
    /// renewal is offered and the call ends at the plain 8 s silence close (both directions dead).
    func testRecordsQueuedOnABlockedTransportDoNotKeepTheRenewalOrTheToleranceAlive() throws {
        let (caller, callee, radio) = try makeCall()
        radio.run(for: 11)
        let blockedAt = radio.now
        caller.writeProgress = { blockedAt }   // the transport's last completed write
        radio.stall(caller); radio.stall(callee)
        radio.run(for: 6.5)
        XCTAssertNotEqual(caller.phase, .closed)
        radio.run(for: 2.6)
        XCTAssertEqual(caller.phase, .closed, "8 s of silence, writes stalled: no tolerance")
        XCTAssertFalse(radio.requests(of: caller).contains { if case .startScan = $0 { return true }; return false }, "no offer")
    }

    /// Review finding 5: a PROOF that arrives just after the 1 s window, with no engine tick in between, is judged at its
    /// own arrival time and refused; one in time is confirmed.
    func testAProofJustAfterItsWindowIsRefusedWithoutAnInterveningTick() throws {
        let (caller, callee, radio) = try makeCall()
        radio.advertVisible = false
        radio.run(for: 11)
        radio.stall(callee)
        radio.run(for: 4.5)
        let ticket = try XCTUnwrap(callee.renewal?.armed.ticket)
        XCTAssertEqual(callee.renewal?.armed.phase, .armed)
        let key = try XCTUnwrap(caller.endpoint?.renewalKey), callId = try XCTUnwrap(caller.state?.callId)
        let late = try XCTUnwrap(callee.renewalAcceptConnection(now: radio.now))
        let lateOfferer = RenewalOpening(offerer: key, callId: callId, ticket: ticket)
        let lateProof = try XCTUnwrap(try lateOfferer.receive(try XCTUnwrap(late.start())))
        XCTAssertNil(try callee.renewalOpeningReceive(late, lateProof, now: radio.now + 1.05))
        XCTAssertEqual(late.state, .refused, "judged at its arrival, not at the last tick")
        let inTime = try XCTUnwrap(callee.renewalAcceptConnection(now: radio.now))
        let offerer = RenewalOpening(offerer: key, callId: callId, ticket: ticket)
        let proof = try XCTUnwrap(try offerer.receive(try XCTUnwrap(inTime.start())))
        XCTAssertNotNil(try callee.renewalOpeningReceive(inTime, proof, now: radio.now + 0.5), "a proof in time is confirmed")
        XCTAssertEqual(inTime.state, .proved)
    }

    func testANotYetActiveOrTooYoungCallIsRefusedWithTheLimitReason() throws {
        let (caller, callee, radio) = try makeCall()
        radio.run(for: 2)
        radio.stall(callee)
        radio.run(for: 4.5)
        XCTAssertEqual(radio.logs.first { $0.1["phase"] == "not_offered" }?.1["reason"], "limit")
        XCTAssertTrue(radio.requests(of: caller).isEmpty)
        _ = callee
    }
}

/// The agent alone against a fake host: collisions, limits, duplicate and late messages.
private final class FakeHost: CallRenewalHost {
    var renewalNow: TimeInterval = 100
    var renewalFacts = CallRenewalScope.Facts(gattOnBothEnds: true, relayHops: 0, relayedRoute: false, linkPeerIsEndpointPeer: true, verificationSession: false)
    var renewalCallActive = true
    var renewalActiveAt: TimeInterval? = 0
    var renewalCallId: UUID? = UUID()
    var renewalLastReceiveAt: TimeInterval = 100
    var renewalLastSendAt: TimeInterval = 100
    let link = SecureLink(role: .initiator, identity: SoftwareSigningIdentity(),
                          capabilities: NodeCapabilities(transportMask: 4, encodeCodecMask: 0, decodeCodecMask: 0, maxBitrateKbps: 0, maxChildren: 0))
    var renewalCurrentLink: SecureLink { link }
    var sent: [CallRenewalWire.Message] = []
    var ended: String?
    func renewalSend(_ message: CallRenewalWire.Message) { sent.append(message) }
    func renewalEndCall(_ reason: String) { ended = reason }
    func renewalAdopt(_ link: SecureLink, buffered: Data) {}
    func renewalOpen(_ encoded: Data) throws -> EndToEndContentRecord { throw ProtocolError.state("none") }
    func renewalReassert() {}
}

final class CallRenewalAgentTests: XCTestCase {
    private func agent(role: UInt8) -> (CallRenewalAgent, FakeHost, Box) {
        let host = FakeHost()
        let agent = CallRenewalAgent(enabled: true, role: role)
        agent.host = host
        let box = Box()
        agent.onRequest = { box.requests.append($0) }
        agent.sessionReady(key: CallRenewalKey(Data(repeating: 7, count: 32)), peerSigned: true)
        return (agent, host, box)
    }
    final class Box { var requests: [CallRenewalAgent.Request] = [] }

    /// Soft state for 1 s: the agent offers.
    private func offer(_ agent: CallRenewalAgent, _ host: FakeHost) {
        host.renewalLastReceiveAt = host.renewalNow - 3
        agent.tick()
        host.renewalNow += 1; host.renewalLastSendAt = host.renewalNow
        agent.tick()
    }

    func testOnCollisionTheCallerKeepsItsOfferAndTheCalleeArmsForTheCallers() {
        let (caller, callerHost, _) = agent(role: 0)
        offer(caller, callerHost)
        guard case .offer(let callerTicket, 0)? = callerHost.sent.last else { return XCTFail("\(callerHost.sent)") }
        caller.onRecord(.offer(ticket: 99, role: 1))
        XCTAssertEqual(callerHost.sent.last, .refused(ticket: 99, reason: .collision))
        XCTAssertEqual(caller.offerer.phase, .scanning, "the caller keeps its offer")

        let (callee, calleeHost, calleeBox) = agent(role: 1)
        offer(callee, calleeHost)
        XCTAssertEqual(callee.attempts.count, 1)
        callee.onRecord(.offer(ticket: callerTicket, role: 0))
        XCTAssertEqual(callee.offerer.phase, .idle, "the callee yields")
        XCTAssertEqual(callee.armed.phase, .arming)
        XCTAssertEqual(callee.attempts.count, 1, "a yielding callee does not count the caller's attempt again")
        XCTAssertTrue(calleeBox.requests.contains(.stopScan))
        XCTAssertTrue(calleeBox.requests.contains { if case .startAdvert = $0 { return true }; return false })
    }

    func testAnOfferWithinSixtySecondsOrAThirdAttemptIsRefusedWithTheLimit() {
        let (armed, host, _) = agent(role: 1)
        armed.onRecord(.offer(ticket: 1, role: 0))
        armed.armReady(true, failure: .advertising)
        XCTAssertEqual(host.sent.last, .armed(ticket: 1))
        armed.onRecord(.offer(ticket: 2, role: 0))
        XCTAssertEqual(host.sent.last, .refused(ticket: 2, reason: .limit), "a duplicate offer while armed")
        armed.onRecord(.refused(ticket: 1, reason: .abandoned))
        XCTAssertEqual(armed.armed.phase, .idle)
        host.renewalNow += 59
        armed.onRecord(.offer(ticket: 3, role: 0))
        XCTAssertEqual(host.sent.last, .refused(ticket: 3, reason: .limit), "60 s between attempts")
        host.renewalNow += 1
        armed.onRecord(.offer(ticket: 4, role: 0))
        XCTAssertEqual(armed.armed.phase, .arming)
        armed.onRecord(.refused(ticket: 4, reason: .abandoned))
        host.renewalNow += 61
        armed.onRecord(.offer(ticket: 5, role: 0))
        XCTAssertEqual(host.sent.last, .refused(ticket: 5, reason: .limit), "at most 2 attempts per call")
    }

    func testARegistrationThatTakesThreeSecondsIsRefusedAndALateOneIsClosed() {
        let (armed, host, box) = agent(role: 1)
        armed.onRecord(.offer(ticket: 1, role: 0))
        host.renewalNow += 3
        armed.tick()
        XCTAssertEqual(host.sent.last, .refused(ticket: 1, reason: .serverRegistration))
        XCTAssertEqual(box.requests.last, .endAttempt)
        armed.armReady(true, failure: .advertising)
        XCTAssertFalse(host.sent.contains(.armed(ticket: 1)), "a registration that finished later is never adopted")
        let (failing, failingHost, _) = agent(role: 1)
        failing.onRecord(.offer(ticket: 2, role: 0))
        failing.armReady(false, failure: .advertising)
        XCTAssertEqual(failingHost.sent.last, .refused(ticket: 2, reason: .advertising))
        XCTAssertFalse(failing.ownsLiveness)
    }

    func testLateAndStrayMessagesChangeNothing() {
        let (offerer, host, box) = agent(role: 0)
        offerer.onRecord(.bind(ticket: 5, nextSequence: 9))
        offerer.onRecord(.armed(ticket: 5))
        offerer.onRecord(.refused(ticket: 5, reason: .limit))
        offerer.onRecord(.refused(ticket: 5, reason: .abandoned))
        XCTAssertTrue(host.sent.isEmpty)
        XCTAssertTrue(box.requests.isEmpty)
        offer(offerer, host)
        offerer.onRecord(.refused(ticket: 12345, reason: .limit))
        XCTAssertEqual(offerer.offerer.phase, .scanning, "a refusal of another ticket is ignored")
        guard case .offer(let ticket, _)? = host.sent.last else { return XCTFail() }
        offerer.onRecord(.refused(ticket: ticket, reason: .notDirect))
        XCTAssertEqual(offerer.offerer.phase, .waitingOldLink)
        XCTAssertEqual(box.requests.last, .stopScan)
        XCTAssertFalse(offerer.advertSeen(), "a sighting after the refusal never breaks the old link")
        XCTAssertNil(offerer.offererOpening())
    }

    func testAVerificationOrRelayedCallIsNotDirect() {
        let (offerer, host, _) = agent(role: 0)
        host.renewalFacts.verificationSession = true
        offer(offerer, host)
        XCTAssertTrue(host.sent.isEmpty)
        let (armed, armedHost, _) = agent(role: 1)
        armedHost.renewalFacts.relayHops = 1
        armed.onRecord(.offer(ticket: 1, role: 0))
        XCTAssertEqual(armedHost.sent.last, .refused(ticket: 1, reason: .notDirect))
    }

    func testTheArmedPhoneEndsTheCallAtTwelveSecondsWhenItsOldLinkDied() {
        let (armed, host, _) = agent(role: 1)
        armed.onRecord(.offer(ticket: 1, role: 0))
        armed.armReady(true, failure: .advertising)
        XCTAssertTrue(armed.holdLinkLoss("closed"))
        host.renewalNow += 11.9; armed.tick()
        XCTAssertNil(host.ended)
        host.renewalNow += 0.1; armed.tick()
        XCTAssertEqual(host.ended, "Call link lost: the link renewal did not complete")
    }

    func testALinkLossOutsideARenewalIsNotHeld() {
        let (agent, _, _) = agent(role: 0)
        XCTAssertFalse(agent.holdLinkLoss("closed"))
    }
}
