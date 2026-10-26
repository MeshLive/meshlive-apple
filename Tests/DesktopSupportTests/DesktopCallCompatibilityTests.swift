import XCTest
import NearbyCore
@testable import DesktopSupport

final class DesktopCallCompatibilityTests: XCTestCase {
    private let epoch: Int64 = 1_990_656
    private let vp9 = NodeCapabilities.codecVP9

    private func offer(for identity: SigningIdentity, rotating: Bool) -> (DiscoveryAnnouncement, OpeningEntry) {
        let entry = RotatingDiscoveryIds.ownEntry(presenceKey: Data(repeating: 9, count: 32),
                                                 nodeId: identity.nodeId.bytes, epoch: epoch, role: 0)
        var offer = DiscoveryAnnouncement(nodeIdPrefix: rotating ? entry.rdi : identity.nodeId.prefix,
                                          flags: DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable,
                                          capabilitySummary: vp9, streamToken: 0, routeCost: 0)
        offer.rotating = rotating
        return (offer, entry)
    }

    private func pump(_ caller: CallEngine, _ callee: CallEngine, now: TimeInterval = 0) {
        for _ in 0..<80 {
            var moved = false
            while let data = caller.nextOutgoing(now: now) { callee.receive(data, now: now); moved = true }
            while let data = callee.nextOutgoing(now: now) { caller.receive(data, now: now); moved = true }
            if !moved { return }
        }
        XCTFail("Call engines did not settle")
    }

    private func caller(policy: DesktopCallCompatibility, selected: DiscoveryAnnouncement, type: CallType = .voice) -> CallEngine {
        var rotating = policy.rotatingOptions(selected: selected)
        rotating?.wallEpoch = { self.epoch }
        var bmh3 = policy.bmh3Options(selected: selected)
        bmh3?.wallEpoch = { self.epoch }
        return CallEngine(role: .caller, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: type,
                          encodeMask: vp9, decodeMask: vp9, expectedPeerPrefix: selected.rotating ? nil : selected.nodeIdPrefix,
                          rotating: rotating, bmh3: bmh3)
    }

    private func callee(identity: SigningIdentity, entry: OpeningEntry, pseudonyms: Bool) -> CallEngine {
        CallEngine(role: .callee, transport: .gatt, identity: identity, requestedType: .voice, encodeMask: vp9, decodeMask: vp9,
                   rotating: RotatingCallOptions(entries: { [entry] }),
                   bmh3: Bmh3CallOptions(pseudonyms: pseudonyms, budget: Bmh3SigningBudget(capacity: 1_000)))
    }

    func testExperimentControlsRotatingDiscoveryWithoutEnablingOwnRotatingIds() throws {
        let (announcement, _) = offer(for: SoftwareSigningIdentity(), rotating: true)
        let bytes = try announcement.encoded()
        let uuid = try CompactAnnouncement.encode(announcement)
        let off = DesktopCallCompatibility()
        XCTAssertThrowsError(try DiscoveryAnnouncement(decoding: bytes, acceptRotating: off.acceptsRotating))
        XCTAssertNil(CompactAnnouncement.decode(uuid, acceptRotating: off.acceptsRotating))
        XCTAssertNil(off.rotatingOptions(selected: announcement))
        XCTAssertNil(off.bmh3Options(selected: announcement))

        let on = DesktopCallCompatibility(enabled: true)
        XCTAssertFalse(on.rotatingIds)
        XCTAssertEqual(try DiscoveryAnnouncement(decoding: bytes, acceptRotating: on.acceptsRotating), announcement)
        XCTAssertEqual(CompactAnnouncement.decode(uuid, acceptRotating: on.acceptsRotating), announcement)
        XCTAssertNotNil(on.rotatingOptions(selected: announcement))
        XCTAssertNil(on.rotatingOptions(selected: announcement)?.presence)
        XCTAssertEqual(on.bmh3Options(selected: announcement)?.pseudonyms, true)
    }

    func testMacWithOwnRotatingIdsOffCanCallRotatingPseudonymousPeer() throws {
        let identity = SoftwareSigningIdentity()
        let (selected, entry) = offer(for: identity, rotating: true)
        let mac = caller(policy: DesktopCallCompatibility(enabled: true), selected: selected)
        let android = callee(identity: identity, entry: entry, pseudonyms: true)
        try mac.start(now: 0); try android.start(now: 0); pump(mac, android)
        XCTAssertEqual(android.state?.phase, .incomingRinging, mac.closeReason ?? "")
        XCTAssertTrue(mac.linkUsedBmh3)
        XCTAssertTrue(mac.discoveryNegotiated)
        XCTAssertTrue(mac.peerIsStranger)
        XCTAssertNotNil(DesktopNearbyNames.shared?.name(forStranger: mac))
        try android.accept(as: .voice); pump(mac, android)
        XCTAssertEqual(mac.state?.phase, .active, mac.closeReason ?? "")
        XCTAssertEqual(mac.revealedPeer?.nodeId, identity.nodeId)
        XCTAssertFalse(mac.peerIsStranger)
        XCTAssertNil(DesktopNearbyNames.shared?.name(forStranger: mac), "A revealed real identity must not become a generated name")
        var receivedByMac: [Data] = [], receivedByPeer: [Data] = []
        mac.onEvent = { if case .remoteAudio(let packet) = $0 { receivedByMac.append(packet.payload) } }
        android.onEvent = { if case .remoteAudio(let packet) = $0 { receivedByPeer.append(packet.payload) } }
        mac.sendAudio(presentationTimeUs: 0, opus: Data([0xfc, 1]))
        android.sendAudio(presentationTimeUs: 0, opus: Data([0xfc, 2]))
        pump(mac, android)
        XCTAssertEqual(receivedByMac, [Data([0xfc, 2])])
        XCTAssertEqual(receivedByPeer, [Data([0xfc, 1])])
        mac.end(); pump(mac, android)
        XCTAssertEqual(android.state?.phase, .ended)
    }

    func testMacRequiresRealIdentityPeerToOpenSelectedRotatingOffer() throws {
        let identity = SoftwareSigningIdentity()
        let (selected, entry) = offer(for: identity, rotating: true)
        let mac = caller(policy: DesktopCallCompatibility(enabled: true), selected: selected)
        let android = callee(identity: identity, entry: entry, pseudonyms: false)
        try mac.start(now: 0); try android.start(now: 0); pump(mac, android)
        XCTAssertEqual(android.state?.phase, .incomingRinging, mac.closeReason ?? "")
        XCTAssertTrue(mac.discoveryNegotiated)
        try android.accept(as: .voice); pump(mac, android)
        XCTAssertEqual(mac.state?.phase, .active, mac.closeReason ?? "")
        XCTAssertEqual(mac.endpoint?.peerNodeId, identity.nodeId)
    }

    func testCopiedRotatingOfferFailsAuthentication() throws {
        let victim = SoftwareSigningIdentity()
        let (selected, entry) = offer(for: victim, rotating: true)
        for pseudonyms in [false, true] {
            let mac = caller(policy: DesktopCallCompatibility(enabled: true), selected: selected)
            let impostor = callee(identity: SoftwareSigningIdentity(), entry: entry, pseudonyms: pseudonyms)
            try mac.start(now: 0); try impostor.start(now: 0); pump(mac, impostor)
            if pseudonyms {
                XCTAssertEqual(impostor.state?.phase, .incomingRinging)
                try impostor.accept(as: .voice); pump(mac, impostor)
            }
            XCTAssertEqual(mac.phase, .closed)
            XCTAssertNotEqual(mac.state?.phase, .active)
            XCTAssertNil(mac.revealedPeer)
        }
    }

    func testLegacyPeerRemainsCallableWithExperimentOnOrOff() throws {
        let identity = SoftwareSigningIdentity()
        let (selected, _) = offer(for: identity, rotating: false)
        for enabled in [false, true] {
            let mac = caller(policy: DesktopCallCompatibility(enabled: enabled), selected: selected)
            let legacy = CallEngine(role: .callee, transport: .gatt, identity: identity, requestedType: .voice,
                                    encodeMask: vp9, decodeMask: vp9)
            try mac.start(now: 0); try legacy.start(now: 0); pump(mac, legacy)
            XCTAssertEqual(legacy.state?.phase, .incomingRinging, mac.closeReason ?? "")
            XCTAssertFalse(mac.linkUsedBmh3)
            try legacy.accept(as: .voice); pump(mac, legacy)
            XCTAssertEqual(mac.state?.phase, .active)
        }
    }

    func testMacAcceptsBmh3WithoutEnablingItsOwnRotatingIds() throws {
        let identity = SoftwareSigningIdentity()
        var (selected, _) = offer(for: identity, rotating: false)
        selected.capabilitySummary |= Bmh3Choice.hintBit
        let remote = caller(policy: DesktopCallCompatibility(enabled: true), selected: selected)
        let mac = CallEngine(role: .callee, transport: .gatt, identity: identity, requestedType: .voice,
                             encodeMask: vp9, decodeMask: vp9,
                             bmh3: DesktopCallCompatibility(enabled: true).bmh3Options(selected: nil))
        try remote.start(now: 0); try mac.start(now: 0); pump(remote, mac)
        XCTAssertEqual(mac.state?.phase, .incomingRinging, remote.closeReason ?? "")
        XCTAssertTrue(mac.linkUsedBmh3)
        try mac.accept(as: .voice); pump(remote, mac)
        XCTAssertEqual(remote.state?.phase, .active)
        XCTAssertEqual(remote.endpoint?.peerNodeId, identity.nodeId)
    }

    func testExperimentDoesNotOverridePseudonymPrivacyParentSwitch() {
        let (selected, _) = offer(for: SoftwareSigningIdentity(), rotating: false)
        let parentOff = DesktopCallCompatibility(enabled: true, rotatingIds: true, hiddenIdentities: false, pseudonyms: true)
        XCTAssertEqual(parentOff.bmh3Options(selected: selected)?.pseudonyms, false)
        XCTAssertEqual(parentOff.bmh3Options(selected: nil)?.pseudonyms, false)
        let parentOn = DesktopCallCompatibility(enabled: true, rotatingIds: true, hiddenIdentities: true, pseudonyms: true)
        XCTAssertEqual(parentOn.bmh3Options(selected: selected)?.pseudonyms, true)
        let ownRotatingIds = DesktopCallCompatibility(rotatingIds: true)
        XCTAssertTrue(ownRotatingIds.acceptsRotating)
        XCTAssertNotNil(ownRotatingIds.rotatingOptions(selected: selected))
        XCTAssertNil(ownRotatingIds.bmh3Options(selected: selected))
    }

    func testIncomingCompatibilityCallSurvivesBothMutedWithVideoThenWithoutMedia() throws {
        let identity = SoftwareSigningIdentity()
        var (selected, _) = offer(for: identity, rotating: false)
        selected.capabilitySummary |= Bmh3Choice.hintBit
        let remote = caller(policy: DesktopCallCompatibility(enabled: true), selected: selected, type: .video)
        let mac = CallEngine(role: .callee, transport: .gatt, identity: identity, requestedType: .video,
                             encodeMask: vp9, decodeMask: vp9,
                             bmh3: DesktopCallCompatibility(enabled: true).bmh3Options(selected: nil))
        try remote.start(now: 0); try mac.start(now: 0); pump(remote, mac)
        try mac.accept(as: .video); pump(remote, mac)
        remote.setMuted(true); pump(remote, mac)
        mac.setMuted(true); pump(remote, mac)
        for second in 1...32 {
            let now = TimeInterval(second)
            // The first half has video; the second has no media at all. Each lasts longer
            // than the silence deadline, so only regular received heartbeats keep it alive.
            if second <= 16 {
                XCTAssertTrue(remote.sendVideo(flags: 0, presentationTimeUs: Int64(second) * 1_000_000, payload: Data([1, 2])))
                XCTAssertTrue(mac.sendVideo(flags: 0, presentationTimeUs: Int64(second) * 1_000_000, payload: Data([3, 4])))
            }
            remote.tick(now: now); mac.tick(now: now); pump(remote, mac, now: now)
            XCTAssertEqual(remote.phase, .open, remote.closeReason ?? "")
            XCTAssertEqual(mac.state?.phase, .active, mac.closeReason ?? "")
        }
        XCTAssertEqual(mac.receivedVideoPackets, 16)
        XCTAssertEqual(remote.receivedVideoPackets, 16)
        remote.setMuted(false); mac.setMuted(false)
        remote.sendAudio(presentationTimeUs: 33_000_000, opus: Data([0xfc, 1]))
        mac.sendAudio(presentationTimeUs: 33_000_000, opus: Data([0xfc, 2]))
        pump(remote, mac, now: 33)
        XCTAssertEqual(mac.receivedAudioPackets, 1)
        XCTAssertEqual(remote.receivedAudioPackets, 1)
        mac.end(); pump(remote, mac, now: 33)
        XCTAssertEqual(remote.state?.phase, .ended)
    }
}
