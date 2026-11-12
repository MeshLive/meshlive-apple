import XCTest
import CoreMedia
import CoreVideo
@testable import NearbyCore
@testable import NearbyMedia

/// Android's M31 hardware HEVC parameter sets (Exynos, Main, 352x288; the same vectors as `AnnexBTests`).
private enum AnnexBTestVectors {
    static let vps = Data(hex: "40010c01ffff0160000003000003000003000003003c2c09")!
    static let sps = Data(hex: "4201010160000003000003000003000003003ca00b080485a2d2bb04bb9a8101010040")!
    static let pps = Data(hex: "4401c0667c0cc640")!
}

/// AB5B (runs on the Mac): VideoToolbox hardware encoders feed the packetiser, every access unit passes the receiver's
/// gate (the rules Android applies to what this device sends), and the VideoToolbox decoder shows the picture again at
/// its visible size. H.264 must pass. HEVC is offered only when one probe setup's output passes the gate (PROTOCOL rule 7
/// and rule 2 are not relaxed); otherwise it is not advertised, and the probe names why for every setup it tried.
final class HardwareCodecRoundTripTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StreamProtocol.hevcEnabled = true
        StreamProtocol.h264Enabled = true
    }

    override func tearDown() {
        StreamProtocol.hevcEnabled = false
        StreamProtocol.h264Enabled = false
        super.tearDown()
    }

    private func meanLumaDifference(_ a: I420Picture, _ b: I420Picture) -> Double {
        zip(a.y, b.y).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.y.count)
    }

    /// 30 frames at the portrait call size: an IDR first, a forced IDR at frame 20, P frames between; every unit passes the
    /// gate in order and decodes back to 240x426 close to the source.
    private func roundTrip(_ configuration: HardwareEncoderConfiguration) throws {
        let codec = configuration.profile.codec
        let (width, height, fps) = (240, 426, 15)
        let encoder = try VideoToolboxEncoder(configuration: configuration, width: width, height: height, fps: fps, bitrateKbps: 300)
        let gate = AccessUnitGate(codec: codec, headerMaxWidth: width, headerMaxHeight: height)
        let decoder = try VideoToolboxDecoder(codecId: codec.rawValue)
        var decoded: [CVPixelBuffer] = []
        decoder.onPicture = { pixels, _ in decoded.append(pixels) }
        var keyFrames: [Int] = [], units = 0, last: I420Picture?
        for i in 0..<30 {
            let picture = HardwareEncoderSupport.testPicture(width: width, height: height, frame: i)
            let pts = Int64(i) * 66_667
            guard let unit = try encoder.encode(picture, presentationTimeUs: pts, forceKeyFrame: i == 0 || i == 20) else { continue }
            units += 1
            if unit.keyFrame { keyFrames.append(i) }
            let flags = unit.keyFrame ? StreamProtocol.flagKeyFrame : 0
            let verdict = gate.check(unit.data, flags: flags, nowMs: pts / 1000)
            guard case .accept(let accessUnit, let keyFrame, _) = verdict else {
                return XCTFail("\(configuration.label) frame \(i) refused by the gate: \(verdict)")
            }
            XCTAssertEqual(keyFrame, unit.keyFrame)
            XCTAssertEqual(accessUnit, unit.data, "the sender already strips SEI, AUD and filler")
            try decoder.decode(accessUnit, presentationTimeUs: pts, keyFrame: keyFrame)
            last = picture
        }
        XCTAssertEqual(keyFrames.first, 0)
        XCTAssertTrue(keyFrames.contains(20), "a forced keyframe is an IDR: \(keyFrames)")
        XCTAssertGreaterThanOrEqual(units, 28)
        XCTAssertGreaterThanOrEqual(decoded.count, units - 1)
        let picture = try XCTUnwrap(decoded.last)
        XCTAssertEqual(CVPixelBufferGetWidth(picture), width)
        XCTAssertEqual(CVPixelBufferGetHeight(picture), height)
        let back = try XCTUnwrap(PixelConversion.i420(from: picture, width: width, height: height))
        XCTAssertLessThan(meanLumaDifference(back, try XCTUnwrap(last)), 12, "the decoded picture matches the source")
    }

    /// Every probe attempt, for the report (`hc_probe_attempt` lines).
    private func printAttempts() {
        for codec in AnnexBCodec.allCases {
            for attempt in HardwareEncoderSupport.probeAttempts(codec) { print("hc_probe_attempt codec=\(codec.label) \(attempt)") }
        }
    }

    func testH264EncodeGateDecodeRoundTrip() throws {
        printAttempts()
        let configuration = try XCTUnwrap(HardwareEncoderSupport.eligible(.h264),
                                          "no H.264 hardware encoder passed the receiver rules: \(HardwareEncoderSupport.probeProblem(.h264) ?? "-")")
        try roundTrip(configuration)
    }

    /// HEVC either has a setup whose output passes the gate (then it round-trips like H.264), or it is not offered at all
    /// and the probe tried every setup of the ladder and says why each was refused. Never anything in between.
    func testHevcIsOfferedOnlyWithASetupThatPassesTheGate() throws {
        printAttempts()
        let attempts = HardwareEncoderSupport.probeAttempts(.hevc)
        if let configuration = HardwareEncoderSupport.eligible(.hevc) {
            XCTAssertTrue(attempts.last?.hasSuffix("passed") == true, "\(attempts)")
            XCTAssertNotEqual(VideoDecoderSupport.encodeMask & NodeCapabilities.codecHEVC, 0)
            try roundTrip(configuration)
        } else {
            XCTAssertEqual(attempts.count, VideoToolboxSetup.ladder(.hevc).count, "every setup was tried: \(attempts)")
            XCTAssertFalse(attempts.contains { $0.hasSuffix("passed") }, "\(attempts)")
            XCTAssertEqual(VideoDecoderSupport.encodeMask & NodeCapabilities.codecHEVC, 0, "HEVC encode is not advertised")
            XCTAssertNotEqual(VideoDecoderSupport.decodeMask & NodeCapabilities.codecHEVC, 0, "HEVC decode still works")
            print("hc_probe_result codec=HEVC result=HEVC encode unavailable on this Mac")
        }
    }

    /// Android's M31 HEVC sets (and a Constrained Baseline H.264 SPS/PPS) open a VideoToolbox decoder at their size.
    func testAndroidsParameterSetsOpenAVideoToolboxDecoder() throws {
        XCTAssertTrue(VideoDecoderSupport.videoToolboxHEVC)
        XCTAssertTrue(VideoDecoderSupport.videoToolboxH264)
        let format = try VideoToolboxDecoder.formatDescription(codec: .hevc, sets: [AnnexBTestVectors.vps, AnnexBTestVectors.sps, AnnexBTestVectors.pps])
        let size = CMVideoFormatDescriptionGetDimensions(format)
        XCTAssertEqual(size.width, 352)
        XCTAssertEqual(size.height, 288)
    }

    /// The hello masks carry a codec only with its master on, and encode only for a codec whose probe passed.
    func testTheMasksFollowTheMastersAndTheProbe() {
        XCTAssertNotEqual(VideoDecoderSupport.decodeMask & NodeCapabilities.codecHEVC, 0)
        XCTAssertNotEqual(VideoDecoderSupport.decodeMask & NodeCapabilities.codecH264, 0)
        XCTAssertNotEqual(VideoDecoderSupport.encodeMask & NodeCapabilities.codecH264, 0)
        XCTAssertEqual(VideoDecoderSupport.encodeMask & NodeCapabilities.codecHEVC != 0, HardwareEncoderSupport.isEligible(.hevc))
        StreamProtocol.hevcEnabled = false
        StreamProtocol.h264Enabled = false
        XCTAssertEqual(VideoDecoderSupport.decodeMask & (NodeCapabilities.codecHEVC | NodeCapabilities.codecH264), 0)
        XCTAssertEqual(VideoDecoderSupport.encodeMask & (NodeCapabilities.codecHEVC | NodeCapabilities.codecH264), 0)
    }

    /// The encoder stays near the requested rate (200, 400 and 800 kbps). Overshoot is what hurts a Bluetooth link, so
    /// the bound is 1.5 times the request over 3 s of moving test pictures after the first keyframe. Every eligible codec.
    func testTheEncoderOutputStaysNearTheRequestedRate() throws {
        let configurations = AnnexBCodec.allCases.compactMap { HardwareEncoderSupport.eligible($0) }
        XCTAssertTrue(configurations.contains { $0.profile.codec == .h264 }, "H.264 is eligible")
        for configuration in configurations {
            for kbps in [200, 400, 800] {
                let encoder = try VideoToolboxEncoder(configuration: configuration, width: 360, height: 640, fps: 15, bitrateKbps: kbps)
                var bytes = 0
                for i in 0..<60 {
                    let picture = HardwareEncoderSupport.testPicture(width: 360, height: 640, frame: i * 7)
                    guard let unit = try encoder.encode(picture, presentationTimeUs: Int64(i) * 66_667, forceKeyFrame: i == 0) else { continue }
                    if i >= 15 { bytes += unit.data.count }
                }
                let achieved = Double(bytes * 8) / 3.0 / 1000
                print("encoder_rate codec=\(configuration.profile.codec.label) configuration=\(configuration.label) mode=\(encoder.rateMode) requested=\(kbps) achieved=\(Int(achieved))")
                XCTAssertLessThan(achieved, Double(kbps) * 1.5, "\(configuration.label) at \(kbps) kbps")
            }
        }
    }

    /// A rate change takes effect on the running encoder, or is reported as refused (never silent).
    func testARateChangeIsAppliedOrReported() throws {
        let configuration = try XCTUnwrap(HardwareEncoderSupport.eligible(.h264))
        let encoder = try VideoToolboxEncoder(configuration: configuration, width: 240, height: 426, fps: 15, bitrateKbps: 400)
        _ = try encoder.encode(HardwareEncoderSupport.testPicture(width: 240, height: 426, frame: 0), presentationTimeUs: 0, forceKeyFrame: true)
        let applied = encoder.trySetBitrate(kbps: 200)
        XCTAssertEqual(encoder.bitrateKbps, applied ? 200 : 400)
        print("encoder_rate_change codec=H264 mode=\(encoder.rateMode) applied=\(applied)")
    }
}
