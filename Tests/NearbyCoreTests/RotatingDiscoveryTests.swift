import XCTest
@testable import NearbyCore

/// Experimental rotating discovery IDs: the reviewed shared vectors (Android RotatingDiscoveryTest), the RV4
/// clock, pins, tarpit, window, and BDO1 over real call engines (Android RotatingDiscoveryLinkTest).
final class RotatingDiscoveryTests: XCTestCase {
    let presenceKey = Data(0..<32)
    let nodeId = Data(hex: "a1b2c3d4e5f60718293a4b5c6d7e8f90")!
    let epoch: Int64 = 1_990_656

    func testDomainsAndEpoch() {
        XCTAssertEqual(RotatingDiscoveryIds.saltDomain.hex, "426c7565746f6f7468566964656f4d6573682f446973636f766572792f53616c742f3100")
        XCTAssertEqual(RotatingDiscoveryIds.idDomain.hex, "426c7565746f6f7468566964656f4d6573682f446973636f766572792f49642f3100")
        XCTAssertEqual(RotatingDiscoveryIds.wallEpoch(unixSeconds: 1_791_590_400), epoch)
        XCTAssertEqual(epoch, 0x001e6000)
    }

    func testSaltsAndIdsMatchTheReviewedVectors() {
        let vectors: [(Int64, UInt8, String, String)] = [
            (epoch, 0, "d8cbe82b78824c1ba08d0c4eed26502189e19ccccd180e46c4826c5ba47e7167", "44e69c0a7a7d"),
            (epoch, 1, "dcd9349e228e00ceb4a7ec2e7e023fc0c34c507f88e99934897105ca4fae84c0", "bb2d061f6480"),
            (epoch, 2, "e59970c8523f23a6b1b16a858daf75320e3291d6c86d0329df89a62899804335", "974ae410ea91"),
            (epoch + 1, 0, "7ece98afad0378297e68c9e2b59c1a1f88448a0c70b86d91f192f65d263a763b", "67aba670e65a"),
        ]
        for (e, role, salt, rdi) in vectors {
            let s = RotatingDiscoveryIds.salt(key: presenceKey, epoch: e, role: role)
            XCTAssertEqual(s.hex, salt)
            XCTAssertEqual(RotatingDiscoveryIds.rdi(nodeId: nodeId, epoch: e, role: role, salt: s).hex, rdi)
            XCTAssertEqual(RotatingDiscoveryIds.entry(saltKey: presenceKey, nodeId: nodeId, epoch: e, role: role).rdi.hex, rdi)
        }
    }

    func testLeaseKeysAndTheOwnersOwnId() {
        XCTAssertEqual(RotatingDiscoveryIds.week(of: epoch), 2962)
        XCTAssertEqual(RotatingDiscoveryIds.leaseKey(presenceKey: presenceKey, week: 2962).hex, "d4b8f2947b874084885be10af7cae3f5e2f5a3037d65bbd3da0af828245d568a")
        XCTAssertEqual(RotatingDiscoveryIds.leaseKey(presenceKey: presenceKey, week: 2963).hex, "b5d948c06d9ce94699b90f2d9feebfc49817a64422d5acadc7c58cfdae8e3fdc")
        let own = RotatingDiscoveryIds.ownEntry(presenceKey: presenceKey, nodeId: nodeId, epoch: epoch, role: 0)
        XCTAssertEqual(own.salt.hex, "f82bb42958807ae3f9b64ec0bccff4370d521b5719df26d6286c36e3d573265f")
        XCTAssertEqual(own.rdi.hex, "ddb0a80c67aa")
    }

    func testCompactV2VectorAndRejectionWhenOff() throws {
        var call = DiscoveryAnnouncement(nodeIdPrefix: Data(hex: "44e69c0a7a7d")!, flags: DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable,
                                         capabilitySummary: NodeCapabilities.codecVP9 | NodeCapabilities.codecAV1, streamToken: 0, routeCost: 0)
        call.rotating = true
        let uuid = try CompactAnnouncement.encode(call)
        XCTAssertEqual(uuid, "C8D6844E-69C0-A7A7-D0C0-000000000000")
        let decoded = try XCTUnwrap(CompactAnnouncement.decode(uuid, acceptRotating: true))
        XCTAssertTrue(decoded.rotating); XCTAssertEqual(decoded.nodeIdPrefix.hex, "44e69c0a7a7d")
        XCTAssertNil(CompactAnnouncement.decode(uuid), "compact v2 is rejected when rotating IDs are off")
        let v1 = try XCTUnwrap(CompactAnnouncement.decode("C8D64010-2030-4050-60C0-000000000000", acceptRotating: true))
        XCTAssertFalse(v1.rotating); XCTAssertEqual(v1.nodeIdPrefix.hex, "010203040506")
        // Phase 1: only call offers rotate.
        var stream = DiscoveryAnnouncement(nodeIdPrefix: Data(repeating: 1, count: 6), flags: DiscoveryAnnouncement.flagStreamAvailable, capabilitySummary: 1,
                                           streamToken: 0x80000001, routeCost: 0)
        stream.rotating = true
        XCTAssertThrowsError(try CompactAnnouncement.encode(stream))
    }

    func testAndroidVersion5AnnouncementVector() throws {
        let bytes = Data(hex: "0544e69c0a7a7d410300000000000000000000000000")!
        let a = try DiscoveryAnnouncement(decoding: bytes, acceptRotating: true)
        XCTAssertTrue(a.rotating); XCTAssertTrue(a.isPrivateCallOffer); XCTAssertEqual(a.nodeIdPrefix.hex, "44e69c0a7a7d")
        XCTAssertEqual(try a.encoded().hex, bytes.hex)
        XCTAssertThrowsError(try DiscoveryAnnouncement(decoding: bytes), "version 5 is rejected when off")
    }

    func testLinkOpeningVectorsAndRejections() throws {
        let entry = RotatingDiscoveryIds.entry(saltKey: presenceKey, nodeId: nodeId, epoch: epoch, role: 0)
        let one = try DiscoveryOpeningCodec.encode([entry])
        XCTAssertEqual(one.hex, "42444f31010144e69c0a7a7d001e600000d8cbe82b78824c1ba08d0c4eed26502189e19ccccd180e46c4826c5ba47e7167")
        XCTAssertEqual(try DiscoveryOpeningCodec.encode([]).hex, "42444f310100")
        XCTAssertEqual(try DiscoveryOpeningCodec.decode(one), [entry])
        XCTAssertTrue(try DiscoveryOpeningCodec.decode(Data(hex: "42444f310100")!).isEmpty)
        var bad: [Data] = []
        var m = one; m[0] = UInt8(ascii: "X"); bad.append(m)
        var v = one; v[4] = 2; bad.append(v)
        var c3 = one; c3[5] = 3; bad.append(c3)
        var c2 = one; c2[5] = 2; bad.append(c2)
        bad.append(one.prefix(one.count - 1)); bad.append(one + Data([0])); bad.append(Data(hex: "42444f31")!)
        for (i, b) in bad.enumerated() { XCTAssertThrowsError(try DiscoveryOpeningCodec.decode(b), "case \(i)") }
        XCTAssertThrowsError(try DiscoveryOpeningCodec.encode((0..<3).map { RotatingDiscoveryIds.entry(saltKey: presenceKey, nodeId: nodeId, epoch: epoch + Int64($0), role: 0) }))
    }

    private func selectedCall(_ rdi: Data, rotating: Bool = true) -> DiscoveryAnnouncement {
        var a = DiscoveryAnnouncement(nodeIdPrefix: rdi, flags: DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable,
                                      capabilitySummary: 1, streamToken: 0, routeCost: 0)
        a.rotating = rotating
        return a
    }

    func testOpeningBindsTheSelectedIdToTheAuthenticatedNode() {
        let entry = RotatingDiscoveryIds.entry(saltKey: presenceKey, nodeId: nodeId, epoch: epoch, role: 0)
        let selected = selectedCall(entry.rdi)
        XCTAssertEqual(DiscoverySelectionCheck.check(selected: selected, expectedRole: 0, peerNodeId: nodeId, openingEntries: [entry]), .pass)
        var other = nodeId; other[15] &+= 1
        XCTAssertEqual(DiscoverySelectionCheck.check(selected: selected, expectedRole: 0, peerNodeId: other, openingEntries: [entry]), .openingMismatch)
        let forged = OpeningEntry(rdi: entry.rdi, epoch: entry.epoch, role: 0, salt: Data(count: 32))
        XCTAssertEqual(DiscoverySelectionCheck.check(selected: selected, expectedRole: 0, peerNodeId: nodeId, openingEntries: [forged]), .openingMismatch)
        let stream = RotatingDiscoveryIds.entry(saltKey: presenceKey, nodeId: nodeId, epoch: epoch, role: 1)
        XCTAssertEqual(DiscoverySelectionCheck.check(selected: selectedCall(stream.rdi), expectedRole: 0, peerNodeId: nodeId, openingEntries: [stream]), .openingMismatch)
        let previous = RotatingDiscoveryIds.entry(saltKey: presenceKey, nodeId: nodeId, epoch: epoch - 1, role: 0)
        XCTAssertEqual(DiscoverySelectionCheck.check(selected: selected, expectedRole: 0, peerNodeId: nodeId, openingEntries: [previous]), .openingMismatch)
        XCTAssertEqual(DiscoverySelectionCheck.check(selected: selected, expectedRole: 0, peerNodeId: nodeId, openingEntries: [previous, entry]), .pass)
        // RV15: the check follows the selected advert, not the hello.
        XCTAssertEqual(DiscoverySelectionCheck.check(selected: selected, expectedRole: 0, peerNodeId: nodeId, openingEntries: nil), .openingMissing)
        XCTAssertEqual(DiscoverySelectionCheck.check(selected: selectedCall(nodeId.prefix(6), rotating: false), expectedRole: 0, peerNodeId: nodeId, openingEntries: [entry]), .pass)
        XCTAssertEqual(DiscoverySelectionCheck.check(selected: selectedCall(entry.rdi, rotating: false), expectedRole: 0, peerNodeId: nodeId, openingEntries: [entry]), .prefixMismatch)
    }

    func testPinsKeepThePreviousIdOnlyForSixtySeconds() {
        let pins = OpeningPins()
        let first = RotatingDiscoveryIds.entry(saltKey: presenceKey, nodeId: nodeId, epoch: epoch, role: 0)
        let second = RotatingDiscoveryIds.entry(saltKey: presenceKey, nodeId: nodeId, epoch: epoch + 1, role: 0)
        XCTAssertTrue(pins.pinned(elapsedMs: 0).isEmpty)
        pins.onAdvertised(first, elapsedMs: 1_000); XCTAssertEqual(pins.pinned(elapsedMs: 2_000), [first])
        pins.onAdvertised(first, elapsedMs: 5_000); XCTAssertEqual(pins.pinned(elapsedMs: 5_000), [first])
        pins.offAir(elapsedMs: 900_000); pins.onAdvertised(second, elapsedMs: 904_000)
        XCTAssertEqual(pins.pinned(elapsedMs: 959_999), [second, first])
        XCTAssertEqual(pins.pinned(elapsedMs: 960_000), [second])
        // An ID that left the air long ago is never opened again.
        let p2 = OpeningPins()
        let after = RotatingDiscoveryIds.entry(saltKey: presenceKey, nodeId: nodeId, epoch: epoch + 12, role: 0)
        p2.onAdvertised(first, elapsedMs: 1_000); p2.offAir(elapsedMs: 2_000)
        XCTAssertEqual(p2.pinned(elapsedMs: 31_999), [first])
        p2.onAdvertised(after, elapsedMs: 2_000 + 3 * 3_600_000)
        XCTAssertEqual(p2.pinned(elapsedMs: 2_000 + 3 * 3_600_000 + 1), [after])
        p2.offAir(elapsedMs: 20_000_000)
        XCTAssertEqual(p2.pinned(elapsedMs: 20_059_999), [after]); XCTAssertTrue(p2.pinned(elapsedMs: 20_060_000).isEmpty)
    }

    func testEpochClockRules() {
        let t0: Int64 = 1_791_590_400_000
        var saved: [EpochClockState] = []
        let clock = DiscoveryEpochClock(state: EpochClockState(), bootId: "boot1") { saved.append($0) }
        XCTAssertEqual(clock.read(wallMs: t0 + 1_000, elapsedMs: 10_000).epoch, epoch)
        for i in 0..<50 { XCTAssertEqual(clock.read(wallMs: t0 + 2_000 + Int64(i) * 1_000, elapsedMs: 11_000 + Int64(i) * 1_000).epoch, epoch) }
        let next = clock.read(wallMs: t0 + 900_100, elapsedMs: 910_100)
        XCTAssertEqual(next.epoch, epoch + 1); XCTAssertTrue(next.ticked)
        XCTAssertEqual(saved.last?.lastEpoch, epoch + 1)
        // A backward wall clock never repeats an epoch; a stuck wall still rotates by elapsed time.
        let back = DiscoveryEpochClock(state: EpochClockState(), bootId: "b") { _ in }
        XCTAssertEqual(back.read(wallMs: t0, elapsedMs: 0).epoch, epoch)
        let behind = t0 - 3 * 3_600_000
        XCTAssertEqual(back.read(wallMs: behind, elapsedMs: 1_000).epoch, epoch + 1)
        XCTAssertEqual(back.read(wallMs: behind + 2_000, elapsedMs: 1_000 + DiscoveryEpochClock.elapsedTickMs).epoch, epoch + 2)
        let fresh = DiscoveryEpochClock(state: EpochClockState(), bootId: "b") { _ in }
        XCTAssertEqual(fresh.read(wallMs: t0 + 500, elapsedMs: 0).epoch, epoch)
        XCTAssertEqual(fresh.read(wallMs: t0 + 899_000, elapsedMs: 899_500).epoch, epoch)
        XCTAssertEqual(fresh.read(wallMs: t0 + 900_200, elapsedMs: 900_700).epoch, epoch + 1)
        XCTAssertEqual(fresh.read(wallMs: t0 + 1_799_000, elapsedMs: 1_799_500).epoch, epoch + 1)
        XCTAssertEqual(fresh.read(wallMs: t0 + 1_800_100, elapsedMs: 1_800_600).epoch, epoch + 2)
        // After a reboot the epoch is reused only while the wall agrees.
        let state = EpochClockState(lastEpoch: epoch, tickWallEpoch: epoch, tickElapsedMs: 500_000, bootId: "boot1")
        let same = DiscoveryEpochClock(state: state, bootId: "boot2") { _ in }.read(wallMs: t0 + 300_000, elapsedMs: 20_000)
        XCTAssertEqual(same.epoch, epoch); XCTAssertFalse(same.ticked)
        XCTAssertEqual(DiscoveryEpochClock(state: state, bootId: "boot2") { _ in }.read(wallMs: t0 + 3 * 900_000 + 5, elapsedMs: 20_000).epoch, epoch + 3)
        XCTAssertEqual(DiscoveryEpochClock(state: state, bootId: "boot1") { _ in }.read(wallMs: t0 + 600_000, elapsedMs: 600_000).epoch, epoch)
    }

    func testPinnedForwardJumpRecoversAfterAnHourOfConsistentWallTime() {
        let t0: Int64 = 1_791_590_400_000
        let clock = DiscoveryEpochClock(state: EpochClockState(), bootId: "b") { _ in }
        let pinned = clock.read(wallMs: t0 + 365 * 24 * 3_600_000, elapsedMs: 0).epoch
        XCTAssertGreaterThan(pinned - epoch, DiscoveryEpochClock.maxAheadEpochs)
        XCTAssertEqual(clock.read(wallMs: t0, elapsedMs: 1_000).epoch, pinned + 1)
        _ = clock.read(wallMs: t0 + 1_800_000, elapsedMs: 1_801_000 + 300_000)
        XCTAssertFalse(clock.read(wallMs: t0 + 3_600_000, elapsedMs: 3_601_000 + 300_000).newGeneration)
        let end: Int64 = 3_601_000 + 300_000 + DiscoveryEpochClock.aheadRecoveryMs
        let recovered = clock.read(wallMs: t0 + end - 300_000 - 1_000, elapsedMs: end)
        XCTAssertTrue(recovered.newGeneration); XCTAssertEqual(clock.state.generation, 2)
        XCTAssertEqual(recovered.epoch, RotatingDiscoveryIds.wallEpoch(unixSeconds: (t0 + end - 301_000) / 1000))
    }

    func testTarpitAndVisibleWindow() {
        XCTAssertEqual([0, 1, 6, 7, 10, 11, 1_000].map(StrangerTarpit.delayMs), [0, 31, 1_000, 2_000, 16_000, 30_000, 30_000])
        let tarpit = StrangerTarpit()
        XCTAssertEqual((1...7).map { _ in tarpit.nextDelayMs(epoch: epoch) }, [31, 62, 125, 250, 500, 1_000, 2_000])
        tarpit.forgive(epoch: epoch)
        XCTAssertEqual(tarpit.nextDelayMs(epoch: epoch), 2_000)
        XCTAssertEqual(tarpit.nextDelayMs(epoch: epoch + 1), 31)
        let boundary: Int64 = 1_791_590_400
        XCTAssertEqual(VisibleByHandleWindow.endEpoch(startUnixSeconds: boundary), epoch + 1)
        XCTAssertEqual(VisibleByHandleWindow.endEpoch(startUnixSeconds: boundary + 300), epoch + 1)
        XCTAssertEqual(VisibleByHandleWindow.endEpoch(startUnixSeconds: boundary + 301), epoch + 2)
        for offset: Int64 in [0, 299, 300, 301, 899] {
            let start = boundary + offset
            let length = VisibleByHandleWindow.endEpoch(startUnixSeconds: start) * 900 - start
            XCTAssertTrue((600...1_500).contains(length), "offset \(offset) gives \(length) s")
        }
        let end = VisibleByHandleWindow.endEpoch(startUnixSeconds: boundary + 100)
        XCTAssertTrue(VisibleByHandleWindow.isActive(endEpoch: end, nowUnixSeconds: boundary + 100))
        XCTAssertTrue(VisibleByHandleWindow.isActive(endEpoch: end, nowUnixSeconds: end * 900 - 1))
        XCTAssertFalse(VisibleByHandleWindow.isActive(endEpoch: end, nowUnixSeconds: end * 900))
        XCTAssertFalse(VisibleByHandleWindow.isActive(endEpoch: -1, nowUnixSeconds: boundary))
    }
}

/// BDO1 over real BMH2 links (call engines), as Android RotatingDiscoveryLinkTest.
final class RotatingDiscoveryLinkTests: XCTestCase {
    let vp9 = NodeCapabilities.codecVP9
    private func pump(_ a: MeshConnection, _ b: MeshConnection) {
        for _ in 0..<50 {
            var moved = false
            while let d = a.nextOutgoing(now: 0) { b.receive(d, now: 0); moved = true }
            while let d = b.nextOutgoing(now: 0) { a.receive(d, now: 0); moved = true }
            if !moved { return }
        }
    }
    private func advert(_ rdi: Data) -> DiscoveryAnnouncement {
        var a = DiscoveryAnnouncement(nodeIdPrefix: rdi, flags: DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable,
                                      capabilitySummary: 1, streamToken: 0, routeCost: 0)
        a.rotating = true
        return a
    }

    func testCallingASelectedRotatingIdOpensAndRings() throws {
        let calleeId = SoftwareSigningIdentity()
        let entry = RotatingDiscoveryIds.ownEntry(presenceKey: Data(repeating: 7, count: 32), nodeId: calleeId.nodeId.bytes, epoch: 1_990_656, role: 0)
        let caller = CallEngine(role: .caller, transport: .l2cap, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                expectedPeerPrefix: entry.rdi, rotating: RotatingCallOptions(selected: advert(entry.rdi), wallEpoch: { 1_990_656 }))
        let callee = CallEngine(role: .callee, transport: .l2cap, identity: calleeId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                rotating: RotatingCallOptions(entries: { [entry] }))
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        XCTAssertEqual(callee.state?.phase, .incomingRinging)
        XCTAssertEqual(caller.peerOpening, [entry]); XCTAssertEqual(callee.peerOpening, [], "the caller sends an empty opening")
    }

    func testAnImpostorOrAPeerWithoutBit3Fails() throws {
        let realCallee = SoftwareSigningIdentity()
        let entry = RotatingDiscoveryIds.ownEntry(presenceKey: Data(repeating: 7, count: 32), nodeId: realCallee.nodeId.bytes, epoch: 1_990_656, role: 0)
        // Another identity replaying the real callee's entry: the RDI does not recompute from its node ID.
        let caller = CallEngine(role: .caller, transport: .l2cap, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                rotating: RotatingCallOptions(selected: advert(entry.rdi), wallEpoch: { 1_990_656 }))
        let impostor = CallEngine(role: .callee, transport: .l2cap, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                  rotating: RotatingCallOptions(entries: { [entry] }))
        try caller.start(now: 0); try impostor.start(now: 0); pump(caller, impostor)
        XCTAssertEqual(caller.phase, .closed); XCTAssertNil(impostor.state)
        // An old callee (no bit 3) cannot answer a selected rotating advert.
        let caller2 = CallEngine(role: .caller, transport: .l2cap, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                 rotating: RotatingCallOptions(selected: advert(entry.rdi), wallEpoch: { 1_990_656 }))
        let old = CallEngine(role: .callee, transport: .l2cap, identity: realCallee, requestedType: .voice, encodeMask: vp9, decodeMask: vp9)
        try caller2.start(now: 0); try old.start(now: 0); pump(caller2, old)
        XCTAssertEqual(caller2.phase, .closed)
    }

    func testOneSidedBitSendsNothingAndAFixedAdvertStillWorks() throws {
        let calleeId = SoftwareSigningIdentity()
        let caller = CallEngine(role: .caller, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                expectedPeerPrefix: calleeId.nodeId.prefix, rotating: RotatingCallOptions(selected: nil))
        let callee = CallEngine(role: .callee, transport: .gatt, identity: calleeId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9)
        try caller.start(now: 0); try callee.start(now: 0); pump(caller, callee)
        XCTAssertNil(caller.peerOpening); XCTAssertFalse(caller.openingExpected)
        XCTAssertEqual(callee.state?.phase, .incomingRinging, "bit 3 on one side only changes nothing")
    }
}

/// RD4 (opening epoch window) and RH4 (2-epoch ahead bound), Android 2026-10-11 / 2026-10-14.
final class OpeningEpochWindowTests: XCTestCase {
    func testAnOpeningMoreThanTwoEpochsFromTheVerifiersClockIsStale() {
        let id = SoftwareSigningIdentity()
        let e: Int64 = 1_990_656
        let entry = RotatingDiscoveryIds.ownEntry(presenceKey: Data(repeating: 3, count: 32), nodeId: id.nodeId.bytes, epoch: e, role: 0)
        var selected = DiscoveryAnnouncement(nodeIdPrefix: entry.rdi, flags: DiscoveryAnnouncement.flagPrivateCallAvailable | DiscoveryAnnouncement.flagAcceptingConnections,
                                             capabilitySummary: 1, streamToken: 0, routeCost: 0)
        selected.rotating = true
        for (wall, expected) in [(e, DiscoverySelectionCheck.Result.pass), (e + 2, .pass), (e - 2, .pass), (e + 3, .openingStale), (e - 3, .openingStale)] {
            XCTAssertEqual(DiscoverySelectionCheck.check(selected: selected, expectedRole: 0, peerNodeId: id.nodeId.bytes, openingEntries: [entry],
                                                         verifierWallEpoch: wall), expected, "wall \(wall - e)")
        }
        XCTAssertEqual(DiscoveryEpochClock.maxAheadEpochs, 2)
    }

    func testACallerWhoseClockIsThreeEpochsOffRefusesTheOpening() throws {
        let vp9 = NodeCapabilities.codecVP9
        let calleeId = SoftwareSigningIdentity()
        let entry = RotatingDiscoveryIds.ownEntry(presenceKey: Data(repeating: 7, count: 32), nodeId: calleeId.nodeId.bytes, epoch: 1_990_656, role: 0)
        var selected = DiscoveryAnnouncement(nodeIdPrefix: entry.rdi, flags: DiscoveryAnnouncement.flagPrivateCallAvailable | DiscoveryAnnouncement.flagAcceptingConnections,
                                             capabilitySummary: 1, streamToken: 0, routeCost: 0)
        selected.rotating = true
        let caller = CallEngine(role: .caller, transport: .l2cap, identity: SoftwareSigningIdentity(), requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                rotating: RotatingCallOptions(selected: selected, wallEpoch: { 1_990_659 }))
        let callee = CallEngine(role: .callee, transport: .l2cap, identity: calleeId, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                                rotating: RotatingCallOptions(entries: { [entry] }))
        try caller.start(now: 0); try callee.start(now: 0)
        for _ in 0..<50 {
            var moved = false
            while let d = caller.nextOutgoing(now: 0) { callee.receive(d, now: 0); moved = true }
            while let d = callee.nextOutgoing(now: 0) { caller.receive(d, now: 0); moved = true }
            if !moved { break }
        }
        XCTAssertEqual(caller.phase, .closed)
    }
}

/// Phase 1b streams: Android version 5 stream offers decode, and a viewer of one checks the connector's role-1 BDO1.
final class RotatingStreamTests: XCTestCase {
    let vp9 = NodeCapabilities.codecVP9
    let epoch: Int64 = 1_990_656

    func testAndroidVersion5StreamOfferVector() throws {
        // PROTOCOL vector: role-1 RDI bb2d061f6480, flags 0x0c, VP9, token for logical 0x12345678, 640x360 15 FPS 300 kbps.
        let bytes = Data(hex: "05bb2d061f64800c0192529fc40001028001680f012c")!
        let a = try DiscoveryAnnouncement(decoding: bytes, acceptRotating: true)
        XCTAssertTrue(a.rotating && a.isStreamOffer); XCTAssertEqual(a.transport, .gatt)
        XCTAssertEqual(a.streamToken, 0x92529fc4); XCTAssertEqual(a.logicalStreamToken, 0x12345678)
        XCTAssertEqual(a.streamWidth, 640); XCTAssertEqual(a.streamFps, 15); XCTAssertEqual(a.streamBitrateKbps, 300)
        XCTAssertEqual(try a.encoded().hex, bytes.hex)
        XCTAssertThrowsError(try DiscoveryAnnouncement(decoding: bytes), "version 5 is rejected when off")
        // A version 5 viewer request is still refused (the iPhone never offers a version 5 stream).
        XCTAssertThrowsError(try DiscoveryAnnouncement(decoding: Data(hex: "05974ae410ea91090092529fc400000000000000012c")!, acceptRotating: true))
    }

    private func run(sourceId: SigningIdentity, entryOwner: SigningIdentity, sourceEntries: Bool = true, verifierEpoch: Int64? = nil)
        throws -> (StreamSourceEngine, StreamViewerEngine) {
        let entry = RotatingDiscoveryIds.ownEntry(presenceKey: Data(repeating: 5, count: 32), nodeId: entryOwner.nodeId.bytes, epoch: epoch, role: 1)
        let token = try StreamRouteToken.forAdvertiser(logical: 0x1234, prefix: entry.rdi)
        var offer = DiscoveryAnnouncement(nodeIdPrefix: entry.rdi, flags: DiscoveryAnnouncement.flagStreamAvailable | DiscoveryAnnouncement.flagGattTransport,
                                          capabilitySummary: vp9, streamToken: token, routeCost: 0)
        offer.rotating = true
        let viewerId = SoftwareSigningIdentity()
        let reference = verifierEpoch ?? epoch
        let header = StreamHeader(width: 640, height: 360, fps: 15, codecId: StreamProtocol.codecVP9, includeAudio: true)
        let source = StreamSourceEngine(transport: .gatt, identity: sourceId, header: header, expectedViewerPrefix: viewerId.nodeId.prefix,
                                        rotatingEntries: sourceEntries ? { [entry] } : nil)
        let viewer = StreamViewerEngine(transport: .gatt, identity: viewerId, decodeMask: vp9, expectedAdjacentPrefix: offer.nodeIdPrefix,
                                        rotatingOffer: offer, wallEpoch: { reference })
        try source.start(now: 0); try viewer.start(now: 0)
        for _ in 0..<50 {
            var moved = false
            while let d = source.nextOutgoing(now: 0) { viewer.receive(d, now: 0); moved = true }
            while let d = viewer.nextOutgoing(now: 0) { source.receive(d, now: 0); moved = true }
            if !moved { break }
        }
        return (source, viewer)
    }

    func testAViewerOfARotatingOfferJoinsWhenTheSourceOpensIt() throws {
        let sourceId = SoftwareSigningIdentity()
        let (source, viewer) = try run(sourceId: sourceId, entryOwner: sourceId)
        XCTAssertTrue(source.ready, "\(viewer.closeReason ?? "")"); XCTAssertEqual(viewer.header?.width, 640)
        XCTAssertEqual(source.peerOpening, [], "the viewer advertised a fixed prefix and opens nothing")
    }

    func testAnImpostorSourceAStaleOpeningAndAMissingBit3AllFail() throws {
        let (_, impostorViewer) = try run(sourceId: SoftwareSigningIdentity(), entryOwner: SoftwareSigningIdentity())
        XCTAssertEqual(impostorViewer.phase, .closed)
        let sourceId = SoftwareSigningIdentity()
        let (_, staleViewer) = try run(sourceId: sourceId, entryOwner: sourceId, verifierEpoch: epoch + 3)
        XCTAssertEqual(staleViewer.phase, .closed)
        let (_, noBitViewer) = try run(sourceId: sourceId, entryOwner: sourceId, sourceEntries: false)
        XCTAssertEqual(noBitViewer.phase, .closed)
    }

    /// Phase 1b for streams is not built here (requests and forwarder offers carry the fixed prefix): with rotating
    /// IDs on, a rotating stream is neither joined nor forwarded; a fixed one, or the setting off, behaves as before.
    func testARotatingStreamIsNotJoinedOrForwardedWithTheFixedPrefixWhileRotatingIdsAreOn() {
        var offer = DiscoveryAnnouncement(nodeIdPrefix: Data([1, 2, 3, 4, 5, 6]), flags: DiscoveryAnnouncement.flagStreamAvailable,
                                          capabilitySummary: NodeCapabilities.codecVP9, streamToken: 0x8000_1234, routeCost: 0)
        XCTAssertNil(RotatingStreamPolicy.joinRefusal(offer: offer, rotatingIds: true))
        XCTAssertTrue(RotatingStreamPolicy.mayForward(offer: offer, rotatingIds: true))
        offer.rotating = true
        XCTAssertEqual(RotatingStreamPolicy.joinRefusal(offer: offer, rotatingIds: true), RotatingStreamPolicy.joinRefusal)
        XCTAssertFalse(RotatingStreamPolicy.mayForward(offer: offer, rotatingIds: true))
        XCTAssertNil(RotatingStreamPolicy.joinRefusal(offer: offer, rotatingIds: false), "the fixed prefix is already public")
        XCTAssertTrue(RotatingStreamPolicy.mayForward(offer: offer, rotatingIds: false))
    }
}
