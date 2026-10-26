import XCTest
import NearbyCore
@testable import DesktopSupport

final class DesktopCallDeliveryTests: XCTestCase {
    private func report(_ bytes: UInt32, _ clock: UInt32) -> LinkCapacityReport {
        LinkCapacityReport(arrivalKbps: 0, linkLate: false, receivedBytes: bytes, clockMs: clock)
    }

    func testRemoteQueueChangesAdaptationEvenWhenLocalTransportQueueIsEmpty() throws {
        let delivery = DesktopCallDelivery()
        delivery.submitted(payloadBytes: 10_000, audio: false, at: 0)
        delivery.accept(report(10_000, 1_000))
        _ = delivery.rateInput(enabled: true, localQueueAge: 0, localDeliveredKbps: 200)
        delivery.submitted(payloadBytes: 10_000, audio: false, at: 1)
        delivery.accept(report(20_000, 2_600))
        let input = delivery.rateInput(enabled: true, localQueueAge: 0, localDeliveredKbps: 200)
        XCTAssertTrue(input.usesPeer)
        XCTAssertEqual(input.queueAge, 0.6, accuracy: 0.001)
        XCTAssertEqual(input.deliveredKbps, 50, accuracy: 0.001)
        var controller = VideoRateController(startKbps: 200, maxKbps: 200)
        XCTAssertEqual(controller.update(queueAge: input.queueAge, encodedKbps: 200, deliveredKbps: input.deliveredKbps), 48)
    }

    func testRemovingAudioDoesNotReduceMeasuredVideoGoodput() throws {
        let delivery = DesktopCallDelivery()
        for second in 0...2 {
            delivery.submitted(payloadBytes: 750, audio: false, at: Double(second))
            if second < 2 { delivery.submitted(payloadBytes: 250, audio: true, at: Double(second)) }
            delivery.accept(report(second == 2 ? 2_750 : UInt32((second + 1) * 1_000), UInt32((second + 1) * 1_000)))
            if second > 0 {
                let sample = try XCTUnwrap(delivery.latest)
                XCTAssertEqual(sample.videoKbps, 6, accuracy: 0.001)
                XCTAssertEqual(sample.queueMs, 0)
            }
        }
        var controller = VideoRateController(startKbps: 200, maxKbps: 200)
        XCTAssertNil(controller.update(queueAge: 0, encodedKbps: 6, deliveredKbps: 6), "A quiet scene is not evidence of lost capacity")
    }

    func testDuplicateIdleReportsCannotRepeatedlyCutTheEncoder() {
        let delivery = DesktopCallDelivery()
        delivery.submitted(payloadBytes: 10_000, audio: false, at: 0)
        delivery.accept(report(10_000, 1_000))
        delivery.submitted(payloadBytes: 10_000, audio: false, at: 1)
        delivery.accept(report(20_000, 2_600))
        XCTAssertTrue(delivery.rateInput(enabled: true, localQueueAge: 0, localDeliveredKbps: 200).usesPeer)
        delivery.accept(report(20_000, 2_600))
        let idle = delivery.rateInput(enabled: true, localQueueAge: 0, localDeliveredKbps: 200)
        XCTAssertFalse(idle.usesPeer)
        XCTAssertEqual(idle.queueAge, 0)
    }

    func testDisabledLegacyAndInvalidReportsUseExistingLocalAdaptation() {
        let delivery = DesktopCallDelivery()
        delivery.submitted(payloadBytes: 10_000, audio: false, at: 0)
        delivery.accept(report(10_000, 1_000))
        delivery.submitted(payloadBytes: 10_000, audio: false, at: 1)
        delivery.accept(report(20_000, 2_600))
        let off = delivery.rateInput(enabled: false, localQueueAge: 0.1, localDeliveredKbps: 180)
        XCTAssertFalse(off.usesPeer); XCTAssertEqual(off.queueAge, 0.1); XCTAssertEqual(off.deliveredKbps, 180)
        delivery.accept(LinkCapacityReport(arrivalKbps: 500, linkLate: true))
        XCTAssertFalse(delivery.rateInput(enabled: true, localQueueAge: 0, localDeliveredKbps: 200).usesPeer)
        delivery.accept(report(19_999, 2_700))
        XCTAssertEqual(delivery.fault, "counter_reset")
        XCTAssertNil(delivery.latest)
        delivery.accept(report(20_000, 2_800))
        XCTAssertFalse(delivery.rateInput(enabled: true, localQueueAge: 0, localDeliveredKbps: 200).usesPeer)
        let ahead = DesktopCallDelivery()
        ahead.accept(report(2_000_000, 1_000))
        XCTAssertEqual(ahead.fault, "counter_ahead")
    }

    func testByteAndClockWrapStayMonotonic() throws {
        let delivery = DesktopCallDelivery()
        delivery.submitted(payloadBytes: Int(UInt32.max) - 10, audio: false, at: 0)
        delivery.accept(report(UInt32.max - 10, UInt32.max - 10))
        delivery.submitted(payloadBytes: 20, audio: false, at: 0.02)
        delivery.accept(report(9, 9))
        delivery.submitted(payloadBytes: 1_000, audio: false, at: 1.02)
        delivery.accept(report(1_009, 1_009))
        XCTAssertNil(delivery.fault)
        XCTAssertEqual(try XCTUnwrap(delivery.latest).queueMs, 0)
        XCTAssertEqual(try XCTUnwrap(delivery.latest).videoKbps, 8, accuracy: 0.001)
    }

    func testOldAcknowledgementCannotMapToPrunedWrites() {
        let delivery = DesktopCallDelivery()
        delivery.submitted(payloadBytes: 1_000, audio: false, at: 0)
        delivery.submitted(payloadBytes: 1_000, audio: false, at: 30)
        delivery.accept(report(1_000, 31_000))
        XCTAssertNil(delivery.latest)
    }

    func testUnmatchedReportDiscardsPendingRateInput() {
        let delivery = DesktopCallDelivery()
        delivery.submitted(payloadBytes: 1_000, audio: false, at: 0)
        delivery.accept(report(1_000, 1_000))
        delivery.submitted(payloadBytes: 1_000, audio: false, at: 1)
        delivery.accept(report(2_000, 2_000))
        delivery.accept(report(2_100, 2_100))
        XCTAssertNil(delivery.fault, "A small lead can be transient, but is not a usable rate sample")
        XCTAssertFalse(delivery.rateInput(enabled: true, localQueueAge: 0, localDeliveredKbps: 200).usesPeer)
    }

    func testLongReportGapDoesNotKeepAnOldHighRateOrTreatLowLoadAsCongestion() throws {
        let delivery = DesktopCallDelivery()
        delivery.submitted(payloadBytes: 125_000, audio: false, at: 0)
        delivery.accept(report(125_000, 1_000))
        delivery.submitted(payloadBytes: 125_000, audio: false, at: 1)
        delivery.accept(report(250_000, 2_000))
        XCTAssertEqual(try XCTUnwrap(delivery.latest).videoKbps, 1_000, accuracy: 0.001)
        delivery.submitted(payloadBytes: 37_500, audio: false, at: 4)
        delivery.accept(report(287_500, 5_000))
        let input = delivery.rateInput(enabled: true, localQueueAge: 0, localDeliveredKbps: 1_000)
        XCTAssertEqual(input.deliveredKbps, 100, accuracy: 0.001)
        XCTAssertEqual(input.queueAge, 0)
        var controller = VideoRateController(startKbps: 1_000, maxKbps: 1_000)
        XCTAssertNil(controller.update(queueAge: input.queueAge, encodedKbps: 1_000, deliveredKbps: input.deliveredKbps))
    }

    func testProductionSealingMetadataMatchesPeersDeliveryCountersAndSkipsMuteAndRotation() throws {
        for fragments in [false, true] {
            let codec = NodeCapabilities.codecVP9
            let mac = CallEngine(role: .caller, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .video,
                                 encodeMask: codec, decodeMask: codec, videoFragments: fragments)
            let peer = CallEngine(role: .callee, transport: .gatt, identity: SoftwareSigningIdentity(), requestedType: .video,
                                  encodeMask: codec, decodeMask: codec, videoFragments: fragments)
            var clock: TimeInterval = 0
            func pump() {
                for _ in 0..<80 {
                    var moved = false
                    while let bytes = mac.nextOutgoing(now: clock) { peer.receive(bytes, now: clock); moved = true }
                    while let bytes = peer.nextOutgoing(now: clock) { mac.receive(bytes, now: clock); moved = true }
                    if !moved { return }
                }
                XCTFail("Call did not settle")
            }
            var submitted: [(Int, Bool)] = []
            var acknowledged: UInt32?
            mac.onMediaSubmitted = { bytes, audio, _ in submitted.append((bytes, audio)) }
            mac.onEvent = { if case .peerReport(let report) = $0 { acknowledged = report.receivedBytes } }
            try mac.start(now: 0); try peer.start(now: 0); pump()
            try peer.accept(as: .video); pump()
            clock = 1
            mac.sendRotation(90)
            mac.sendAudio(presentationTimeUs: 0, opus: Data([0xfc, 1, 2]))
            XCTAssertTrue(mac.sendVideo(flags: StreamProtocol.flagKeyFrame, presentationTimeUs: 0, payload: Data(repeating: 1, count: 5_000)))
            pump()
            peer.tick(now: 2); clock = 2; pump()
            let total = submitted.reduce(0) { $0 + $1.0 }
            XCTAssertEqual(total, OpusHead.make().count + 5_003 + (fragments ? StreamProtocol.packetHeaderBytes : 0))
            XCTAssertEqual(acknowledged, UInt32(total))
            XCTAssertEqual(submitted.filter { $0.1 }.map { $0.0 }, [OpusHead.make().count, 3])
            mac.setMuted(true); mac.sendAudio(presentationTimeUs: 2_000_000, opus: Data([0xfc, 9])); pump()
            XCTAssertEqual(submitted.reduce(0) { $0 + $1.0 }, total)
            mac.end(); pump()
            XCTAssertEqual(peer.state?.phase, .ended)
        }
    }
}
