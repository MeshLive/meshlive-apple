import XCTest
import CryptoKit
@testable import NearbyCore

private let wifiUw = Data(repeating: 1, count: 32)
private let wifiTicket = Data(repeating: 9, count: 8)
private let guestSendKey = Data(repeating: 0x11, count: 32)
private let guestReceiveKey = Data(repeating: 0x22, count: 32)

private final class FakeGuest: Bwu1GuestSession {
    func respond(toFrame1 frame1: Data) throws -> Data {
        XCTAssertEqual(frame1.count, 21)
        return Data(repeating: 2, count: 126)
    }
    func finish(frame3: Data) throws -> WifiCarrierKeys {
        XCTAssertEqual(frame3.count, 102)
        return WifiCarrierKeys(send: guestSendKey, receive: guestReceiveKey)
    }
}

private final class Requests {
    var items: [WifiCallAgent.Request] = []
}

final class WifiCallAgentTests: XCTestCase {
    private func ip(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> UInt32 {
        UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
    }
    private var en0: IPv4Interface { IPv4Interface(name: "en0", address: ip(192, 168, 49, 2), prefixLength: 24) }

    private func makeAgent(linkInitiator: Bool = false, uw: Data? = wifiUw, peerSentMarker: Bool = true,
                           directClient: Bool = true) -> (WifiCallAgent, Requests) {
        let requests = Requests()
        let agent = WifiCallAgent(linkInitiator: linkInitiator, uw: uw, peerSentMarker: peerSentMarker,
                                  config: .init(directClient: directClient))
        agent.directNames = { _, _ in ("DIRECT-ab-cdefgh", "pw") }
        agent.makeGuest = { _, _ in FakeGuest() }
        agent.onRequest = { requests.items.append($0) }
        return (agent, requests)
    }

    private func caps(_ bearers: UInt8 = 12, freeHost: UInt8 = 0, freeGuest: UInt8 = 0) -> Data {
        Bwf1.caps(bearers: bearers, freeHost: freeHost, freeGuest: freeGuest).encoded()
    }
    private func host(_ ticket: Data = wifiTicket, freqMhz: Int = 5745) -> Data {
        Bwf1.host(status: 1, bearer: 2, ticket: ticket, validMs: 20000, freqMhz: freqMhz).encoded()
    }
    private func creds(_ ticket: Data = wifiTicket, host: UInt32? = nil) -> Data {
        Bwf1.creds(ticket: ticket, port: 40000, ipv4: host ?? ip(192, 168, 49, 1)).encoded()
    }

    private func beginJoin(_ agent: WifiCallAgent, freqMhz: Int = 5745, hostAddress: UInt32? = nil) {
        agent.tick(now: 0, ready: true, heartbeat: Data())
        _ = agent.takeBluetoothRecords()
        agent.receivedOnBluetooth(caps(), now: 1)
        agent.receivedOnBluetooth(host(freqMhz: freqMhz), now: 2)
        agent.receivedOnBluetooth(creds(host: hostAddress), now: 3)
    }

    @discardableResult
    private func bringUp(_ agent: WifiCallAgent, now: TimeInterval = 100) throws -> (sealer: SecureRecordSealer, opener: SecureRecordOpener) {
        beginJoin(agent)
        agent.joined(ticket: wifiTicket, local: en0, all: [en0], band: .ghz5, now: 4)
        agent.connected(ticket: wifiTicket, now: now)
        _ = agent.receivedOnSocket(Data(count: 21), ticket: wifiTicket, now: now)
        XCTAssertEqual(agent.takeSocketBytes(), Data(repeating: 2, count: 126))
        _ = agent.receivedOnSocket(Data(count: 102), ticket: wifiTicket, now: now)
        let sealer = SecureRecordSealer(key: SymmetricKey(data: guestReceiveKey))
        let opener = SecureRecordOpener(key: SymmetricKey(data: guestSendKey))
        opener.acceptWifi = true
        XCTAssertEqual(try opener.feed(try XCTUnwrap(agent.takeSocketBytes())).map(\.type), [.wifi])
        _ = agent.receivedOnSocket(try sealer.seal(.wifi, Bwf1.bind(role: 2, ticket: wifiTicket).encoded()), ticket: wifiTicket, now: now)
        XCTAssertEqual(try opener.feed(try XCTUnwrap(agent.takeSocketBytes())).map(\.type), [.wifi])
        let ready = Bwf1.ready(recvCeilingKbps: 0xFFFF, familyCapKbps: 0, transportBudgetKbps: 0xFFFF)
        _ = agent.receivedOnSocket(try sealer.seal(.wifi, ready.encoded()), ticket: wifiTicket, now: now)
        XCTAssertTrue(agent.carrierUp)
        return (sealer, opener)
    }

    func testTheResponderSendsCapsFirstAndOnlyOnce() {
        let (agent, _) = makeAgent()
        agent.tick(now: 0, ready: false, heartbeat: Data())
        XCTAssertTrue(agent.takeBluetoothRecords().isEmpty)
        agent.tick(now: 1, ready: true, heartbeat: Data())
        XCTAssertEqual(agent.takeBluetoothRecords(), [.caps(bearers: 8, freeHost: 0, freeGuest: 0)])
        agent.tick(now: 2, ready: true, heartbeat: Data())
        XCTAssertTrue(agent.takeBluetoothRecords().isEmpty)
    }

    func testTheInitiatorAnswersTheResponder() {
        let (agent, _) = makeAgent(linkInitiator: true, peerSentMarker: false)
        agent.tick(now: 0, ready: true, heartbeat: Data())
        XCTAssertTrue(agent.takeBluetoothRecords().isEmpty)
        agent.receivedOnBluetooth(caps(), now: 1)
        agent.tick(now: 2, ready: true, heartbeat: Data())
        XCTAssertEqual(agent.takeBluetoothRecords(), [.caps(bearers: 8, freeHost: 0, freeGuest: 0)])
    }

    func testWithoutACallKeyCapsIsClearAndEveryHostIsDeclined() {
        let (agent, _) = makeAgent(uw: nil)
        agent.tick(now: 0, ready: true, heartbeat: Data())
        XCTAssertEqual(agent.takeBluetoothRecords(), [.caps(bearers: 0, freeHost: 0, freeGuest: 0)])
        agent.receivedOnBluetooth(caps(), now: 1)
        agent.receivedOnBluetooth(host(), now: 2)
        XCTAssertEqual(agent.takeBluetoothRecords(), [.decline(ticket: wifiTicket, reason: 1)])
    }

    func testRecordsBeforeCapsOrARepeatedCapsEndWifiForTheCall() {
        let (before, _) = makeAgent()
        before.receivedOnBluetooth(host(), now: 0)
        XCTAssertTrue(before.wifiOver)
        XCTAssertTrue(before.takeBluetoothRecords().isEmpty)
        before.receivedOnBluetooth(host(Data(repeating: 5, count: 8)), now: 1)
        XCTAssertTrue(before.takeBluetoothRecords().isEmpty)

        let (repeated, _) = makeAgent()
        repeated.tick(now: 0, ready: true, heartbeat: Data())
        _ = repeated.takeBluetoothRecords()
        repeated.receivedOnBluetooth(caps(), now: 1)
        repeated.receivedOnBluetooth(caps(), now: 2)
        XCTAssertTrue(repeated.wifiOver)
        repeated.receivedOnBluetooth(host(Data(repeating: 6, count: 8)), now: 3)
        XCTAssertTrue(repeated.takeBluetoothRecords().isEmpty)
    }

    func testAnUnknownKindIsIgnored() {
        let (agent, _) = makeAgent()
        agent.tick(now: 0, ready: true, heartbeat: Data())
        _ = agent.takeBluetoothRecords()
        agent.receivedOnBluetooth(Data(hex: "425746310c")!, now: 1)
        XCTAssertFalse(agent.wifiOver)
    }

    func testAHostAndCredsJoinTheGroup() {
        let (agent, requests) = makeAgent()
        beginJoin(agent)
        XCTAssertEqual(requests.items, [.join(ssid: "DIRECT-ab-cdefgh", passphrase: "pw", hostFreqMhz: 5745, ticket: wifiTicket)])
    }

    func testA24GhzReadingDeclinesSeven() {
        let (agent, requests) = makeAgent()
        beginJoin(agent)
        agent.joined(ticket: wifiTicket, local: en0, all: [en0], band: .ghz2_4, now: 4)
        XCTAssertEqual(agent.takeBluetoothRecords(), [.decline(ticket: wifiTicket, reason: 7)])
        XCTAssertTrue(requests.items.contains(.leave(ticket: wifiTicket)))

        let (iphone, iphoneRequests) = makeAgent()
        beginJoin(iphone, freqMhz: 0)
        iphone.joined(ticket: wifiTicket, local: en0, all: [en0], band: .unknown, now: 4)
        XCTAssertEqual(iphone.takeBluetoothRecords(), [.decline(ticket: wifiTicket, reason: 7)])
        XCTAssertTrue(iphoneRequests.items.contains(.leave(ticket: wifiTicket)))
    }

    func testCredsOffTheJoinedLinkDeclinesSix() {
        let (agent, requests) = makeAgent()
        beginJoin(agent, hostAddress: ip(10, 0, 0, 1))
        agent.joined(ticket: wifiTicket, local: en0, all: [en0], band: .ghz5, now: 4)
        XCTAssertEqual(agent.takeBluetoothRecords(), [.decline(ticket: wifiTicket, reason: 6)])
        XCTAssertTrue(requests.items.contains(.leave(ticket: wifiTicket)))
    }

    func testTheGuestBindsAndTheCarrierComesUp() throws {
        let (agent, _) = makeAgent()
        beginJoin(agent)
        agent.joined(ticket: wifiTicket, local: en0, all: [en0], band: .ghz5, now: 4)
        XCTAssertTrue(agent.binding)
        agent.connected(ticket: wifiTicket, now: 5)
        _ = agent.receivedOnSocket(Data(count: 21), ticket: wifiTicket, now: 5)
        XCTAssertEqual(agent.takeSocketBytes(), Data(repeating: 2, count: 126))
        _ = agent.receivedOnSocket(Data(count: 102), ticket: wifiTicket, now: 5)
        let opener = SecureRecordOpener(key: SymmetricKey(data: guestSendKey))
        opener.acceptWifi = true
        let bind = try opener.feed(try XCTUnwrap(agent.takeSocketBytes()))
        XCTAssertEqual(bind.count, 1)
        XCTAssertEqual(bind.first?.type, .wifi)
        XCTAssertEqual(try Bwf1.decode(try XCTUnwrap(bind.first?.payload)), .bind(role: 1, ticket: wifiTicket))

        let sealer = SecureRecordSealer(key: SymmetricKey(data: guestReceiveKey))
        _ = agent.receivedOnSocket(try sealer.seal(.wifi, Bwf1.bind(role: 2, ticket: wifiTicket).encoded()), ticket: wifiTicket, now: 5)
        let ready = try opener.feed(try XCTUnwrap(agent.takeSocketBytes()))
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(try Bwf1.decode(try XCTUnwrap(ready.first?.payload)),
                       .ready(recvCeilingKbps: 0xFFFF, familyCapKbps: 0, transportBudgetKbps: 0xFFFF))
        XCTAssertFalse(agent.carrierUp)

        let hostReady = Bwf1.ready(recvCeilingKbps: 0xFFFF, familyCapKbps: 0, transportBudgetKbps: 0xFFFF)
        _ = agent.receivedOnSocket(try sealer.seal(.wifi, hostReady.encoded()), ticket: wifiTicket, now: 5)
        XCTAssertTrue(agent.carrierUp)
    }

    func testAWrongHostBindFailsTheAttemptWithSix() throws {
        let (agent, requests) = makeAgent()
        beginJoin(agent)
        agent.joined(ticket: wifiTicket, local: en0, all: [en0], band: .ghz5, now: 4)
        agent.connected(ticket: wifiTicket, now: 5)
        _ = agent.receivedOnSocket(Data(count: 21), ticket: wifiTicket, now: 5)
        _ = agent.takeSocketBytes()
        _ = agent.receivedOnSocket(Data(count: 102), ticket: wifiTicket, now: 5)
        _ = agent.takeSocketBytes()
        let sealer = SecureRecordSealer(key: SymmetricKey(data: guestReceiveKey))
        let wrong = Data(repeating: 4, count: 8)
        _ = agent.receivedOnSocket(try sealer.seal(.wifi, Bwf1.bind(role: 2, ticket: wrong).encoded()), ticket: wifiTicket, now: 6)
        XCTAssertFalse(agent.carrierUp)
        XCTAssertEqual(agent.takeBluetoothRecords(), [.decline(ticket: wifiTicket, reason: 6)])
        XCTAssertTrue(requests.items.contains(.closeSocket(ticket: wifiTicket)))
        XCTAssertTrue(requests.items.contains(.leave(ticket: wifiTicket)))
    }

    func testTheCarrierHeartbeatsAndFallsBackAfterSilence() throws {
        let (agent, requests) = makeAgent()
        _ = try bringUp(agent, now: 100)
        agent.tick(now: 100.6, ready: true, heartbeat: Data())
        XCTAssertNotNil(agent.takeSocketBytes())
        agent.tick(now: 102.7, ready: true, heartbeat: Data())
        XCTAssertFalse(agent.carrierUp)
        XCTAssertTrue(requests.items.contains(.closeSocket(ticket: wifiTicket)))
        XCTAssertTrue(requests.items.contains(.leave(ticket: wifiTicket)))
        XCTAssertTrue(requests.items.contains(.keyFrame))
        guard case .resume(_, let ticket, let next, let mesh)? = agent.takeMarker(nextSequence: 5) else {
            return XCTFail("no resume")
        }
        XCTAssertEqual(ticket, wifiTicket)
        XCTAssertEqual(next, 5)
        XCTAssertEqual(mesh, 0)
    }

    func testHostDeclinesFollowTheSpacingRule() {
        let (agent, _) = makeAgent()
        agent.tick(now: 0, ready: true, heartbeat: Data())
        _ = agent.takeBluetoothRecords()
        agent.receivedOnBluetooth(caps(), now: 1)
        let first = Data(repeating: 3, count: 8)
        agent.receivedOnBluetooth(host(first), now: 10)
        agent.receivedOnBluetooth(creds(first), now: 10)
        XCTAssertTrue(agent.takeBluetoothRecords().isEmpty)
        agent.joinFailed(ticket: first, reason: .setupFailed, detail: "x", now: 10)
        XCTAssertEqual(agent.takeBluetoothRecords(), [.decline(ticket: first, reason: 6)])
        let second = Data(repeating: 4, count: 8)
        agent.receivedOnBluetooth(host(second), now: 20)
        XCTAssertEqual(agent.takeBluetoothRecords(), [.decline(ticket: second, reason: 4)])
        let third = Data(repeating: 5, count: 8)
        agent.receivedOnBluetooth(host(third), now: 40)
        XCTAssertTrue(agent.takeBluetoothRecords().isEmpty)
    }

    func testCallEndedClosesAndSendsNothing() throws {
        let (agent, requests) = makeAgent()
        _ = try bringUp(agent, now: 100)
        requests.items.removeAll()
        agent.callEnded(now: 110)
        XCTAssertFalse(agent.carrierUp)
        XCTAssertEqual(requests.items, [.closeSocket(ticket: wifiTicket), .leave(ticket: wifiTicket)])
        XCTAssertTrue(agent.takeBluetoothRecords().isEmpty)
        agent.receivedOnBluetooth(host(Data(repeating: 6, count: 8)), now: 200)
        XCTAssertTrue(agent.takeBluetoothRecords().isEmpty)
    }

    func testAViolationWhileSendingOnWifiStillResumesOnBluetooth() throws {
        let (agent, _) = makeAgent()
        try bringUp(agent, now: 100)
        agent.requestSwitch(now: 104, activeSince: 100, oldestQueuedAge: 0)
        guard case .switchTo = try XCTUnwrap(agent.takeMarker(nextSequence: 7)) else { return XCTFail("no SWITCH") }
        XCTAssertTrue(agent.sendingOnWifi)
        agent.receivedOnBluetooth(Data([0, 1, 2, 3, 4]), now: 105)
        XCTAssertTrue(agent.wifiOver)
        XCTAssertFalse(agent.sendingOnWifi)
        // Without the RESUME the peer would drop this side's Bluetooth content after the SWITCH for the rest of the call.
        guard case .resume(_, _, let next, _) = try XCTUnwrap(agent.takeMarker(nextSequence: 9)) else { return XCTFail("no RESUME") }
        XCTAssertEqual(next, 9)
        XCTAssertNil(agent.takeMarker(nextSequence: 10))
    }

    func testADeclineForTheLiveCarrierIsStaleAndChangesNothing() throws {
        let (agent, requests) = makeAgent()
        try bringUp(agent, now: 100)
        agent.receivedOnBluetooth(Bwf1.switchTo(gen: 1, ticket: wifiTicket, e2eBoundary: 3, meshBoundary: 0).encoded(), now: 101)
        agent.requestSwitch(now: 104, activeSince: 100, oldestQueuedAge: 0)
        guard case .switchTo = try XCTUnwrap(agent.takeMarker(nextSequence: 7)) else { return XCTFail("no SWITCH") }
        requests.items.removeAll()
        agent.receivedOnBluetooth(Bwf1.decline(ticket: wifiTicket, reason: 6).encoded(), now: 105)
        // Both directions stay on Wi-Fi: the peer's Bluetooth content from its boundary is still fenced, ours still leaves on Wi-Fi.
        XCTAssertTrue(agent.carrierUp)
        XCTAssertTrue(agent.sendingOnWifi)
        XCTAssertEqual(agent.bluetoothVerdict(sequence: 3), .drop)
        XCTAssertTrue(requests.items.isEmpty)
        XCTAssertNil(agent.takeMarker(nextSequence: 8))
    }

    func testAStalledWriteFallsBackWhileThePeerKeepsSending() throws {
        let (agent, requests) = makeAgent()
        let (sealer, _) = try bringUp(agent, now: 100)
        agent.requestSwitch(now: 104, activeSince: 100, oldestQueuedAge: 0)
        guard case .switchTo = try XCTUnwrap(agent.takeMarker(nextSequence: 7)) else { return XCTFail("no SWITCH") }
        agent.socketSendState(oldestPendingSince: 104, ticket: wifiTicket)
        for now in [105.0, 106.0, 106.4] {
            _ = agent.receivedOnSocket(try sealer.seal(.linkHeartbeat, Data()), ticket: wifiTicket, now: now)
            agent.tick(now: now, ready: true, heartbeat: Data())
        }
        XCTAssertTrue(agent.carrierUp)
        // The peer's heartbeats keep arriving, but our oldest write has waited more than 2.5 s.
        _ = agent.receivedOnSocket(try sealer.seal(.linkHeartbeat, Data()), ticket: wifiTicket, now: 106.6)
        agent.tick(now: 106.6, ready: true, heartbeat: Data())
        XCTAssertFalse(agent.carrierUp)
        XCTAssertTrue(requests.items.contains(.closeSocket(ticket: wifiTicket)))
        guard case .resume? = agent.takeMarker(nextSequence: 9) else { return XCTFail("no RESUME") }
    }

    func testWritesThatCompleteKeepTheCarrier() throws {
        let (agent, _) = makeAgent()
        let (sealer, _) = try bringUp(agent, now: 100)
        agent.socketSendState(oldestPendingSince: 100, ticket: wifiTicket)
        agent.socketSendState(oldestPendingSince: nil, ticket: wifiTicket)
        _ = agent.receivedOnSocket(try sealer.seal(.linkHeartbeat, Data()), ticket: wifiTicket, now: 102)
        agent.tick(now: 102, ready: true, heartbeat: Data())
        XCTAssertTrue(agent.carrierUp)
        agent.socketSendState(oldestPendingSince: 101, ticket: Data(repeating: 1, count: 8))
        _ = agent.receivedOnSocket(try sealer.seal(.linkHeartbeat, Data()), ticket: wifiTicket, now: 104)
        agent.tick(now: 104, ready: true, heartbeat: Data())
        XCTAssertTrue(agent.carrierUp, "another attempt's socket state changes nothing")
    }

    func testAJoinThatCompletesAfterLeaveOrAfterANewerJoinUndoesItself() {
        var gate = WifiJoinGate()
        let first = gate.begin(ssid: "DIRECT-ab-cdefgh")
        XCTAssertEqual(gate.completed(token: first, ssid: "DIRECT-ab-cdefgh"), .proceed)
        gate.end()
        XCTAssertEqual(gate.completed(token: first, ssid: "DIRECT-ab-cdefgh"), .undo(ssid: "DIRECT-ab-cdefgh"))
        let second = gate.begin(ssid: "DIRECT-xy-zzzzzz")
        XCTAssertEqual(gate.completed(token: first, ssid: "DIRECT-ab-cdefgh"), .undo(ssid: "DIRECT-ab-cdefgh"))
        XCTAssertEqual(gate.completed(token: second, ssid: "DIRECT-xy-zzzzzz"), .proceed)
    }

    func testAWifiRecordHeaderOutsideItsSizeIsRefusedBeforeItsBody() throws {
        func header(_ size: Int) -> Data {
            var w = BinaryWriter()
            w.bytes(SecureRecordProtocol.magic); w.byte(SecureRecordType.wifi.rawValue); w.u64(0); w.u32(UInt32(size))
            return w.data
        }
        for size in [20, 113, 100_000] {
            let opener = SecureRecordOpener(key: SymmetricKey(size: .bits256)); opener.acceptWifi = true
            XCTAssertThrowsError(try opener.feed(header(size)), "ciphertext \(size)")
        }
        for size in [21, 112] {
            let opener = SecureRecordOpener(key: SymmetricKey(size: .bits256)); opener.acceptWifi = true
            XCTAssertEqual(try opener.feed(header(size)).count, 0, "ciphertext \(size) waits for its body")
        }
    }

    // MARK: AW2 stream child (agent)

    private func makeStreamChild(gate: Bool = true) -> (WifiCallAgent, Requests) {
        let requests = Requests()
        let agent = WifiCallAgent(linkInitiator: false, uw: wifiUw, peerSentMarker: gate, config: .init(directClient: true), streamChild: true)
        agent.directNames = { _, _ in ("DIRECT-ab-cdefgh", "pw") }
        agent.makeGuest = { _, _ in FakeGuest() }
        agent.onRequest = { requests.items.append($0) }
        return (agent, requests)
    }

    /// Android HopCapsPlan STREAM_CHILD: the child sends CAPS first, once, after its first stream header; it does not wait
    /// for the parent, which only answers.
    func testAStreamChildSendsCapsFirstOnceItsHeaderArrived() {
        let (agent, _) = makeStreamChild()
        agent.tick(now: 0, ready: false, heartbeat: Data())
        XCTAssertTrue(agent.takeBluetoothRecords().isEmpty)
        agent.tick(now: 1, ready: true, heartbeat: Data())
        XCTAssertEqual(agent.takeBluetoothRecords(), [.caps(bearers: 8, freeHost: 0, freeGuest: 0)])
        XCTAssertEqual(agent.sentBearers, 8)
        agent.tick(now: 2, ready: true, heartbeat: Data())
        XCTAssertTrue(agent.takeBluetoothRecords().isEmpty)
    }

    /// Without both build tags the parent is not proven to read BWF1: the child never writes one.
    func testAStreamChildWithoutTheBuildTagGateNeverSendsCaps() {
        let (agent, _) = makeStreamChild(gate: false)
        agent.tick(now: 1, ready: true, heartbeat: Data())
        XCTAssertTrue(agent.takeBluetoothRecords().isEmpty)
        XCTAssertFalse(agent.capsSent)
    }

    /// The child is the link initiator of the role choice: toward a parent that can own a group (bits 2 and 3) it is the
    /// guest and joins; toward a parent that can only join (bit 3) no tuple exists and a HOST is declined with 2.
    func testAStreamChildIsTheGuestOfAParentThatOwnsTheGroup() {
        let (agent, requests) = makeStreamChild()
        agent.tick(now: 0, ready: true, heartbeat: Data())
        _ = agent.takeBluetoothRecords()
        agent.receivedOnBluetooth(caps(12), now: 1)
        agent.receivedOnBluetooth(host(), now: 2)
        agent.receivedOnBluetooth(creds(), now: 3)
        XCTAssertEqual(requests.items, [.join(ssid: "DIRECT-ab-cdefgh", passphrase: "pw", hostFreqMhz: 5745, ticket: wifiTicket)])

        let (joinOnly, joinRequests) = makeStreamChild()
        joinOnly.tick(now: 0, ready: true, heartbeat: Data())
        _ = joinOnly.takeBluetoothRecords()
        joinOnly.receivedOnBluetooth(caps(8), now: 1)
        joinOnly.receivedOnBluetooth(host(), now: 2)
        XCTAssertEqual(joinOnly.takeBluetoothRecords(), [.decline(ticket: wifiTicket, reason: 2)])
        XCTAssertTrue(joinRequests.items.isEmpty)
    }

    /// A hop that is not eligible when CAPS leaves (mesh envelopes, audio only) offers nothing, and the bits it sent stay
    /// its offer: a later change cannot turn the parent's HOST into a join.
    func testAnIneligibleStreamHopSendsClearCapsAndKeepsThem() {
        let (agent, requests) = makeStreamChild()
        agent.hopEligible = false
        agent.tick(now: 0, ready: true, heartbeat: Data())
        XCTAssertEqual(agent.takeBluetoothRecords(), [.caps(bearers: 0, freeHost: 0, freeGuest: 0)])
        agent.hopEligible = true
        agent.receivedOnBluetooth(caps(12), now: 1)
        agent.receivedOnBluetooth(host(), now: 2)
        XCTAssertEqual(agent.takeBluetoothRecords(), [.decline(ticket: wifiTicket, reason: 2)])
        XCTAssertTrue(requests.items.isEmpty)
    }

    /// Security: the stream child's carrier comes up only when the host's BIND opens under this hop's binding keys; an
    /// impostor's BIND fails the attempt with DECLINE 6, leaves the group, and Wi-Fi stays possible for the hop.
    func testAStreamChildCarrierComesUpOnlyWithTheParentsBind() throws {
        let (agent, requests) = makeStreamChild()
        agent.tick(now: 0, ready: true, heartbeat: Data())
        _ = agent.takeBluetoothRecords()
        agent.receivedOnBluetooth(caps(12), now: 1)
        agent.receivedOnBluetooth(host(), now: 2)
        agent.receivedOnBluetooth(creds(), now: 3)
        agent.joined(ticket: wifiTicket, local: en0, all: [en0], band: .ghz5, now: 4)
        agent.connected(ticket: wifiTicket, now: 5)
        _ = agent.receivedOnSocket(Data(count: 21), ticket: wifiTicket, now: 5)
        _ = agent.takeSocketBytes()
        _ = agent.receivedOnSocket(Data(count: 102), ticket: wifiTicket, now: 5)
        _ = agent.takeSocketBytes()
        let impostor = SecureRecordSealer(key: SymmetricKey(data: Data(repeating: 0x33, count: 32)))
        _ = agent.receivedOnSocket(try impostor.seal(.wifi, Bwf1.bind(role: 2, ticket: wifiTicket).encoded()), ticket: wifiTicket, now: 5)
        XCTAssertFalse(agent.carrierUp)
        XCTAssertEqual(agent.takeBluetoothRecords(), [.decline(ticket: wifiTicket, reason: 6)])
        XCTAssertTrue(requests.items.contains(.leave(ticket: wifiTicket)))
        XCTAssertFalse(agent.wifiOver)
    }

    // MARK: AW2 stream hop (engine level)

    /// An Apple source stands in for the Android parent on Bluetooth; the test plays the parent's BWF1 records by sealing
    /// them on the source's link, and never delivers the viewer's own records back (the Apple source has no Wi-Fi).
    private final class StreamHop {
        let source: StreamSourceEngine
        let viewer: StreamViewerEngine
        var requests: [WifiCallAgent.Request] = []
        var now: TimeInterval = 0

        init(parentTag: Bool, wifi: WifiCallAgent.Config?, relayingViewer: Bool = false) {
            let sourceId = SoftwareSigningIdentity(), viewerId = SoftwareSigningIdentity()
            let header = StreamHeader(width: 640, height: 360, fps: 15, codecId: StreamProtocol.codecVP9, includeAudio: true)
            source = StreamSourceEngine(transport: .l2cap, identity: sourceId, header: header, expectedViewerPrefix: viewerId.nodeId.prefix)
            if parentTag { source.link.ownBuildTag = BuildTag(releaseKey: false, release: WifiWire.firstRelease) }
            viewer = StreamViewerEngine(transport: .l2cap, identity: viewerId, decodeMask: NodeCapabilities.codecVP9,
                                        expectedAdjacentPrefix: sourceId.nodeId.prefix, maxChildren: relayingViewer ? 1 : 0, wifi: wifi)
            viewer.onWifiRequest = { [unowned self] in self.requests.append($0) }
        }

        /// Starts both and moves bytes both ways until quiet.
        func open() throws {
            try source.start(now: now); try viewer.start(now: now)
            for _ in 0..<50 {
                var moved = false
                while let bytes = source.nextOutgoing(now: now) { viewer.receive(bytes, now: now); moved = true }
                while let bytes = viewer.nextOutgoing(now: now) { source.receive(bytes, now: now); moved = true }
                if !moved { return }
            }
        }

        /// Parent to viewer only.
        func parentToViewer() { while let bytes = source.nextOutgoing(now: now) { viewer.receive(bytes, now: now) } }

        /// One record from the parent on Bluetooth (carrier 0).
        func fromParent(_ type: SecureRecordType, _ payload: Data) throws { viewer.receive(try source.link.seal(type, payload), now: now) }
    }

    /// The viewer's Wi-Fi carrier up with its parent's group; the parent's side is played with FakeGuest's keys.
    private func streamCarrierUp(_ hop: StreamHop) throws -> (sealer: SecureRecordSealer, agent: WifiCallAgent) {
        try hop.open()
        XCTAssertNotNil(hop.viewer.header)
        let agent = try XCTUnwrap(hop.viewer.wifi)
        agent.directNames = { _, _ in ("DIRECT-ab-cdefgh", "pw") }
        agent.makeGuest = { _, _ in FakeGuest() }
        hop.now = 1
        hop.viewer.tick(now: 1)
        XCTAssertTrue(agent.capsSent)
        XCTAssertEqual(agent.sentBearers, WifiWire.bitDirectClient)
        try hop.fromParent(.wifi, caps(12))
        try hop.fromParent(.wifi, host())
        try hop.fromParent(.wifi, creds())
        XCTAssertEqual(hop.requests, [.join(ssid: "DIRECT-ab-cdefgh", passphrase: "pw", hostFreqMhz: 5745, ticket: wifiTicket)])
        hop.viewer.wifiJoined(ticket: wifiTicket, local: en0, all: [en0], band: .ghz5, now: 2)
        hop.viewer.wifiConnected(ticket: wifiTicket, now: 2)
        hop.viewer.wifiReceive(Data(count: 21), ticket: wifiTicket, now: 2)
        XCTAssertEqual(hop.viewer.nextWifiOutgoing(now: 2), Data(repeating: 2, count: 126))
        hop.viewer.wifiReceive(Data(count: 102), ticket: wifiTicket, now: 2)
        let sealer = SecureRecordSealer(key: SymmetricKey(data: guestReceiveKey))
        let opener = SecureRecordOpener(key: SymmetricKey(data: guestSendKey))
        opener.acceptWifi = true
        XCTAssertEqual(try opener.feed(try XCTUnwrap(hop.viewer.nextWifiOutgoing(now: 2))).map(\.type), [.wifi])
        hop.viewer.wifiReceive(try sealer.seal(.wifi, Bwf1.bind(role: 2, ticket: wifiTicket).encoded()), ticket: wifiTicket, now: 2)
        XCTAssertEqual(try opener.feed(try XCTUnwrap(hop.viewer.nextWifiOutgoing(now: 2))).map(\.type), [.wifi])
        let ready = Bwf1.ready(recvCeilingKbps: 0xFFFF, familyCapKbps: 0, transportBudgetKbps: 0xFFFF)
        hop.viewer.wifiReceive(try sealer.seal(.wifi, ready.encoded()), ticket: wifiTicket, now: 2)
        XCTAssertTrue(agent.carrierUp)
        return (sealer, agent)
    }

    /// AW2: a viewer whose parent signed the Wi-Fi build tag joins the parent's group as guest after its first header,
    /// reads the parent's media from Wi-Fi from the SWITCH boundary on, drops the parent's carrier-0 heartbeats, and
    /// falls back to Bluetooth with a RESUME when the carrier dies; the stream never ends.
    func testAStreamViewerReadsItsParentsMediaFromWifiAndFallsBackToBluetooth() throws {
        let hop = StreamHop(parentTag: true, wifi: .init(directClient: true))
        let (sealer, agent) = try streamCarrierUp(hop)
        let endpoint = try XCTUnwrap(hop.source.endpoint)
        hop.now = 3
        try hop.fromParent(.wifi, Bwf1.switchTo(gen: 1, ticket: wifiTicket, e2eBoundary: endpoint.sealer.nextSequence, meshBoundary: 0).encoded())
        XCTAssertTrue(agent.cutover.acceptWifi)
        let before = hop.viewer.videoPackets
        let frame = MediaPacket(flags: StreamProtocol.flagKeyFrame, presentationTimeUs: 0, payload: Data(repeating: 7, count: 3000))
        hop.viewer.wifiReceive(try sealer.seal(.endToEndContent, try endpoint.sealer.seal(.mediaPacket, flags: frame.flags, frame.encoded)),
                               ticket: wifiTicket, now: 3)
        XCTAssertEqual(hop.viewer.videoPackets, before + 1)
        // Android's carrier set heartbeats carrier 0 once the hop machine runs; a stream child drops them.
        try hop.fromParent(.linkHeartbeat, LinkHeartbeat.version1)
        XCTAssertEqual(hop.viewer.phase, .open)
        // The group goes away: reading returns to Bluetooth, a RESUME is due, the guest leaves, and the next frame plays.
        hop.viewer.wifiSocketClosed(ticket: wifiTicket, detail: "eof", now: 4)
        XCTAssertFalse(agent.carrierUp)
        XCTAssertFalse(agent.cutover.acceptWifi)
        XCTAssertTrue(agent.cutover.hasMarker)
        XCTAssertTrue(hop.requests.contains(.leave(ticket: wifiTicket)))
        hop.now = 4
        hop.source.sendVideo(flags: 0, presentationTimeUs: 66_000, payload: Data(repeating: 8, count: 1000))
        hop.parentToViewer()
        XCTAssertEqual(hop.viewer.videoPackets, before + 2)
        XCTAssertNotNil(hop.viewer.nextOutgoing(now: 4))
        XCTAssertFalse(agent.cutover.hasMarker, "the RESUME leaves first, on Bluetooth")
        XCTAssertEqual(hop.viewer.phase, .open)
    }

    /// With the Wi-Fi switches off the viewer signs no build tag (every byte as before); without the parent's tag no agent
    /// exists and type 16 stays rejected. Either way the stream plays.
    func testWithoutBothBuildTagsAStreamHopNeverCarriesWifiRecords() throws {
        let off = StreamHop(parentTag: true, wifi: nil)
        try off.open()
        XCTAssertNotNil(off.viewer.header)
        XCTAssertNil(off.source.link.peerBuildTag)
        XCTAssertNil(off.viewer.wifi)
        XCTAssertFalse(off.viewer.link.acceptWifi)

        let untagged = StreamHop(parentTag: false, wifi: .init(directClient: true))
        try untagged.open()
        XCTAssertNotNil(untagged.viewer.header)
        XCTAssertEqual(untagged.source.link.peerBuildTag, BuildTag(releaseKey: false, release: WifiWire.firstRelease))
        XCTAssertFalse(untagged.viewer.link.wifiBuildTagGate)
        XCTAssertNil(untagged.viewer.wifi)
        XCTAssertFalse(untagged.viewer.link.acceptWifi)
        untagged.now = 1
        untagged.viewer.tick(now: 1)
        untagged.source.sendVideo(flags: StreamProtocol.flagKeyFrame, presentationTimeUs: 0, payload: Data(repeating: 7, count: 500))
        untagged.parentToViewer()
        XCTAssertEqual(untagged.viewer.videoPackets, 1)
        XCTAssertEqual(untagged.viewer.phase, .open)
    }

    /// A viewer that relays (its parent sends mesh envelopes) offers no Wi-Fi: its CAPS is all clear.
    func testAMeshEnvelopeStreamHopSendsClearCaps() throws {
        let hop = StreamHop(parentTag: true, wifi: .init(directClient: true), relayingViewer: true)
        try hop.open()
        XCTAssertNotNil(hop.viewer.header)
        let agent = try XCTUnwrap(hop.viewer.wifi)
        hop.now = 1
        hop.viewer.tick(now: 1)
        XCTAssertTrue(agent.capsSent)
        XCTAssertEqual(agent.sentBearers, 0)
    }

    /// A malformed BWF1 from the parent ends Wi-Fi for the hop, never the stream.
    func testAMalformedParentRecordEndsWifiNotTheStream() throws {
        let hop = StreamHop(parentTag: true, wifi: .init(directClient: true))
        try hop.open()
        let agent = try XCTUnwrap(hop.viewer.wifi)
        hop.now = 1
        hop.viewer.tick(now: 1)
        try hop.fromParent(.wifi, Data("BWF1".utf8) + Data([1, 12]))
        XCTAssertTrue(agent.wifiOver)
        XCTAssertEqual(hop.viewer.phase, .open)
        hop.source.sendVideo(flags: StreamProtocol.flagKeyFrame, presentationTimeUs: 0, payload: Data(repeating: 7, count: 500))
        hop.parentToViewer()
        XCTAssertEqual(hop.viewer.videoPackets, 1)
        XCTAssertEqual(hop.viewer.phase, .open)
    }

    /// AW2: while the parent's media arrives on Wi-Fi the viewer's Bluetooth arrival meter sees only heartbeats, so it
    /// reports on time (0 kbps, not late) about every 2 s instead of a Bluetooth-measured rate.
    func testAViewerReadingWifiReportsOnTimeInsteadOfABluetoothRate() throws {
        let hop = StreamHop(parentTag: true, wifi: .init(directClient: true))
        let (sealer, agent) = try streamCarrierUp(hop)
        hop.viewer.sendLinkReport(arrivalKbps: 640, linkLate: false, addedDelayMs: 0)   // the link was measured on Bluetooth
        let endpoint = try XCTUnwrap(hop.source.endpoint)
        hop.now = 2
        try hop.fromParent(.wifi, Bwf1.switchTo(gen: 1, ticket: wifiTicket, e2eBoundary: endpoint.sealer.nextSequence, meshBoundary: 0).encoded())
        XCTAssertTrue(agent.cutover.acceptWifi)
        let measured = hop.viewer.measuredReportsSent, onTime = hop.viewer.onTimeReportsSent
        for second in 0..<6 {
            hop.now = 3 + Double(second)
            let frame = MediaPacket(flags: second == 0 ? StreamProtocol.flagKeyFrame : 0, presentationTimeUs: Int64(second) * 1_000_000,
                                    payload: Data(repeating: 1, count: 800))
            hop.viewer.wifiReceive(try sealer.seal(.endToEndContent, try endpoint.sealer.seal(.mediaPacket, flags: frame.flags, frame.encoded)),
                                   ticket: wifiTicket, now: hop.now)
            try hop.fromParent(.linkHeartbeat, LinkHeartbeat.version1)
            hop.viewer.tick(now: hop.now)
        }
        XCTAssertTrue(agent.carrierUp)
        XCTAssertEqual(hop.viewer.measuredReportsSent, measured)
        XCTAssertGreaterThanOrEqual(hop.viewer.onTimeReportsSent - onTime, 2)
    }
}
