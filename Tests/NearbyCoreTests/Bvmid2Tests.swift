import XCTest
@testable import NearbyCore

/// BVMID2 against the shared conformance vectors (Fixtures/bvmid2.json, copied byte for byte from the conformance set built
/// from Android's tests) and the K_tag fixture of tools/bmh3_reference.py, then the single-use rules and whole verification
/// sessions over real call engines: a scan reaches the code's key, the code is consumed once, a second phone raises the
/// reuse alert, the Meet screen accepts only its code, and Design QL moves leases only on the second of two scans.
final class Bvmid2VectorTests: XCTestCase {
    private func vectors() throws -> [[String: Any]] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "bvmid2", withExtension: "json", subdirectory: "Fixtures"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(json["vectors"] as? [[String: Any]])
    }
    private func vector(_ id: String) throws -> [String: Any] { try XCTUnwrap(try vectors().first { $0["id"] as? String == id }) }
    private func bytes(_ hex: Any?) throws -> Data { try XCTUnwrap(Data(hex: try XCTUnwrap(hex as? String))) }

    func testTheTagKeyMatchesBvmid2_011AndTheBmh3Fixture() throws {
        let v = try vector("bvmid2-011")
        let inputs = try XCTUnwrap(v["inputs"] as? [String: Any]), expected = try XCTUnwrap(v["expected"] as? [String: Any])
        XCTAssertEqual(inputs["info_ascii"] as? String, String(decoding: Bmh3Crypto.qrTagInfo, as: UTF8.self))
        let key = try Bmh3Crypto.qrTagKey(kQr: try bytes(inputs["k_qr"]))
        XCTAssertEqual(key.hex, expected["k_tag"] as? String)
        XCTAssertEqual(key.hex, Bmh3Vectors.K_TAG_QR)
        XCTAssertEqual(Bmh3Vectors.K_QR, inputs["k_qr"] as? String)
        XCTAssertNotEqual(key.hex, Bmh3Vectors.K_QR)
        XCTAssertNotEqual(key.hex, Bmh3Vectors.K_TAG, "the code's tag key is not a lease tag key")
        XCTAssertThrowsError(try Bmh3Crypto.qrTagKey(kQr: Data(count: 31)))
    }

    func testTheTextRoundTripsAsBvmid2_012() throws {
        let v = try vector("bvmid2-012")
        let inputs = try XCTUnwrap(v["inputs"] as? [String: Any]), expected = try XCTUnwrap(v["expected"] as? [String: Any])
        let payload = try Bvmid2Payload(fingerprint: try IdentityFingerprint(bytes: try bytes(inputs["fingerprint"])),
                                        kQr: try bytes(inputs["k_qr"]), rdi: try bytes(inputs["rdi"]))
        let text = Bvmid2.encode(payload)
        XCTAssertEqual(text, expected["text"] as? String)
        XCTAssertEqual(text.count, expected["length"] as? Int)
        XCTAssertEqual(text.count, Bvmid2.textLength)
        XCTAssertTrue(text.allSatisfy { $0 == "." || $0.isNumber || ("A"..."Z").contains($0) })
        XCTAssertEqual(try Bvmid2.parse(text), payload)
        XCTAssertEqual(try Bvmid2.parse(try XCTUnwrap(expected["lowercase_form_also_parses"] as? String)), payload)
        XCTAssertEqual(payload.fingerprint.nodeId.bytes, try bytes(inputs["fingerprint"]).prefix(16))
        XCTAssertThrowsError(try Bvmid2.parse(text.replacingOccurrences(of: "BA78", with: "ba78"))) {
            XCTAssertEqual(($0 as? Bvmid2FormatError)?.reason, "mixed case")
        }
        XCTAssertThrowsError(try Bvmid2.parse(text.replacingOccurrences(of: "BVMID2", with: "BVMID3"))) {
            XCTAssertEqual(($0 as? Bvmid2FormatError)?.reason, "other version")
        }
        XCTAssertTrue(Bvmid2.looksLikeBvmid2(text))
        XCTAssertFalse(Bvmid2.looksLikeBvmid2("BVMID1.abc"))
        XCTAssertNil(Bvmid2.tryParse("BVMID2.x"))
    }

    func testEveryMalformedTextOfBvmid2_013IsRejectedWithItsReason() throws {
        let v = try vector("bvmid2-013")
        let inputs = try XCTUnwrap(v["inputs"] as? [String: Any])
        let cases = try XCTUnwrap(inputs["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let text = try XCTUnwrap(c["text"] as? String)
            XCTAssertThrowsError(try Bvmid2.parse(text), c["description"] as? String ?? "") {
                XCTAssertEqual(($0 as? Bvmid2FormatError)?.reason, c["reason"] as? String, c["description"] as? String ?? "")
            }
        }
        XCTAssertNoThrow(try Bvmid2.parse(try XCTUnwrap(inputs["valid_sample"] as? String)))
    }

    func testLimitsMatchBvmid2_014() throws {
        let e = try XCTUnwrap(try vector("bvmid2-014")["expected"] as? [String: Any])
        XCTAssertEqual(e["lifetime_ms"] as? Int, Int(QrCodeDisplay.lifetime * 1000))
        XCTAssertEqual(e["reservation_ms"] as? Int, Int(QrCodeDisplay.reservation * 1000))
        XCTAssertEqual(e["max_attempts"] as? Int, QrCodeDisplay.maxAttempts)
        XCTAssertEqual(e["max_session_ms"] as? Int, Int(QrSessionScope.maxSession * 1000))
    }

    /// bvmid2-015: reserve, busy, consume, a silent replay, the reuse alert.
    func testTheReservationSequenceOfBvmid2_015() throws {
        var t: TimeInterval = 1_000
        let display = QrCodeDisplay(clock: { t }, budget: Bmh3SigningBudget(capacity: 50, refill: 0.001, clock: { t }))
        let events = Recorder()
        display.events = events
        let owner = SoftwareSigningIdentity().fingerprint
        try display.show(fingerprint: owner, rdi: Data([0x44, 0xe6, 0x9c, 0x0a, 0x7a, 0x7d]))
        let a = display.newGate()
        let gateA = try XCTUnwrap(display.tagCheck(a)?.qrGate)
        XCTAssertThrowsError(try gateA.onTagMatch(purpose: .endToEnd, msg1Ephemeral: ephemeral(1))) { XCTAssertEqual($0 as? Bmh3Failure, Bmh3Failure("qr end-to-end without link")) }
        try gateA.onTagMatch(purpose: .link, msg1Ephemeral: ephemeral(2))
        XCTAssertEqual(display.phase(), .reserved)
        try gateA.onTagMatch(purpose: .endToEnd, msg1Ephemeral: ephemeral(3))     // the same connection continues
        let b = display.newGate()
        let gateB = try XCTUnwrap(display.tagCheck(b)?.qrGate)
        XCTAssertThrowsError(try gateB.onTagMatch(purpose: .link, msg1Ephemeral: ephemeral(4))) { XCTAssertEqual($0 as? Bmh3Failure, Bmh3Failure("qr busy")) }
        XCTAssertTrue(a.complete(owner))
        XCTAssertFalse(a.complete(owner), "a commit happens once")
        XCTAssertEqual(display.phase(), .consumed)
        XCTAssertEqual(events.scans, [owner])
        let c = display.newGate()
        let gateC = try XCTUnwrap(display.tagCheck(c)?.qrGate)
        XCTAssertThrowsError(try gateC.onTagMatch(purpose: .link, msg1Ephemeral: ephemeral(2))) { XCTAssertEqual($0 as? Bmh3Failure, Bmh3Failure("replay")) }
        XCTAssertEqual(events.reuse, 0, "a replay of a sniffed first message raises no alert")
        XCTAssertThrowsError(try gateC.onTagMatch(purpose: .link, msg1Ephemeral: ephemeral(9))) { XCTAssertEqual($0 as? Bmh3Failure, Bmh3Failure("qr consumed")) }
        XCTAssertEqual(events.reuse, 1)
        XCTAssertNil(display.livePayload(), "a consumed code is no longer drawn")
        t += 1
    }

    final class Recorder: QrDisplayEvents {
        var scans: [IdentityFingerprint] = []
        var reuse = 0
        var ended: [String] = []
        func onScanCompleted(_ peer: IdentityFingerprint) { scans.append(peer) }
        func onReuseAlert() { reuse += 1 }
        func onCodeEnded(_ reason: String) { ended.append(reason) }
    }

    private func ephemeral(_ n: UInt8) -> Data { Data((0..<65).map { n &+ UInt8($0) }) }
}

final class QrCodeDisplayTests: XCTestCase {
    private var t: TimeInterval = 1_000
    private let rdi = Data([0x44, 0xe6, 0x9c, 0x0a, 0x7a, 0x7d])
    private let owner = SoftwareSigningIdentity().fingerprint
    private func ephemeral(_ n: UInt8) -> Data { Data((0..<65).map { n &+ UInt8($0) }) }

    private func display(budget: Bmh3SigningBudget? = nil) -> (QrCodeDisplay, Bvmid2VectorTests.Recorder) {
        let clock = { [unowned self] in self.t }
        let d = QrCodeDisplay(clock: clock, budget: budget ?? Bmh3SigningBudget(capacity: 50, refill: 0.001, clock: clock))
        let r = Bvmid2VectorTests.Recorder()
        d.events = r
        return (d, r)
    }

    func testACodeLivesThreeHundredSecondsThenEnds() throws {
        let (d, r) = display()
        try d.show(fingerprint: owner, rdi: rdi)
        t += QrCodeDisplay.lifetime - 0.001
        XCTAssertTrue(d.hasCode())
        t += 0.001
        XCTAssertFalse(d.hasCode())
        XCTAssertEqual(r.ended, ["expired"])
    }

    func testOneLiveCodeAndLeavingOrANewIdEndsIt() throws {
        let (d, r) = display()
        let first = try d.show(fingerprint: owner, rdi: rdi)
        let second = try d.show(fingerprint: owner, rdi: rdi)
        XCTAssertNotEqual(first, second, "every code has a fresh secret")
        d.onRdiChanged(rdi)
        XCTAssertTrue(d.hasCode())
        d.onRdiChanged(Data([1, 2, 3, 4, 5, 6]))
        XCTAssertFalse(d.hasCode())
        try d.show(fingerprint: owner, rdi: rdi)
        d.leave()
        XCTAssertFalse(d.hasCode())
        XCTAssertEqual(r.ended, ["replaced", "id_changed", "left"])
    }

    func testAFailedAttemptReleasesTheCodeAndTheThirdEndsIt() throws {
        let (d, r) = display()
        try d.show(fingerprint: owner, rdi: rdi)
        for i in 0..<QrCodeDisplay.maxAttempts {
            let gate = d.newGate()
            try XCTUnwrap(d.tagCheck(gate)?.qrGate).onTagMatch(purpose: .link, msg1Ephemeral: ephemeral(UInt8(10 + i)))
            gate.fail()
            XCTAssertEqual(d.phase(), .live)
        }
        let gate = d.newGate()
        XCTAssertThrowsError(try XCTUnwrap(d.tagCheck(gate)?.qrGate).onTagMatch(purpose: .link, msg1Ephemeral: ephemeral(50))) {
            XCTAssertEqual($0 as? Bmh3Failure, Bmh3Failure("qr attempts"))
        }
        XCTAssertFalse(d.hasCode())
        XCTAssertEqual(r.ended, ["attempt_cap"])
    }

    func testAReservationThatNeverCommitsExpiresAfter45Seconds() throws {
        let (d, _) = display()
        try d.show(fingerprint: owner, rdi: rdi)
        let a = d.newGate(), b = d.newGate()
        try XCTUnwrap(d.tagCheck(a)?.qrGate).onTagMatch(purpose: .link, msg1Ephemeral: ephemeral(1))
        t += QrCodeDisplay.reservation - 1
        XCTAssertThrowsError(try XCTUnwrap(d.tagCheck(b)?.qrGate).onTagMatch(purpose: .link, msg1Ephemeral: ephemeral(2)))
        t += 1
        try XCTUnwrap(d.tagCheck(b)?.qrGate).onTagMatch(purpose: .link, msg1Ephemeral: ephemeral(3))
        XCTAssertFalse(a.complete(owner), "the stale attempt cannot commit any more")
        XCTAssertTrue(b.complete(owner))
    }

    func testTheMeetScreensOwnBudgetLimitsSignatures() throws {
        let (d, _) = display(budget: Bmh3SigningBudget(capacity: 1, refill: 10, clock: { [unowned self] in self.t }))
        try d.show(fingerprint: owner, rdi: rdi)
        let a = d.newGate()
        try XCTUnwrap(d.tagCheck(a)?.qrGate).onTagMatch(purpose: .link, msg1Ephemeral: ephemeral(1))
        a.fail()
        let b = d.newGate()
        XCTAssertThrowsError(try XCTUnwrap(d.tagCheck(b)?.qrGate).onTagMatch(purpose: .link, msg1Ephemeral: ephemeral(2))) {
            XCTAssertEqual($0 as? Bmh3Failure, Bmh3Failure("budget"))
        }
    }

    func testTheScopeAllowsOnlyTheVerificationRecords() {
        let scope = QrSessionScope(startedAt: 0)
        XCTAssertFalse(scope.refuseContent(.labels))
        for type in [EndToEndContentType.privateCallSignal, .streamHeader, .mediaPacket, .keyFrameRequest] {
            XCTAssertTrue(scope.refuseContent(type), "\(type)")
        }
        let offer = (try? DiscoveryExchange.encode(.recognitionOffer)) ?? Data()
        let opening = (try? DiscoveryExchange.encode(.opening([]))) ?? Data()
        XCTAssertTrue(scope.refuseDiscovery(offer, negotiated: false), "only when both hellos carried bit 3")
        XCTAssertFalse(scope.refuseDiscovery(offer, negotiated: true))
        XCTAssertTrue(scope.refuseDiscovery(offer, negotiated: true), "one OFFER per direction")
        XCTAssertTrue(scope.refuseDiscovery(opening, negotiated: true), "no OPENING in a verification session")
        XCTAssertTrue(QrSessionScope.allowsLinkRecord(.linkHeartbeat))
        XCTAssertFalse(QrSessionScope.allowsLinkRecord(.relaySetup))
        XCTAssertTrue(scope.expired(now: QrSessionScope.maxSession))
        XCTAssertFalse(scope.expired(now: QrSessionScope.maxSession - 1))
    }

    func testTheMeetScreenSaysWhoScannedWhom() {
        let session = MeetSession(), peer = SoftwareSigningIdentity().fingerprint
        XCTAssertNil(session.message(peer, name: "Rahul"))
        session.scanReached(peer, name: "Rahul")
        XCTAssertEqual(session.pendingName(peer), "Rahul")
        XCTAssertFalse(session.confirmScreen(peer, yes: false), "No marks nothing")
        XCTAssertEqual(session.outcome(peer), .none)
        session.scanReached(peer, name: "Rahul")
        XCTAssertTrue(session.confirmScreen(peer, yes: true))
        XCTAssertEqual(session.outcome(peer), .youScanned)
        session.scannedByPeer(peer)
        XCTAssertEqual(session.outcome(peer), .scannedEachOther)
        XCTAssertFalse(session.recognises(peer))
        session.leaseStored(peer)
        XCTAssertTrue(session.message(peer, name: "Rahul")?.contains("now recognise") == true)
        session.scanReached(peer, name: "Rahul")
        session.onReuseAlert()
        XCTAssertNil(session.pendingName(peer), "a reuse alert cancels the pending confirmation")
    }

    func testTheRecognitionAnswerIsTheVisitsLeaseGate() {
        let visit = MeetVisit(), peer = SoftwareSigningIdentity().fingerprint, other = SoftwareSigningIdentity().fingerprint
        visit.begin()
        XCTAssertFalse(visit.mayLease(peer), "nobody confirmed yet")
        visit.confirm(peer, recognise: false)
        XCTAssertFalse(visit.mayLease(peer), "confirmed, but not allowed to recognise this device")
        visit.confirm(peer, recognise: true)
        XCTAssertTrue(visit.mayLease(peer))
        XCTAssertFalse(visit.mayLease(other), "per person")
        visit.confirm(peer, recognise: false)
        XCTAssertFalse(visit.mayLease(peer), "a later answer replaces the earlier one")
        visit.confirm(peer, recognise: true)
        visit.onReuseAlert()
        XCTAssertFalse(visit.mayLease(peer), "nothing after a reuse alert")
        visit.begin()
        XCTAssertFalse(visit.mayLease(peer), "a new visit forgets every answer")
        visit.confirm(peer, recognise: true)
        visit.end()
        XCTAssertFalse(visit.mayLease(peer), "leaving the screen ends the gate")
        visit.confirm(peer, recognise: true)
        XCTAssertFalse(visit.mayLease(peer), "nothing is granted after the visit ended")
    }

    func testTheRecognitionAnswerIsStoredBeforeAnythingMayLeaveAndAFailedWriteWithholds() {
        var written: [Bool] = []
        XCTAssertTrue(QlConsent.applyAnswer(recognise: true, vaultUsable: true) { written.append($0); return true })
        XCTAssertFalse(QlConsent.applyAnswer(recognise: false, vaultUsable: true) { written.append($0); return true })
        XCTAssertEqual(written, [true, false], "both answers are written")
        XCTAssertFalse(QlConsent.applyAnswer(recognise: true, vaultUsable: true) { _ in false }, "a failed write withholds")
        XCTAssertFalse(QlConsent.applyAnswer(recognise: false, vaultUsable: false) { _ in XCTFail("nothing to write"); return true })
        XCTAssertTrue(QlConsent.applyAnswer(recognise: true, vaultUsable: false) { _ in XCTFail("nothing to write"); return true })
    }

    func testThePlainResultAndCallNowFollowWhatHappenedInTheVisit() {
        let session = MeetSession()
        let (asha, ravi, mira) = (SoftwareSigningIdentity().fingerprint, SoftwareSigningIdentity().fingerprint, SoftwareSigningIdentity().fingerprint)
        for peer in [asha, ravi, mira] { XCTAssertNil(session.qlResult(peer)) }
        // Asha: both scans and a stored lease.
        session.scanReached(asha, name: "Asha"); session.confirmScreen(asha, yes: true)
        XCTAssertEqual(session.qlResult(asha), .oneScan)
        XCTAssertFalse(session.callNowVisible(asha, now: 10))
        session.scannedByPeer(asha)
        XCTAssertEqual(session.qlResult(asha), .notFinished, "no lease yet, and no reason guessed")
        session.leaseStored(asha, at: 100)
        XCTAssertEqual(session.qlResult(asha), .recognised)
        XCTAssertTrue(session.callNowVisible(asha, now: 100))
        XCTAssertTrue(session.callNowVisible(asha, now: 100 + MeetSession.callNowSeconds - 1))
        XCTAssertFalse(session.callNowVisible(asha, now: 100 + MeetSession.callNowSeconds), "Call now lasts 60 s")
        XCTAssertEqual(session.callNowPeer(now: 130), asha)
        XCTAssertNil(session.callNowPeer(now: 170))
        // Ravi: this device declined.
        session.scanReached(ravi, name: "Ravi"); session.confirmScreen(ravi, yes: true); session.declinedRecognition(ravi)
        session.scannedByPeer(ravi)
        XCTAssertEqual(session.qlResult(ravi), .declined)
        XCTAssertFalse(session.callNowVisible(ravi, now: 100))
        // Mira scanned this device only.
        session.scannedByPeer(mira)
        XCTAssertEqual(session.qlResult(mira), .oneScan)
    }

    func testAnOlderCodeOnlyChecksByCodeAndSuchAContactGetsNoNewLease() {
        XCTAssertEqual(Bvmid1Policy.methodForBvmid1Scan(compat: false), Bvmid1Policy.checkedByCode)
        XCTAssertEqual(Bvmid1Policy.methodForBvmid1Scan(compat: true), Bvmid1Policy.scanned)
        XCTAssertTrue(CodeOnlyLeaseRule.blocked(method: Bvmid1Policy.checkedByCode, scannedBothWays: false, holdsLease: false))
        XCTAssertFalse(CodeOnlyLeaseRule.blocked(method: Bvmid1Policy.checkedByCode, scannedBothWays: true, holdsLease: false))
        XCTAssertFalse(CodeOnlyLeaseRule.blocked(method: Bvmid1Policy.checkedByCode, scannedBothWays: false, holdsLease: true))
        XCTAssertFalse(CodeOnlyLeaseRule.blocked(method: Bvmid1Policy.scanned, scannedBothWays: false, holdsLease: false))
    }

    func testTheScannerTriesOnlyTheCodesDirectCallOffers() throws {
        let payload = try Bvmid2Payload(fingerprint: owner, kQr: Data(repeating: 7, count: 32), rdi: rdi)
        func offer(_ six: Data, cost: UInt8 = 0, rotating: Bool = true) -> DiscoveryAnnouncement {
            var a = DiscoveryAnnouncement(nodeIdPrefix: six, flags: DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable,
                                          capabilitySummary: 1, streamToken: 0, routeCost: cost)
            a.rotating = rotating
            return a
        }
        let seen = [("a", offer(rdi)), ("b", offer(rdi, cost: 1)), ("c", offer(Data(repeating: 1, count: 6))), ("d", offer(rdi, rotating: false)),
                    ("e", offer(rdi)), ("a", offer(rdi))]
        XCTAssertEqual(QrScanPolicy.addressesToTry(payload, seen), ["a", "e"])
    }
}

/// Whole verification sessions between two real call engines (scanner = caller, displayer = callee).
final class VerificationSessionTests: XCTestCase {
    let vp9 = NodeCapabilities.codecVP9
    let epoch: Int64 = 1_990_656
    private var t: TimeInterval = 0

    final class Side {
        let id = SoftwareSigningIdentity()
        var verifiedPeers: Set<String> = []
        var dayKeys: [Int64: Data] = [:]
        var stored: [String: DiscoveryExchange.PresenceLease] = [:]
        var delivered: [String] = []
        let visit = MeetVisit()
        let events = Bvmid2VectorTests.Recorder()
        var display: QrCodeDisplay!
        /// Set: the vault's eligibility answer for every peer (false: a contact only checked by code, a switch off...).
        var eligibleOverride: Bool?
        func hooks(epoch: Int64) -> PresenceCallHooks {
            PresenceCallHooks(
                eligible: { [unowned self] _, fp in eligibleOverride ?? verifiedPeers.contains(fp.hex) },
                lease: { [unowned self] id, fp in
                    guard verifiedPeers.contains(fp.hex) else { return nil }
                    delivered.append(id.hex)
                    return PresenceLeases.delivery(dayKeys: dayKeys, generation: 1, epoch: epoch)
                },
                store: { [unowned self] id, lease in stored[id.hex] = lease },
                verified: { [unowned self] fp in verifiedPeers.contains(fp.hex) })
        }
        /// The user answered yes and the shield was stored; `recognise` is the stored answer to "Let <name>'s phone recognise
        /// yours nearby" (Design QL revision 2). The vault's own switch is not modelled: only the visit gate decides.
        func confirm(_ other: Side, recognise: Bool = true) {
            verifiedPeers.insert(other.id.fingerprint.hex); visit.confirm(other.id.fingerprint, recognise: recognise)
        }
    }

    private func side() -> Side {
        let s = Side()
        s.dayKeys = DayKeyWindow.fresh(epoch: epoch)
        let clock = { [unowned self] in self.t }
        s.display = QrCodeDisplay(clock: clock, budget: Bmh3SigningBudget(capacity: 50, refill: 0.001, clock: clock))
        s.display.events = s.events
        s.display.onReuse = { [unowned s] in s.visit.onReuseAlert() }
        s.visit.begin()
        return s
    }

    private func entry(_ s: Side) -> OpeningEntry {
        PresenceLeases.ownEntry(dayKeys: s.dayKeys, nodeId: s.id.nodeId.bytes, epoch: epoch, role: 0)!
    }

    private func offer(_ rdi: Data) -> DiscoveryAnnouncement {
        var a = DiscoveryAnnouncement(nodeIdPrefix: rdi, flags: DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable,
                                      capabilitySummary: 1, streamToken: 0, routeCost: 0)
        a.rotating = true
        return a
    }

    final class Box { var scanner: [CallEngine.Event] = []; var displayer: [CallEngine.Event] = [] }

    /// `scanner` scans the code `displayer` shows (or `code`, a code someone else made).
    private func scan(_ scanner: Side, _ displayer: Side, code: Bvmid2Payload? = nil, scannerId: SigningIdentity? = nil,
                      ordinaryCall: Bool = false) throws -> (CallEngine, CallEngine, Box) {
        let e = entry(displayer)
        let payload = try code ?? displayer.display.livePayload() ?? displayer.display.show(fingerprint: displayer.id.fingerprint, rdi: e.rdi)
        let selected = offer(e.rdi)
        let we = epoch
        var scannerRotating = RotatingCallOptions(selected: selected, wallEpoch: { we }); scannerRotating.presence = scanner.hooks(epoch: epoch)
        var displayerRotating = RotatingCallOptions(entries: { [e] }, wallEpoch: { we }); displayerRotating.presence = displayer.hooks(epoch: epoch)
        var scannerBmh3 = Bmh3CallOptions(pseudonyms: true, selected: selected, budget: Bmh3SigningBudget(capacity: 100), wallEpoch: { we })
        if !ordinaryCall { scannerBmh3.qrScan = payload }
        var displayerBmh3 = Bmh3CallOptions(pseudonyms: true, budget: Bmh3SigningBudget(capacity: 100), wallEpoch: { we })
        displayerBmh3.qrDisplay = displayer.display
        let a = CallEngine(role: .caller, transport: .gatt, identity: scannerId ?? scanner.id, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                           rotating: scannerRotating, bmh3: scannerBmh3)
        let b = CallEngine(role: .callee, transport: .gatt, identity: displayer.id, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                           rotating: displayerRotating, bmh3: displayerBmh3)
        a.meetVisit = scanner.visit
        b.meetVisit = displayer.visit
        let box = Box()
        a.onEvent = { box.scanner.append($0) }
        b.onEvent = { box.displayer.append($0) }
        try a.start(now: t); try b.start(now: t)
        pump(a, b)
        return (a, b, box)
    }

    private func pump(_ a: CallEngine, _ b: CallEngine) {
        a.tick(now: t); b.tick(now: t)
        for _ in 0..<80 {
            var moved = false
            while let d = a.nextOutgoing(now: t) { b.receive(d, now: t); moved = true }
            while let d = b.nextOutgoing(now: t) { a.receive(d, now: t); moved = true }
            if !moved { return }
        }
    }

    /// Advances time in half-second steps, pumping both engines, until both closed or `limit` passed.
    private func run(_ a: CallEngine, _ b: CallEngine, for seconds: TimeInterval) {
        let end = t + seconds
        while t < end, a.phase != .closed || b.phase != .closed { t += 0.5; pump(a, b) }
    }

    private func reached(_ events: [CallEngine.Event]) -> IdentityFingerprint? {
        for case .verificationReached(_, let fp) in events { return fp }
        return nil
    }
    private func committed(_ events: [CallEngine.Event]) -> (IdentityFingerprint, Bool)? {
        for case .verificationCommitted(let fp, let c) in events { return (fp, c) }
        return nil
    }
    private func leaseStored(_ events: [CallEngine.Event]) -> Bool {
        events.contains { if case .verificationLeaseStored = $0 { return true }; return false }
    }
    private func ranAsACall(_ events: [CallEngine.Event]) -> Bool {
        events.contains {
            switch $0 {
            case .incomingCall, .startLocalMedia, .peerLabels: return true
            case .phase(let p): return p != .ended
            default: return false
            }
        }
    }

    func testAScanReachesTheCodesKeyAndConsumesTheCodeWithoutACall() throws {
        let scanner = side(), displayer = side()
        let (a, b, box) = try scan(scanner, displayer)
        XCTAssertEqual(reached(box.scanner), displayer.id.fingerprint, a.closeReason ?? b.closeReason ?? "")
        XCTAssertEqual(committed(box.displayer)?.0, scanner.id.fingerprint)
        XCTAssertEqual(committed(box.displayer)?.1, true)
        XCTAssertEqual(displayer.events.scans, [scanner.id.fingerprint], "<name> scanned your code")
        XCTAssertEqual(displayer.display.phase(), .consumed)
        XCTAssertNil(a.state); XCTAssertNil(b.state)
        XCTAssertFalse(ranAsACall(box.scanner) || ranAsACall(box.displayer), "no Invite, no ring, no media")
        XCTAssertTrue(a.isVerificationSession && b.isVerificationSession)
        // The displayer's user did not confirm this scanner in this visit: it ends shortly, and nothing moved.
        run(a, b, for: 5)
        XCTAssertEqual(b.closeReason, CallEngine.verificationFinished)
        XCTAssertTrue(scanner.stored.isEmpty && displayer.stored.isEmpty)
    }

    func testTheScannerSaysNoAndTheSessionEndsAtOnce() throws {
        let scanner = side(), displayer = side()
        let (a, b, _) = try scan(scanner, displayer)
        a.confirmVerification(displayer.id.fingerprint, yes: false)
        XCTAssertEqual(a.phase, .closed)
        pump(a, b)
        XCTAssertTrue(scanner.stored.isEmpty && displayer.stored.isEmpty && scanner.delivered.isEmpty)
    }

    func testWithoutAnAnswerTheScannerEndsAfterTwentySeconds() throws {
        let scanner = side(), displayer = side()
        displayer.confirm(scanner)     // the displayer would answer, but the scanner's user never does
        let (a, b, _) = try scan(scanner, displayer)
        run(a, b, for: QrSessionScope.confirmWait - 1)
        XCTAssertNotEqual(a.phase, .closed)
        run(a, b, for: 2)
        XCTAssertEqual(a.closeReason, CallEngine.verificationFinished)
        XCTAssertTrue(scanner.stored.isEmpty && displayer.stored.isEmpty)
    }

    /// Design QL: the first of two scans moves no lease (the displayer has not confirmed the scanner yet); the second
    /// moves both, and each phone then recognises the other.
    func testTheFirstScanMovesNoLeaseAndTheSecondMovesBoth() throws {
        let asha = side(), ravi = side()
        // Ravi scans Asha's code and confirms; Asha has not confirmed Ravi yet.
        let (a1, b1, box1) = try scan(ravi, asha)
        XCTAssertEqual(reached(box1.scanner), asha.id.fingerprint)
        ravi.confirm(asha)
        a1.confirmVerification(asha.id.fingerprint, yes: true)
        run(a1, b1, for: 10)
        XCTAssertTrue(asha.stored.isEmpty && ravi.stored.isEmpty, "the first scan moves no lease")
        XCTAssertTrue(asha.delivered.isEmpty, "the displayer never offers at the commit")
        // Asha scans Ravi's code and confirms: Ravi confirmed Asha during this visit, so both leases move.
        let (a2, b2, box2) = try scan(asha, ravi)
        XCTAssertEqual(reached(box2.scanner), ravi.id.fingerprint, a2.closeReason ?? b2.closeReason ?? "")
        asha.confirm(ravi)
        a2.confirmVerification(ravi.id.fingerprint, yes: true)
        pump(a2, b2)
        XCTAssertEqual(asha.stored[ravi.id.nodeId.hex]?.leases.count, 28)
        XCTAssertEqual(ravi.stored[asha.id.nodeId.hex]?.leases.count, 28)
        XCTAssertTrue(leaseStored(box2.scanner) && leaseStored(box2.displayer))
        XCTAssertTrue(a2.presenceRejections.isEmpty && b2.presenceRejections.isEmpty)
        run(a2, b2, for: 5)
        XCTAssertEqual(a2.phase, .closed); XCTAssertEqual(b2.phase, .closed)
    }

    func testAReuseAlertWithholdsEveryLeaseOfTheVisit() throws {
        let asha = side(), ravi = side(), mallory = side()
        ravi.confirm(asha)                                  // Ravi already confirmed Asha in this visit
        let code = try ravi.display.show(fingerprint: ravi.id.fingerprint, rdi: entry(ravi).rdi)
        let (a1, b1, box1) = try scan(asha, ravi, code: code)
        XCTAssertNotNil(reached(box1.scanner))
        // A second phone with a photograph of the same code: refused, and Ravi sees the reuse alert.
        let (m, b2, box2) = try scan(mallory, ravi, code: code)
        XCTAssertNil(reached(box2.scanner))
        XCTAssertNotEqual(m.phase, .open)
        XCTAssertEqual(b2.phase, .closed, "closed silently at msg1")
        XCTAssertEqual(ravi.events.reuse, 1)
        XCTAssertTrue(ravi.visit.reuseAlerted())
        asha.confirm(ravi)
        a1.confirmVerification(ravi.id.fingerprint, yes: true)
        run(a1, b1, for: 5)
        XCTAssertTrue(asha.stored.isEmpty && ravi.stored.isEmpty && ravi.delivered.isEmpty, "a reuse alert withholds the leases")
        XCTAssertEqual(b1.presenceOffersSent, 0, "the alerted displayer answers nothing, not even an OFFER")
        XCTAssertTrue(asha.delivered.isEmpty)
    }

    // MARK: Design QL revision 2: consent at the scan

    /// Two scans in the given order; `declines` unchecks "Let <name>'s phone recognise yours nearby" at its own scan, and
    /// its session is told yes anyway, so only the lease gate stands between the answer and the radio.
    private func twoScans(first: (Side, Side), second: (Side, Side), declines: Side) throws -> [CallEngine] {
        var engines: [CallEngine] = []
        for (scanner, displayer) in [first, second] {
            let (a, b, box) = try scan(scanner, displayer)
            XCTAssertEqual(reached(box.scanner), displayer.id.fingerprint, a.closeReason ?? b.closeReason ?? "")
            scanner.confirm(displayer, recognise: scanner !== declines)
            a.confirmVerification(displayer.id.fingerprint, yes: true)
            run(a, b, for: 10)
            engines += [a, b]
        }
        return engines
    }

    func testADeclinedRecognitionSendsNoOfferAndNoLeaseInEitherOrderOfTheScans() throws {
        for decliningScansFirst in [true, false] {
            let asha = side(), ravi = side()
            let engines = decliningScansFirst
                ? try twoScans(first: (ravi, asha), second: (asha, ravi), declines: ravi)
                : try twoScans(first: (asha, ravi), second: (ravi, asha), declines: ravi)
            let order = "declining side scans \(decliningScansFirst ? "first" : "second")"
            // Ravi never offers. Asha offers once as scanner (in whichever session she scans) and gets no answer.
            let ravisEngines = decliningScansFirst ? [engines[0], engines[3]] : [engines[1], engines[2]]
            XCTAssertEqual(ravisEngines.reduce(0) { $0 + $1.presenceOffersSent }, 0, order)
            XCTAssertEqual(engines.reduce(0) { $0 + $1.presenceOffersSent }, 1, order)
            XCTAssertEqual(engines.reduce(0) { $0 + $1.presenceLeasesSent }, 0, order)
            XCTAssertTrue(ravi.delivered.isEmpty && asha.delivered.isEmpty, "\(order): no lease was even built")
            XCTAssertTrue(ravi.stored.isEmpty && asha.stored.isEmpty, order)
        }
    }

    func testWithBothConsentsExactlyOneOfferAndOneLeaseCrossEachWay() throws {
        let asha = side(), ravi = side()
        let engines = try twoScans(first: (ravi, asha), second: (asha, ravi), declines: side())
        let (a2, b2) = (engines[2], engines[3])
        XCTAssertEqual(engines[0].presenceOffersSent, 1, "the first scanner offers")
        XCTAssertEqual(engines[1].presenceOffersSent + engines[0].presenceLeasesSent + engines[1].presenceLeasesSent, 0,
                       "the first scan moves no lease")
        XCTAssertEqual([a2.presenceOffersSent, b2.presenceOffersSent, a2.presenceLeasesSent, b2.presenceLeasesSent], [1, 1, 1, 1])
        XCTAssertEqual([a2.presenceLeasesStored, b2.presenceLeasesStored], [1, 1])
        XCTAssertEqual(asha.delivered, [ravi.id.nodeId.hex])
        XCTAssertEqual(ravi.delivered, [asha.id.nodeId.hex])
        XCTAssertTrue(a2.presenceRejections.isEmpty && b2.presenceRejections.isEmpty)
    }

    func testAWithheldOfferNeverLetsALeaseLeaveEvenWhenThePeerOfferedFirst() throws {
        let asha = side(), ravi = side()
        ravi.confirm(asha)                        // Ravi confirmed Asha in this visit and lets her recognise him...
        ravi.eligibleOverride = false             // ...but his vault refuses (e.g. she was only checked by code)
        let (a, b, _) = try scan(asha, ravi)
        asha.confirm(ravi)
        a.confirmVerification(ravi.id.fingerprint, yes: true)   // Asha's OFFER arrives first; Ravi's answer withholds
        run(a, b, for: 5)
        XCTAssertEqual(a.presenceOffersSent, 1)
        XCTAssertEqual(b.presenceOffersSent, 0)
        XCTAssertEqual(b.presenceLeasesSent, 0, "no LEASE after a withheld OFFER")
        XCTAssertTrue(ravi.delivered.isEmpty, "no delivery recorded either")
        XCTAssertEqual(a.presenceLeasesSent, 0, "Asha leases only after both OFFERs")
        XCTAssertTrue(asha.stored.isEmpty && ravi.stored.isEmpty)
        XCTAssertEqual(b.phase, .closed, "the withheld side settles and ends the session")
    }

    func testAScannerWhoseOfferIsWithheldSendsNoLease() throws {
        let asha = side(), ravi = side()
        ravi.confirm(asha)
        asha.eligibleOverride = false
        let (a, b, _) = try scan(asha, ravi)
        asha.confirm(ravi)
        a.confirmVerification(ravi.id.fingerprint, yes: true)
        run(a, b, for: 5)
        XCTAssertEqual(a.presenceOffersSent + b.presenceOffersSent + a.presenceLeasesSent + b.presenceLeasesSent, 0)
        XCTAssertTrue(asha.delivered.isEmpty && ravi.delivered.isEmpty)
    }

    func testAfterTheScreenLeftNeitherRoleLeases() throws {
        // The scanner's screen left (the visit ended): it offers nothing.
        let asha = side(), ravi = side()
        ravi.confirm(asha); asha.confirm(ravi)
        let (a, b, _) = try scan(asha, ravi)
        asha.visit.end()
        a.confirmVerification(ravi.id.fingerprint, yes: true)
        run(a, b, for: 5)
        XCTAssertEqual(a.presenceOffersSent + b.presenceOffersSent + a.presenceLeasesSent + b.presenceLeasesSent, 0)
        // The displayer's visit is gone by the time the scanner's OFFER arrives: the send-time check withholds its answer.
        let asha2 = side(), ravi2 = side()
        ravi2.confirm(asha2); asha2.confirm(ravi2)
        let (c, d, _) = try scan(asha2, ravi2)
        ravi2.visit.end()                         // Ravi left Add contact before Asha's OFFER arrived
        c.confirmVerification(ravi2.id.fingerprint, yes: true)
        run(c, d, for: 5)
        XCTAssertEqual(c.presenceOffersSent, 1)
        XCTAssertEqual(d.presenceOffersSent + c.presenceLeasesSent + d.presenceLeasesSent, 0)
        XCTAssertTrue(asha.stored.isEmpty && ravi.stored.isEmpty && asha2.stored.isEmpty && ravi2.stored.isEmpty && ravi2.delivered.isEmpty)
    }

    func testAReuseAlertOnTheScannersOwnCodeWithholdsItsOffer() throws {
        let asha = side(), ravi = side()
        ravi.confirm(asha)
        let (a, b, _) = try scan(asha, ravi)
        asha.confirm(ravi)
        asha.visit.onReuseAlert()                 // Asha's own code was used twice meanwhile
        a.confirmVerification(ravi.id.fingerprint, yes: true)
        run(a, b, for: 5)
        XCTAssertEqual(a.presenceOffersSent + a.presenceLeasesSent + b.presenceOffersSent + b.presenceLeasesSent, 0)
        XCTAssertTrue(asha.stored.isEmpty && ravi.stored.isEmpty)
    }

    func testTheScannerRefusesAPhoneWhoseKeyIsNotTheCodesAndTheCodeStaysLive() throws {
        let scanner = side(), displayer = side()
        // A code that names someone else's key, shown by `displayer` (a relayed or forged screen).
        let other = SoftwareSigningIdentity()
        let code = try displayer.display.show(fingerprint: other.fingerprint, rdi: entry(displayer).rdi)
        let (a, b, box) = try scan(scanner, displayer, code: code)
        XCTAssertNil(reached(box.scanner))
        XCTAssertEqual(a.phase, .closed, "the scanner never presents its key to the wrong phone")
        XCTAssertEqual(displayer.display.phase(), .reserved)
        run(a, b, for: 25)     // the displayer's unfinished handshake times out
        XCTAssertNil(committed(box.displayer))
        XCTAssertEqual(displayer.display.phase(), .live, "the failed attempt released the reservation")
    }

    func testWhileOnlyTheScreenMadeItReachableTheDisplayerRefusesAnOrdinaryCall() throws {
        let caller = side(), displayer = side()
        displayer.display.screenOnlyReachable = true
        try displayer.display.show(fingerprint: displayer.id.fingerprint, rdi: entry(displayer).rdi)
        let (a, b, box) = try scan(caller, displayer, ordinaryCall: true)
        run(a, b, for: 1)
        XCTAssertEqual(b.phase, .closed)
        XCTAssertNil(b.state, "it never rang")
        XCTAssertFalse(box.displayer.contains { if case .incomingCall = $0 { return true }; return false })
        XCTAssertEqual(displayer.display.phase(), .live)
        // With the device reachable for calls anyway, the same ordinary call rings.
        let caller2 = side(), reachable = side()
        let (c, d, _) = try scan(caller2, reachable, ordinaryCall: true)
        XCTAssertEqual(d.state?.phase, .incomingRinging, c.closeReason ?? d.closeReason ?? "")
    }
}
