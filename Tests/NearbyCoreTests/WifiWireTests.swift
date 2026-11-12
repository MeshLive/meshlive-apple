import XCTest
@testable import NearbyCore

/// The Android Wi-Fi vectors (`app/src/test/resources/wifi-vectors.json`), byte for byte.
final class WifiWireTests: XCTestCase {
    private var json: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "wifi-vectors", withExtension: "json", subdirectory: "Fixtures"))
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func entries(_ key: String) throws -> [[String: Any]] { try XCTUnwrap(json[key] as? [[String: Any]]) }
    private func hex(_ value: Any?) throws -> Data { try XCTUnwrap(Data(hex: try XCTUnwrap(value as? String))) }
    private func name(_ entry: [String: Any]) -> String { entry["name"] as? String ?? "" }

    private func dottedQuad(_ value: UInt32) -> String {
        "\(value >> 24).\(value >> 16 & 255).\(value >> 8 & 255).\(value & 255)"
    }

    /// The vector's field names for one decoded record.
    private func fields(_ record: Bwf1) -> [String: String] {
        switch record {
        case .caps(let bearers, let freeHost, let freeGuest):
            return ["bearers": "\(bearers)", "freeHost": "\(freeHost)", "freeGuest": "\(freeGuest)"]
        case .host(let status, let bearer, let ticket, let validMs, let freqMhz):
            return ["status": "\(status)", "bearer": "\(bearer)", "ticket": ticket.hex, "validMs": "\(validMs)", "freqMhz": "\(freqMhz)"]
        case .decline(let ticket, let reason):
            return ["ticket": ticket.hex, "reason": "\(reason)"]
        case .pick(let ticket, let challenge):
            return ["ticket": ticket.hex, "challenge": challenge.hex]
        case .armed(let ticket):
            return ["ticket": ticket.hex]
        case .bind(let role, let ticket):
            return ["role": "\(role)", "ticket": ticket.hex]
        case .ready(let recvCeilingKbps, let familyCapKbps, let transportBudgetKbps):
            return ["recvCeilingKbps": "\(recvCeilingKbps)", "familyCapKbps": "\(familyCapKbps)", "transportBudgetKbps": "\(transportBudgetKbps)"]
        case .switchTo(let gen, let ticket, let e2eBoundary, let meshBoundary):
            return ["gen": "\(gen)", "ticket": ticket.hex, "e2eBoundary": "\(e2eBoundary)", "meshBoundary": "\(meshBoundary)"]
        case .resume(let gen, let ticket, let e2eNext, let meshNext):
            return ["gen": "\(gen)", "ticket": ticket.hex, "e2eNext": "\(e2eNext)", "meshNext": "\(meshNext)"]
        case .close(let reason):
            return ["reason": "\(reason)"]
        case .creds(let ticket, let port, let ipv4):
            return ["ticket": ticket.hex, "port": "\(port)", "ipv4": dottedQuad(ipv4)]
        }
    }

    private func strings(_ values: [String: Any]) -> [String: String] {
        values.mapValues { value in
            if let text = value as? String { return text }
            if let number = value as? NSNumber { return number.stringValue }
            return "\(value)"
        }
    }

    func testEveryValidRecordDecodesAsAndroid() throws {
        for entry in try entries("bwf1") {
            let decoded = try Bwf1.decode(try hex(entry["hex"]))
            let expected = strings(try XCTUnwrap(entry["decoded"] as? [String: Any]))
            XCTAssertEqual(fields(decoded), expected, name(entry))
        }
    }

    func testRecordsThatRoundTripEncodeByteForByte() throws {
        for entry in try entries("bwf1") where entry["roundTrip"] as? Bool == true {
            let bytes = try hex(entry["hex"])
            XCTAssertEqual(try Bwf1.decode(bytes).encoded(), bytes, name(entry))
        }
    }

    func testEveryInvalidRecordIsRefusedWithAndroidsError() throws {
        for entry in try entries("bwf1Invalid") {
            let expected = try XCTUnwrap(WifiWireError(rawValue: try XCTUnwrap(entry["error"] as? String)))
            XCTAssertThrowsError(try Bwf1.decode(try hex(entry["hex"])), name(entry)) { error in
                XCTAssertEqual(error as? WifiWireError, expected, name(entry))
            }
        }
    }

    func testRolesMatchAndroidForEveryRow() throws {
        let roles = try XCTUnwrap(json["roles"] as? [String: Any])
        let rows = try XCTUnwrap(roles["rows"] as? [[Int]])
        var mismatches: [[Int]] = []
        for row in rows {
            XCTAssertEqual(row.count, 9)
            let local = WifiRoles.Caps(bearers: UInt8(row[0]), freeHost: UInt8(row[1]), freeGuest: UInt8(row[2]))
            let peer = WifiRoles.Caps(bearers: UInt8(row[3]), freeHost: UInt8(row[4]), freeGuest: UInt8(row[5]))
            let expected = row[7] == 0 ? nil : WifiRoles.Tuple(bearer: UInt8(row[7]), localIsHost: row[8] == 1)
            let actual = WifiRoles.choose(local: local, peer: peer, localIsLinkInitiator: row[6] == 1)
            if actual != expected {
                mismatches.append(row)
                if mismatches.count <= 5 { print("roles mismatch: row \(row), got \(String(describing: actual))") }
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count) role rows mismatch; first five: \(mismatches.prefix(5))")
    }

    func testAnAppleGuestAlwaysJoinsAnAndroidHost() {
        for initiator in [true, false] {
            for peer in [WifiRoles.Caps(bearers: 12, freeHost: 0, freeGuest: 0), WifiRoles.Caps(bearers: 13, freeHost: 2, freeGuest: 2)] {
                XCTAssertEqual(WifiRoles.choose(local: (8, 0, 0), peer: peer, localIsLinkInitiator: initiator),
                               WifiRoles.Tuple(bearer: 2, localIsHost: false))
            }
            XCTAssertNil(WifiRoles.choose(local: (8, 0, 0), peer: (8, 0, 0), localIsLinkInitiator: initiator))
        }
    }

    func testBwu1FramesMatchAndroid() throws {
        let keys = try XCTUnwrap(json["keys"] as? [String: Any])
        let bind = try XCTUnwrap(json["bind"] as? [String: Any])
        XCTAssertEqual(try Bwu1Wire.challenge(fromFrame1: try hex(bind["frame1"])), try hex(bind["challenge"]))
        XCTAssertEqual(Bwu1Wire.frame2(ticket: try hex(keys["ticket"]), guestPoint: try hex(bind["guestPoint"]),
                                       guestNonce: try hex(bind["guestNonce"]), pre: try hex(bind["pre"])),
                       try hex(bind["frame2"]))
        let frame3 = try Bwu1Wire.parts(ofFrame3: try hex(bind["frame3"]))
        XCTAssertEqual(frame3.point, try hex(bind["hostPoint"]))
        XCTAssertEqual(frame3.nonce, try hex(bind["hostNonce"]))
    }

    func testBadBwu1FramesAreRefusedWithAndroidsError() throws {
        for entry in try entries("wireInvalid") {
            let frame = try XCTUnwrap(entry["frame"] as? Int)
            guard frame == 1 || frame == 2 || frame == 3 else { continue }
            let expected = try XCTUnwrap(WifiWireError(rawValue: try XCTUnwrap(entry["error"] as? String)))
            let bytes = try hex(entry["hex"])
            XCTAssertThrowsError(try {
                switch frame {
                case 1: _ = try Bwu1Wire.challenge(fromFrame1: bytes)
                case 2: _ = try Bwu1Wire.parts(ofFrame2: bytes)
                default: _ = try Bwu1Wire.parts(ofFrame3: bytes)
                }
            }(), name(entry)) { error in
                XCTAssertEqual(error as? WifiWireError, expected, name(entry))
            }
        }
    }

    // MARK: AW2 BMH2 build-tag gate and hop key

    private func linkPair(initiatorTag: BuildTag?, responderTag: BuildTag?, deriveKeys: Bool = false) throws -> (SecureLink, SecureLink) {
        let caps = NodeCapabilities(transportMask: NodeCapabilities.transportL2CAP, encodeCodecMask: 0, decodeCodecMask: 0,
                                    maxBitrateKbps: 0, maxChildren: 0)
        let initiator = SecureLink(role: .initiator, identity: SoftwareSigningIdentity(), capabilities: caps)
        let responder = SecureLink(role: .responder, identity: SoftwareSigningIdentity(), capabilities: caps)
        initiator.ownBuildTag = initiatorTag; responder.ownBuildTag = responderTag
        initiator.deriveHopWifiKey = deriveKeys; responder.deriveHopWifiKey = deriveKeys
        let hello = try XCTUnwrap(try initiator.start())
        let replies = try responder.receive(hello)
        guard case .send(let reply)? = replies.first else { XCTFail("no responder hello"); return (initiator, responder) }
        XCTAssertTrue(replies.contains(.established))
        XCTAssertEqual(try initiator.receive(reply), [.established])
        return (initiator, responder)
    }

    /// Android "BMH2 hops": both link hellos sign a build tag of at least WifiWire.firstRelease, so the gate opens on both
    /// ends; each reads the other's tag, and bit 7 never shows as a capability.
    func testBuildTagsInBothLinkHellosOpenTheWifiGate() throws {
        let tag = BuildTag(releaseKey: false, release: WifiWire.firstRelease)
        let (initiator, responder) = try linkPair(initiatorTag: tag, responderTag: tag)
        XCTAssertTrue(initiator.wifiBuildTagGate)
        XCTAssertTrue(responder.wifiBuildTagGate)
        XCTAssertEqual(initiator.peerBuildTag, tag)
        XCTAssertEqual(responder.peerBuildTag, tag)
        XCTAssertEqual(initiator.sentBuildTag, tag)
        XCTAssertEqual((initiator.peerCapabilities?.transportMask ?? 0) & NodeCapabilities.transportBuildTag, 0)
        XCTAssertEqual((responder.peerCapabilities?.transportMask ?? 0) & NodeCapabilities.transportBuildTag, 0)
    }

    /// A missing tag on either side, or a lower release, is no BWF1 on that hop, ever.
    func testAMissingOrLowerBuildTagKeepsTheWifiGateClosed() throws {
        let tag = BuildTag(releaseKey: false, release: WifiWire.firstRelease)
        let older = BuildTag(releaseKey: true, release: WifiWire.firstRelease - 1)
        let cases: [(BuildTag?, BuildTag?)] = [(tag, nil), (nil, tag), (older, tag), (tag, older), (nil, nil)]
        for (initiatorTag, responderTag) in cases {
            let (initiator, responder) = try linkPair(initiatorTag: initiatorTag, responderTag: responderTag)
            XCTAssertFalse(initiator.wifiBuildTagGate)
            XCTAssertFalse(responder.wifiBuildTagGate)
            XCTAssertEqual(responder.peerBuildTag, initiatorTag)
            XCTAssertEqual(initiator.peerBuildTag, responderTag)
        }
    }

    /// The tag belongs to a link hello whose bit 7 is free: it takes nonce bytes 0-1 and still verifies; an end-to-end
    /// hello, or a link hello whose bit 7 is already set, keeps its nonce and capabilities as given.
    func testOnlyAFreeLinkHelloCarriesTheBuildTag() throws {
        let identity = SoftwareSigningIdentity()
        let tag = try XCTUnwrap(BuildTag(releaseKey: false, release: WifiWire.firstRelease))
        let nonce = Data(repeating: 0xAB, count: SignedHandshakeHello.nonceBytes)
        let caps = NodeCapabilities(transportMask: NodeCapabilities.transportL2CAP, encodeCodecMask: 0, decodeCodecMask: 0,
                                    maxBitrateKbps: 0, maxChildren: 0)
        let link = try MeshHandshake.start(identity: identity, role: .initiator, capabilities: caps, purpose: .link, nonce: nonce, buildTag: tag)
        XCTAssertEqual(link.hello.nonce.prefix(2), Data([0x00, 0x0B]))
        XCTAssertEqual(link.hello.nonce.suffix(30), nonce.suffix(30))
        XCTAssertNotEqual(link.hello.capabilities.transportMask & NodeCapabilities.transportBuildTag, 0)
        XCTAssertNoThrow(try MeshHandshake.verify(link.hello, purpose: .link))
        let endToEnd = try MeshHandshake.start(identity: identity, role: .initiator, capabilities: caps, purpose: .endToEnd,
                                               nonce: nonce, buildTag: tag)
        XCTAssertEqual(endToEnd.hello.nonce, nonce)
        XCTAssertEqual(endToEnd.hello.capabilities, caps)
        var taken = caps
        taken.transportMask |= NodeCapabilities.transportBuildTag
        let busy = try MeshHandshake.start(identity: identity, role: .initiator, capabilities: taken, purpose: .link, nonce: nonce, buildTag: tag)
        XCTAssertEqual(busy.hello.nonce, nonce)
    }

    /// Both ends of one BMH2 link derive the same hop key, hand it over once, and another link derives another; a link
    /// that was not asked keeps none.
    func testBothEndsOfALinkDeriveOneHopKeyOnce() throws {
        let (a, b) = try linkPair(initiatorTag: nil, responderTag: nil, deriveKeys: true)
        let key = try XCTUnwrap(a.takeHopWifiKey())
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(b.takeHopWifiKey(), key)
        XCTAssertNil(a.takeHopWifiKey())
        let (c, _) = try linkPair(initiatorTag: nil, responderTag: nil, deriveKeys: true)
        XCTAssertNotEqual(c.takeHopWifiKey(), key)
        let (off, _) = try linkPair(initiatorTag: nil, responderTag: nil)
        XCTAssertNil(off.takeHopWifiKey())
    }
}
