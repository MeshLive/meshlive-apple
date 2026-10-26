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

    /// Overhead trim (Android test_call_audio_coalesce): audio that queued behind a slow link leaves as one BTA2 batch and
    /// the callee plays the same units in order; with the switch off every unit is its own record.
    func testQueuedCallAudioLeavesAsOneBatchAndArrivesAsTheSameUnits() throws {
        for coalesce in [false, true] {
            let (caller, callee, pipe, _, _) = try makeCall(gatt: true)
            var heard: [MediaPacket] = []
            callee.onEvent = { if case .remoteAudio(let unit) = $0 { heard.append(unit) } }
            try caller.start(now: 0); try callee.start(now: 0); try pipe.pump()
            try callee.accept(as: .voice); try pipe.pump()
            caller.queues.coalesceAudio = coalesce
            let sentBefore = caller.sentBytes
            for i in 0..<5 { caller.sendAudio(presentationTimeUs: Int64(i) * 20_000, opus: Data([0xfc]) + Data(repeating: UInt8(i), count: 79)) }
            try pipe.pump()
            XCTAssertEqual(heard.map(\.presentationTimeUs), [0, 20_000, 40_000, 60_000, 80_000], "coalesce \(coalesce)")
            XCTAssertEqual(heard.map { $0.payload.last }, [0, 1, 2, 3, 4])
            XCTAssertEqual(caller.queues.coalescedAudioUnits, coalesce ? 4 : 0)
            if coalesce { XCTAssertLessThan(caller.sentBytes - sentBefore, 5 * 80 + 4 * 80, "per-record framing saved") }
        }
    }

    /// Connection review A3: a callee that completes the handshakes but never rings ends the caller's call after 15 s
    /// (not 60 s), with a plain reason; the control arm keeps waiting.
    func testACallerStopsWaitingForAnAnswerAfterFifteenSeconds() throws {
        for armed in [true, false] {
            let (caller, callee, pipe, _, _) = try makeCall()
            callee.testingIgnoreInvite = true
            caller.callerAnswerDeadline = armed
            try caller.start(now: 0); try callee.start(now: 0); try pipe.pump()
            XCTAssertEqual(caller.state?.phase, .outgoingInvite)
            for t in stride(from: 1.0, through: 16.0, by: 1.0) { try pipe.advance(1); _ = t }
            if armed {
                XCTAssertEqual(caller.phase, .closed)
                XCTAssertEqual(caller.closeReason, CallEngine.callerAnswerReason)
            } else {
                XCTAssertNotEqual(caller.phase, .closed, "control arm: only the 60 s ring timeout")
            }
        }
    }

    /// Busy rule (Android F14): a phone already in a call answers an Invite with Decline BUSY and never rings.
    func testABusyPhoneDeclinesWithBusyBeforeRinging() throws {
        let (caller, callee, pipe, _, _) = try makeCall()
        var calleeEvents: [CallEngine.Event] = []
        callee.onEvent = { calleeEvents.append($0) }
        callee.declineAsBusy = true
        try caller.start(now: 0); try callee.start(now: 0); try pipe.pump()
        XCTAssertTrue(callee.declinedBusy)
        XCTAssertFalse(calleeEvents.contains { if case .incomingCall = $0 { return true }; return false }, "it never rang")
        XCTAssertEqual(caller.phase, .closed)
        XCTAssertTrue(caller.closeReason?.contains("busy") == true, caller.closeReason ?? "-")
    }

    /// Glare (Android F14 DialCollision): only the person being dialled rings while a dial still looks for its person.
    func testDialCollisionRingsOnlyThePersonBeingDialled() {
        XCTAssertEqual(DialCollision.decide(dialling: true, target: "a1b2c3d4e5f6", callerPrefix: "A1B2C3D4E5F6"), .ring)
        XCTAssertEqual(DialCollision.decide(dialling: true, target: "a1b2c3d4e5f6", callerPrefix: "0102030405a8"), .declineBusy)
        XCTAssertEqual(DialCollision.decide(dialling: true, target: "a1b2c3d4e5f6", callerPrefix: nil), .declineBusy, "a throwaway never matches")
        XCTAssertEqual(DialCollision.decide(dialling: true, target: nil, callerPrefix: "a1b2c3d4e5f6"), .declineBusy)
        XCTAssertEqual(DialCollision.decide(dialling: false, target: "a1b2c3d4e5f6", callerPrefix: "a1b2c3d4e5f6"), .declineBusy, "in a call: busy")
    }

    func testABusyListenerRingsForTheDialledPersonAndDeclinesEveryoneElse() throws {
        for ring in [true, false] {
            let (caller, callee, pipe, _, _) = try makeCall()
            var asked: NodeId?
            callee.declineAsBusy = true
            callee.ringInsteadOfBusy = { id in asked = id; return ring }
            try caller.start(now: 0); try callee.start(now: 0); try pipe.pump()
            XCTAssertEqual(asked, caller.identityNodeIdForTests, "the hook sees the caller's real ID")
            if ring { XCTAssertEqual(callee.state?.phase, .incomingRinging); XCTAssertFalse(callee.declinedBusy) }
            else { XCTAssertTrue(callee.declinedBusy); XCTAssertTrue(caller.closeReason?.contains("busy") == true) }
        }
    }

    /// Both devices dial each other: the first Invite to arrive while the other still looks becomes the only call.
    func testTwoDevicesDiallingEachOtherEndInOneCall() throws {
        // A's dial reaches B's listener first; B's own dial (to A) is still looking.
        let (aOut, bListen, first, _, _) = try makeCall()
        var bDialling = true
        bListen.declineAsBusy = true
        bListen.ringInsteadOfBusy = { id in
            guard DialCollision.decide(dialling: bDialling, target: id?.prefix.hex, callerPrefix: id?.prefix.hex) == .ring else { return false }
            bDialling = false   // B's own dial stops: the call from A is the conversation
            return true
        }
        try aOut.start(now: 0); try bListen.start(now: 0); try first.pump()
        XCTAssertEqual(bListen.state?.phase, .incomingRinging)
        XCTAssertFalse(bDialling, "B cancelled its own dial, so its Invite never reaches A")
        try bListen.accept(as: .voice); try first.pump()
        XCTAssertEqual(aOut.state?.phase, .active)
    }

    /// The end-to-end hello never signs transport bit 4 (0x10, Android's in-call link renewal), whatever is on.
    func testCallHellosNeverSignTheRenewalBit() throws {
        let (caller, callee, pipe, _, _) = try makeCall(type: .video, fragments: true)
        try caller.start(now: 0); try callee.start(now: 0); try pipe.pump()
        XCTAssertEqual((caller.endpoint?.peerCapabilities.transportMask ?? 0x10) & 0x10, 0)
        XCTAssertEqual((callee.endpoint?.peerCapabilities.transportMask ?? 0x10) & 0x10, 0)
    }

    func testAlignedGattValuesFillWholeLePdusAndStillReassemble() throws {
        XCTAssertEqual(GattChunk.valueBytes(valueLimit: 514, aligned: true), 495)
        XCTAssertEqual(GattChunk.valueBytes(valueLimit: 400, aligned: true), 244)
        XCTAssertEqual(GattChunk.valueBytes(valueLimit: 182, aligned: true), 182, "below one PDU the limit stays")
        XCTAssertEqual(GattChunk.valueBytes(valueLimit: 514, aligned: false), 512)
        var writer = GattChunkWriter(), reader = GattChunkReader()
        let bytes = Data((0..<5_000).map { UInt8($0 % 251) })
        let values = writer.chunks(bytes, valueLimit: 514, aligned: true)
        XCTAssertTrue(values.allSatisfy { $0.count <= 495 })
        var out = Data(); for v in values { out.append(try reader.accept(v, now: 0)) }
        XCTAssertEqual(out, bytes)
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

/// Android 2026-10-16 on-time reports and the live media states 4-6 (iPhone as viewer).
final class OnTimeReportTests: XCTestCase {
    let vp9 = NodeCapabilities.codecVP9

    private func stream() throws -> (StreamSourceEngine, StreamViewerEngine, Pipe, Box) {
        let sourceId = SoftwareSigningIdentity(), viewerId = SoftwareSigningIdentity()
        let header = StreamHeader(width: 640, height: 360, fps: 15, codecId: StreamProtocol.codecVP9, includeAudio: true)
        let source = StreamSourceEngine(transport: .gatt, identity: sourceId, header: header, expectedViewerPrefix: viewerId.nodeId.prefix)
        let viewer = StreamViewerEngine(transport: .gatt, identity: viewerId, decodeMask: vp9, expectedAdjacentPrefix: sourceId.nodeId.prefix)
        let box = Box()
        source.onEvent = { box.source.append($0) }; viewer.onEvent = { box.viewer.append($0) }
        let pipe = Pipe(source, viewer, gatt: true)
        try source.start(now: 0); try viewer.start(now: 0); try pipe.pump()
        return (source, viewer, pipe, box)
    }
    final class Box { var source: [StreamSourceEngine.Event] = []; var viewer: [StreamViewerEngine.Event] = [] }
    private func reports(_ events: [StreamSourceEngine.Event]) -> [LinkCapacityReport] {
        events.compactMap { if case .peerReport(let r) = $0 { return r }; return nil }
    }

    func testAnUnmeasuredViewerReportsOnTimeEveryTwoSecondsWhileMediaArrives() throws {
        let (source, viewer, pipe, box) = try stream()
        try pipe.advance(3)
        XCTAssertTrue(reports(box.source).isEmpty, "no media yet: nothing to report")
        for second in 0..<6 {
            source.sendVideo(flags: second == 0 ? StreamProtocol.flagKeyFrame : 0, presentationTimeUs: Int64(second) * 1_000_000, payload: Data(repeating: 1, count: 800))
            try pipe.advance(1)
        }
        let sent = reports(box.source)
        XCTAssertTrue((2...4).contains(sent.count), "about one report per 2 s: \(sent.count)")
        XCTAssertTrue(sent.allSatisfy { $0.arrivalKbps == 0 && !$0.linkLate && $0.receivedBytes == nil })
        XCTAssertEqual(viewer.onTimeReportsSent, sent.count)
        // Media stops: the reports stop too (only the version-1 heartbeat keeps the link alive).
        try pipe.advance(2)  // the last frame may still earn one report
        let settled = reports(box.source).count
        XCTAssertLessThanOrEqual(settled, sent.count + 1)
        try pipe.advance(2); try pipe.advance(1)
        XCTAssertEqual(reports(box.source).count, settled)
        XCTAssertEqual(viewer.phase, .open)
        // A measured link reports for itself and the on-time report stops.
        viewer.sendLinkReport(arrivalKbps: 640, linkLate: false, addedDelayMs: 0); try pipe.pump()
        source.sendVideo(flags: 0, presentationTimeUs: 9_000_000, payload: Data(repeating: 1, count: 800)); try pipe.advance(3)
        XCTAssertEqual(reports(box.source).last?.arrivalKbps, 640)
        // Off restores the silent viewer.
        let (source2, viewer2, pipe2, box2) = try stream()
        viewer2.onTimeReports = false
        source2.sendVideo(flags: StreamProtocol.flagKeyFrame, presentationTimeUs: 0, payload: Data(repeating: 1, count: 800)); try pipe2.advance(3)
        XCTAssertTrue(reports(box2.source).isEmpty)
    }

    /// Android LinkPacer on the source: the backlog waits in the app queue (control still passes), drains as time
    /// passes at the seeded pace, and the viewer's on-time reports raise the seed while the source backs up.
    func testASourcePacesItsChildLinkAndOnTimeReportsRaiseTheSeed() throws {
        let sourceId = SoftwareSigningIdentity(), viewerId = SoftwareSigningIdentity()
        let header = StreamHeader(width: 640, height: 360, fps: 15, codecId: StreamProtocol.codecVP9, includeAudio: true)
        let source = StreamSourceEngine(transport: .gatt, identity: sourceId, header: header, expectedViewerPrefix: viewerId.nodeId.prefix, linkPacing: true)
        let viewer = StreamViewerEngine(transport: .gatt, identity: viewerId, decodeMask: vp9, expectedAdjacentPrefix: sourceId.nodeId.prefix)
        let pipe = Pipe(source, viewer, gatt: true)
        try source.start(now: 0); try viewer.start(now: 0); try pipe.pump()
        XCTAssertEqual(source.pacer?.seedKbps, 350, "seeded at the conservative GATT prior")
        for i in 0..<20 {   // 20 x 6 KB = 120 KB offered at once: about 2.3 s at the paced 52 500 B/s
            source.sendVideo(flags: i == 0 ? StreamProtocol.flagKeyFrame : 0, presentationTimeUs: Int64(i) * 66_666, payload: Data(repeating: 1, count: 6_000))
        }
        try pipe.pump()
        XCTAssertLessThan(viewer.videoPackets, 3, "held in the app queue, not written ahead of the link")
        // The transport driver pumps every 100 ms; the pacer releases what one link second carries.
        func second() throws { for _ in 0..<10 { try pipe.advance(0.1) } }
        try second()
        let afterOne = viewer.videoPackets
        XCTAssertTrue((7...11).contains(afterOne), "about one second of link time: \(afterOne)")
        // The viewer's on-time report (unmeasured, media arriving) while the source queue is over 0.5 s old: +25%.
        try second(); try second()   // the next on-time report is due 2 s after the first
        XCTAssertGreaterThanOrEqual(source.seedRaises, 1, "seed raised: \(source.pacer?.seedKbps ?? 0)")
        XCTAssertGreaterThan(source.pacer?.seedKbps ?? 0, 350)
        for _ in 0..<3 { try second() }
        XCTAssertEqual(viewer.videoPackets, 20, "everything arrives, in order, nothing dropped")
    }

    func testDueRule() {
        XCTAssertTrue(StreamViewerEngine.onTimeReportDue(enabled: true, measured: false, late: false, mediaArrived: true, sinceLastReport: 2))
        XCTAssertFalse(StreamViewerEngine.onTimeReportDue(enabled: true, measured: false, late: false, mediaArrived: true, sinceLastReport: 1.9))
        XCTAssertFalse(StreamViewerEngine.onTimeReportDue(enabled: true, measured: true, late: false, mediaArrived: true, sinceLastReport: 5))
        XCTAssertFalse(StreamViewerEngine.onTimeReportDue(enabled: true, measured: false, late: true, mediaArrived: true, sinceLastReport: 5))
        XCTAssertFalse(StreamViewerEngine.onTimeReportDue(enabled: true, measured: false, late: false, mediaArrived: false, sinceLastReport: 5))
        XCTAssertFalse(StreamViewerEngine.onTimeReportDue(enabled: false, measured: false, late: false, mediaArrived: true, sinceLastReport: 5))
    }

    func testLiveMediaStatesDecodeAsLiveVariants() throws {
        XCTAssertEqual(try StreamLifecycleState(decoding: Data([4])), .liveMuted)
        XCTAssertEqual(try StreamLifecycleState(decoding: Data([5])), .liveCameraOff)
        let both = try StreamLifecycleState(decoding: Data([6]))
        XCTAssertTrue(both.isLive && both.microphoneMuted && both.cameraOff)
        XCTAssertFalse(StreamLifecycleState.paused.isLive)
        XCTAssertThrowsError(try StreamLifecycleState(decoding: Data([7])))
        XCTAssertThrowsError(try StreamLifecycleState(decoding: Data([0])))
    }
}

/// Experimental audio-only live end to end (iPhone source to iPhone listener over the in-memory pipe): BTL1 header,
/// signed config and 200 ms records, marker agreement both ways, and a forged record ending the stream.
final class AudioLiveEngineTests: XCTestCase {
    private let header = StreamHeader(width: 640, height: 360, fps: 15, codecId: StreamProtocol.codecVP9, includeAudio: true)

    private func record(_ signer: AudioLiveSigner, at pts: Int64) throws -> MediaPacket {
        let units = (0..<10).map { MediaPacket(flags: StreamProtocol.flagAudio, presentationTimeUs: pts + Int64($0) * 20_000, payload: Data([0x08, 1, 2, 3])) }
        let body = try MediaPacket.combineAudio(units)
        return try signer.sign(flags: body.flags, presentationTimeUs: body.presentationTimeUs, body: body.payload)
    }

    func testRadioSourceToListener() throws {
        for gatt in [false, true] {
            let sourceId = SoftwareSigningIdentity(), viewerId = SoftwareSigningIdentity()
            let signer = try AudioLiveSigner(identity: sourceId, streamId: UUID(), preset: AudioLive.presetVoice)
            let transport: MeshTransport = gatt ? .gatt : .l2cap
            let source = StreamSourceEngine(transport: transport, identity: sourceId, header: header, expectedViewerPrefix: viewerId.nodeId.prefix, audioLive: signer)
            let viewer = StreamViewerEngine(transport: transport, identity: viewerId, decodeMask: 0, expectedAdjacentPrefix: sourceId.nodeId.prefix, expectAudioOnly: true, allowAudioOnly: true)
            var events: [StreamViewerEngine.Event] = []; viewer.onEvent = { events.append($0) }
            let pipe = Pipe(source, viewer, gatt: gatt)
            try source.start(now: 0); try viewer.start(now: 0); try pipe.pump()
            XCTAssertTrue(source.ready); XCTAssertTrue(source.useMeshEnvelope)
            XCTAssertEqual(viewer.audioLiveHeader, signer.header)
            XCTAssertEqual(viewer.meshStreamId, signer.streamId)
            source.sendSignedAudio(try signer.sign(flags: StreamProtocol.flagAudio | StreamProtocol.flagCodecConfig, presentationTimeUs: 0, body: OpusHead.make()))
            for i in 0..<3 { source.sendSignedAudio(try record(signer, at: Int64(i) * 200_000)) }
            try pipe.pump()
            XCTAssertEqual(viewer.audioPackets, 30)
            XCTAssertEqual(viewer.audioLiveGuard?.verifiedRecords, 4)
            XCTAssertTrue(events.contains(.audioConfig(OpusHead.make())))
            source.setPaused(true); try pipe.pump()
            for _ in 0..<4 { try pipe.advance(1) }
            source.setPaused(false); try pipe.pump()
            source.sendSignedAudio(try record(signer, at: 60_000_000)) // resume at a later time: baseline restarted
            try pipe.pump()
            XCTAssertEqual(viewer.audioPackets, 40)
            source.endStream(); try pipe.pump()
            XCTAssertTrue(events.contains(.state(.ended)))
            XCTAssertEqual(viewer.phase, .closed)
        }
    }

    func testMarkerMismatchAndForgeryFailClosed() throws {
        let sourceId = SoftwareSigningIdentity(), viewerId = SoftwareSigningIdentity()
        do { // audio-live switch off: a BTL1 header is an unsupported header, not a marker mismatch (Android allowAudioOnly)
            let signer = try AudioLiveSigner(identity: sourceId, streamId: UUID(), preset: AudioLive.presetVoice)
            let source = StreamSourceEngine(transport: .l2cap, identity: sourceId, header: header, expectedViewerPrefix: nil, audioLive: signer)
            let viewer = StreamViewerEngine(transport: .l2cap, identity: viewerId, decodeMask: NodeCapabilities.codecVP9, expectedAdjacentPrefix: nil)
            let pipe = Pipe(source, viewer); try source.start(now: 0); try viewer.start(now: 0); try pipe.pump()
            XCTAssertEqual(viewer.phase, .closed)
            XCTAssertNil(viewer.audioLiveHeader)
            XCTAssertNil(viewer.audioMarkerMismatch, "no route penalty: this phone simply does not take audio-only streams")
            XCTAssertEqual(viewer.closeReason?.contains("Unsupported stream header"), true, viewer.closeReason ?? "")
        }
        do { // radio stream, unmarked offer
            let signer = try AudioLiveSigner(identity: sourceId, streamId: UUID(), preset: AudioLive.presetVoice)
            let source = StreamSourceEngine(transport: .l2cap, identity: sourceId, header: header, expectedViewerPrefix: nil, audioLive: signer)
            let viewer = StreamViewerEngine(transport: .l2cap, identity: viewerId, decodeMask: NodeCapabilities.codecVP9, expectedAdjacentPrefix: nil, allowAudioOnly: true)
            let pipe = Pipe(source, viewer); try source.start(now: 0); try viewer.start(now: 0); try pipe.pump()
            XCTAssertEqual(viewer.phase, .closed)
            XCTAssertNil(viewer.audioLiveHeader)
            XCTAssertEqual(viewer.audioMarkerMismatch, false)
        }
        do { // video stream, offer marked audio only
            let source = StreamSourceEngine(transport: .l2cap, identity: sourceId, header: header, expectedViewerPrefix: nil)
            let viewer = StreamViewerEngine(transport: .l2cap, identity: viewerId, decodeMask: NodeCapabilities.codecVP9, expectedAdjacentPrefix: nil, expectAudioOnly: true, allowAudioOnly: true)
            let pipe = Pipe(source, viewer); try source.start(now: 0); try viewer.start(now: 0); try pipe.pump()
            XCTAssertEqual(viewer.phase, .closed)
            XCTAssertNil(viewer.header)
            XCTAssertEqual(viewer.audioMarkerMismatch, true)
        }
        do { // a record signed by another stream key
            let signer = try AudioLiveSigner(identity: sourceId, streamId: UUID(), preset: AudioLive.presetVoice)
            let forger = try AudioLiveSigner(identity: sourceId, streamId: signer.streamId, preset: AudioLive.presetVoice)
            let source = StreamSourceEngine(transport: .l2cap, identity: sourceId, header: header, expectedViewerPrefix: nil, audioLive: signer)
            let viewer = StreamViewerEngine(transport: .l2cap, identity: viewerId, decodeMask: 0, expectedAdjacentPrefix: nil, expectAudioOnly: true, allowAudioOnly: true)
            let pipe = Pipe(source, viewer); try source.start(now: 0); try viewer.start(now: 0); try pipe.pump()
            source.sendSignedAudio(try record(signer, at: 0)); try pipe.pump()
            XCTAssertEqual(viewer.audioPackets, 10)
            source.sendSignedAudio(try record(forger, at: 200_000)); try pipe.pump()
            XCTAssertEqual(viewer.audioPackets, 10)
            XCTAssertEqual(viewer.phase, .closed)
        }
    }
}

final class AudioLiveSheddingTests: XCTestCase {
    func testAudioQueueShedsOldestWholeRecordsOnly() {
        var q = OutboundQueues()
        func item(_ at: TimeInterval) -> OutboundItem { OutboundItem(kind: .raw(Data([1])), enqueuedAt: at, isKeyFrame: false, closeAfter: false) }
        _ = q.push(item(0), .control)
        for i in 0..<20 { _ = q.push(item(Double(i) * 0.2), .audio) }   // 0.0 ... 3.8 s
        XCTAssertEqual(q.shedAudio(now: 2.9, trigger: 3, keep: 1.5), 0, "under the trigger")
        let dropped = q.shedAudio(now: 4.0, trigger: 3, keep: 1.5)
        XCTAssertEqual(dropped, 13, "records older than 1.5 s at 4.0 s: 0.0 ... 2.4")
        XCTAssertEqual(q.audioAge(now: 4.0), 1.4, accuracy: 1e-9)
        XCTAssertEqual(q.count, 1 + 7, "the control item is never shed")
    }
}

/// PROTOCOL ingress budgets: reject an over-limit ciphertext from its length alone, before reading its body.
final class AudioLiveRecordLimitTests: XCTestCase {
    private func pair(_ transport: MeshTransport) throws -> (StreamSourceEngine, StreamViewerEngine, AudioLiveSigner) {
        let sourceId = SoftwareSigningIdentity(), viewerId = SoftwareSigningIdentity()
        let signer = try AudioLiveSigner(identity: sourceId, streamId: UUID(), preset: AudioLive.presetVoice)
        let header = StreamHeader(width: 640, height: 360, fps: 15, codecId: StreamProtocol.codecVP9, includeAudio: true)
        let source = StreamSourceEngine(transport: transport, identity: sourceId, header: header,
                                        expectedViewerPrefix: viewerId.nodeId.prefix, audioLive: signer)
        let viewer = StreamViewerEngine(transport: transport, identity: viewerId, decodeMask: 0,
                                        expectedAdjacentPrefix: sourceId.nodeId.prefix, expectAudioOnly: true, allowAudioOnly: true)
        try source.start(now: 0); try viewer.start(now: 0)
        // Link hellos, then endpoint hellos; leave the stream header queued at the source.
        for _ in 0..<2 {
            viewer.receive(try XCTUnwrap(source.nextOutgoing(now: 0)), now: 0)
            source.receive(try XCTUnwrap(viewer.nextOutgoing(now: 0)), now: 0)
        }
        XCTAssertEqual(viewer.phase, .open)
        XCTAssertNil(viewer.audioLiveHeader)
        return (source, viewer, signer)
    }

    func testOversizedRecordFailsBeforeItsCiphertextArrives() throws {
        for transport: MeshTransport in [.gatt, .l2cap] {
            for afterHeader in [false, true] {
                let (source, viewer, _) = try pair(transport)
                if afterHeader {
                    viewer.receive(try XCTUnwrap(source.nextOutgoing(now: 0)), now: 0)
                    XCTAssertNotNil(viewer.audioLiveHeader)
                }
                let limit = afterHeader ? 28 * 1024 : 4 * 1024
                let lengthOnly = SecureRecordProtocol.header(type: .meshEnvelope, sequence: viewer.link.receivedRecords,
                                                            ciphertextBytes: limit + 1)
                viewer.receive(lengthOnly, now: 0)
                XCTAssertEqual(viewer.phase, .closed, "cap=\(limit), transport=\(transport)")
            }
        }
    }
    func testCoalescedHeaderAndLargeSignedBatchUseTheVerifiedHeaderCap() throws {
        for transport: MeshTransport in [.gatt, .l2cap] {
            let (source, viewer, signer) = try pair(transport)
            source.sendSignedAudio(try signer.sign(flags: StreamProtocol.flagAudio | StreamProtocol.flagCodecConfig,
                                                  presentationTimeUs: 0, body: OpusHead.make()))
            var opus = Data(repeating: 0, count: 1275); opus[0] = 0xf8
            let units = (0..<20).map {
                MediaPacket(flags: StreamProtocol.flagAudio, presentationTimeUs: Int64($0) * 20_000, payload: opus)
            }
            let batch = try MediaPacket.combineAudio(units)
            source.sendSignedAudio(try signer.sign(flags: batch.flags, presentationTimeUs: batch.presentationTimeUs, body: batch.payload))
            var coalesced = Data()
            while let record = source.nextOutgoing(now: 0) { coalesced.append(record) }
            XCTAssertGreaterThan(coalesced.count, 4 * 1024)
            viewer.receive(coalesced, now: 0)
            XCTAssertEqual(viewer.phase, .open, viewer.closeReason ?? "")
            XCTAssertEqual(viewer.audioLiveGuard?.verifiedRecords, 2)
            XCTAssertEqual(viewer.audioPackets, 20)
        }
    }

}

final class StreamRoutePenaltyEngineTests: XCTestCase {
    func testKnownParentIsBlockedOnlyAfterItsLinkAuthenticates() throws {
        let parent = SoftwareSigningIdentity(), child = SoftwareSigningIdentity()
        let signer = try AudioLiveSigner(identity: parent, streamId: UUID(), preset: AudioLive.presetVoice)
        let header = StreamHeader(width: 640, height: 360, fps: 15, codecId: StreamProtocol.codecVP9, includeAudio: true)
        let source = StreamSourceEngine(transport: .gatt, identity: parent, header: header, expectedViewerPrefix: nil, audioLive: signer)
        let viewer = StreamViewerEngine(transport: .gatt, identity: child, decodeMask: 0, expectedAdjacentPrefix: parent.nodeId.prefix, expectAudioOnly: true, allowAudioOnly: true)
        var checked: NodeId?
        viewer.isParentBlocked = { checked = $0; return true }
        let pipe = Pipe(source, viewer, gatt: true)
        try source.start(now: 0); try viewer.start(now: 0); try pipe.pump()
        XCTAssertEqual(checked, parent.nodeId)
        XCTAssertEqual(viewer.phase, .closed)
        XCTAssertNil(viewer.audioLiveHeader)
        XCTAssertNil(viewer.audioMarkerMismatch)
    }
}


final class AudioLiveRelayEngineTests: XCTestCase {
    func testSignedChainBootstrapControlsEndAndForgeryOnBothTransports() throws {
        for gatt in [false, true] {
          for forge in [false, true] {
            let sourceId = SoftwareSigningIdentity(), relayId = SoftwareSigningIdentity(), childId = SoftwareSigningIdentity()
            let t: MeshTransport = gatt ? .gatt : .l2cap
            let signer = try AudioLiveSigner(identity: sourceId, streamId: UUID(), preset: AudioLive.presetVoice)
            let placeholder = StreamHeader(width: 640, height: 360, fps: 15, codecId: StreamProtocol.codecVP9, includeAudio: true)
            let source = StreamSourceEngine(transport: t, identity: sourceId, header: placeholder, expectedViewerPrefix: relayId.nodeId.prefix, audioLive: signer)
            let relay = StreamViewerEngine(transport: t, identity: relayId, decodeMask: 0, expectedAdjacentPrefix: sourceId.nodeId.prefix, maxChildren: 1, expectAudioOnly: true, allowAudioOnly: true)
            let core = StreamForwardingCore(localNodeId: relayId.nodeId, upstreamPeerNodeId: sourceId.nodeId, streamId: signer.streamId, sourceNodeId: sourceId.nodeId, audioOnly: true)
            var hop: StreamForwarderEngine?
            var originals: [MeshEnvelope] = [], copies: [MeshEnvelope] = []
            var requests = 0
            source.onEvent = { if case .keyFrameRequested = $0 { requests += 1 } }
            relay.onEvent = {
                if case .envelope(let e) = $0 {
                    originals.append(e)
                    if case .forward(let copy, _) = try? core.receive(e) { hop?.forward(copy) }
                }
            }
            let parentPipe = Pipe(source, relay, gatt: gatt)
            try source.start(now: 0); try relay.start(now: 0); try parentPipe.pump()
            source.sendSignedAudio(try signer.sign(flags: StreamProtocol.flagAudio | StreamProtocol.flagCodecConfig, presentationTimeUs: 0, body: OpusHead.make()))
            try parentPipe.pump()
            let grant = ForwardedStreamGrant(sourceNodeId: sourceId.nodeId, streamId: signer.streamId, key: try XCTUnwrap(relay.mediaOpenKey))
            let forwarder = StreamForwarderEngine(transport: t, identity: relayId, grant: grant, codecId: 0, expectedChildPrefix: childId.nodeId.prefix, audioOnly: true)
            let child = StreamViewerEngine(transport: t, identity: childId, decodeMask: 0, expectedAdjacentPrefix: relayId.nodeId.prefix, expectedMediaSource: sourceId.nodeId, expectAudioOnly: true, allowAudioOnly: true)
            hop = forwarder
            forwarder.onEvent = {
                if case .childAuthenticated(let id, _) = $0 { for e in (try? core.addChild(id)) ?? [] { forwarder.forward(e) } }
                if case .keyFrameRequested = $0 { requests += 1 }
                if case .endAcknowledged = $0 { relay.releaseEndAck() }
            }
            var events: [StreamViewerEngine.Event] = []
            child.onEvent = { events.append($0); if case .envelope(let e) = $0 { copies.append(e) } }
            let childPipe = Pipe(forwarder, child, gatt: gatt)
            try forwarder.start(now: 0); try child.start(now: 0); try childPipe.pump()
            XCTAssertEqual(child.audioLiveHeader, signer.header)
            XCTAssertEqual(child.mediaSourceNodeId, sourceId.nodeId)
            XCTAssertEqual(child.peerLinkNodeId, relayId.nodeId)
            let units = (0..<10).map { MediaPacket(flags: StreamProtocol.flagAudio, presentationTimeUs: Int64($0) * 20_000, payload: Data([0xf8, 0xff, 0xfe])) }
            let batch = try MediaPacket.combineAudio(units)
            source.sendSignedAudio(try signer.sign(flags: batch.flags, presentationTimeUs: 0, body: batch.payload))
            try parentPipe.pump(); try childPipe.pump()
            XCTAssertEqual(child.audioPackets, 10)
            XCTAssertEqual(child.audioLiveGuard?.verifiedRecords, 2)
            XCTAssertTrue(events.contains(.audioConfig(OpusHead.make())))
            for copy in copies {
                let original = try XCTUnwrap(originals.first { $0.sequence == copy.sequence })
                XCTAssertEqual(copy.payload, original.payload)
                XCTAssertEqual(copy.sourceNodeId, original.sourceNodeId)
                XCTAssertEqual(copy.ttl, original.ttl - 1)
            }
            source.setPaused(true); try parentPipe.pump(); try childPipe.pump()
            XCTAssertTrue(events.contains(.state(.paused)))
            source.setPaused(false); try parentPipe.pump(); try childPipe.pump()
            relay.requestKeyFrame(); child.requestKeyFrame()
            try parentPipe.pump(); try childPipe.pump()
            XCTAssertEqual(requests, 0)
            if forge {
                let forger = try AudioLiveSigner(identity: sourceId, streamId: signer.streamId, preset: AudioLive.presetVoice)
                let before = originals.count
                source.sendSignedAudio(try forger.sign(flags: StreamProtocol.flagAudio, presentationTimeUs: 200_000, body: Data([0xf8, 0xff, 0xfe])))
                try parentPipe.pump(); try childPipe.pump()
                XCTAssertEqual(relay.phase, .closed)
                XCTAssertEqual(originals.count, before, "an invalid signature never reaches forwarding")
                XCTAssertEqual(child.audioPackets, 10)
            } else {
                relay.holdEndAck = true
                source.endStream(); try parentPipe.pump(); try childPipe.pump(); try parentPipe.pump()
                XCTAssertTrue(events.contains(.state(.ended)))
                XCTAssertEqual(child.phase, .closed)
                XCTAssertEqual(source.phase, .closed)
                XCTAssertEqual(forwarder.phase, .closed)
            }
          }
        }
    }
    private func pair(ageBound: Bool = true) throws -> (StreamForwarderEngine, StreamViewerEngine, Pipe, ForwardedStreamGrant) {
        let p = SoftwareSigningIdentity(), c = SoftwareSigningIdentity(), s = SoftwareSigningIdentity()
        let grant = ForwardedStreamGrant(sourceNodeId: s.nodeId, streamId: UUID(), key: Data(repeating: 9, count: 32))
        let hop = StreamForwarderEngine(transport: .l2cap, identity: p, grant: grant, codecId: 0, expectedChildPrefix: c.nodeId.prefix, audioOnly: true)
        hop.audioAgeBound = ageBound
        let child = StreamViewerEngine(transport: .l2cap, identity: c, decodeMask: 0, expectedAdjacentPrefix: p.nodeId.prefix, expectAudioOnly: true, allowAudioOnly: true)
        let pipe = Pipe(hop, child)
        try hop.start(now: 0); try child.start(now: 0); try pipe.pump()
        XCTAssertTrue(hop.ready)
        return (hop, child, pipe, grant)
    }
    private func envelope(_ grant: ForwardedStreamGrant, _ seq: UInt64, _ flags: UInt8) -> MeshEnvelope {
        MeshEnvelope(streamId: grant.streamId, sourceNodeId: grant.sourceNodeId, sequence: seq, ttl: 4, flags: flags, payload: Data(repeating: 7, count: 40))
    }
    func testShedPredicatePreservesConfigControlAndOddFlags() throws {
        let (hop, child, _, grant) = try pair()
        hop.forward(envelope(grant, 0, 10), now: 0); hop.forward(envelope(grant, 1, 16), now: 0)
        for i in 0..<9 { hop.forward(envelope(grant, UInt64(i + 2), i % 2 == 0 ? 8 : 72), now: Double(i) * 0.5) }
        hop.forward(envelope(grant, 11, 24), now: 4)
        XCTAssertGreaterThan(hop.shedAudioRecords, 0)
        XCTAssertFalse(hop.isWithdrawing)
        var kept: [MeshEnvelope] = []
        while let bytes = hop.nextOutgoing(now: 4) {
            for output in try child.link.receive(bytes) { if case .record(let r) = output, r.type == .meshEnvelope { kept.append(try MeshEnvelope(decoding: r.payload)) } }
        }
        XCTAssertEqual(Array(kept.prefix(2)).map(\.sequence), [0, 1])
        XCTAssertEqual(kept.last?.sequence, 11)
        XCTAssertTrue(kept.contains { $0.sequence == 10 })
        XCTAssertLessThan(kept.count, 12)
    }
    func testShedRateAndThirtySecondControlArmWithdrawChild() throws {
        for bounded in [true, false] {
            let (hop, child, pipe, grant) = try pair(ageBound: bounded)
            var events: [StreamViewerEngine.Event] = []
            child.onEvent = { events.append($0) }
            if bounded {
                for i in 0..<25 { hop.forward(envelope(grant, UInt64(i), 72), now: Double(i) * 0.2) }
                XCTAssertGreaterThan(hop.shedAudioRecords, 0)
            } else {
                hop.forward(envelope(grant, 0, 72), now: 0)
                hop.receive(try child.link.seal(.linkHeartbeat, Data([1])), now: 29); hop.tick(now: 29)
                XCTAssertFalse(hop.isWithdrawing)
                hop.receive(try child.link.seal(.linkHeartbeat, Data([1])), now: 31); hop.tick(now: 31)
                XCTAssertEqual(hop.shedAudioRecords, 0)
            }
            XCTAssertTrue(hop.isWithdrawing)
            XCTAssertEqual(hop.queuedEnvelopes, 0)
            pipe.now = bounded ? 5 : 31
            try pipe.pump()
            XCTAssertTrue(events.contains { if case .routeWithdrawn = $0 { return true }; return false })
            XCTAssertEqual(child.phase, .closed)
        }
    }
}
