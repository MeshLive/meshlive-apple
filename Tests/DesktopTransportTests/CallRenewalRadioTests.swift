import XCTest
import NearbyCore
@testable import MeshPeer

/// The app's renewal radio (`CallRenewalRadio`) with the real call engines and transport drivers over in-memory links and
/// an in-memory radio, on one fake clock: the armed side keeps the link it bound, a failed connect is retried, writes
/// that never complete keep nothing alive, and renewal deadlines fire while the UI tracks touches.
final class CallRenewalRadioTests: XCTestCase {
    final class Clock { var t: TimeInterval = 1_000 }

    /// One end of an in-memory GATT-like link. `blocked`: its writes never complete (no write credit, refused
    /// notifications): bytes wait in its queue and its last completed write stays where it was.
    final class End: MeshLink {
        let transport = MeshTransport.gatt
        let label: String
        var onBytes: ((Data) -> Void)?
        var onClosed: ((String) -> Void)?
        var onWritable: (() -> Void)?
        weak var peer: End?
        var outbox: [Data] = []
        var closed = false
        var blocked = false
        var peerToldClosed = false
        private(set) var lastWriteAt: TimeInterval?
        var queuedBytes: Int { outbox.reduce(0) { $0 + $1.count } }
        var peerIdentifier: UUID? { nil }
        init(_ label: String) { self.label = label }
        func send(_ data: Data) { if !closed { outbox.append(data) } }
        func close() { closed = true; outbox.removeAll() }
        func move(at now: TimeInterval) {
            guard let peer else { return }
            if closed {
                if !peerToldClosed, !peer.closed { peerToldClosed = true; peer.closed = true; peer.onClosed?("The peer closed the link") }
                return
            }
            guard !blocked, !peer.closed, !outbox.isEmpty else { return }
            let bytes = outbox; outbox.removeAll()
            lastWriteAt = now
            for chunk in bytes { peer.onBytes?(chunk) }
            onWritable?()
        }
        static func pair(_ a: String, _ b: String) -> (End, End) {
            let x = End(a), y = End(b); x.peer = y; y.peer = x; return (x, y)
        }
    }

    /// Both phones' radios: adverts, scans, connects (optionally failing) and the links they make.
    final class Air {
        var ports: [Port] = []
        var links: [End] = []
        var failConnects = 0
        var connects: [(from: Port, to: Port, done: (Result<MeshLink, Error>) -> Void)] = []
        /// Connects over the existing connection (the old link's): nil = not usable, false = fails, true = works.
        var existingWorks: Bool?
        private(set) var existingCalls = 0, sightingCalls = 0, releases = 0
        var existing: [(from: Port, done: (Result<MeshLink, Error>) -> Void)] = []
        func noteSighting() { sightingCalls += 1 }
        func noteExisting() { existingCalls += 1 }
        func noteRelease() { releases += 1 }

        func step(_ now: TimeInterval) {
            for port in ports { if let started = port.pendingStarted { port.pendingStarted = nil; started(true) } }
            for scanner in ports {
                guard let (uuid, found) = scanner.scan else { continue }
                for other in ports where other !== scanner && other.advert == uuid { found(other) }
            }
            let viaExisting = existing; existing = []
            for connect in viaExisting {
                guard existingWorks == true, let to = ports.first(where: { $0 !== connect.from }) else {
                    connect.done(.failure(RadioError.connect(stage: "services_stall", reason: "Service discovery stalled"))); continue
                }
                connects.append((connect.from, to, connect.done))
            }
            let pending = connects; connects = []
            for connect in pending {
                if failConnects > 0 {
                    failConnects -= 1
                    connect.done(.failure(RadioError.connect(stage: "connect", reason: "Could not connect")))
                    continue
                }
                let (central, server) = End.pair("central", "server")
                links += [central, server]
                guard let subscriber = connect.to.renewalSubscriber else { central.close(); connect.done(.success(central)); continue }
                subscriber(server)
                connect.done(.success(central))
            }
            for _ in 0..<4 { for link in links { link.move(at: now) } }
        }
    }

    final class Port: CallRenewalRadioPort {
        let air: Air
        var renewalSubscriber: ((MeshLink) -> Void)?
        var scan: (UUID, (AnyObject) -> Void)?
        var advert: UUID?
        var pendingStarted: ((Bool) -> Void)?
        init(_ air: Air) { self.air = air; air.ports.append(self) }
        func renewalScan(_ uuid: UUID?, found: ((AnyObject) -> Void)?) {
            if let uuid, let found { scan = (uuid, found) } else { scan = nil }
        }
        func setRenewalAdvert(_ uuid: UUID, started: @escaping (Bool) -> Void) { advert = uuid; pendingStarted = started }
        func pauseRenewalAdvert() { advert = nil }
        func endRenewalAdvert() { advert = nil }
        func renewalConnect(_ peer: AnyObject, until: TimeInterval, completion: @escaping (Result<MeshLink, Error>) -> Void) -> ConnectHandle {
            air.noteSighting()
            if let target = peer as? Port { air.connects.append((self, target, completion)) }
            return ConnectHandle()
        }
        func renewalConnectExisting(_ oldLink: MeshLink, completion: @escaping (Result<MeshLink, Error>) -> Void) -> ConnectHandle? {
            guard air.existingWorks != nil else { return nil }
            air.noteExisting()
            air.existing.append((self, completion))
            return ConnectHandle()
        }
        func releaseRenewalExisting(_ oldLink: MeshLink) { air.noteRelease() }
        private(set) var established: [MeshLink?] = []
        func renewalEstablished(_ link: MeshLink?) { established.append(link) }
    }

    /// A direct GATT call between two phones with renewal on, ACTIVE, on the fake clock.
    final class Call {
        let clock = Clock(), air = Air()
        let caller: CallEngine, callee: CallEngine
        let callerOld: End, calleeOld: End
        var callerDriver: ConnectionDriver!, calleeDriver: ConnectionDriver!
        var callerRadio: CallRenewalRadio!, calleeRadio: CallRenewalRadio!
        var callerPort: Port!, calleePort: Port!

        init() throws {
            let callerId = SoftwareSigningIdentity(), calleeId = SoftwareSigningIdentity()
            caller = CallEngine(role: .caller, transport: .gatt, identity: callerId, requestedType: .voice, encodeMask: NodeCapabilities.codecVP9,
                                decodeMask: NodeCapabilities.codecVP9, expectedPeerPrefix: calleeId.nodeId.prefix, linkRenewal: true)
            callee = CallEngine(role: .callee, transport: .gatt, identity: calleeId, requestedType: .voice, encodeMask: NodeCapabilities.codecVP9,
                                decodeMask: NodeCapabilities.codecVP9, linkRenewal: true)
            (callerOld, calleeOld) = End.pair("caller old", "callee old")
            air.links += [callerOld, calleeOld]
            let clock = self.clock
            callerDriver = ConnectionDriver(engine: caller, link: callerOld, clock: { clock.t })
            calleeDriver = ConnectionDriver(engine: callee, link: calleeOld, clock: { clock.t })
            callerPort = Port(air); calleePort = Port(air)
            callerRadio = CallRenewalRadio(engine: caller, radio: callerPort, driver: { [unowned self] in self.callerDriver }, clock: { clock.t })
            calleeRadio = CallRenewalRadio(engine: callee, radio: calleePort, driver: { [unowned self] in self.calleeDriver }, clock: { clock.t })
            callerDriver.start(); calleeDriver.start()
            run(for: 1)
            try callee.accept(as: .voice)
            run(for: 1)
        }

        func step() {
            clock.t += 0.1
            caller.tick(now: clock.t); callee.tick(now: clock.t)
            callerDriver.pump(); calleeDriver.pump()
            air.step(clock.t)
            callerDriver.pump(); calleeDriver.pump()
            air.step(clock.t)
        }

        func run(for seconds: TimeInterval) { for _ in 0..<Int((seconds * 10).rounded()) { step() } }

        func stop() { callerDriver.cancel(); calleeDriver.cancel(); callerRadio.stop(); calleeRadio.stop() }
    }

    private func audio(_ engine: CallEngine, at t: TimeInterval) {
        for i in 0..<5 { engine.sendAudio(presentationTimeUs: Int64(t * 1_000_000) + Int64(i) * 20_000, opus: Data([0xf8, 0xff, 0xfe, UInt8(i)])) }
    }

    /// Review finding 1: the armed side's bind ends the attempt, and that cleanup never closes the link that
    /// just became the call's; the renewed links carry records both ways.
    func testTheArmedSideKeepsTheLinkItBoundAndBothDirectionsCarryTheCall() throws {
        let call = try Call()
        defer { call.stop() }
        XCTAssertEqual(call.caller.state?.phase, .active)
        XCTAssertEqual(call.callee.state?.phase, .active)
        call.run(for: 11)
        call.calleeOld.blocked = true   // the callee's sending stalls; it still hears the caller
        call.run(for: 8)
        XCTAssertEqual(call.caller.renewal?.bound, 1, "the caller offered and bound")
        XCTAssertEqual(call.callee.renewal?.bound, 1, "the callee armed and accepted BIND")
        let calleeLink = try XCTUnwrap(call.calleeDriver.link as? End), callerLink = try XCTUnwrap(call.callerDriver.link as? End)
        XCTAssertEqual(calleeLink.label, "server")
        XCTAssertFalse(calleeLink.closed, "the bound connection stays open")
        XCTAssertEqual(callerLink.label, "central")
        XCTAssertFalse(callerLink.closed)
        XCTAssertTrue(call.calleeOld.closed && call.callerOld.closed, "both old links are closed")
        let before = (call.caller.receivedAudioPackets, call.callee.receivedAudioPackets)
        audio(call.caller, at: call.clock.t); audio(call.callee, at: call.clock.t)
        call.run(for: 20)
        XCTAssertEqual(call.caller.receivedAudioPackets, before.0 + 5)
        XCTAssertEqual(call.callee.receivedAudioPackets, before.1 + 5)
        XCTAssertEqual(call.caller.state?.phase, .active, call.caller.closeReason ?? "")
        XCTAssertEqual(call.callee.state?.phase, .active, call.callee.closeReason ?? "")
    }

    /// Review finding 2: a connect that fails after the sighting (the old link is already broken) reaches the engine,
    /// which scans again; the next sighting connects and binds within the budget.
    func testAFailedConnectIsRetriedAndTheRetryBinds() throws {
        let call = try Call()
        defer { call.stop() }
        call.air.failConnects = 1
        call.run(for: 11)
        call.calleeOld.blocked = true
        call.run(for: 9)
        XCTAssertEqual(call.air.failConnects, 0, "the first connect failed")
        XCTAssertEqual(call.caller.renewal?.bound, 1, "the retry bound")
        XCTAssertEqual(call.callee.renewal?.bound, 1)
        call.run(for: 15)
        XCTAssertEqual(call.caller.state?.phase, .active, call.caller.closeReason ?? "")
    }

    /// An Apple offerer first runs the renewed link over the LE connection that already exists to the armed device
    /// (Apple keeps one address); when that fails, the next attempt lets that connection go and connects the sighting.
    func testTheOffererTriesTheExistingConnectionFirstThenTheSighting() throws {
        let call = try Call()
        defer { call.stop() }
        call.air.existingWorks = false
        call.run(for: 11)
        call.calleeOld.blocked = true
        call.run(for: 9)
        XCTAssertEqual(call.air.existingCalls, 1, "the first attempt used the existing connection")
        XCTAssertEqual(call.air.sightingCalls, 1, "the retry connected the sighting")
        XCTAssertGreaterThanOrEqual(call.air.releases, 1, "after letting the old connection go")
        XCTAssertEqual(call.caller.renewal?.bound, 1)
        XCTAssertEqual(call.callee.renewal?.bound, 1)
    }

    func testTheRenewalOverTheExistingConnectionBinds() throws {
        let call = try Call()
        defer { call.stop() }
        call.air.existingWorks = true
        call.run(for: 11)
        call.calleeOld.blocked = true
        call.run(for: 8)
        XCTAssertEqual(call.air.existingCalls, 1)
        XCTAssertEqual(call.air.sightingCalls, 0)
        XCTAssertEqual(call.caller.renewal?.bound, 1)
        XCTAssertEqual(call.callee.renewal?.bound, 1)
        let releases = call.air.releases
        call.callerRadio.stop()
        XCTAssertEqual(call.air.releases, releases, "the call's end never lets go of the connection the renewed link uses")
    }

    /// Review: a renewal over the existing connection that never binds keeps the old LE connection up for the next
    /// attempt; when the call ends, that connection is let go (it is not left connected to the other phone).
    func testACallThatEndsWithoutABindLetsTheKeptConnectionGo() throws {
        let call = try Call()
        defer { call.stop() }
        call.air.existingWorks = false
        call.air.failConnects = 1_000
        call.run(for: 11)
        call.calleeOld.blocked = true
        call.run(for: 20)
        XCTAssertGreaterThanOrEqual(call.air.existingCalls, 1, "the renewal tried the existing connection")
        XCTAssertNotEqual(call.caller.renewal?.bound, 1, "no renewal bound")
        let releases = call.air.releases
        call.callerRadio.stop()
        XCTAssertEqual(call.air.releases, releases + 1, "the kept connection is let go at the call's end")
    }

    /// Review finding 2: the call's second renewal (60 s after the first) arms with the link the first one bound as the
    /// established call link, so a HELLO on that same connection can start the second renewal's stream.
    func testASecondRenewalArmsWithTheBoundLinkAsTheCallsLink() throws {
        let call = try Call()
        defer { call.stop() }
        call.run(for: 11)
        call.calleeOld.blocked = true
        call.run(for: 8)
        XCTAssertEqual(call.callee.renewal?.bound, 1, "the first renewal bound")
        let bound = try XCTUnwrap(call.calleeDriver.link as? End)
        XCTAssertTrue(call.calleePort.established.last.map { $0 === call.calleeOld } ?? false, "the first arming marked the old link")
        call.run(for: 62)
        bound.blocked = true
        call.run(for: 9)
        XCTAssertTrue(call.calleePort.established.contains { $0 === bound }, "the second arming marked the bound link as the call's")
        XCTAssertEqual(call.callee.renewal?.bound, 2, "the second renewal bound too")
    }

    /// Review findings 1, 3 and 5 (decisions the CoreBluetooth callbacks take): a renewal attempt takes the newest
    /// data-service instance, a subscription callback is the attempt's only for its own characteristic in its subscribe
    /// stage, and only that characteristic's early notifications are kept for it.
    func testARenewalAttemptKeepsToItsOwnServiceInstanceAndCharacteristic() {
        let old = NSObject(), renewal = NSObject(), other = NSObject()
        XCTAssertTrue(MeshRadio.dataServiceInstance([old, renewal], renewal: true) === renewal, "fresh sighting: the renewal instance")
        XCTAssertTrue(MeshRadio.dataServiceInstance([renewal], renewal: true) === renewal, "an Apple armed device has one instance")
        XCTAssertTrue(MeshRadio.dataServiceInstance([old, renewal], renewal: false) === old, "a first connect keeps the first")
        XCTAssertNil(MeshRadio.dataServiceInstance([NSObject](), renewal: true))

        XCTAssertFalse(MeshRadio.subscriptionCallbackBelongs(attemptNotify: nil, characteristic: other, stage: "subscribe"),
                       "before the attempt chose its characteristic")
        XCTAssertFalse(MeshRadio.subscriptionCallbackBelongs(attemptNotify: renewal, characteristic: old, stage: "subscribe"),
                       "the old link's unsubscribe")
        XCTAssertFalse(MeshRadio.subscriptionCallbackBelongs(attemptNotify: renewal, characteristic: renewal, stage: "characteristics"))
        XCTAssertTrue(MeshRadio.subscriptionCallbackBelongs(attemptNotify: renewal, characteristic: renewal, stage: "subscribe"))

        XCTAssertFalse(MeshRadio.buffersEarlyNotification(renewal: true, attemptNotify: renewal, characteristic: old, failed: false),
                       "old instance traffic is not the renewal's")
        XCTAssertFalse(MeshRadio.buffersEarlyNotification(renewal: true, attemptNotify: nil, characteristic: renewal, failed: false))
        XCTAssertFalse(MeshRadio.buffersEarlyNotification(renewal: true, attemptNotify: renewal, characteristic: renewal, failed: true))
        XCTAssertFalse(MeshRadio.buffersEarlyNotification(renewal: false, attemptNotify: renewal, characteristic: renewal, failed: false))
        XCTAssertTrue(MeshRadio.buffersEarlyNotification(renewal: true, attemptNotify: renewal, characteristic: renewal, failed: false))
    }

    /// Android -> Apple (an Apple armed device, the offerer re-using the same LE connection): only a GR1 HELLO on an established,
    /// non-renewal server link starts a renewal stream; data, a link's own first HELLO and a renewal link's HELLO do not.
    func testAHelloOnAnEstablishedServerLinkStartsARenewalStream() {
        let hello = Gr1.hello()
        XCTAssertTrue(MeshRadio.startsRenewalStream(linkIsRenewal: false, peerHelloSeen: true, value: hello))
        XCTAssertFalse(MeshRadio.startsRenewalStream(linkIsRenewal: false, peerHelloSeen: false, value: hello), "the link's own first HELLO")
        XCTAssertFalse(MeshRadio.startsRenewalStream(linkIsRenewal: true, peerHelloSeen: true, value: hello), "a renewal link's repeat")
        XCTAssertFalse(MeshRadio.startsRenewalStream(linkIsRenewal: false, peerHelloSeen: true, value: Gr1.high(7)), "another GR1 message")
        var writer = GattChunkWriter()
        let data = writer.chunks(Data([1, 2, 3]), valueLimit: 182)[0]
        XCTAssertFalse(MeshRadio.startsRenewalStream(linkIsRenewal: false, peerHelloSeen: true, value: data), "a data chunk")
    }

    /// Review finding 3: with both transports' writes blocked (no write credit, refused notifications) the driver keeps
    /// handing small heartbeats to them, but no write completes: no renewal is offered and the call ends at the 8 s
    /// silence close, not the 14 s tolerance.
    func testBlockedWritesWithAHeartbeatOnlyQueueKeepNeitherTheRenewalNorTheToleranceAlive() throws {
        let call = try Call()
        defer { call.stop() }
        call.run(for: 11)
        call.callerOld.blocked = true; call.calleeOld.blocked = true
        call.run(for: 6.5)
        XCTAssertGreaterThan(call.callerOld.queuedBytes, 0, "heartbeats were handed to the blocked transport")
        XCTAssertNotEqual(call.caller.phase, .closed)
        call.run(for: 2.6)
        XCTAssertEqual(call.caller.phase, .closed)
        XCTAssertEqual(call.caller.closeReason, "Call peer stopped responding")
        XCTAssertEqual(call.caller.renewal?.attempts.count, 0, "no offer")
        XCTAssertEqual(call.callee.renewal?.attempts.count, 0)
    }

    /// Review finding 5: renewal deadlines (the 1 s proof window, the connect budget) run in the run loop's common
    /// modes, so they fire while a scroll or a held control tracks touches; a default-mode timer would not.
    func testRenewalDeadlinesFireWhileTheRunLoopTracksTouches() {
        let tracking = CFRunLoopMode("MeshLiveTestTracking" as CFString)
        CFRunLoopAddCommonMode(CFRunLoopGetCurrent(), tracking)
        var fired = false, defaultFired = false
        let deadline = CallRenewalRadio.deadline(after: 0.05) { fired = true }
        let control = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in defaultFired = true }
        defer { deadline.invalidate(); control.invalidate() }
        let end = Date().addingTimeInterval(1)
        while !fired && Date() < end { _ = RunLoop.current.run(mode: RunLoop.Mode(tracking.rawValue as String), before: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(fired, "the renewal deadline fired during tracking")
        XCTAssertFalse(defaultFired, "a default-mode timer waits for tracking to end")
    }
}
