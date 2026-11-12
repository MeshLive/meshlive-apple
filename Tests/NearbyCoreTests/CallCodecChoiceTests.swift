import XCTest
@testable import NearbyCore

/// AB5 step 4: the call codec choice against Android's negotiation table (Android `HcCodecNegotiationTest`,
/// `CodecPowerAwareTest`; the Android design record "Design HC" and "Automatic codec order after the 2026-10-28 phone measurements"):
/// the same peer masks give the same codec, list and reason. The Android phone sets are the ones Android's test uses;
/// the Apple set is this device's: VideoToolbox HEVC and H.264 (hardware) and the bundled libvpx VP9.
final class CallCodecChoiceTests: XCTestCase {
    private let vp9 = NodeCapabilities.codecVP9, av1 = NodeCapabilities.codecAV1
    private let h264 = NodeCapabilities.codecH264, hevc = NodeCapabilities.codecHEVC
    private let bit4 = NodeCapabilities.decodeAV1Software, bit7 = NodeCapabilities.decodePrefersVP9
    private let on = CodecChoiceSwitches(hevc: true, h264: true)

    private func c(_ name: String, _ codecId: UInt8, _ backend: VideoEncoderCandidate.Backend) -> VideoEncoderCandidate {
        VideoEncoderCandidate(name: name, codecId: codecId, backend: backend)
    }

    // Apple.
    private lazy var vtHevc = c("VideoToolbox HEVC", StreamProtocol.codecHEVC, .hardware)
    private lazy var vtAvc = c("VideoToolbox H264", StreamProtocol.codecH264, .hardware)
    private lazy var libvpx = c("libvpx VP9", StreamProtocol.codecVP9, .libvpx)
    private lazy var apple = [vtHevc, vtAvc, libvpx]
    // Android (the sets of Android's HcCodecNegotiationTest).
    private lazy var libaom = c("libaom-native", StreamProtocol.codecAV1, .software)
    private lazy var swAv1 = c("c2.android.av1.encoder", StreamProtocol.codecAV1, .software)
    private lazy var swVp9 = c("c2.android.vp9.encoder", StreamProtocol.codecVP9, .software)
    private lazy var swHevc = c("c2.android.hevc.encoder", StreamProtocol.codecHEVC, .software)
    private lazy var m31Vp9 = c("OMX.Exynos.VP9.Encoder", StreamProtocol.codecVP9, .hardware)
    private lazy var m31Hevc = c("OMX.Exynos.HEVC.Encoder", StreamProtocol.codecHEVC, .hardware)
    private lazy var m31 = [m31Vp9, m31Hevc, libaom, swAv1]
    private lazy var a15sAvc = c("OMX.MTK.VIDEO.ENCODER.AVC", StreamProtocol.codecH264, .hardware)
    private lazy var a15s = [a15sAvc, libaom, swAv1]
    private lazy var hwAv1 = c("c2.vendor.av1.encoder", StreamProtocol.codecAV1, .hardware)
    private lazy var hwHevc = c("c2.vendor.hevc.encoder", StreamProtocol.codecHEVC, .hardware)
    private lazy var hwVp9 = c("c2.vendor.vp9.encoder", StreamProtocol.codecVP9, .hardware)
    private lazy var hwAvc = c("c2.vendor.avc.encoder", StreamProtocol.codecH264, .hardware)

    private func call(_ available: [VideoEncoderCandidate], _ peer: UInt8, _ switches: CodecChoiceSwitches? = nil,
                      ineligible: Set<String> = []) -> CallCodecChoice {
        CallCodecChoice.forCall(available: available, peerDecodeMask: peer, switches: switches ?? on, ineligible: ineligible)
    }

    /// The Apple order: hardware HEVC, then libvpx VP9, then hardware H.264.
    func testTheAppleAutomaticOrderIsHevcThenLibvpxThenH264() {
        XCTAssertEqual(CallCodecChoice.automatic(apple, switches: on), [vtHevc, libvpx, vtAvc])
        XCTAssertEqual(CallCodecChoice.automatic([libvpx, vtAvc, vtHevc], switches: on), [vtHevc, libvpx, vtAvc], "input order does not matter")
        XCTAssertEqual(CallCodecChoice.automatic(apple, switches: CodecChoiceSwitches(hevc: false, h264: true)), [libvpx, vtAvc])
    }

    func testAnAndroidPeerWithHevcGetsHardwareHevcAndOldPeersGetVp9() {
        let android042 = call(apple, vp9 | av1 | h264 | hevc | bit4)
        XCTAssertEqual(android042.sent, vtHevc)
        XCTAssertEqual(android042.reason, "hw_hevc_preferred")
        XCTAssertEqual(android042.ordered, [vtHevc, libvpx, vtAvc])
        for old: UInt8 in [vp9 | av1, vp9] { // Android before 0.4.2 (or masters off), an Apple build before AB5
            let choice = call(apple, old)
            XCTAssertEqual(choice.sent, libvpx, "peer \(old)")
            XCTAssertEqual(choice.reason, "peer_no_hevc_decode")
            XCTAssertEqual(choice.ordered, [libvpx], "fallback walks only codecs the peer decodes")
        }
        XCTAssertEqual(call(apple, h264).sent, vtAvc, "a peer that decodes only H.264")
        XCTAssertEqual(call(apple, h264).reason, "peer_no_hevc_decode")
        XCTAssertEqual(call(apple, vp9 | h264).sent, libvpx, "libvpx ranks above hardware H.264")
        let none = call(apple, 0)
        XCTAssertNil(none.sent)
        XCTAssertEqual(none.reason, "no_common_codec")
    }

    /// Peer bit 7 (legacy Qualcomm): VP9 first, below only a hardware HEVC encoder the peer decodes; ignored without VP9.
    func testBit7KeepsHardwareHevcFirstAndOtherwisePutsVp9First() {
        let asusHello = vp9 | av1 | hevc | bit4 | bit7
        XCTAssertEqual(asusHello, 0x9b)
        let toAsus = call(apple, asusHello)
        XCTAssertEqual(toAsus.sent, vtHevc)
        XCTAssertEqual(toAsus.notes, ["bit7_hw_hevc_first"])
        XCTAssertEqual(toAsus.ordered, [vtHevc, libvpx])
        let vp9Peer = call(apple, vp9 | av1 | bit7)
        XCTAssertEqual(vp9Peer.sent, libvpx)
        XCTAssertEqual(vp9Peer.reason, "peer_prefers_vp9")
        let noVp9 = call(apple, hevc | bit7)
        XCTAssertEqual(noVp9.sent, vtHevc)
        XCTAssertEqual(noVp9.notes, ["bit7_without_vp9_ignored"])
        let controlArm = call(apple, vp9 | hevc | bit7, CodecChoiceSwitches(hevc: true, h264: true, bit7AllowsHwHevc: false))
        XCTAssertEqual(controlArm.sent, libvpx)
        XCTAssertEqual(controlArm.reason, "peer_prefers_vp9")
        // Android's own cases give Android's answers.
        XCTAssertEqual(call(m31, asusHello).sent, m31Hevc)
        XCTAssertEqual(Array(call(m31, asusHello).ordered.prefix(2)), [m31Hevc, m31Vp9])
        XCTAssertEqual(call([hwAv1, hwHevc, hwVp9, hwAvc], asusHello | h264).ordered, [hwHevc, hwVp9, hwAv1, hwAvc])
        XCTAssertEqual(call([hwAv1, hwVp9, hwAvc], asusHello).sent, hwVp9)
        XCTAssertEqual(call([hwAv1, hwVp9, hwAvc], asusHello).reason, "peer_prefers_vp9")
        XCTAssertEqual(call([libaom, swVp9, swHevc], asusHello).sent, swVp9, "a software HEVC encoder is never in Automatic")
        XCTAssertEqual(call(m31, vp9 | av1 | bit7).reason, "peer_prefers_vp9")
        XCTAssertEqual(call(m31, hevc | bit7).notes, ["bit7_without_vp9_ignored"])
        XCTAssertEqual(call(m31, asusHello, CodecChoiceSwitches(hevc: true, h264: true, bit7AllowsHwHevc: false)).sent, m31Vp9)
    }

    /// Peer bit 4 (software AV1 decoding) moves AV1 below hardware HEVC and VP9, never below hardware H.264.
    func testBit4MovesAv1BelowHardwareHevcAndVp9Only() {
        let all = vp9 | av1 | hevc | h264 | bit4
        XCTAssertEqual(call([hwAv1, hwHevc, libaom], all).sent, hwHevc)
        XCTAssertEqual(call([hwAv1, hwHevc, libaom], all).reason, "peer_av1_software")
        XCTAssertEqual(call([hwAv1, hwVp9, libaom], all).sent, hwVp9)
        XCTAssertEqual(call([hwAv1, hwAvc, libaom], all).sent, hwAv1)
        XCTAssertEqual(call([hwAv1, hwHevc, hwVp9, hwAvc, libaom], all & ~bit4).sent, hwAv1)
        XCTAssertEqual(call([hwAv1, libaom, swVp9], all).sent, hwAv1)
        XCTAssertEqual(call([hwAv1, hwHevc, hwVp9, hwAvc, libaom], all).ordered, [hwHevc, hwVp9, hwAv1, hwAvc, libaom])
    }

    func testFallbackControlArmsAndIneligibleEncoders() {
        XCTAssertEqual(call(a15s, vp9 | av1).sent, libaom)
        XCTAssertEqual(call(a15s, vp9 | av1).reason, "peer_no_avc_decode")
        let noHevc = call(apple, vp9 | av1 | hevc | h264, CodecChoiceSwitches(hevc: true, h264: true, preferHevc: false))
        XCTAssertEqual(noHevc.sent, libvpx)
        XCTAssertEqual(noHevc.reason, "hevc_not_preferred")
        XCTAssertFalse(noHevc.ordered.contains(vtHevc), "a control arm removes its codec from Automatic")
        XCTAssertEqual(call(m31, vp9 | av1 | hevc, CodecChoiceSwitches(hevc: true, h264: true, preferHevc: false)).sent, m31Vp9)
        let noAvc = call(a15s, vp9 | av1 | h264, CodecChoiceSwitches(hevc: true, h264: true, preferAvc: false))
        XCTAssertEqual(noAvc.sent, libaom)
        XCTAssertEqual(noAvc.reason, "avc_not_preferred")
        let noIdr = call(apple, vp9 | av1 | hevc | h264, ineligible: ["VideoToolbox HEVC"])
        XCTAssertEqual(noIdr.sent, libvpx)
        XCTAssertEqual(noIdr.reason, "ineligible:policy")
        XCTAssertEqual(call(m31, vp9 | av1 | hevc, ineligible: ["OMX.Exynos.HEVC.Encoder"]).sent, m31Vp9)
        XCTAssertEqual(call(m31, vp9 | av1 | h264 | hevc | bit4).sent, m31Hevc)
        XCTAssertEqual(call(m31, vp9 | av1).reason, "peer_no_hevc_decode")
    }

    /// `codec_power_aware`: Low Power Mode or a warm device at call start moves hardware H.264 above libvpx when HEVC is not
    /// possible; never over bit 7, never when the first choice is already hardware, and not with the control arm.
    func testPowerAwareStartPrefersHardwareH264OverLibvpx() {
        let saver = CodecChoiceSwitches(hevc: true, h264: true, power: .saver)
        let toVp9H264Peer = call(apple, vp9 | h264, saver)
        XCTAssertEqual(toVp9H264Peer.sent, vtAvc)
        XCTAssertEqual(toVp9H264Peer.reason, "power_prefers_hw_avc")
        XCTAssertTrue(toVp9H264Peer.powerApplied)
        XCTAssertEqual(toVp9H264Peer.ordered, [vtAvc, libvpx])
        XCTAssertEqual(call(apple, vp9 | h264 | hevc, CodecChoiceSwitches(hevc: true, h264: true, power: .warm)).sent, vtHevc)
        XCTAssertEqual(call(apple, vp9 | h264 | bit7, saver).sent, libvpx, "bit 7 wins")
        let controlArm = call(apple, vp9 | h264, CodecChoiceSwitches(hevc: true, h264: true, powerAware: false, power: .saver))
        XCTAssertEqual(controlArm.sent, libvpx)
        XCTAssertFalse(controlArm.powerApplied)
    }

    /// The `encoder_choice` fields carry the choice, the list and the switches.
    func testTheLogFieldsNameTheChoice() {
        let fields = call(apple, vp9 | hevc).logFields(role: "call")
        XCTAssertEqual(fields["codec"], "HEVC")
        XCTAssertEqual(fields["reason"], "hw_hevc_preferred")
        XCTAssertEqual(fields["list"], "VideoToolbox HEVC,libvpx VP9")
        XCTAssertEqual(fields["peer_decode_mask"], "9")
        XCTAssertEqual(fields["power"], "normal")
    }
}
