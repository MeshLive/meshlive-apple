import XCTest
import CryptoKit
@testable import NearbyCore

private struct VectorEntropy: Bwu1Entropy {
    let scalar: Data, nonceValue: Data
    func ephemeral() -> P256.KeyAgreement.PrivateKey { try! P256.KeyAgreement.PrivateKey(rawRepresentation: scalar) }
    func nonce() -> Data { nonceValue }
}

/// The Wi-Fi keys, Direct names and BWU1 guest against Android's vectors (tools/wifi_reference.py), so Apple and
/// Android derive the same bytes.
final class WifiKeysTests: XCTestCase {
    private var json: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "wifi-vectors", withExtension: "json", subdirectory: "Fixtures"))
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func obj(_ key: String, in dict: [String: Any]? = nil) throws -> [String: Any] { try XCTUnwrap((dict ?? json)[key] as? [String: Any]) }
    private func hex(_ key: String, in dict: [String: Any]? = nil) throws -> Data { try XCTUnwrap(Data(hex: try XCTUnwrap((dict ?? json)[key] as? String))) }
    private func k(_ key: String) throws -> Data { try hex(key, in: try obj("keys")) }
    private func b(_ key: String) throws -> Data { try hex(key, in: try obj("bind")) }
    private func s(_ key: String) throws -> String { try XCTUnwrap(try obj("keys")[key] as? String) }

    private func vectorGuest() throws -> Bwu1Guest {
        Bwu1Guest(uw: try k("uwCall"), ticket: try k("ticket"),
                  entropy: VectorEntropy(scalar: try b("guestScalar"), nonceValue: try b("guestNonce")))
    }

    func testCallKeyMatchesAndroid() throws {
        XCTAssertEqual(try WifiKeys.uwCall(exporter: try k("exporter")), try k("uwCall"))
    }

    func testDirectNamesMatchAndroid() throws {
        let uw = try k("uwCall")
        XCTAssertEqual(try WifiKeys.directSsid(uw: uw, ticket: try k("ticket")), try s("ssid"))
        XCTAssertEqual(try WifiKeys.directPsk(uw: uw, ticket: try k("ticket")), try s("psk"))
        XCTAssertEqual(try WifiKeys.directSsid(uw: uw, ticket: try k("ticket2")), try s("ssidTicket2"))
        XCTAssertEqual(try WifiKeys.directPsk(uw: uw, ticket: try k("ticket2")), try s("pskTicket2"))
    }

    func testDirectNamesAlwaysFollowTheNetworkNameAndPasswordRules() throws {
        let uw = try k("uwCall")
        let name = try NSRegularExpression(pattern: "^DIRECT-[abcdefghjkmnpqrstuvwxyz23456789]{2}-[abcdefghjkmnpqrstuvwxyz23456789]{6}$")
        let password = try NSRegularExpression(pattern: "^[A-Za-z0-9_-]{43}$")
        for i in 0..<20 {
            let ticket = Data((0..<8).map { UInt8(truncatingIfNeeded: $0 * 17 + i * 5) })
            let ssid = try WifiKeys.directSsid(uw: uw, ticket: ticket), psk = try WifiKeys.directPsk(uw: uw, ticket: ticket)
            XCTAssertEqual(name.numberOfMatches(in: ssid, range: NSRange(ssid.startIndex..., in: ssid)), 1, ssid)
            XCTAssertEqual(password.numberOfMatches(in: psk, range: NSRange(psk.startIndex..., in: psk)), 1, psk)
        }
    }

    func testWrongSizesAreRefused() throws {
        let uw = try k("uwCall"), ticket = try k("ticket")
        XCTAssertThrowsError(try WifiKeys.uwCall(exporter: Data(count: 31)))
        XCTAssertThrowsError(try WifiKeys.directSsid(uw: Data(count: 31), ticket: ticket))
        XCTAssertThrowsError(try WifiKeys.directPsk(uw: uw, ticket: Data(count: 7)))
        XCTAssertThrowsError(try Bwu1Guest(uw: uw, ticket: Data(count: 9)).respond(toFrame1: try b("frame1")))
    }

    func testThePreProofIsBoundToTheHostsChallenge() throws {
        let uw = try k("uwCall"), ticket = try k("ticket"), point = try b("guestPoint"), nonce = try b("guestNonce")
        XCTAssertEqual(try WifiKeys.pre(uw: uw, ticket: ticket, challenge: try b("challenge"), guestPoint: point, guestNonce: nonce), try b("pre"))
        XCTAssertEqual(try WifiKeys.pre(uw: uw, ticket: ticket, challenge: try b("challenge2"), guestPoint: point, guestNonce: nonce),
                       try b("preWithSecondChallenge"))
        XCTAssertNotEqual(try WifiKeys.pre(uw: try k("uwHop"), ticket: ticket, challenge: try b("challenge"), guestPoint: point, guestNonce: nonce),
                          try b("pre"))
    }

    func testGuestFramesAndKeysMatchAndroid() throws {
        let guest = try vectorGuest()
        XCTAssertEqual(try guest.respond(toFrame1: try b("frame1")), try b("frame2"))
        XCTAssertEqual(try guest.finish(frame3: try b("frame3")), WifiCarrierKeys(send: try b("kG2H"), receive: try b("kH2G")))
    }

    func testTheHostsViewOfTheSameTranscriptGivesTheMirroredKeys() throws {
        let th = WifiKeys.transcriptHash(frame1: try b("frame1"), frame2: try b("frame2"), frame3: try b("frame3"))
        XCTAssertEqual(th, try b("th"))
        let host = try P256.KeyAgreement.PrivateKey(rawRepresentation: try b("hostScalar"))
        XCTAssertEqual(host.publicKey.x963Representation, try b("hostPoint"))
        let dh = try Bmh3Crypto.agree(host, try b("guestPoint"))
        XCTAssertEqual(dh, try b("dh"))
        let secret = try WifiKeys.bindSecret(uw: try k("uwCall"), ticket: try k("ticket"), th: th, dh: dh)
        XCTAssertEqual(secret, try b("K"))
        XCTAssertEqual(WifiKeys.carrierKeys(secret: secret, isGuest: false), WifiCarrierKeys(send: try b("kH2G"), receive: try b("kG2H")))
        // Another ticket gives other carrier keys.
        let other = try WifiKeys.bindSecret(uw: try k("uwCall"), ticket: try k("ticket2"), th: th, dh: dh)
        XCTAssertNotEqual(WifiKeys.carrierKeys(secret: other, isGuest: true).send, try b("kG2H"))
    }

    func testGuestRefusesAHostPointOffTheCurve() throws {
        let guest = try vectorGuest()
        _ = try guest.respond(toFrame1: try b("frame1"))
        var frame3 = try b("frame3")
        frame3.replaceSubrange(5..<70, with: try b("offCurveGuestPoint"))
        XCTAssertThrowsError(try guest.finish(frame3: frame3)) { error in
            XCTAssertEqual(error as? WifiKeyError, .badPoint)
        }
    }

    func testAGuestIsSingleUseAndRefusesBadFrames() throws {
        let bad = try vectorGuest()
        var frame1 = try b("frame1"); frame1[0] = 0
        XCTAssertThrowsError(try bad.respond(toFrame1: frame1)) { XCTAssertEqual($0 as? WifiKeyError, .badFrame) }
        XCTAssertThrowsError(try bad.respond(toFrame1: try b("frame1")))

        let guest = try vectorGuest()
        XCTAssertThrowsError(try guest.finish(frame3: try b("frame3")))
        _ = try guest.respond(toFrame1: try b("frame1"))
        XCTAssertThrowsError(try guest.respond(toFrame1: try b("frame1")))
        XCTAssertNoThrow(try guest.finish(frame3: try b("frame3")))
        XCTAssertThrowsError(try guest.finish(frame3: try b("frame3")))
    }

    // MARK: The agent with the real keys against a host that follows the vectors

    private func ip(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> UInt32 { UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d) }

    private func joinedAgent() throws -> (WifiCallAgent, () -> [WifiCallAgent.Request]) {
        var requests: [WifiCallAgent.Request] = []
        let ticket = try k("ticket")
        let agent = WifiCallAgent(linkInitiator: false, uw: try WifiKeys.uwCall(exporter: try k("exporter")), peerSentMarker: true,
                                  config: .init(directClient: true))
        let entropy = VectorEntropy(scalar: try b("guestScalar"), nonceValue: try b("guestNonce"))
        agent.makeGuest = { uw, ticket in Bwu1Guest(uw: uw, ticket: ticket, entropy: entropy) }
        agent.onRequest = { requests.append($0) }
        agent.tick(now: 0, ready: true, heartbeat: Data())
        _ = agent.takeBluetoothRecords()
        agent.receivedOnBluetooth(Bwf1.caps(bearers: 12, freeHost: 0, freeGuest: 0).encoded(), now: 1)
        agent.receivedOnBluetooth(Bwf1.host(status: 1, bearer: 2, ticket: ticket, validMs: 20000, freqMhz: 5745).encoded(), now: 2)
        agent.receivedOnBluetooth(Bwf1.creds(ticket: ticket, port: 40000, ipv4: ip(192, 168, 49, 1)).encoded(), now: 3)
        let en0 = IPv4Interface(name: "en0", address: ip(192, 168, 49, 2), prefixLength: 24)
        agent.joined(ticket: ticket, local: en0, all: [en0], band: .ghz5, now: 4)
        agent.connected(ticket: ticket, now: 5)
        XCTAssertEqual(agent.receivedOnSocket(try b("frame1"), ticket: ticket, now: 5), [])
        XCTAssertEqual(agent.takeSocketBytes(), try b("frame2"))
        _ = agent.receivedOnSocket(try b("frame3"), ticket: ticket, now: 5)
        return (agent, { requests })
    }

    func testTheAgentJoinsWithAndroidsNamesAndBindsWithAndroidsKeys() throws {
        let ticket = try k("ticket")
        let (agent, requests) = try joinedAgent()
        XCTAssertEqual(requests().first, .join(ssid: try s("ssid"), passphrase: try s("psk"), hostFreqMhz: 5745, ticket: ticket))
        let opener = SecureRecordOpener(key: SymmetricKey(data: try b("kG2H"))); opener.acceptWifi = true
        let bind = try opener.feed(try XCTUnwrap(agent.takeSocketBytes()))
        XCTAssertEqual(try bind.map { try Bwf1.decode($0.payload) }, [.bind(role: 1, ticket: ticket)])
        let host = SecureRecordSealer(key: SymmetricKey(data: try b("kH2G")))
        _ = agent.receivedOnSocket(try host.seal(.wifi, Bwf1.bind(role: 2, ticket: ticket).encoded()), ticket: ticket, now: 6)
        _ = agent.receivedOnSocket(try host.seal(.wifi, Bwf1.ready(recvCeilingKbps: 0xFFFF, familyCapKbps: 0, transportBudgetKbps: 0xFFFF).encoded()),
                                   ticket: ticket, now: 6)
        XCTAssertTrue(agent.carrierUp)
    }

    func testAHostBindUnderAnotherKeyEndsTheAttemptAndTheCarrierNeverComesUp() throws {
        let ticket = try k("ticket")
        let (agent, requests) = try joinedAgent()
        _ = agent.takeSocketBytes()
        // A host that does not hold this call's UW (or saw another transcript) cannot produce a BIND the guest opens.
        let impostor = SecureRecordSealer(key: SymmetricKey(data: try b("kG2H")))
        _ = agent.receivedOnSocket(try impostor.seal(.wifi, Bwf1.bind(role: 2, ticket: ticket).encoded()), ticket: ticket, now: 6)
        XCTAssertFalse(agent.carrierUp)
        XCTAssertFalse(agent.binding)
        XCTAssertNil(agent.takeSocketBytes())
        XCTAssertTrue(requests().contains(.closeSocket(ticket: ticket)))
        XCTAssertTrue(requests().contains(.leave(ticket: ticket)))
        XCTAssertFalse(agent.wifiOver)
    }

    /// AW2: the UW of a stream or relay hop from its two directional BMS1 keys, as Android (either order; equal keys and
    /// wrong sizes refused; never the call key).
    func testHopKeyMatchesAndroid() throws {
        let a = try k("hopKeyA"), b = try k("hopKeyB")
        XCTAssertEqual(try WifiKeys.uwHop(keyA: a, keyB: b), try k("uwHop"))
        XCTAssertEqual(try WifiKeys.uwHop(keyA: b, keyB: a), try k("uwHop"))
        XCTAssertNotEqual(try WifiKeys.uwHop(keyA: a, keyB: b), try k("uwCall"))
        XCTAssertThrowsError(try WifiKeys.uwHop(keyA: a, keyB: a))
        XCTAssertThrowsError(try WifiKeys.uwHop(keyA: a.prefix(31), keyB: b))
    }
}
