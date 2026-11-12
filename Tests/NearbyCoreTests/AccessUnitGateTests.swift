import XCTest
@testable import NearbyCore

/// AB5 step 3: the receiver's access-unit gate (PROTOCOL "Access-unit validation", rules 1-11 and the outcomes), the
/// sender's packetiser ("Sender rules") and the keyframe-request rule. HEVC: Android's M31 hardware vectors
/// (`AnnexBTests`). H.264: synthetic Constrained Baseline 640x480 streams written from ITU-T H.264 (SPS
/// `6742c01eda0280f640`, PPS `68ce3c80`, one IDR and one P slice), plus one negative per rule.
final class AccessUnitGateTests: XCTestCase {
    private let start = AnnexB.startCode
    private let key = StreamProtocol.flagKeyFrame
    private let hevcP = Data(hex: "000000010201d0744e17370529df6a47e361c8a4b469bfbe9bcbd09f9dc77aea8fd571f4d430bf43964c243b")!
    private let trailSlice = Data(hex: "0201d0744e17370529df6a47e361c8a4b469bfbe9bcbd09f9dc77aea8fd571f4d430bf43964c243b")!
    private let avcSps = Data(hex: "6742c01eda0280f640")!
    private let avcPps = Data(hex: "68ce3c80")!
    private let avcIdr = Data(hex: "6588a020a121a222a323a424a525a626a727a828a929aa2aab2bac2cad2dae2eaf2fc0")!
    private let avcP = Data(hex: "419a80828486888a8c8e90929496989a9c9ea0a2a4a6a8aaacaeb0b2b4b6b8babcbf")!
    private var hevcKey: Data { AnnexBTests.keyFrame }
    private var avcKey: Data { AnnexB.annexB([avcSps, avcPps, avcIdr]) }

    private func hevcKeyFrame(vps: Data = AnnexBTests.vps, sps: Data = AnnexBTests.sps, pps: Data = AnnexBTests.pps,
                              slice: Data = AnnexBTests.idrSlice) -> Data {
        AnnexB.annexB([vps, sps, pps, slice])
    }

    private func mutated(_ data: Data, at index: Int, to value: UInt8) -> Data {
        var copy = data
        copy[index] = value
        return copy
    }

    private func rule(_ verdict: AuVerdict) -> Int? {
        if case .reject(let rule, _, _, _, _) = verdict { return rule }
        return nil
    }

    private func accepted(_ verdict: AuVerdict) -> (Data, Bool, ParameterSets?)? {
        if case .accept(let unit, let keyFrame, let activated) = verdict { return (unit, keyFrame, activated) }
        return nil
    }

    func testAndroidsHevcKeyFrameAndPFrameAreAccepted() throws {
        for (width, height) in [(352, 288), (288, 352)] {
            let gate = AccessUnitGate(codec: .hevc, headerMaxWidth: width, headerMaxHeight: height)
            let first = try XCTUnwrap(accepted(gate.check(hevcKey, flags: key, nowMs: 0)), "header \(width)x\(height)")
            XCTAssertEqual(first.0, hevcKey)
            XCTAssertTrue(first.1)
            XCTAssertEqual(first.2?.visibleWidth, 352)
            XCTAssertEqual(first.2?.visibleHeight, 288)
            let second = try XCTUnwrap(accepted(gate.check(hevcP, flags: 0, nowMs: 66)))
            XCTAssertEqual(second.0, hevcP)
            XCTAssertFalse(second.1)
            XCTAssertNil(second.2, "a P frame activates nothing")
            // The same sets again activate nothing new.
            XCTAssertNil(try XCTUnwrap(accepted(gate.check(hevcKey, flags: key, nowMs: 133))).2)
        }
    }

    func testH264BaselineHighAndPoc0StreamsAreAccepted() throws {
        let gate = AccessUnitGate(codec: .h264, headerMaxWidth: 640, headerMaxHeight: 480)
        let first = try XCTUnwrap(accepted(gate.check(avcKey, flags: key, nowMs: 0)))
        XCTAssertEqual(first.2?.visibleWidth, 640)
        XCTAssertEqual(first.2?.visibleHeight, 480)
        XCTAssertNotNil(accepted(gate.check(start + avcP, flags: 0, nowMs: 66)))
        for sps in ["6764001eacb40501ec80", "6742c01eed01407b403682211a80"] { // High; POC type 0 with VUI max_num_reorder_frames 0
            let other = AccessUnitGate(codec: .h264, headerMaxWidth: 480, headerMaxHeight: 640)
            XCTAssertNotNil(accepted(other.check(AnnexB.annexB([Data(hex: sps)!, avcPps, avcIdr]), flags: key, nowMs: 0)), sps)
        }
        // The portrait call size: 240x432 coded, cropped to 240x426.
        let call = AccessUnitGate(codec: .h264, headerMaxWidth: 240, headerMaxHeight: 426)
        let sets = try XCTUnwrap(accepted(call.check(AnnexB.annexB([Data(hex: "6742c01eda0f0dfe44")!, avcPps, avcIdr]), flags: key, nowMs: 0))?.2)
        XCTAssertEqual(sets.visibleWidth, 240)
        XCTAssertEqual(sets.visibleHeight, 426)
    }

    /// One negative vector per rule; each is dropped with its rule number, and an accepted IDR first where the rule needs one.
    func testEveryRuleRejectsItsNegativeVector() {
        var badEscape = AnnexBTests.idrSlice
        badEscape.replaceSubrange(10..<14, with: [0x00, 0x00, 0x03, 0x04])
        let sei = Data(hex: "4e01050280")!
        let cases: [(name: String, codec: AnnexBCodec, header: (Int, Int), steps: [(Data, UInt8)], rule: Int)] = [
            ("no start code", .hevc, (352, 288), [(hevcKey.dropFirst(4).rebased, key)], 1),
            ("bad escape", .hevc, (352, 288), [(hevcKeyFrame(slice: badEscape), key)], 1),
            ("nine NAL units", .hevc, (352, 288), [(AnnexB.annexB([AnnexBTests.vps, AnnexBTests.sps, AnnexBTests.pps, sei, sei, sei, sei, sei, AnnexBTests.idrSlice]), key)], 1),
            ("temporal ID 1", .hevc, (352, 288), [(hevcKeyFrame(slice: mutated(AnnexBTests.idrSlice, at: 1, to: 0x02)), key)], 2),
            ("CRA", .hevc, (352, 288), [(hevcKeyFrame(slice: mutated(AnnexBTests.idrSlice, at: 0, to: 21 << 1)), key)], 3),
            ("two slices", .hevc, (352, 288), [(hevcKey + start + AnnexBTests.idrSlice, key)], 4),
            ("not the first slice segment", .hevc, (352, 288), [(hevcKeyFrame(slice: mutated(AnnexBTests.idrSlice, at: 2, to: 0x2f)), key)], 4),
            ("prefix SEI after the slice", .hevc, (352, 288), [(hevcKey + start + sei, key)], 4),
            ("IDR without the keyframe flag", .hevc, (352, 288), [(hevcKey, 0)], 5),
            ("keyframe flag on a P frame", .hevc, (352, 288), [(hevcKey, key), (hevcP, key)], 5),
            ("IDR without a VPS", .hevc, (352, 288), [(AnnexB.annexB([AnnexBTests.sps, AnnexBTests.pps, AnnexBTests.idrSlice]), key)], 5),
            ("P frame with a PPS", .hevc, (352, 288), [(hevcKey, key), (AnnexB.annexB([AnnexBTests.pps, trailSlice]), 0)], 5),
            ("P frame before any IDR", .hevc, (352, 288), [(hevcP, 0)], 5),
            ("larger than the header", .hevc, (320, 240), [(hevcKey, key)], 6),
            ("VPS with two layers", .hevc, (352, 288), [(hevcKeyFrame(vps: mutated(AnnexBTests.vps, at: 3, to: 0x11)), key)], 7),
            ("SPS profile space 1", .hevc, (352, 288), [(hevcKeyFrame(sps: mutated(AnnexBTests.sps, at: 3, to: 0x41)), key)], 8),
            ("H.264 POC type 0 without VUI", .h264, (640, 480), [(AnnexB.annexB([Data(hex: "6742c01eed01407b20")!, avcPps, avcIdr]), key)], 9),
            ("H.264 VUI reorder 1", .h264, (640, 480), [(AnnexB.annexB([Data(hex: "6742c01eed01407b4036822114a0")!, avcPps, avcIdr]), key)], 9),
            ("H.264 profile 88", .h264, (640, 480), [(AnnexB.annexB([Data(hex: "6758c01eda0280f640")!, avcPps, avcIdr]), key)], 9),
            ("H.264 656 wide", .h264, (640, 480), [(AnnexB.annexB([Data(hex: "6742c01eda0290f640")!, avcPps, avcIdr]), key)], 6),
            ("H.264 redundant_pic_cnt", .h264, (640, 480), [(AnnexB.annexB([avcSps, Data(hex: "68ce3d80")!, avcIdr]), key)], 10),
            ("H.264 I slice outside an IDR", .h264, (640, 480),
             [(avcKey, key), (start + Data(hex: "4188a020a121a222a323a424a525a626a727a828a929aa2aab2bac2cad2dae2eaf2fc0")!, 0)], 4),
            ("H.264 first_mb_in_slice 1", .h264, (640, 480),
             [(AnnexB.annexB([avcSps, avcPps, Data(hex: "6542280828486888a8c8e90929496989a9c9ea0a2a4a6a8aaacaeb0b2b4b6b8babcbf0")!]), key)], 4),
        ]
        for c in cases {
            let gate = AccessUnitGate(codec: c.codec, headerMaxWidth: c.header.0, headerMaxHeight: c.header.1)
            var last: AuVerdict?
            for (i, step) in c.steps.enumerated() {
                last = gate.check(step.0, flags: step.1, nowMs: Int64(i) * 100)
                if i < c.steps.count - 1 { XCTAssertNotNil(accepted(last!), "\(c.name): step \(i) must pass") }
            }
            XCTAssertEqual(rule(last!), c.rule, c.name)
        }
    }

    /// Rule 11: SEI, AUD and filler are removed before decoding.
    func testSeiAudAndFillerAreStripped() throws {
        var withExtras = start + Data(hex: "460150")!
        withExtras += hevcKeyFrame().dropLast(AnnexBTests.idrSlice.count + 4).rebased
        withExtras += start + Data(hex: "4e01050280")!
        withExtras += start + AnnexBTests.idrSlice
        withExtras += start + Data(hex: "5001050280")!
        withExtras += start + Data(hex: "4c01ffff80")!
        let gate = AccessUnitGate(codec: .hevc, headerMaxWidth: 352, headerMaxHeight: 288)
        XCTAssertEqual(try XCTUnwrap(accepted(gate.check(withExtras, flags: key, nowMs: 0))).0, hevcKey)
    }

    func testCodecConfigAndDiscardablePacketsCloseTheSession() {
        let gate = AccessUnitGate(codec: .hevc, headerMaxWidth: 352, headerMaxHeight: 288)
        XCTAssertEqual(gate.check(hevcKey, flags: key | StreamProtocol.flagCodecConfig, nowMs: 0), .close("codec_config"))
        XCTAssertEqual(gate.check(hevcKey, flags: key, nowMs: 1), .close("codec_config"), "a closed session stays closed")
        let other = AccessUnitGate(codec: .h264, headerMaxWidth: 640, headerMaxHeight: 480)
        XCTAssertEqual(other.check(start + avcP, flags: StreamProtocol.flagDiscardable, nowMs: 0), .close("discardable"))
    }

    func testThreeRejectedKeyframesWithinTenSecondsCloseTheSession() {
        let broken = hevcKeyFrame(sps: mutated(AnnexBTests.sps, at: 3, to: 0x41))
        let gate = AccessUnitGate(codec: .hevc, headerMaxWidth: 352, headerMaxHeight: 288)
        XCTAssertEqual(rule(gate.check(broken, flags: key, nowMs: 0)), 8)
        XCTAssertEqual(rule(gate.check(broken, flags: key, nowMs: 4_000)), 8)
        XCTAssertEqual(gate.check(broken, flags: key, nowMs: 10_000), .close("rejected_keyframes"))
        let slower = AccessUnitGate(codec: .hevc, headerMaxWidth: 352, headerMaxHeight: 288)
        XCTAssertEqual(rule(slower.check(broken, flags: key, nowMs: 0)), 8)
        XCTAssertEqual(rule(slower.check(broken, flags: key, nowMs: 6_000)), 8)
        XCTAssertEqual(rule(slower.check(broken, flags: key, nowMs: 10_001)), 8, "the first and third are more than 10 s apart")
        XCTAssertNotNil(accepted(slower.check(hevcKey, flags: key, nowMs: 10_002)))
    }

    func testARejectedIdrKeepsTheActiveSetsAndDropsPFramesUntilTheNextValidIdr() throws {
        let broken = hevcKeyFrame(sps: mutated(AnnexBTests.sps, at: 3, to: 0x41))
        let gate = AccessUnitGate(codec: .hevc, headerMaxWidth: 352, headerMaxHeight: 288)
        XCTAssertNotNil(accepted(gate.check(hevcKey, flags: key, nowMs: 0)))
        let before = gate.active
        XCTAssertEqual(rule(gate.check(broken, flags: key, nowMs: 100)), 8)
        XCTAssertEqual(gate.active, before)
        XCTAssertTrue(gate.waitingForIdr)
        XCTAssertEqual(rule(gate.check(hevcP, flags: 0, nowMs: 200)), 5)
        XCTAssertNotNil(accepted(gate.check(hevcKey, flags: key, nowMs: 300)))
        XCTAssertFalse(gate.waitingForIdr)
        XCTAssertNotNil(accepted(gate.check(hevcP, flags: 0, nowMs: 400)))
    }

    /// Sender: VideoToolbox gives length-prefixed NAL units and its parameter sets in the format description.
    func testThePacketiserPutsTheSetsBeforeEveryIdrOnlyAndTakesTheFlagFromTheNalType() {
        var packetiser = HardwareAccessUnitPacketiser(codec: .hevc)
        XCTAssertEqual(packetiser.packetise([AnnexBTests.idrSlice], presentationTimeUs: 0), .error("no_parameter_sets"))
        packetiser.updateParameterSets([AnnexBTests.pps, AnnexBTests.vps, AnnexBTests.sps])
        XCTAssertEqual(packetiser.packetise([AnnexBTests.idrSlice], presentationTimeUs: 1),
                       .packet(payload: hevcKey, keyFrame: true, visibleWidth: 352, visibleHeight: 288))
        let sei = Data(hex: "4e01050280")!, aud = Data(hex: "460150")!
        XCTAssertEqual(packetiser.packetise([aud, AnnexBTests.sps, sei, trailSlice], presentationTimeUs: 2),
                       .packet(payload: hevcP, keyFrame: false, visibleWidth: nil, visibleHeight: nil), "sets, SEI and AUD leave a P frame")
        XCTAssertEqual(packetiser.packetise([trailSlice], presentationTimeUs: 2), .error("reorder"))
        XCTAssertEqual(packetiser.packetise([trailSlice, trailSlice], presentationTimeUs: 3), .error("multi_slice"))
        XCTAssertEqual(packetiser.packetise([mutated(AnnexBTests.idrSlice, at: 0, to: 21 << 1)], presentationTimeUs: 4), .error("unsupported_nal 21"))
        var broken = HardwareAccessUnitPacketiser(codec: .hevc)
        broken.updateParameterSets([AnnexBTests.vps, mutated(AnnexBTests.sps, at: 3, to: 0x41), AnnexBTests.pps])
        guard case .error(let reason) = broken.packetise([AnnexBTests.idrSlice], presentationTimeUs: 0) else { return XCTFail("a refused SPS must not be sent") }
        XCTAssertTrue(reason.hasPrefix("no_parameter_sets"), reason)
        XCTAssertNotNil(broken.parameterSetProblem)
        var avc = HardwareAccessUnitPacketiser(codec: .h264)
        avc.updateParameterSets([avcSps, avcPps])
        XCTAssertEqual(avc.packetise([avcIdr], presentationTimeUs: 0), .packet(payload: avcKey, keyFrame: true, visibleWidth: 640, visibleHeight: 480))
    }

    /// The packetiser's output passes the receiver's gate (what is sent is what is accepted).
    func testPacketiserOutputPassesTheGate() throws {
        var packetiser = HardwareAccessUnitPacketiser(codec: .hevc)
        packetiser.updateParameterSets([AnnexBTests.vps, AnnexBTests.sps, AnnexBTests.pps])
        let gate = AccessUnitGate(codec: .hevc, headerMaxWidth: 352, headerMaxHeight: 288)
        for (pts, slice) in [(Int64(0), AnnexBTests.idrSlice), (66_666, trailSlice)] {
            guard case .packet(let payload, let keyFrame, _, _) = packetiser.packetise([slice], presentationTimeUs: pts) else { return XCTFail("packet \(pts)") }
            XCTAssertNotNil(accepted(gate.check(payload, flags: keyFrame ? key : 0, nowMs: pts / 1000)))
        }
    }

    func testAKeyframeRequestIsRepeatedEverySecondAndGivesUpAfterThreeMisses() {
        var tracker = IdrRequestTracker()
        XCTAssertEqual(tracker.tick(now: 0), .none)
        tracker.requested(now: 10)
        tracker.requested(now: 10.5) // keeps the first deadline
        XCTAssertEqual(tracker.tick(now: 10.9), .none)
        tracker.emitted(idr: false)
        XCTAssertEqual(tracker.tick(now: 11.0), .repeatRequest)
        XCTAssertEqual(tracker.tick(now: 12.0), .repeatRequest)
        XCTAssertEqual(tracker.tick(now: 13.0), .giveUp)
        XCTAssertFalse(tracker.waiting)
        var answered = IdrRequestTracker()
        answered.requested(now: 0)
        XCTAssertEqual(answered.tick(now: 1.0), .repeatRequest)
        answered.emitted(idr: true)
        XCTAssertEqual(answered.tick(now: 5.0), .none)
        answered.requested(now: 6)
        XCTAssertEqual(answered.tick(now: 7.0), .repeatRequest, "an IDR resets the miss count")
        XCTAssertEqual(answered.tick(now: 8.0), .repeatRequest)
        XCTAssertEqual(answered.tick(now: 9.0), .giveUp)
    }
}
