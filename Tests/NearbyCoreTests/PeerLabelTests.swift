import XCTest
import CryptoKit
@testable import NearbyCore

/// Ports of Android's LabelTextTest, SignedLabelTest, TitlePageTest, PeerLabelTest (handle parsing) and the
/// compact R11 vector (CompactDiscoveryAnnouncementTest), naming phase 1.
final class LabelTextTests: XCTestCase {
    private func ok(_ kind: LabelKind, _ text: String) throws -> String { try LabelText.normalize(kind, text).get() }
    private func rejected(_ kind: LabelKind, _ text: String) -> String? { LabelText.rejection(kind, text) }

    func testOrdinaryNamesThatParseUnderCrockfordAliasesStayValid() throws {
        XCTAssertEqual(try ok(.personName, "Brave Tiger"), "Brave Tiger")
        XCTAssertEqual(try ok(.personName, "Mike Foster"), "Mike Foster")
        XCTAssertNotNil(IdentityHandle.parse("Brave Tiger"))
        XCTAssertEqual(try ok(.personName, "Asha"), "Asha")
    }

    func testHandleShapedTextIsRejected() {
        XCTAssertEqual(rejected(.personName, "M6SC7-N75YR"), "looks like a handle")
        XCTAssertEqual(rejected(.personName, "m6sc7n75yr"), "looks like a handle")
        XCTAssertEqual(rejected(.personName, "ab12c"), "looks like a handle")
        XCTAssertEqual(rejected(.personName, "abcde-fghij"), "looks like a handle")
        XCTAssertEqual(rejected(.personName, "\u{FF2D}6SC7-N75YR"), "looks like a handle") // fullwidth folds under NFKC
    }

    func testCheckMarksBidiControlsAndJoinersAreRejected() {
        XCTAssertEqual(rejected(.personName, "Asha \u{2713}"), "check mark")
        XCTAssertEqual(rejected(.personName, "Asha \u{1F5F8}"), "check mark")
        XCTAssertNotNil(rejected(.personName, "Asha\u{202E}evil"))
        XCTAssertNotNil(rejected(.personName, "As\u{2066}ha"))
        XCTAssertNotNil(rejected(.personName, "A\u{200D}sha"))
        XCTAssertNotNil(rejected(.personName, "A\u{200C}sha"))
    }

    func testScriptMixingFollowsModeratelyRestrictive() {
        XCTAssertEqual(rejected(.personName, "p\u{0430}ypal"), "mixed scripts")
        XCTAssertEqual(rejected(.personName, "Al\u{03B1}n"), "mixed scripts")
        XCTAssertNil(rejected(.personName, "Ravi \u{0930}\u{093E}\u{092E}"))
        XCTAssertNil(rejected(.personName, "\u{0410}\u{043B}\u{0435}\u{043A}\u{0441}"))
        XCTAssertNil(rejected(.streamTitle, "Tokyo \u{6771}\u{4EAC}\u{3067}\u{3059}"))
        XCTAssertEqual(rejected(.personName, "\u{0410}\u{0440} \u{0930}\u{093E}"), "mixed scripts")
    }

    func testByteLimitsCountUtf8AtMultiByteBoundaries() throws {
        XCTAssertEqual(try ok(.personName, String(repeating: "\u{00E9}", count: 16)).utf8.count, 32)
        XCTAssertEqual(rejected(.personName, String(repeating: "\u{20AC}", count: 11)), "too long")
        XCTAssertNil(rejected(.streamTitle, String(repeating: "a", count: 48)))
        XCTAssertEqual(rejected(.streamTitle, String(repeating: "a", count: 49)), "too long")
        XCTAssertNil(rejected(.callSubject, String(repeating: "a", count: 64)))
        XCTAssertEqual(rejected(.callSubject, String(repeating: "a", count: 65)), "too long")
    }

    func testWhitespaceCollapsesAndNfcIsIdempotent() throws {
        XCTAssertEqual(try ok(.personName, "  Asha \t\n  Rao  "), "Asha Rao")
        XCTAssertEqual(try ok(.personName, "e\u{0301}te\u{0301}"), "\u{00E9}t\u{00E9}")
        let once = try ok(.personName, "e\u{0301}te\u{0301}")
        XCTAssertEqual(try ok(.personName, once), once)
        XCTAssertTrue(LabelText.isCanonical(.personName, once))
        XCTAssertFalse(LabelText.isCanonical(.personName, " Asha"))
        XCTAssertFalse(LabelText.isCanonical(.personName, "e\u{0301}"))
        XCTAssertEqual(rejected(.personName, "   "), "empty")
    }

    func testStackedCombiningMarksAreCapped() {
        XCTAssertNil(rejected(.personName, "Zx\u{0300}\u{0301}\u{0302}"))
        XCTAssertEqual(rejected(.personName, "Zx\u{0300}\u{0301}\u{0302}\u{0303}"), "stacked combining marks")
    }

    func testHandleParsingAcceptsAliasesAndRejectsNonCanonicalTail() {
        XCTAssertEqual(IdentityHandle.parse("04106-1050R")?.hex, "010203040506")
        XCTAssertEqual(IdentityHandle.parse("o41o6 io5or")?.hex, "010203040506")
        XCTAssertEqual(IdentityHandle.parse("m6sc7n75yr")?.hex, "a1b2c3d4e5f6")
        XCTAssertEqual(IdentityHandle.parse("ZZZZZ-ZZZZW")?.hex, "ffffffffffff")
        XCTAssertEqual(IdentityHandle.canonical("m6sc7 n75yr"), "M6SC7-N75YR")
        XCTAssertNil(IdentityHandle.parse("ZZZZZ-ZZZZZ"))
        XCTAssertNil(IdentityHandle.parse("04106-1050"))
        XCTAssertNil(IdentityHandle.parse("04106-1050U"))
        XCTAssertEqual(IdentityHandle.parseShort("m6sc7"), "M6SC7")
    }
}

final class SignedLabelTests: XCTestCase {
    let alice = SoftwareSigningIdentity(), mallory = SoftwareSigningIdentity()
    let callId = UUID(uuidString: "01020304-0506-0708-090a-0b0c0d0e0f10")!
    let otherCall = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func reason(_ block: () throws -> Void) -> String {
        do { try block(); XCTFail("expected a rejection"); return "" }
        catch let e as LabelRejected { return e.reason } catch { return "\(error)" }
    }
    private func withSignature(_ unsigned: Data, _ signer: SigningIdentity) throws -> Data {
        let sig = try signer.sign(SignedLabelCodec.domain + unsigned)
        var w = BinaryWriter(); w.bytes(unsigned); w.u16(UInt16(sig.count)); w.bytes(sig); return w.data
    }

    func testSignedPartMatchesTheProtocolVector() throws {
        let unsigned = try SignedLabelCodec.signedPart(kind: 3, spki: Data([0x30, 0x01]), sequence: 0, binding: .call(callId), text: "Hi")
        XCTAssertEqual(unsigned.hex, "424e4c31" + "01" + "03" + "0002" + "3001" + "00000000" + "01" + "0102030405060708090a0b0c0d0e0f10" + "02" + "4869")
        XCTAssertEqual(SignedLabelCodec.domain.hex, "426c7565746f6f7468566964656f4d6573682f4c6162656c2f3100")
        XCTAssertEqual(try SignedLabelCodec.encodeContainer([]).hex, "424c423100")
    }

    func testRoundTripVerifiesSignerBindingAndText() throws {
        let encoded = try SignedLabelCodec.sign(identity: alice, kind: .callSubject, binding: .call(callId), text: "Water at the school")
        let label = try SignedLabelCodec.decode(encoded)
        XCTAssertEqual(try SignedLabelCodec.verify(label, expectedSigner: alice.nodeId, expectedBinding: .call(callId)), .callSubject)
        XCTAssertEqual(label.text, "Water at the school"); XCTAssertEqual(label.encoded, encoded)
        let longest = try SignedLabelCodec.sign(identity: alice, kind: .callSubject, binding: .call(callId), text: String(repeating: "a", count: 64))
        XCTAssertLessThanOrEqual(longest.count, 259)
        // DER signature, as Android requires.
        XCTAssertNoThrow(try P256.Signing.ECDSASignature(derRepresentation: label.signature))
    }

    func testWrongSignerForeignSignatureAndRebindingAreRejected() throws {
        let encoded = try SignedLabelCodec.sign(identity: alice, kind: .personName, binding: .call(callId), text: "Asha")
        let label = try SignedLabelCodec.decode(encoded)
        XCTAssertEqual(reason { try SignedLabelCodec.verify(label, expectedSigner: mallory.nodeId, expectedBinding: .call(callId)) }, "signer")
        XCTAssertEqual(reason { try SignedLabelCodec.verify(label, expectedSigner: alice.nodeId, expectedBinding: .call(otherCall)) }, "binding")
        XCTAssertEqual(reason { try SignedLabelCodec.verify(label, expectedSigner: alice.nodeId, expectedBinding: .stream(callId)) }, "binding")
        let forged = try SignedLabelCodec.signedPart(kind: 1, spki: alice.publicKeyEncoded, sequence: 0, binding: .call(callId), text: "Asha")
        let forgedBytes = try withSignature(forged, mallory)
        XCTAssertEqual(reason { try SignedLabelCodec.verify(try SignedLabelCodec.decode(forgedBytes), expectedSigner: alice.nodeId, expectedBinding: .call(callId)) }, "signature")
        var rebound = encoded
        let bindingOffset = 4 + 1 + 1 + 2 + alice.publicKeyEncoded.count + 4 + 1
        rebound[bindingOffset] ^= 1
        let reboundLabel = try SignedLabelCodec.decode(rebound)
        XCTAssertEqual(reason { try SignedLabelCodec.verify(reboundLabel, expectedSigner: alice.nodeId, expectedBinding: reboundLabel.binding) }, "signature")
    }

    func testNonCanonicalTextIsDroppedEvenWhenSigned() throws {
        let unsigned = try SignedLabelCodec.signedPart(kind: 1, spki: alice.publicKeyEncoded, sequence: 0, binding: .call(callId), text: " Asha")
        let bytes = try withSignature(unsigned, alice)
        XCTAssertTrue(reason { try SignedLabelCodec.verify(try SignedLabelCodec.decode(bytes), expectedSigner: alice.nodeId, expectedBinding: .call(callId)) }.hasPrefix("text"))
    }

    func testInboxKeepsHigherSequenceSkipsUnknownKindsAndNeverThrows() throws {
        var now: TimeInterval = 0
        let inbox = LabelInbox { now }
        let binding = LabelBinding.call(callId)
        let v1 = try SignedLabelCodec.sign(identity: alice, kind: .personName, binding: binding, text: "Asha", sequence: 1)
        let v0 = try SignedLabelCodec.sign(identity: alice, kind: .personName, binding: binding, text: "Old", sequence: 0)
        XCTAssertEqual(inbox.accept(try SignedLabelCodec.encodeContainer([v1]), expectedSigner: alice.nodeId, expectedBinding: binding), [.personName])
        now += 3
        XCTAssertTrue(inbox.accept(try SignedLabelCodec.encodeContainer([v0]), expectedSigner: alice.nodeId, expectedBinding: binding).isEmpty)
        XCTAssertEqual(inbox.text(.personName), "Asha")
        now += 3
        let unknown = try withSignature(try SignedLabelCodec.signedPart(kind: 9, spki: alice.publicKeyEncoded, sequence: 0, binding: binding, text: "x"), alice)
        XCTAssertTrue(inbox.accept(try SignedLabelCodec.encodeContainer([unknown]), expectedSigner: alice.nodeId, expectedBinding: binding).isEmpty)
        now += 3
        let container = try SignedLabelCodec.encodeContainer([v1])
        XCTAssertTrue(inbox.accept(container.prefix(container.count - 5), expectedSigner: alice.nodeId, expectedBinding: binding).isEmpty)
        now += 3
        XCTAssertTrue(inbox.accept(Data([1, 2, 3]), expectedSigner: alice.nodeId, expectedBinding: binding).isEmpty)
        XCTAssertEqual(inbox.text(.personName), "Asha")
        XCTAssertEqual(inbox.verifiedEncoded(), [v1])
    }

    func testContainerCountAndRateLimits() throws {
        XCTAssertTrue(try SignedLabelCodec.decodeContainer(try SignedLabelCodec.encodeContainer([])).isEmpty)
        XCTAssertEqual(reason { _ = try SignedLabelCodec.decodeContainer(Data("BLB1".utf8) + Data([4])) }, "container count")
        var now: TimeInterval = 0
        let inbox = LabelInbox { now }
        let binding = LabelBinding.call(callId)
        let name = try SignedLabelCodec.encodeContainer([try SignedLabelCodec.sign(identity: alice, kind: .personName, binding: binding, text: "Asha")])
        XCTAssertEqual(inbox.accept(name, expectedSigner: alice.nodeId, expectedBinding: binding).count, 1)
        now += 0.5
        let subject = try SignedLabelCodec.encodeContainer([try SignedLabelCodec.sign(identity: alice, kind: .callSubject, binding: binding, text: "Hi")])
        XCTAssertTrue(inbox.accept(subject, expectedSigner: alice.nodeId, expectedBinding: binding).isEmpty)
        XCTAssertNil(inbox.text(.callSubject))
    }

    func testForwardedLabelsVerifyAgainstTheGrantSourceAndStream() throws {
        let streamId = UUID()
        let title = try SignedLabelCodec.sign(identity: alice, kind: .streamTitle, binding: .stream(streamId), text: "Flood update")
        let forwarder = LabelInbox()
        forwarder.accept(try SignedLabelCodec.encodeContainer([title]), expectedSigner: alice.nodeId, expectedBinding: .stream(streamId))
        let child = LabelInbox()
        child.accept(try SignedLabelCodec.encodeContainer(forwarder.verifiedEncoded()), expectedSigner: alice.nodeId, expectedBinding: .stream(streamId))
        XCTAssertEqual(child.text(.streamTitle), "Flood update")
        let other = LabelInbox()
        other.accept(try SignedLabelCodec.encodeContainer([title]), expectedSigner: alice.nodeId, expectedBinding: .stream(UUID()))
        XCTAssertNil(other.text(.streamTitle))
        let wrongSource = LabelInbox()
        wrongSource.accept(try SignedLabelCodec.encodeContainer([title]), expectedSigner: mallory.nodeId, expectedBinding: .stream(streamId))
        XCTAssertNil(wrongSource.text(.streamTitle))
        XCTAssertEqual(LabelBinding.stream(nil), LabelBinding.directStream)
        XCTAssertEqual(LabelBinding.directStream.id.rawBytes, Data(count: 16))
    }

    func testOldPeersNeverReceiveOrParseLabels() throws {
        let base = NodeCapabilities(transportMask: 0x01, encodeCodecMask: 0x01, decodeCodecMask: 0x01, maxBitrateKbps: 500, maxChildren: 0)
        XCTAssertEqual(PeerLabelFeature.advertise(base, enabled: false), base)
        let withBit = PeerLabelFeature.advertise(base, enabled: true)
        XCTAssertEqual(withBit.transportMask, 0x21)
        XCTAssertFalse(PeerLabelFeature.negotiated(localEnabled: true, peer: base))
        XCTAssertFalse(PeerLabelFeature.negotiated(localEnabled: false, peer: withBit))
        XCTAssertTrue(PeerLabelFeature.negotiated(localEnabled: true, peer: withBit))
        XCTAssertFalse(PeerLabelFeature.streamHopNegotiated(localEnabled: true, linkPeer: mallory.nodeId, endpointPeer: alice.nodeId, peer: withBit))
        XCTAssertTrue(PeerLabelFeature.streamHopNegotiated(localEnabled: true, linkPeer: alice.nodeId, endpointPeer: alice.nodeId, peer: withBit))
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        let record = try EndToEndContentSealer(key: key).seal(.labels, try SignedLabelCodec.encodeContainer([]))
        XCTAssertThrowsError(try EndToEndContentOpener(key: key).open(record)) { error in
            XCTAssertTrue("\(error)".contains("Unknown end-to-end content type 10"))
        }
        let opener = EndToEndContentOpener(key: key); opener.acceptLabels = true
        XCTAssertEqual(try opener.open(record).type, .labels)
    }
}

final class TitlePageTests: XCTestCase {
    let token: UInt32 = 0x81234567

    func testShortTitleIsOnePageWithTheProtocolLayout() throws {
        let pages = try TitlePageCodec.pages(routeToken: token, title: "Hi")
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].hex, "03" + "81234567" + String(format: "%04x", TitlePageCodec.digest(Data("Hi".utf8))) + "01" + "4869")
        XCTAssertEqual(pages[0].hex, "03812345673639014869")
        XCTAssertThrowsError(try DiscoveryAnnouncement(decoding: pages[0]))
    }

    func testMultiByteTitleNeverSplitsACodePointAndReassemblesOutOfOrder() throws {
        let title = String(repeating: "a", count: 18) + String(repeating: "\u{20AC}", count: 10)
        XCTAssertEqual(title.utf8.count, 48)
        let pages = try TitlePageCodec.pages(routeToken: token, title: title)
        XCTAssertEqual(pages.count, 3)
        for page in pages {
            let fragment = try TitlePageCodec.decode(page).fragment
            XCTAssertNotNil(String(data: fragment, encoding: .utf8))
            XCTAssertLessThanOrEqual(page.count, 27)
        }
        let board = TitleBoard { 1 }
        XCTAssertNil(board.add(try TitlePageCodec.decode(pages[2])))
        XCTAssertNil(board.add(try TitlePageCodec.decode(pages[0])))
        XCTAssertEqual(board.add(try TitlePageCodec.decode(pages[1])), title)
        XCTAssertEqual(board.title(routeToken: token), title)
    }

    func testDigestMismatchAndConflictingTitlesShowNoTitle() throws {
        var now: TimeInterval = 0
        let board = TitleBoard { now }
        let good = try TitlePageCodec.decode(try TitlePageCodec.pages(routeToken: token, title: "Market")[0])
        let tampered = TitlePage(routeToken: good.routeToken, digest: good.digest, index: 0, count: 1, fragment: Data("Marker".utf8))
        XCTAssertNil(board.add(tampered)); XCTAssertNil(board.title(routeToken: token))
        now += 1
        XCTAssertNil(board.add(try TitlePageCodec.decode(try TitlePageCodec.pages(routeToken: token, title: "Other")[0])))
        XCTAssertNil(board.title(routeToken: token))
        now += 61
        XCTAssertEqual(board.add(good), "Market")
    }

    func testMalformedPagesAreRejected() throws {
        let page = try TitlePageCodec.pages(routeToken: token, title: "Hi")[0]
        var badIndex = page; badIndex[7] = 0x11
        XCTAssertThrowsError(try TitlePageCodec.decode(badIndex))
        var zeroCount = page; zeroCount[7] = 0
        XCTAssertThrowsError(try TitlePageCodec.decode(zeroCount))
        XCTAssertThrowsError(try TitlePageCodec.decode(page.prefix(8)))
        XCTAssertThrowsError(try TitlePageCodec.pages(routeToken: token, title: String(repeating: "a", count: 49)))
    }

    func testNonCanonicalAdvertisedTitleIsNotShown() {
        let board = TitleBoard { 0 }
        let raw = Data(" padded".utf8)
        XCTAssertNil(board.add(TitlePage(routeToken: token, digest: TitlePageCodec.digest(raw), index: 0, count: 1, fragment: raw)))
    }

    /// Naming review R11: call-offer bit 18 = "may be relayed", carried as capabilitySummary 0x10, never rejected.
    func testCompactCallOfferRelayConsentBit() throws {
        let p1 = Data([1, 2, 3, 4, 5, 6])
        let consenting = DiscoveryAnnouncement(nodeIdPrefix: p1, flags: DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable,
                                               capabilitySummary: 0x03 | 0x10, streamToken: 0, routeCost: 0)
        XCTAssertEqual(try CompactAnnouncement.encode(consenting), "C8D64010-2030-4050-60C0-000000040000")
        let decoded = try XCTUnwrap(CompactAnnouncement.decode("C8D64010-2030-4050-60C0-000000040000"))
        XCTAssertEqual(decoded, consenting)
        XCTAssertEqual(decoded.capabilitySummary & 0x7, 0x03)
        XCTAssertNotNil(CompactAnnouncement.decode("C8D64010-2030-4050-60C0-000000000000"))
        // Every other call-offer bit 49..19 and 17..0 still rejects.
        func flip(_ uuid: String, bit: Int) -> String {
            var b = UUID(uuidString: uuid)!.rawBytes; b[15 - bit / 8] ^= UInt8(1 << (bit % 8)); return UUID(rawBytes: b).uuidString
        }
        for bit in Array(0...17) + Array(19...49) { XCTAssertNil(CompactAnnouncement.decode(flip("C8D64010-2030-4050-60C0-000000000000", bit: bit)), "bit \(bit)") }
        // Stream offers and viewer requests cannot carry the consent bit.
        let stream = DiscoveryAnnouncement(nodeIdPrefix: p1, flags: DiscoveryAnnouncement.flagStreamAvailable, capabilitySummary: 0x11, streamToken: 0x80000001, routeCost: 0)
        XCTAssertThrowsError(try CompactAnnouncement.encode(stream))
    }
}

/// Labels signed by the Android patch's own SignedLabel.kt verify in Swift; Swift's text verdicts match
/// Android's LabelText on a shared table (scripts, handle shapes, whitespace, marks); title pages reassemble.
final class AndroidLabelVectorTests: XCTestCase {
    func testAndroidLabelsTextVerdictsAndPages() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "android-labels", withExtension: "json", subdirectory: "Fixtures"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        func hex(_ k: String) throws -> Data { try XCTUnwrap(Data(hex: try XCTUnwrap(json[k] as? String))) }
        let signer = NodeId.fromPublicKey(try hex("spki"))
        XCTAssertEqual(signer.hex, json["signer"] as? String)
        let callId = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(json["callId"] as? String)))
        let streamId = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(json["streamId"] as? String)))
        let name = try SignedLabelCodec.decode(try hex("name"))
        XCTAssertEqual(try SignedLabelCodec.verify(name, expectedSigner: signer, expectedBinding: .call(callId)), .personName)
        XCTAssertEqual(name.text, "Asha Rao")
        let title = try SignedLabelCodec.decode(try hex("title"))
        XCTAssertEqual(try SignedLabelCodec.verify(title, expectedSigner: signer, expectedBinding: .stream(streamId)), .streamTitle)
        let direct = try SignedLabelCodec.decode(try hex("direct"))
        XCTAssertEqual(direct.sequence, 7)
        XCTAssertEqual(try SignedLabelCodec.verify(direct, expectedSigner: signer, expectedBinding: .directStream), .streamTitle)
        let inbox = LabelInbox()
        XCTAssertEqual(inbox.accept(try hex("container"), expectedSigner: signer, expectedBinding: .call(callId)), [.personName, .callSubject])
        XCTAssertEqual(inbox.text(.callSubject), "Water at the school")
        let board = TitleBoard { 5 }
        var assembled: String?
        for page in try XCTUnwrap(json["pages"] as? [String]) { assembled = board.add(try TitlePageCodec.decode(try XCTUnwrap(Data(hex: page)))) ?? assembled }
        XCTAssertEqual(assembled, String(repeating: "a", count: 18) + String(repeating: "\u{20AC}", count: 10))
        let cases = try XCTUnwrap(json["textCases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 40)
        for c in cases {
            let text = try XCTUnwrap(c["text"] as? String)
            let kind = try XCTUnwrap(LabelKind(rawValue: UInt8(try XCTUnwrap(c["kind"] as? Int))))
            XCTAssertEqual(LabelText.rejection(kind, text), c["rejection"] as? String, "verdict for \(text.unicodeScalars.map { String(format: "U+%04X", $0.value) })")
        }
    }

    /// Writes Swift-signed labels for `java -jar labels.jar verify <file>` (Interop/android-vectors/README.md).
    func testSwiftLabelsForAndroidVerification() throws {
        let alice = SoftwareSigningIdentity()
        let callId = UUID(), streamId = UUID()
        let name = try SignedLabelCodec.sign(identity: alice, kind: .personName, binding: .call(callId), text: "Ravi \u{0930}\u{093E}\u{092E}")
        let subject = try SignedLabelCodec.sign(identity: alice, kind: .callSubject, binding: .call(callId), text: "Meet at the gate")
        let title = try SignedLabelCodec.sign(identity: alice, kind: .streamTitle, binding: .stream(streamId), text: "Tokyo \u{6771}\u{4EAC}")
        let out: [String: String] = ["spki": alice.publicKeyEncoded.hex, "callId": callId.uuidString.lowercased(), "streamId": streamId.uuidString.lowercased(),
                                     "name": name.hex, "subject": subject.hex, "title": title.hex,
                                     "container": try SignedLabelCodec.encodeContainer([name, subject]).hex]
        guard let path = ProcessInfo.processInfo.environment["NEARBY_LABELS_OUT"] else { return }
        try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path))
    }
}
