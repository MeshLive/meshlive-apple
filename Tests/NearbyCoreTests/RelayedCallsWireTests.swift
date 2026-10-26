import XCTest
import CryptoKit
@testable import NearbyCore

/// Relayed-call wire formats against Android's vectors (RelayedCallsWireTest, ReachRotatingTest, PROTOCOL).
final class RelayedCallsWireTests: XCTestCase {
    private func d(_ hex: String) -> Data { Data(hex: hex)! }
    private let target = Data(hex: "010203040506")!
    private let relay = Data(hex: "0a0b0c0d0e0f")!
    private let id = Data(hex: "0102030405060708")!

    func testReachPageMatchesAndroidBytes() throws {
        let page = ReachPage(relayPrefix: relay, relayFlags: ReachPageCodec.flagCoc | ReachPageCodec.flagIdle, index: 0, count: 1,
                             entries: [try ReachPageEntry(target: target, cost: 1, ageUnits: 3, via: d("0102"))])
        let encoded = try ReachPageCodec.encode(page)
        XCTAssertEqual(encoded.hex, "040a0b0c0d0e0f0901010203040506230102")
        XCTAssertEqual(try ReachPageCodec.decode(encoded), page)
        XCTAssertEqual(try ReachPageCodec.decode(encoded).entries[0].ageMs, 6_000)
        XCTAssertThrowsError(try DiscoveryAnnouncement(decoding: encoded), "old scanners reject a reach page")
    }

    func testRotatingReachPagesMatchProtocolVectors() throws {
        let rdiRelay = d("44e69c0a7a7d")
        let one = ReachPage(relayPrefix: rdiRelay, relayFlags: ReachPageCodec.flagCoc | ReachPageCodec.flagIdle, index: 0, count: 1,
                            entries: [try ReachPageEntry(target: d("fecba64983fd"), cost: 1, ageUnits: 3, via: d("fecb"))], rotating: true)
        XCTAssertEqual(try ReachPageCodec.encode(one).hex, "0644e69c0a7a7d0901fecba64983fd23fecb")
        let two = try ReachPageCodec.decode(d("0644e69c0a7a7d0912fecba64983fd5fa1b2974ae410ea9120974a"))
        XCTAssertTrue(two.rotating); XCTAssertEqual(two.index, 1); XCTAssertEqual(two.count, 2)
        XCTAssertEqual(two.entries.map(\.cost), [2, 1]); XCTAssertEqual(two.entries[1].target.hex, "974ae410ea91")
        XCTAssertEqual(try ReachPageCodec.encode(two).hex, "0644e69c0a7a7d0912fecba64983fd5fa1b2974ae410ea9120974a")
    }

    func testReachPageDecoderRejectsMalformedPages() throws {
        let good = try ReachPageCodec.encode(ReachPage(relayPrefix: relay, relayFlags: ReachPageCodec.flagCoc, index: 0, count: 1,
                                                       entries: [try ReachPageEntry(target: target, cost: 1, ageUnits: 0, via: d("0102"))]))
        func mutate(_ i: Int, _ v: UInt8) -> Data { var m = good; m[i] = v; return m }
        for bad in [good.prefix(17).rebased, good + Data([0]), mutate(0, 3), mutate(7, 0x04), mutate(7, 0x10), mutate(8, 0),
                    mutate(8, 0x15), mutate(8, 0x11), mutate(15, 0x03), mutate(15, 5 << 5)] {
            XCTAssertThrowsError(try ReachPageCodec.decode(bad))
        }
        var selfTarget = good; selfTarget.replaceSubrange(9..<15, with: relay)
        XCTAssertThrowsError(try ReachPageCodec.decode(selfTarget), "a target equal to the relay")
        let entries = try (1...6).map { try ReachPageEntry(target: Data([UInt8($0), 2, 3, 4, 5, 6]), cost: 1, ageUnits: $0, via: d("0102")) }
        let pages = try ReachPageCodec.pages(relayPrefix: relay, relayFlags: ReachPageCodec.flagCoc, entries: entries)
        XCTAssertEqual(pages.count, 2); XCTAssertEqual(try pages.map { try ReachPageCodec.decode($0).index }, [0, 1])
    }

    func testRelaySetupMatchesAndroidBytes() throws {
        XCTAssertEqual(try RelaySetupCodec.encode(.setup(target: target, budget: 2, remainingMs: 20_000, setupId: id, rotating: false)).hex,
                       "42525331" + "01" + "010203040506" + "02" + "00004e20" + "0102030405060708")
        XCTAssertEqual(try RelaySetupCodec.encode(.ready(setupId: id, relays: 2)).hex, "42525331" + "02" + "0102030405060708" + "02")
        XCTAssertEqual(try RelaySetupCodec.encode(.fail(setupId: id, reason: .refused)).hex, "42525331" + "03" + "0102030405060708" + "05")
        let rdi = d("974ae410ea91")
        let setupRdi = try RelaySetupCodec.encode(.setup(target: rdi, budget: 2, remainingMs: 20_000, setupId: id, rotating: true))
        XCTAssertEqual(setupRdi.hex, "4252533104974ae410ea910200004e200102030405060708")
        XCTAssertThrowsError(try RelaySetupCodec.decode(setupRdi), "message 4 is unknown without rotating relayed calls")
        XCTAssertEqual(try RelaySetupCodec.decode(setupRdi, acceptRdi: true),
                       .setup(target: rdi, budget: 2, remainingMs: 20_000, setupId: id, rotating: true))
    }

    func testRelaySetupDecoderRejectsMalformedMessages() throws {
        let setup = try RelaySetupCodec.encode(.setup(target: target, budget: 1, remainingMs: 2_000, setupId: id, rotating: false))
        func mutate(_ i: Int, _ v: UInt8) -> Data { var m = setup; m[i] = v; return m }
        let bad: [Data] = [mutate(0, 0x41), mutate(4, 9), mutate(11, 0), mutate(11, 5), setup + Data([0]), setup.prefix(23).rebased,
                           d("42525331" + "02" + "0102030405060708" + "00"), d("42525331" + "02" + "0102030405060708" + "05"),
                           d("42525331" + "03" + "0102030405060708" + "07"),
                           d("42525331" + "01" + "000000000000" + "01" + "000007d0" + "0102030405060708"),
                           d("42525331" + "01" + "010203040506" + "01" + "000007cf" + "0102030405060708"),
                           d("42525331" + "01" + "010203040506" + "01" + "00004e21" + "0102030405060708")]
        for b in bad { XCTAssertThrowsError(try RelaySetupCodec.decode(b), b.hex) }
    }

    func testHopTypeTwelveIsRejectedUnlessTheReaderOptsIn() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try SecureRecordSealer(key: key).seal(.relaySetup, Data("BRS1".utf8))
        XCTAssertThrowsError(try SecureRecordOpener(key: key).feed(sealed))
        let opener = SecureRecordOpener(key: key); opener.acceptRelaySetup = true
        XCTAssertEqual(try opener.feed(sealed).first?.type, .relaySetup)
    }

    func testOfferAndHelloBitsAreUnchangedWithTheFeatureOff() {
        let base = DiscoveryAnnouncement(nodeIdPrefix: target, flags: DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable,
                                         capabilitySummary: NodeCapabilities.codecVP9, streamToken: 0, routeCost: 0)
        XCTAssertEqual(RelayedCalls.offerFor(base, consentOn: false, helperActive: false), base)
        let on = RelayedCalls.offerFor(base, consentOn: true, helperActive: true)
        XCTAssertTrue(RelayedCalls.consents(on)); XCTAssertTrue(RelayedCalls.isRelayHelperOffer(on))
        let caps = NodeCapabilities(transportMask: NodeCapabilities.transportGATT, encodeCodecMask: 1, decodeCodecMask: 1, maxBitrateKbps: 1100, maxChildren: 0)
        XCTAssertEqual(RelayedCalls.linkCapabilities(caps, featureOn: false, helperActive: true), caps)
        XCTAssertTrue(RelayedCalls.linkUnderstandsSetup(RelayedCalls.linkCapabilities(caps, featureOn: true, helperActive: false)))
        XCTAssertFalse(RelayedCalls.linkAcceptsSetup(RelayedCalls.linkCapabilities(caps, featureOn: true, helperActive: false)))
        XCTAssertTrue(RelayedCalls.linkAcceptsSetup(RelayedCalls.linkCapabilities(caps, featureOn: true, helperActive: true)))
        XCTAssertEqual(RelayedCalls.nextHopRemainingMs(remainingMs: 4_000, elapsedMs: 1_000), 2_000)
        XCTAssertNil(RelayedCalls.nextHopRemainingMs(remainingMs: 4_000, elapsedMs: 1_001))
    }

    func testHelperAdmissionOrderAndRateLimits() {
        var i = RelaySetupInputs(); i.targetIsSelf = true; i.parentIsTarget = true
        XCTAssertEqual(RelaySetupAdmission.refusal(i), .noRoute, "own ID answers like a missing entry, before loop")
        i = RelaySetupInputs(); i.busy = true; i.rateLimited = true
        XCTAssertEqual(RelaySetupAdmission.refusal(i), .busy)
        i = RelaySetupInputs(); i.budget = 3
        XCTAssertEqual(RelaySetupAdmission.refusal(i), .refused)
        let limiter = RelaySetupRateLimiter()
        XCTAssertEqual((0..<4).map { _ in limiter.tryAdmit("a", nowMs: 0) }, [true, true, true, false])
        XCTAssertTrue(limiter.tryAdmit("a", nowMs: 60_000))
        XCTAssertEqual(RelaySetupRateLimiter.key(parentPrefixHex: "aa", pseudonymous: true, remoteAddress: nil), RelaySetupRateLimiter.unknownAddressBucket)
        XCTAssertEqual(RelaySetupRateLimiter.key(parentPrefixHex: "aa", pseudonymous: false, remoteAddress: "x"), "aa")
    }

    // MARK: Design OR SEEK (Android RelaySeekTest vectors)

    func testSeekTokenAndMessageMatchAndroidBytes() throws {
        let nonce = d("0102030405060708"), target = d("974ae410ea91")
        XCTAssertEqual(RelaySeek.token(nonce: nonce, rdi: target).hex, "f997a00c2596")
        XCTAssertNotEqual(RelaySeek.token(nonce: d("0102030405060709"), rdi: target), RelaySeek.token(nonce: nonce, rdi: target))
        let seek = RelaySetupMessage.seek(budget: 2, remainingMs: 20_000, setupId: d("1112131415161718"), nonce: nonce,
                                          token: RelaySeek.token(nonce: nonce, rdi: target), skip: [d("44e6")])
        let encoded = try RelaySetupCodec.encode(seek)
        XCTAssertEqual(encoded.hex, "42525331050200004e2011121314151617180102030405060708f997a00c25960144e6")
        XCTAssertThrowsError(try RelaySetupCodec.decode(encoded), "message 5 is unknown with the switches off")
        XCTAssertEqual(try RelaySetupCodec.decode(encoded, acceptSeek: true), seek)
        for count in 0...3 {
            let skip = (0..<count).map { Data([0x10, UInt8(0x20 + $0)]) }
            let bytes = try RelaySetupCodec.encode(.seek(budget: 1, remainingMs: 2_000, setupId: id, nonce: nonce, token: d("aabbccddeeff"), skip: skip))
            XCTAssertEqual(bytes.count, 33 + 2 * count)
        }
        for bad in [encoded.prefix(encoded.count - 1).rebased, encoded + Data([0])] { XCTAssertThrowsError(try RelaySetupCodec.decode(bad, acceptSeek: true)) }
        XCTAssertThrowsError(try RelaySetupCodec.encode(.seek(budget: 3, remainingMs: 2_000, setupId: id, nonce: nonce, token: d("aabbccddeeff"), skip: [])))
        XCTAssertThrowsError(try RelaySetupCodec.encode(.seek(budget: 1, remainingMs: 2_000, setupId: id, nonce: Data(count: 8), token: d("aabbccddeeff"), skip: [])))
        XCTAssertThrowsError(try RelaySetupCodec.encode(.seek(budget: 1, remainingMs: 2_000, setupId: id, nonce: nonce, token: d("aabbccddeeff"),
                                                              skip: [d("0102"), d("0102")])))
    }

    func testRelaySeekExtensionIsTypeFiveAndFitsBesideTheLargestBlock() throws {
        let area = try Bmh3Extensions(relaySeek: RelaySeek.featureSeekV1).encodeArea()
        XCTAssertEqual(try Bmh3Extensions.parse(area).relaySeek, 1)
        XCTAssertNil(try Bmh3Extensions.parse(try Bmh3Extensions().encodeArea()).relaySeek)
        var opening = Data(count: 87); opening[0] = 2
        let full = Bmh3Extensions(opening: opening, buildTag: BuildTag(encoded: 0x0601), relaySeek: 1)
        XCTAssertEqual(try Bmh3Extensions.parse(try full.encodeArea()).relaySeek, 1)
        func areaWith(_ tail: [UInt8]) -> Data {
            let pad = Bmh3Wire.extensionBytes - 3 - tail.count
            return Data([0, UInt8(pad >> 8), UInt8(pad & 0xff)]) + Data(count: pad) + Data(tail)
        }
        XCTAssertThrowsError(try Bmh3Extensions.parse(areaWith([5, 0, 2, 1, 0])))
        XCTAssertEqual(try Bmh3Extensions.parse(areaWith([5, 0, 1, 7])).relaySeek, 7, "reserved bits are carried")
    }

    func testAListenerSignsRelaySeekInItsLinkBlockAndTheCallerReadsIt() throws {
        let budget = Bmh3SigningBudget(capacity: 10)
        let listenerSettings = Bmh3CallSettings(speak: false, acceptBmh2: true, replayCache: Bmh3ReplayCache(), budget: budget)
        listenerSettings.relaySeek = RelaySeek.featureSeekV1
        let listener = CallRelayLink(role: .responder, transport: .gatt, identity: SoftwareSigningIdentity(), bmh3: listenerSettings, relaySetup: true)
        let caller = CallRelayLink(role: .initiator, transport: .gatt, identity: SoftwareSigningIdentity(), bmh3: Bmh3CallSettings(speak: true))
        try listener.start(now: 0); try caller.start(now: 0)
        for _ in 0..<10 {
            while let b = caller.nextOutgoing(now: 0) { listener.receive(b, now: 0) }
            while let b = listener.nextOutgoing(now: 0) { caller.receive(b, now: 0) }
        }
        XCTAssertEqual(caller.phase, .open, caller.closeReason ?? "-")
        XCTAssertEqual(caller.linkPeerRelaySeek, 1)
        XCTAssertEqual(listener.linkPeerRelaySeek, 0, "an initiator block never carries it")
    }
}
