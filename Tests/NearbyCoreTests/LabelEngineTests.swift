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

    func testCallNamesSubjectAndCalleeNameOnlyWithAccept() throws {
        let callerId = SoftwareSigningIdentity(), calleeId = SoftwareSigningIdentity()
        let caller = CallEngine(role: .caller, transport: .gatt, identity: callerId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                labels: CallLabelOptions(localName: "Asha", subject: "Water at the school"))
        let callee = CallEngine(role: .callee, transport: .gatt, identity: calleeId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                labels: CallLabelOptions(localName: "Ravi", subject: nil))
        var callerEvents: [CallEngine.Event] = [], calleeEvents: [CallEngine.Event] = []
        caller.onEvent = { callerEvents.append($0) }; callee.onEvent = { calleeEvents.append($0) }
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        XCTAssertTrue(caller.peerAcceptsLabels && callee.peerAcceptsLabels)
        XCTAssertTrue(calleeEvents.contains(.peerLabels(name: "Asha", subject: "Water at the school")), "buffered before Invite, verified on Invite (R3)")
        XCTAssertFalse(callerEvents.contains { if case .peerLabels = $0 { return true }; return false }, "R1: no callee name before Accept")
        try callee.accept(as: .voice); pump(caller, callee, now: 3)
        XCTAssertTrue(callerEvents.contains(.peerLabels(name: "Ravi", subject: nil)))
        XCTAssertEqual(caller.state?.phase, .active)
    }

    func testDeclinedCallNeverRevealsCalleeNameAndVerifiedCallerGetsItAtRinging() throws {
        let calleeId = SoftwareSigningIdentity()
        let caller = CallEngine(role: .caller, transport: .l2cap, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                labels: CallLabelOptions(localName: nil, subject: nil))
        let callee = CallEngine(role: .callee, transport: .l2cap, identity: calleeId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                labels: CallLabelOptions(localName: "Ravi", subject: nil))
        var callerEvents: [CallEngine.Event] = []
        caller.onEvent = { callerEvents.append($0) }
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        try callee.decline(.busy); pump(caller, callee)
        XCTAssertFalse(callerEvents.contains { if case .peerLabels = $0 { return true }; return false })

        let caller2 = CallEngine(role: .caller, transport: .l2cap, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                 labels: CallLabelOptions(localName: nil, subject: nil))
        let callee2 = CallEngine(role: .callee, transport: .l2cap, identity: calleeId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                 labels: CallLabelOptions(localName: "Ravi", subject: nil, isVerifiedPeer: { _ in true }))
        var events2: [CallEngine.Event] = []
        caller2.onEvent = { events2.append($0) }
        try caller2.start(now: 0); try callee2.start(now: 0); pump(caller2, callee2)
        XCTAssertTrue(events2.contains(.peerLabels(name: "Ravi", subject: nil)), "verified contact gets the name at Ringing (R1)")
    }

    func testFeatureOffOnOneSideSendsNothing() throws {
        let caller = CallEngine(role: .caller, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                labels: CallLabelOptions(localName: "Asha", subject: "Hi"))
        let callee = CallEngine(role: .callee, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9)
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        XCTAssertFalse(caller.peerAcceptsLabels)
        XCTAssertEqual(callee.state?.phase, .incomingRinging, "the old peer never saw a type-10 record (it would have failed closed)")
        XCTAssertEqual(callee.endpointCapabilities.transportMask & PeerLabelFeature.capabilityBit, 0)
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
