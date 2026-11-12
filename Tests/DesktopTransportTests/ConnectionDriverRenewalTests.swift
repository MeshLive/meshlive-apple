import XCTest
import NearbyCore
@testable import MeshPeer

/// The transport driver across an in-call link renewal (Design SR): a link that ends while the engine keeps the call
/// leaves the driver waiting without a transport; the renewed link replaces it; the call's end still releases once.
final class ConnectionDriverRenewalTests: XCTestCase {
    private final class Pipe: MeshLink {
        let transport = MeshTransport.gatt
        let label = "In-memory test pipe"
        var onBytes: ((Data) -> Void)?
        var onClosed: ((String) -> Void)?
        var onWritable: (() -> Void)?
        var sent: [Data] = []
        var closed = false
        var queuedBytes: Int { 0 }
        var peerIdentifier: UUID? { nil }
        func send(_ data: Data) { if !closed { sent.append(data) } }
        func close() { closed = true }
        /// The transport failed underneath (the peer closed it).
        func fail(_ reason: String) { closed = true; onClosed?(reason) }
    }

    /// A connection whose transport loss is held while `holding` (a renewal that owns the call's liveness).
    private final class Holding: MeshConnection {
        var holding = true
        override func holdsLinkLoss(_ reason: String) -> Bool { holding }
    }

    private func connection() -> Holding {
        let caps = NodeCapabilities(transportMask: NodeCapabilities.transportGATT, encodeCodecMask: 0, decodeCodecMask: 0, maxBitrateKbps: 0, maxChildren: 0)
        return Holding(role: .initiator, transport: .gatt, identity: SoftwareSigningIdentity(), linkCapabilities: caps, endpointCapabilities: caps)
    }

    func testAHeldLinkLossKeepsTheCallAndTheRenewedLinkTakesOver() {
        let engine = connection(), old = Pipe(), renewed = Pipe()
        let driver = ConnectionDriver(engine: engine, link: old)
        defer { driver.cancel() }
        var ended: [String] = []
        driver.onFinished = { ended.append($0) }
        driver.start()
        XCTAssertFalse(old.sent.isEmpty, "the link hello went out")
        old.fail("The peer closed the link")
        XCTAssertEqual(ended, [], "the renewal owns the call: no finish")
        XCTAssertTrue(driver.linkDown)
        XCTAssertNotEqual(engine.phase, .closed)
        driver.replaceLink(renewed)
        XCTAssertFalse(driver.linkDown)
        XCTAssertTrue(driver.link === renewed)
        XCTAssertNil(old.onBytes, "nothing that still arrives on the old link is read")
        // The renewed link's own loss, no longer held, ends the call once.
        engine.holding = false
        renewed.fail("Bluetooth link lost")
        XCTAssertEqual(ended, ["Bluetooth link lost"])
        XCTAssertEqual(engine.closeReason, "Bluetooth link lost")
    }

    func testTheOffererDropsItsOldLinkAndAFailureWithoutATransportStillReleasesOnce() {
        let engine = connection(), old = Pipe()
        let driver = ConnectionDriver(engine: engine, link: old)
        defer { driver.cancel() }
        var ended: [String] = []
        driver.onFinished = { ended.append($0) }
        driver.start()
        driver.dropLink()
        XCTAssertTrue(old.closed)
        XCTAssertTrue(driver.linkDown)
        old.onClosed?("late callback")
        XCTAssertEqual(ended, [], "the dropped link's callbacks are gone")
        engine.fail("Call link lost: the link renewal did not complete")
        driver.pump()
        XCTAssertEqual(ended, ["Call link lost: the link renewal did not complete"])
    }

    func testALocalEndWhileTheLinkIsDownFinishesAtOnce() {
        let engine = connection(), old = Pipe()
        let driver = ConnectionDriver(engine: engine, link: old)
        defer { driver.cancel() }
        var ended: [String] = []
        driver.onFinished = { ended.append($0) }
        driver.start()
        old.fail("The peer closed the link")
        engine.finish("Call ended", error: false)
        driver.pump()
        XCTAssertEqual(ended, ["Call ended"])
    }
}
