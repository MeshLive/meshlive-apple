import XCTest
import NearbyCore
@testable import MeshPeer

final class ConnectionDriverTests: XCTestCase {
    private final class Pipe: MeshLink {
        let transport = MeshTransport.gatt
        let label = "In-memory test pipe"
        var onBytes: ((Data) -> Void)?
        var onClosed: ((String) -> Void)?
        var onWritable: (() -> Void)?
        var pending: [Data] = []
        var closed = false
        var releases = 0
        var failOnSend = false
        var queuedBytes: Int { pending.reduce(0) { $0 + $1.count } }
        var peerIdentifier: UUID? { nil }
        func send(_ data: Data) {
            guard !closed else { return }
            if failOnSend { close(); onClosed?("Synchronous pipe failure") }
            else { pending.append(data) }
        }
        func close() {
            guard !closed else { return }
            closed = true; pending.removeAll(); releases += 1
        }
        func drain(to peer: Pipe) {
            let bytes = pending; pending.removeAll()
            bytes.forEach { peer.onBytes?($0) }
            onWritable?()
        }
    }

    private func engine(_ role: PrivateCallRole) -> CallEngine {
        CallEngine(role: role, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .voice,
                   encodeMask: NodeCapabilities.codecVP9, decodeMask: NodeCapabilities.codecVP9)
    }

    func testFatalEngineFailureReleasesATransportWhoseQueueNeverDrains() {
        let engine = engine(.caller), pipe = Pipe()
        let driver = ConnectionDriver(engine: engine, link: pipe)
        defer { driver.cancel() }
        var ended: [String] = []
        driver.onFinished = { ended.append($0) }
        driver.start()
        XCTAssertGreaterThan(pipe.queuedBytes, 0, "The real secure hello is stuck in the transport")
        engine.fail("Transport stopped accepting output")
        driver.pump()
        XCTAssertTrue(pipe.closed, "A failed engine must not wait forever for a dead transport")
        XCTAssertEqual(ended, ["Transport stopped accepting output"])
        driver.cancel()
        XCTAssertEqual(pipe.releases, 1)
        XCTAssertEqual(ended.count, 1)
    }

    func testGracefulHangupReachesThePeerBeforeTransportRelease() throws {
        let mac = engine(.caller), peer = engine(.callee), left = Pipe(), right = Pipe()
        let driver = ConnectionDriver(engine: mac, link: left)
        let remote = ConnectionDriver(engine: peer, link: right)
        defer { driver.cancel(); remote.cancel() }
        func transfer() {
            for _ in 0..<80 {
                if left.queuedBytes == 0 && right.queuedBytes == 0 { return }
                left.drain(to: right); right.drain(to: left)
            }
            XCTFail("Encrypted call did not settle")
        }
        driver.start(); remote.start(); transfer()
        try peer.accept(as: .voice); remote.pump(); transfer()
        XCTAssertEqual(mac.state?.phase, .active)
        XCTAssertEqual(peer.state?.phase, .active)
        let released = expectation(description: "Graceful transport release")
        driver.onFinished = { _ in released.fulfill() }
        mac.end(); driver.pump()
        XCTAssertGreaterThan(left.queuedBytes, 0)
        XCTAssertFalse(left.closed, "Keep the sealed hangup until the transport can send it")
        XCTAssertEqual(peer.state?.phase, .active)
        transfer()
        XCTAssertEqual(peer.state?.phase, .ended)
        XCTAssertEqual(peer.closeReason, "Peer ended the call")
        wait(for: [released], timeout: 3)
        XCTAssertTrue(left.closed)
        XCTAssertEqual(left.releases, 1)
    }

    func testSynchronousSendFailureFinishesOnlyOnceAndDetachesCallbacks() {
        let engine = engine(.caller), pipe = Pipe()
        pipe.failOnSend = true
        let driver = ConnectionDriver(engine: engine, link: pipe)
        var reasons: [String] = []
        driver.onFinished = { reasons.append($0) }
        let lateWritable = pipe.onWritable
        driver.start()
        XCTAssertEqual(reasons, ["Synchronous pipe failure"])
        XCTAssertEqual(engine.phase, .closed)
        XCTAssertNil(pipe.onBytes)
        XCTAssertNil(pipe.onWritable)
        XCTAssertNil(pipe.onClosed)
        lateWritable?(); driver.pump(); driver.cancel()
        XCTAssertEqual(pipe.releases, 1)
        XCTAssertEqual(reasons.count, 1)
    }

    func testReleasingOwnerClosesAnAbandonedGracefulDrain() {
        let engine = engine(.caller), pipe = Pipe()
        var driver: ConnectionDriver? = ConnectionDriver(engine: engine, link: pipe)
        driver?.start()
        XCTAssertGreaterThan(pipe.queuedBytes, 0)
        engine.end(); driver?.pump()
        XCTAssertFalse(pipe.closed, "The driver initially preserves the normal drain")
        weak var owner = driver
        driver = nil
        XCTAssertNil(owner)
        XCTAssertTrue(pipe.closed, "A departed owner must not leave a radio slot occupied")
        XCTAssertEqual(pipe.queuedBytes, 0)
        XCTAssertNil(pipe.onBytes)
        XCTAssertNil(pipe.onWritable)
        XCTAssertNil(pipe.onClosed)
    }
}
