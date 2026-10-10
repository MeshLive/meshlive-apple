import XCTest
@testable import NearbyCore

/// Two sans-I/O engines connected by an in-memory byte pipe (optionally through GATT chunk framing).
private final class Pipe {
    let a: MeshConnection, b: MeshConnection
    var now: TimeInterval = 0
    var gatt: Bool
    var aToB = GattChunkWriter(), bToA = GattChunkWriter()
    var bReader = GattChunkReader(), aReader = GattChunkReader()
    var chunkStep = 1
    init(_ a: MeshConnection, _ b: MeshConnection, gatt: Bool = false) { self.a = a; self.b = b; self.gatt = gatt }

    private func move(from: MeshConnection, to: MeshConnection, writer: inout GattChunkWriter, reader: inout GattChunkReader) throws -> Bool {
        var moved = false
        while let bytes = from.nextOutgoing(now: now) {
            moved = true
            if gatt {
                for value in writer.chunks(bytes, valueLimit: 182) { to.receive(try reader.accept(value), now: now) }
            } else {
                var i = bytes.startIndex
                while i < bytes.endIndex { let end = min(bytes.endIndex, i + chunkStep); to.receive(bytes[i..<end].rebased, now: now); i = end; chunkStep = chunkStep % 300 + 7 }
            }
        }
        return moved
    }
    func pump(_ rounds: Int = 50) throws {
        for _ in 0..<rounds {
            let x = try move(from: a, to: b, writer: &aToB, reader: &bReader)
            let y = try move(from: b, to: a, writer: &bToA, reader: &aReader)
            if !x && !y { return }
        }
    }
    func advance(_ seconds: TimeInterval) throws { now += seconds; a.tick(now: now); b.tick(now: now); try pump() }
}

final class EngineTests: XCTestCase {
    let vp9 = NodeCapabilities.codecVP9

    private func makeCall(type: CallType = .voice, gatt: Bool = false, calleeDecode: UInt8? = nil, fragments: Bool = false)
        throws -> (CallEngine, CallEngine, Pipe, [CallEngine.Event], [CallEngine.Event]) {
        let callerId = SoftwareSigningIdentity(), calleeId = SoftwareSigningIdentity()
        let transport: MeshTransport = gatt ? .gatt : .l2cap
        let caller = CallEngine(role: .caller, transport: transport, identity: callerId, requestedType: type, encodeMask: vp9, decodeMask: vp9,
                                expectedPeerPrefix: calleeId.nodeId.prefix, videoFragments: fragments)
        let callee = CallEngine(role: .callee, transport: transport, identity: calleeId, requestedType: .video, encodeMask: vp9, decodeMask: calleeDecode ?? vp9,
                                videoFragments: fragments)
        return (caller, callee, Pipe(caller, callee, gatt: gatt), [], [])
    }

    /// Replays the stalled iPhone -> M31 video call: a video backlog (link stalled) must never delay audio or
    /// heartbeats. Records are pulled one at a time, as a slow GATT link would: the first record after the
    /// backlog forms must be the heartbeat, the next the audio packet, and the peer must not time out.
    func testAudioAndHeartbeatsNeverQueueBehindVideo() throws {
        let (caller, callee, pipe, _, _) = try makeCall(type: .video, gatt: true)
        var calleeEvents: [CallEngine.Event] = []
        callee.onEvent = { calleeEvents.append($0) }
        try caller.start(now: 0); try callee.start(now: 0); try pipe.pump()
        try callee.accept(as: .video); try pipe.pump()
        XCTAssertEqual(caller.state?.phase, .active)
        calleeEvents.removeAll()
        // 30 frames of about 2 kB queue while nothing reaches the link.
        for i in 0..<30 {
            caller.sendVideo(flags: i == 0 ? StreamProtocol.flagKeyFrame : 0, presentationTimeUs: Int64(i) * 66_666, payload: Data(repeating: UInt8(i), count: 2_000))
        }
        caller.tick(now: 1.5)                                         // heartbeat due (control)
        caller.sendAudio(presentationTimeUs: 2_000_000, opus: Data([0xfc, 1, 2, 3]))
        var reader = GattChunkReader(), writer = GattChunkWriter(), backReader = GattChunkReader(), backWriter = GattChunkWriter()
        var clock = 1.5
        /// One record caller -> callee (the slow direction); everything callee -> caller (the fast direction).
        func deliverOne() throws {
            if let bytes = caller.nextOutgoing(now: clock) {
                for value in writer.chunks(bytes, valueLimit: 182) { callee.receive(try reader.accept(value), now: clock) }
            }
            while let bytes = callee.nextOutgoing(now: clock) {
                for value in backWriter.chunks(bytes, valueLimit: 182) { caller.receive(try backReader.accept(value), now: clock) }
            }
        }
        try deliverOne(); try deliverOne()
        XCTAssertTrue(calleeEvents.contains { if case .peerReport = $0 { return true }; return false }, "heartbeat first: \(calleeEvents)")
        XCTAssertTrue(calleeEvents.contains { if case .remoteAudio = $0 { return true }; return false }, "audio before the video backlog")
        XCTAssertFalse(calleeEvents.contains { if case .remoteVideo = $0 { return true }; return false }, "no video yet")
        // While video keeps queueing behind a slow link, each heartbeat still gets through: no silent-link timeout.
        for second in 2...12 {
            caller.sendVideo(flags: 0, presentationTimeUs: Int64(second) * 1_000_000, payload: Data(repeating: 7, count: 2_000))
            clock = Double(second)
            caller.tick(now: clock); callee.tick(now: clock)
            try deliverOne()
        }
        XCTAssertEqual(callee.phase, .open, "the callee did not declare the caller silent")
        XCTAssertNotEqual(callee.state?.phase, .ended)
    }

    func testVoiceCallSetupMediaAndHangUpBothTransports() throws {
        for gatt in [false, true] {
            let (caller, callee, pipe, _, _) = try makeCall(type: .voice, gatt: gatt)
            var callerEvents: [CallEngine.Event] = [], calleeEvents: [CallEngine.Event] = []
            caller.onEvent = { callerEvents.append($0) }; callee.onEvent = { calleeEvents.append($0) }
            try caller.start(now: 0); try callee.start(now: 0); try pipe.pump()
            XCTAssertEqual(caller.state?.phase, .outgoingRinging)
            XCTAssertEqual(callee.state?.phase, .incomingRinging)
            XCTAssertTrue(calleeEvents.contains(.offeredTypeChanged(.voice)), "Invite + Camera off is a voice offer")
            XCTAssertTrue(calleeEvents.contains(.remoteCamera(false)))
            try callee.accept(as: .voice); try pipe.pump()
            XCTAssertEqual(caller.state?.phase, .active); XCTAssertEqual(callee.state?.phase, .active)
            XCTAssertTrue(callerEvents.contains { if case .startLocalMedia(let h, .voice) = $0 { return h.hasAudio && h.codecId == StreamProtocol.codecVP9 }; return false })
            for i in 0..<5 { caller.sendAudio(presentationTimeUs: Int64(i) * 20_000, opus: Data([0xfc, UInt8(i)])) }
            callee.sendAudio(presentationTimeUs: 0, opus: Data([0xfc, 9]))
            try pipe.pump()
            XCTAssertEqual(calleeEvents.filter { if case .remoteAudio = $0 { return true }; return false }.count, 5)
            XCTAssertEqual(callee.receivedAudioPackets, 5); XCTAssertEqual(caller.receivedAudioPackets, 1)
            // Push-to-talk style mute drops audio and signals the peer.
            caller.setMuted(true); caller.sendAudio(presentationTimeUs: 200_000, opus: Data([0xfc])); try pipe.pump()
            XCTAssertTrue(calleeEvents.contains(.remoteMuted(true))); XCTAssertEqual(callee.receivedAudioPackets, 5)
            // Heartbeats keep the call alive past the 8 s silent-link timeout.
            for _ in 0..<12 { try pipe.advance(1) }
            XCTAssertEqual(caller.phase, .open)
            caller.end(); try pipe.pump()
            XCTAssertTrue(caller.shouldCloseAfterFlush)
            XCTAssertEqual(callee.state?.phase, .ended)
            XCTAssertTrue(calleeEvents.contains(.ended("Peer ended the call", error: false)))
        }
    }

    func testVideoCallSendsVideoFragmentsAndKeyFrameRequests() throws {
        let (caller, callee, pipe, _, _) = try makeCall(type: .video, fragments: true)
        var calleeEvents: [CallEngine.Event] = [], callerEvents: [CallEngine.Event] = []
        callee.onEvent = { calleeEvents.append($0) }; caller.onEvent = { callerEvents.append($0) }
        try caller.start(now: 0); try callee.start(now: 0); try pipe.pump()
        XCTAssertFalse(calleeEvents.contains(.offeredTypeChanged(.voice)))
        try callee.accept(as: .video); try pipe.pump()
        let big = Data((0..<9000).map { UInt8($0 % 251) })
        XCTAssertTrue(caller.sendVideo(flags: StreamProtocol.flagKeyFrame, presentationTimeUs: 1, payload: big))
        caller.sendAudio(presentationTimeUs: 0, opus: Data([0xfc]))
        caller.sendRotation(90)
        try pipe.pump()
        let videos = calleeEvents.compactMap { e -> MediaPacket? in if case .remoteVideo(let p) = e { return p }; return nil }
        XCTAssertEqual(videos.first?.payload, big)
        XCTAssertTrue(caller.peerAcceptsDeliveryReports, "both endpoints sent the version-1 hello")
        XCTAssertTrue(calleeEvents.contains(.remoteRotation(90)))
        callee.requestKeyFrame(); try pipe.pump()
        XCTAssertTrue(callerEvents.contains(.keyFrameRequested))
        callee.setCameraEnabled(false); try pipe.pump()
        XCTAssertTrue(callerEvents.contains(.remoteCamera(false)))
    }

    func testDeclineCancelTimeoutsAndCodecMismatch() throws {
        do {
            let (caller, callee, pipe, _, _) = try makeCall()
            var callerEvents: [CallEngine.Event] = []; caller.onEvent = { callerEvents.append($0) }
            try caller.start(now: 0); try callee.start(now: 0); try pipe.pump()
            try callee.decline(.busy); try pipe.pump()
            XCTAssertEqual(caller.state?.phase, .ended)
            XCTAssertTrue(callerEvents.contains { if case .ended(let r, false) = $0 { return r.contains("busy") }; return false })
        }
        do {
            let (caller, callee, pipe, _, _) = try makeCall()
            try caller.start(now: 0); try callee.start(now: 0); try pipe.pump()
            try caller.cancel(); try pipe.pump()
            XCTAssertEqual(callee.state?.phase, .ended)
        }
        do { // Unanswered call times out on the caller and the callee sees the cancel.
            let (caller, callee, pipe, _, _) = try makeCall()
            try caller.start(now: 0); try callee.start(now: 0); try pipe.pump()
            for _ in 0..<61 { try pipe.advance(1) }
            XCTAssertEqual(caller.state?.phase, .ended); XCTAssertEqual(callee.state?.phase, .ended)
        }
        do { // A peer that decodes nothing we can encode fails like Android ("Peer cannot decode ...").
            let (caller, callee, pipe, _, _) = try makeCall(calleeDecode: NodeCapabilities.codecAV1)
            try caller.start(now: 0); try callee.start(now: 0); try pipe.pump()
            XCTAssertEqual(caller.phase, .closed)
            XCTAssertEqual(caller.closeReason, "Peer cannot decode any locally available call codec")
        }
        do { // Silence after setup ends the call (8 s).
            let (caller, callee, pipe, _, _) = try makeCall()
            try caller.start(now: 0); try callee.start(now: 0); try pipe.pump()
            caller.tick(now: 9)
            XCTAssertEqual(caller.closeReason, "Call peer stopped responding")
            _ = callee
        }
    }

    func testWrongPeerPrefixIsRefusedBeforeContent() throws {
        let caller = CallEngine(role: .caller, transport: .l2cap, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                expectedPeerPrefix: Data(repeating: 0xAA, count: 6))
        let callee = CallEngine(role: .callee, transport: .l2cap, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9)
        let pipe = Pipe(caller, callee)
        try caller.start(now: 0); try callee.start(now: 0); try pipe.pump()
        XCTAssertEqual(caller.phase, .closed); XCTAssertNil(caller.state)
        XCTAssertNil(callee.state)
    }

    func testTransportMismatchIsRefused() throws {
        let caller = CallEngine(role: .caller, transport: .l2cap, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9)
        let callee = CallEngine(role: .callee, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9)
        let pipe = Pipe(caller, callee)
        try caller.start(now: 0); try callee.start(now: 0); try pipe.pump()
        XCTAssertEqual(callee.phase, .closed)
        XCTAssertTrue(callee.closeReason?.contains("did not authenticate") ?? false)
    }

    func testVerifiedContactMismatchRefusesEndpoint() throws {
        let calleeId = SoftwareSigningIdentity()
        let book = VerifiedContactBook()
        // A verified contact with the callee's prefix but a different key (forged by grinding).
        var forged = calleeId.fingerprint.hex; forged.replaceSubrange(forged.index(forged.startIndex, offsetBy: 40)..<forged.endIndex, with: String(repeating: "0", count: 24))
        let forgedFp = try IdentityFingerprint(hex: forged)
        try book.markVerified(authenticated: forgedFp, confirmed: forgedFp, name: "Asha", method: "qr")
        var mismatches = 0; book.onMismatch = { _, _, _ in mismatches += 1 }
        let caller = CallEngine(role: .caller, transport: .l2cap, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                expectedPeerPrefix: calleeId.nodeId.prefix)
        caller.identityGate = book
        let callee = CallEngine(role: .callee, transport: .l2cap, identity: calleeId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9)
        let pipe = Pipe(caller, callee)
        try caller.start(now: 0); try callee.start(now: 0); try pipe.pump()
        XCTAssertEqual(mismatches, 1); XCTAssertEqual(caller.phase, .closed); XCTAssertNil(caller.state)
        XCTAssertEqual(book.state(of: calleeId.fingerprint), .mismatch)
    }

    func testStreamSourceToViewerDirectMeshPauseAndEnd() throws {
        for (meshViewer, gatt) in [(false, false), (true, true)] {
            let sourceId = SoftwareSigningIdentity(), viewerId = SoftwareSigningIdentity()
            let transport: MeshTransport = gatt ? .gatt : .l2cap
            let header = StreamHeader(width: 640, height: 360, fps: 15, codecId: StreamProtocol.codecVP9, includeAudio: true)
            let source = StreamSourceEngine(transport: transport, identity: sourceId, header: header, expectedViewerPrefix: viewerId.nodeId.prefix)
            let viewer = StreamViewerEngine(transport: transport, identity: viewerId, decodeMask: vp9, expectedAdjacentPrefix: sourceId.nodeId.prefix,
                                            maxChildren: meshViewer ? 1 : 0)
            var viewerEvents: [StreamViewerEngine.Event] = [], sourceEvents: [StreamSourceEngine.Event] = []
            viewer.onEvent = { viewerEvents.append($0) }; source.onEvent = { sourceEvents.append($0) }
            let pipe = Pipe(source, viewer, gatt: gatt)
            try source.start(now: 0); try viewer.start(now: 0); try pipe.pump()
            XCTAssertTrue(source.ready); XCTAssertEqual(source.useMeshEnvelope, meshViewer)
            XCTAssertEqual(viewer.header, header)
            source.sendAudioConfig()
            source.sendVideo(flags: StreamProtocol.flagKeyFrame, presentationTimeUs: 0, payload: Data(repeating: 7, count: 3000))
            source.sendAudio(presentationTimeUs: 0, opus: Data([0xfc, 1]))
            try pipe.pump()
            XCTAssertEqual(viewer.videoPackets, 1); XCTAssertEqual(viewer.audioPackets, 1)
            XCTAssertEqual(viewer.meshStreamId != nil, meshViewer)
            if meshViewer { XCTAssertTrue(viewerEvents.contains { if case .envelope = $0 { return true }; return false }) }
            viewer.requestKeyFrame(); try pipe.pump()
            XCTAssertTrue(sourceEvents.contains(.keyFrameRequested))
            source.setPaused(true); try pipe.pump()
            for _ in 0..<10 { try pipe.advance(1) } // PAUSED every 2 s + viewer heartbeats keep both alive
            XCTAssertEqual(viewer.phase, .open); XCTAssertEqual(source.phase, .open)
            source.setPaused(false); source.endStream(); try pipe.pump()
            XCTAssertTrue(viewerEvents.contains(.state(.ended)))
            XCTAssertTrue(sourceEvents.contains(.endAcknowledged))
            XCTAssertEqual(source.phase, .closed); XCTAssertEqual(viewer.phase, .closed)
        }
    }

    func testViewerRejectsUndecodableCodecAndRouteWithdrawal() throws {
        let sourceId = SoftwareSigningIdentity(), viewerId = SoftwareSigningIdentity()
        let header = StreamHeader(width: 640, height: 360, fps: 15, codecId: StreamProtocol.codecAV1, includeAudio: true)
        let source = StreamSourceEngine(transport: .l2cap, identity: sourceId, header: header, expectedViewerPrefix: nil)
        let viewer = StreamViewerEngine(transport: .l2cap, identity: viewerId, decodeMask: vp9 | NodeCapabilities.codecAV1, expectedAdjacentPrefix: nil)
        var events: [StreamViewerEngine.Event] = []; viewer.onEvent = { events.append($0) }
        let pipe = Pipe(source, viewer)
        try source.start(now: 0); try viewer.start(now: 0); try pipe.pump()
        source.withdrawRoute(); try pipe.pump()
        XCTAssertTrue(events.contains(.routeWithdrawn(.localCapacity)))
        XCTAssertEqual(source.phase, .closed)

        let viewer2 = StreamViewerEngine(transport: .l2cap, identity: viewerId, decodeMask: vp9, expectedAdjacentPrefix: nil)
        let source2 = StreamSourceEngine(transport: .l2cap, identity: sourceId, header: header, expectedViewerPrefix: nil)
        let pipe2 = Pipe(source2, viewer2)
        try source2.start(now: 0); try viewer2.start(now: 0); try pipe2.pump()
        XCTAssertEqual(source2.closeReason, "Final receiver cannot decode the stream codec")
    }

    func testOutboundPriorityAndVideoShedding() throws {
        var q = OutboundQueues(); q.videoCapacity = 3
        func item(_ key: Bool = false) -> OutboundItem { OutboundItem(kind: .raw(Data([1])), enqueuedAt: 0, isKeyFrame: key, closeAfter: false) }
        XCTAssertTrue(q.push(item(true), .video))
        for _ in 0..<2 { XCTAssertTrue(q.push(item(), .video)) }
        XCTAssertFalse(q.push(item(), .video), "overflow sheds the dependent chain")
        XCTAssertFalse(q.push(item(), .video), "and waits for a keyframe")
        XCTAssertTrue(q.push(item(true), .video))
        XCTAssertTrue(q.push(item(), .audio)); XCTAssertTrue(q.push(item(), .control))
        XCTAssertEqual(q.droppedVideoFrames, 5)
        XCTAssertEqual(q.count, 3)
    }
}
