import XCTest
@testable import NearbyCore

/// Experimental peer labels through the engines: positions and gating as Android's naming phase 1.
final class LabelEngineTests: XCTestCase {
    let vp9 = NodeCapabilities.codecVP9

    private func pump(_ a: MeshConnection, _ b: MeshConnection, now: TimeInterval = 0) {
        for _ in 0..<50 {
            var moved = false
            while let d = a.nextOutgoing(now: now) { b.receive(d, now: now); moved = true }
            while let d = b.nextOutgoing(now: now) { a.receive(d, now: now); moved = true }
            if !moved { return }
        }
    }

    func testCallNamesAndCalleeNameOnlyWithAccept() throws {
        let callerId = SoftwareSigningIdentity(), calleeId = SoftwareSigningIdentity()
        let caller = CallEngine(role: .caller, transport: .gatt, identity: callerId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                labels: CallLabelOptions(localName: "Asha"))
        let callee = CallEngine(role: .callee, transport: .gatt, identity: calleeId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                labels: CallLabelOptions(localName: "Ravi"))
        var callerEvents: [CallEngine.Event] = [], calleeEvents: [CallEngine.Event] = []
        caller.onEvent = { callerEvents.append($0) }; callee.onEvent = { calleeEvents.append($0) }
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        XCTAssertTrue(caller.peerAcceptsLabels && callee.peerAcceptsLabels)
        XCTAssertTrue(calleeEvents.contains(.peerLabels(name: "Asha")), "buffered before Invite, verified on Invite (R3)")
        XCTAssertFalse(callerEvents.contains { if case .peerLabels = $0 { return true }; return false }, "R1: no callee name before Accept")
        try callee.accept(as: .voice); pump(caller, callee, now: 3)
        XCTAssertTrue(callerEvents.contains(.peerLabels(name: "Ravi")))
        XCTAssertEqual(caller.state?.phase, .active)
    }

    func testDeclinedCallNeverRevealsCalleeNameAndVerifiedCallerGetsItAtRinging() throws {
        let calleeId = SoftwareSigningIdentity()
        let caller = CallEngine(role: .caller, transport: .l2cap, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                labels: CallLabelOptions(localName: nil))
        let callee = CallEngine(role: .callee, transport: .l2cap, identity: calleeId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                labels: CallLabelOptions(localName: "Ravi"))
        var callerEvents: [CallEngine.Event] = []
        caller.onEvent = { callerEvents.append($0) }
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        try callee.decline(.busy); pump(caller, callee)
        XCTAssertFalse(callerEvents.contains { if case .peerLabels = $0 { return true }; return false })

        let caller2 = CallEngine(role: .caller, transport: .l2cap, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                 labels: CallLabelOptions(localName: nil))
        let callee2 = CallEngine(role: .callee, transport: .l2cap, identity: calleeId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                 labels: CallLabelOptions(localName: "Ravi", isVerifiedPeer: { _ in true }))
        var events2: [CallEngine.Event] = []
        caller2.onEvent = { events2.append($0) }
        try caller2.start(now: 0); try callee2.start(now: 0); pump(caller2, callee2)
        XCTAssertTrue(events2.contains(.peerLabels(name: "Ravi")), "verified contact gets the name at Ringing")
    }

    func testFeatureOffOnOneSideSendsNothing() throws {
        let caller = CallEngine(role: .caller, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                labels: CallLabelOptions(localName: "Asha"))
        let callee = CallEngine(role: .callee, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9)
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        XCTAssertFalse(caller.peerAcceptsLabels)
        XCTAssertEqual(callee.state?.phase, .incomingRinging, "the old peer never saw a type-10 record (it would have failed closed)")
        XCTAssertEqual(callee.endpointCapabilities.transportMask & PeerLabelFeature.capabilityBit, 0)
    }

    /// "Who sees my name" on real-key calls: Nobody sends no name; "Only my contacts" sends the caller's name only to a
    /// verified contact. No call subject is ever sent.
    func testTheAudienceDecidesWhetherTheNameIsSent() throws {
        func call(callerAudience: NamesAudience, calleeAudience: NamesAudience, verified: Bool) throws -> (CallEngine, CallEngine) {
            let caller = CallEngine(role: .caller, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                    labels: CallLabelOptions(localName: "Asha", audience: callerAudience,
                                                             isVerifiedPeer: { _ in verified }))
            let callee = CallEngine(role: .callee, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                    labels: CallLabelOptions(localName: "Ravi", audience: calleeAudience))
            try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
            try callee.accept(as: .voice); pump(caller, callee, now: 3)
            XCTAssertEqual(caller.state?.phase, .active)
            return (caller, callee)
        }
        var (caller, callee) = try call(callerAudience: .nobody, calleeAudience: .nobody, verified: true)
        XCTAssertNil(callee.labelInbox.text(.personName))
        XCTAssertNil(callee.labelInbox.text(.callSubject), "no subject is ever sent")
        XCTAssertNil(caller.labelInbox.text(.personName))
        (caller, callee) = try call(callerAudience: .verified, calleeAudience: .everyone, verified: false)
        XCTAssertNil(callee.labelInbox.text(.personName), "not a verified contact")
        XCTAssertEqual(caller.labelInbox.text(.personName), "Ravi", "the callee's own audience lets its name go with Accept")
        (caller, callee) = try call(callerAudience: .verified, calleeAudience: .everyone, verified: true)
        XCTAssertEqual(callee.labelInbox.text(.personName), "Asha")
    }

    /// P2-1: under "Only my contacts" a relayed rotating call releases the caller's name at the OPENING, but only to a
    /// verified contact.
    func testARelayedVerifiedCallSendsTheCallersNameAfterTheOpeningOnlyToAVerifiedContact() throws {
        for verified in [true, false] {
            let calleeId = SoftwareSigningIdentity()
            let entry = RotatingDiscoveryIds.ownEntry(presenceKey: Data(repeating: 9, count: 32), nodeId: calleeId.nodeId.bytes,
                                                      epoch: 1_990_656, role: 0)
            var offer = DiscoveryAnnouncement(nodeIdPrefix: entry.rdi,
                                              flags: DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable,
                                              capabilitySummary: 1, streamToken: 0, routeCost: 1)
            offer.rotating = true
            let caller = CallEngine(role: .caller, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .voice,
                                    encodeMask: vp9, decodeMask: vp9, expectedPeerPrefix: entry.rdi,
                                    labels: CallLabelOptions(localName: "Asha", audience: .verified, isVerifiedPeer: { _ in verified }),
                                    rotating: RotatingCallOptions(selected: offer, wallEpoch: { 1_990_656 }))
            let callee = CallEngine(role: .callee, transport: .gatt, identity: calleeId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                    labels: CallLabelOptions(localName: "Ravi"),
                                    rotating: RotatingCallOptions(entries: { [entry] }))
            try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
            XCTAssertEqual(callee.state?.phase, .incomingRinging, "\(caller.closeReason ?? "")")
            XCTAssertEqual(callee.labelInbox.text(.personName), verified ? "Asha" : nil, "verified contact: \(verified)")
        }
    }

    func testStreamTitleDirectAndMesh() throws {
        for mesh in [false, true] {
            let sourceId = SoftwareSigningIdentity(), viewerId = SoftwareSigningIdentity()
            let header = StreamHeader(width: 360, height: 640, fps: 15, codecId: StreamProtocol.codecVP9, includeAudio: true)
            let source = StreamSourceEngine(transport: .gatt, identity: sourceId, header: header, expectedViewerPrefix: nil, labels: true, title: "Flood update")
            let viewer = StreamViewerEngine(transport: .gatt, identity: viewerId, decodeMask: vp9, expectedAdjacentPrefix: nil,
                                            maxChildren: mesh ? 1 : 0, labels: true)
            var events: [StreamViewerEngine.Event] = []
            viewer.onEvent = { events.append($0) }
            try source.start(now: 0); try viewer.start(now: 0); pump(source, viewer)
            XCTAssertTrue(source.labelsSent)
            XCTAssertTrue(events.contains(.title("Flood update")), "mesh \(mesh)")
            XCTAssertEqual(viewer.header, header)
        }
        // A source with labels but no title sends an empty container; the viewer still reads its header.
        let source = StreamSourceEngine(transport: .l2cap, identity: SoftwareSigningIdentity(), header: StreamHeader(width: 360, height: 640, fps: 15, codecId: 2, includeAudio: false),
                                        expectedViewerPrefix: nil, labels: true, title: nil)
        let viewer = StreamViewerEngine(transport: .l2cap, identity: SoftwareSigningIdentity(), decodeMask: vp9, expectedAdjacentPrefix: nil, labels: true)
        try source.start(now: 0); try viewer.start(now: 0); pump(source, viewer)
        XCTAssertNotNil(viewer.header); XCTAssertNil(viewer.labelInbox.text(.streamTitle))
    }
}
