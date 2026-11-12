import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
#if canImport(NearbyCore)
import NearbyCore
#endif

/// An encoder the camera drives: the bundled libvpx VP9 encoder, or (AB5/AB5B, Design HC, Experimental) a VideoToolbox
/// H.264 or HEVC hardware encoder.
public protocol VideoFrameEncoder: AnyObject {
    /// The `BTV3` codec ID of what it emits.
    var codecId: UInt8 { get }
    var name: String { get }
    func setBitrate(kbps: Int)
    func encode(_ picture: I420Picture, presentationTimeUs: Int64, forceKeyFrame: Bool) throws -> EncodedVideoFrame?
}

extension VP9Encoder: VideoFrameEncoder {
    public var codecId: UInt8 { StreamProtocol.codecVP9 }
    public var name: String { "libvpx VP9" }
}

/// The VideoToolbox profile a hardware encoder is asked for. HEVC: Main. H.264: High, then Main, then Constrained Baseline
/// (PROTOCOL "Access-unit validation"; Design HC "Encoder eligibility").
public enum VideoToolboxProfile: String, CaseIterable {
    case hevcMain = "HEVC Main"
    case h264High = "H264 High"
    case h264Main = "H264 Main"
    case h264ConstrainedBaseline = "H264 Constrained Baseline"

    public var codec: AnnexBCodec { self == .hevcMain ? .hevc : .h264 }

    /// Automatic level: VideoToolbox picks the level that covers the session's size, rate and frame rate.
    var value: CFString {
        switch self {
        case .hevcMain: return kVTProfileLevel_HEVC_Main_AutoLevel
        case .h264High: return kVTProfileLevel_H264_High_AutoLevel
        case .h264Main: return kVTProfileLevel_H264_Main_AutoLevel
        case .h264ConstrainedBaseline: return kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel
        }
    }

    /// The order to try for `codec`.
    public static func ladder(_ codec: AnnexBCodec) -> [VideoToolboxProfile] {
        codec == .hevc ? [.hevcMain] : [.h264High, .h264Main, .h264ConstrainedBaseline]
    }
}

/// How the session's rate control and temporal structure are set up (AB5B). Apple's SDK header: low-latency rate control
/// (`kVTVideoEncoderSpecification_EnableLowLatencyRateControl`) "enforces ... Temporal Layer structure", and an HEVC stream
/// with temporal sub-layers breaks PROTOCOL rule 7 (`vps_max_sub_layers_minus1` 0) and rule 2 (`nuh_temporal_id_plus1`
/// 1). Each setup is tried in order and the first whose output passes the receiver's gate is used. The rules are never
/// relaxed and the bitstream is never rewritten.
public enum VideoToolboxSetup: String, CaseIterable {
    /// Low-latency rate control as VideoToolbox sets it up (the AB5 setup; H.264 passed with it).
    case lowLatency = "low-latency"
    /// Low-latency rate control with every frame in the base layer (`kVTCompressionPropertyKey_BaseLayerFrameRateFraction` 1.0).
    case lowLatencyAllBase = "low-latency, base layer fraction 1.0"
    /// The standard rate control (no low-latency specification), real time, no frame reordering.
    case standard = "standard"
    /// The standard rate control with the base layer at the full frame rate (`kVTCompressionPropertyKey_BaseLayerFrameRate`).
    case standardFullBaseRate = "standard, base layer frame rate = frame rate"

    public var lowLatency: Bool { self == .lowLatency || self == .lowLatencyAllBase }

    /// The order to try for `codec`. H.264 keeps AB5's passing setup first. HEVC tries the single-layer requests first and
    /// plain low latency last (it failed rule 7 on the M5 Mac in AB5; kept so that the probe log shows it).
    public static func ladder(_ codec: AnnexBCodec) -> [VideoToolboxSetup] {
        codec == .hevc ? [.lowLatencyAllBase, .standard, .standardFullBaseRate, .lowLatency] : [.lowLatency, .standard]
    }
}

/// The profile and setup the probe accepted for one codec.
public struct HardwareEncoderConfiguration: Equatable {
    public let profile: VideoToolboxProfile
    public let setup: VideoToolboxSetup
    public init(profile: VideoToolboxProfile, setup: VideoToolboxSetup) { self.profile = profile; self.setup = setup }
    public var label: String { "\(profile.rawValue) / \(setup.rawValue)" }
}

/// A VideoToolbox hardware H.264 or HEVC encoder for calls (PROTOCOL "Sender rules"): real time, no frame reordering (no
/// B-frames), closed GOP, keyframes every 60 s or on request (`kVTEncodeFrameOptionKey_ForceKeyFrame`), as the libvpx
/// encoder. Rate: constant bit rate where the encoder accepts it, else an average rate with a one-second cap at 1.5 times
/// the rate; `rateMode` says which. The length-prefixed output becomes Annex B through `HardwareAccessUnitPacketiser`: the
/// format description's parameter sets go in front of every IDR, the keyframe flag comes from the NAL type. One frame in,
/// at most one access unit out (the call waits for the frame).
public final class VideoToolboxEncoder: VideoFrameEncoder {
    public let profile: VideoToolboxProfile
    public let setup: VideoToolboxSetup
    public var codec: AnnexBCodec { profile.codec }
    public var codecId: UInt8 { codec.rawValue }
    public var name: String { "VideoToolbox \(codec.label)" }
    public let width: Int, height: Int, fps: Int
    public private(set) var bitrateKbps: Int
    /// `cbr` (ConstantBitRate accepted) or `average` (AverageBitRate with DataRateLimits).
    public private(set) var rateMode: String = "average"
    /// The session runs with `kVTVideoEncoderSpecification_EnableLowLatencyRateControl`.
    public var lowLatency: Bool { setup.lowLatency }
    private let session: VTCompressionSession
    private var packetiser: HardwareAccessUnitPacketiser
    private var parameterSets: [Data] = []
    private var lengthSize = 4

    public init(configuration: HardwareEncoderConfiguration, width: Int, height: Int, fps: Int, bitrateKbps: Int) throws {
        profile = configuration.profile
        setup = configuration.setup
        self.width = width; self.height = height; self.fps = max(1, fps); self.bitrateKbps = bitrateKbps
        packetiser = HardwareAccessUnitPacketiser(codec: configuration.profile.codec)
        session = try Self.makeSession(codec: configuration.profile.codec, width: width, height: height, lowLatency: configuration.setup.lowLatency)
        func set(_ key: CFString, _ value: CFTypeRef) -> OSStatus { VTSessionSetProperty(session, key: key, value: value) }
        _ = set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        guard set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse) == noErr else {
            throw VideoCodecError.unavailable("\(profile.rawValue): frame reordering cannot be turned off")
        }
        guard set(kVTCompressionPropertyKey_ProfileLevel, profile.value) == noErr else {
            throw VideoCodecError.unavailable("\(profile.rawValue): profile not supported")
        }
        _ = set(kVTCompressionPropertyKey_AllowOpenGOP, kCFBooleanFalse)
        _ = set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: self.fps))
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: self.fps * 60))
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 60))
        switch setup {
        case .lowLatencyAllBase:
            let status = set(kVTCompressionPropertyKey_BaseLayerFrameRateFraction, NSNumber(value: 1.0))
            guard status == noErr else { throw VideoCodecError.unavailable("base layer fraction 1.0 refused (\(status))") }
        case .standardFullBaseRate:
            let status = set(kVTCompressionPropertyKey_BaseLayerFrameRate, NSNumber(value: self.fps))
            guard status == noErr else { throw VideoCodecError.unavailable("base layer frame rate refused (\(status))") }
        case .lowLatency, .standard:
            break
        }
        rateMode = applyRate(kbps: bitrateKbps, first: true) ?? "average"
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    /// Also runs when init throws after the session exists (a refused property), so the session is never leaked.
    deinit { VTCompressionSessionInvalidate(session) }

    /// Hardware only: `RequireHardwareAcceleratedVideoEncoder` (macOS; iOS 17.4 and later). Every iPhone this app runs
    /// on (iOS 17 or later) encodes HEVC and H.264 in hardware, so iOS 17.0 to 17.3 take the platform encoder without
    /// the key.
    private static func makeSession(codec: AnnexBCodec, width: Int, height: Int, lowLatency: Bool) throws -> VTCompressionSession {
        let type = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        var specification: [CFString: Any] = [:]
        if lowLatency { specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        #if os(macOS)
        specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = true
        #else
        if #available(iOS 17.4, *) { specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = true }
        #endif
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: type,
                                                encoderSpecification: specification as CFDictionary, imageBufferAttributes: nil,
                                                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else {
            throw VideoCodecError.unavailable("No hardware \(codec.label) encoder\(lowLatency ? " with low-latency rate control" : "") (\(status))")
        }
        return session
    }

    /// Returns the mode that took the rate, or nil when the encoder refused it (the rate stays as it was).
    private func applyRate(kbps: Int, first: Bool) -> String? {
        let bps = kbps * 1000
        if first || rateMode == "cbr" {
            if #available(iOS 16.0, macOS 13.0, *),
               VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ConstantBitRate, value: NSNumber(value: bps)) == noErr {
                return "cbr"
            }
            if !first { return nil }
        }
        let limits = [NSNumber(value: bps * 3 / 2 / 8), NSNumber(value: 1)] as CFArray
        guard VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bps)) == noErr else { return nil }
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
        return "average"
    }

    /// Never silently: `bitrateKbps` changes only when the encoder took the new rate; false when it refused it.
    @discardableResult
    public func trySetBitrate(kbps: Int) -> Bool {
        guard kbps != bitrateKbps else { return true }
        guard applyRate(kbps: kbps, first: false) != nil else { return false }
        bitrateKbps = kbps
        return true
    }

    public func setBitrate(kbps: Int) { trySetBitrate(kbps: kbps) }

    public func encode(_ picture: I420Picture, presentationTimeUs: Int64, forceKeyFrame: Bool) throws -> EncodedVideoFrame? {
        guard let pixels = PixelConversion.pixelBuffer(from: picture) else { throw VideoCodecError.failed("Pixel buffer allocation failed") }
        return try encode(pixels, presentationTimeUs: presentationTimeUs, forceKeyFrame: forceKeyFrame)
    }

    public func encode(_ pixels: CVPixelBuffer, presentationTimeUs: Int64, forceKeyFrame: Bool) throws -> EncodedVideoFrame? {
        let pts = CMTime(value: presentationTimeUs, timescale: 1_000_000)
        let options: CFDictionary? = forceKeyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as [CFString: Any] as CFDictionary : nil
        // The output handler runs on a VideoToolbox thread; CompleteFrames returns after it ran. The lock makes that
        // hand-off explicit (the thread sanitizer cannot see VideoToolbox's own synchronization and reported it).
        let output = EncodeOutput()
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: pts, duration: .invalid,
                                                     frameProperties: options, infoFlagsOut: nil) { status, _, sample in
            output.set(status, sample)
        }
        guard status == noErr else { throw VideoCodecError.failed("VideoToolbox encode failed (\(status))") }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: pts)
        let (outputStatus, produced) = output.get()
        guard outputStatus == noErr else { throw VideoCodecError.failed("VideoToolbox encode failed (\(outputStatus))") }
        guard let sample = produced else { return nil } // the encoder dropped the frame
        return try accessUnit(sample, presentationTimeUs: presentationTimeUs)
    }

    /// One encode call's output, written by VideoToolbox's output handler and read after CompleteFrames.
    private final class EncodeOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var status: OSStatus = noErr
        private var sample: CMSampleBuffer?
        func set(_ status: OSStatus, _ sample: CMSampleBuffer?) { lock.lock(); self.status = status; self.sample = sample; lock.unlock() }
        func get() -> (OSStatus, CMSampleBuffer?) { lock.lock(); defer { lock.unlock() }; return (status, sample) }
    }

    private func accessUnit(_ sample: CMSampleBuffer, presentationTimeUs: Int64) throws -> EncodedVideoFrame? {
        if let format = CMSampleBufferGetFormatDescription(sample) {
            let (sets, length) = Self.parameterSets(format, codec: codec)
            lengthSize = length
            if sets != parameterSets {
                parameterSets = sets
                packetiser.updateParameterSets(sets)
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }
        var bytes = Data(count: length)
        let copied = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        guard copied == noErr else { throw VideoCodecError.failed("Encoded data copy failed (\(copied))") }
        let nals = try AnnexB.nalUnits(lengthPrefixed: bytes, lengthSize: lengthSize)
        switch packetiser.packetise(nals, presentationTimeUs: presentationTimeUs) {
        case .packet(let payload, let keyFrame, _, _):
            return EncodedVideoFrame(data: payload, keyFrame: keyFrame, presentationTimeUs: presentationTimeUs)
        case .error(let reason):
            throw VideoCodecError.failed("\(codec.label) access unit refused: \(reason)")
        }
    }

    /// The parameter sets of a VideoToolbox format description (HEVC VPS, SPS, PPS; H.264 SPS, PPS) and its NAL length size.
    static func parameterSets(_ format: CMFormatDescription, codec: AnnexBCodec) -> ([Data], Int) {
        var sets: [Data] = []
        var count = 0
        var headerLength: Int32 = 4
        var index = 0
        repeat {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus
            if codec == .hevc {
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                            parameterSetSizeOut: &size, parameterSetCountOut: &count,
                                                                            nalUnitHeaderLengthOut: &headerLength)
            } else {
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                            parameterSetSizeOut: &size, parameterSetCountOut: &count,
                                                                            nalUnitHeaderLengthOut: &headerLength)
            }
            guard status == noErr, let pointer, size > 0 else { break }
            sets.append(Data(bytes: pointer, count: size))
            index += 1
        } while index < count
        return (sets, Int(headerLength))
    }
}

/// Which hardware encoders this device may advertise and use (AB5, AB5B). Each codec is probed once per process at the
/// largest call size (480x854 portrait, 30 FPS, 800 kbps), for each profile and each setup of the ladders in order: the
/// encoder must start and its first eight frames (an IDR and P frames, enough to show any temporal layer) must give at
/// least seven access units that all pass the receiver's gate (`AccessUnitGate`), so an encoder whose output a receiver
/// would refuse is never advertised. Every attempt is recorded (`probeAttempts`; the app logs each as `hc_probe_attempt`).
/// An encoder that missed three keyframe requests (`no_idr`) is ineligible for the rest of the process.
public enum HardwareEncoderSupport {
    public static let probeWidth = 480, probeHeight = 854, probeFps = 30, probeKbps = 800, probeFrames = 8
    private static let lock = NSLock()
    private static var ineligible: [AnnexBCodec: String] = [:]
    private static var attempts: [AnnexBCodec: [String]] = [:]
    private static let hevcConfiguration: HardwareEncoderConfiguration? = probe(.hevc)
    private static let h264Configuration: HardwareEncoderConfiguration? = probe(.h264)

    /// The profile and setup the probe accepted for `codec`, or nil (no hardware encoder, or none whose output passes).
    public static func eligible(_ codec: AnnexBCodec) -> HardwareEncoderConfiguration? {
        let configuration = codec == .hevc ? hevcConfiguration : h264Configuration
        lock.lock(); defer { lock.unlock() }
        return ineligible[codec] == nil ? configuration : nil
    }

    public static func isEligible(_ codec: AnnexBCodec) -> Bool { eligible(codec) != nil }

    /// Every probe attempt of `codec` in order: "<profile> / <setup>: passed" or "<profile> / <setup>: <why refused>".
    public static func probeAttempts(_ codec: AnnexBCodec) -> [String] {
        _ = eligible(codec)
        lock.lock(); defer { lock.unlock() }
        return attempts[codec] ?? []
    }

    /// Why the probe refused `codec` (every attempt joined), or nil when a configuration passed.
    public static func probeProblem(_ codec: AnnexBCodec) -> String? {
        isEligible(codec) ? nil : probeAttempts(codec).joined(separator: "; ")
    }

    /// The encoder failed in a way the rules name (`no_idr`): not advertised or chosen again in this process.
    public static func markIneligible(_ codec: AnnexBCodec, reason: String) {
        lock.lock(); defer { lock.unlock() }
        ineligible[codec] = reason
    }

    /// A smooth moving test picture (no camera).
    public static func testPicture(width: Int, height: Int, frame: Int) -> I420Picture {
        var picture = I420Picture(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width { picture.y[y * width + x] = UInt8(truncatingIfNeeded: 16 + (x + 2 * y + 3 * frame) % 200) }
        }
        let cw = picture.chromaWidth
        for y in 0..<picture.chromaHeight {
            for x in 0..<cw {
                picture.u[y * cw + x] = UInt8(truncatingIfNeeded: 96 + (x + frame) % 64)
                picture.v[y * cw + x] = UInt8(truncatingIfNeeded: 160 - (y + frame) % 64)
            }
        }
        return picture
    }

    private static func probe(_ codec: AnnexBCodec) -> HardwareEncoderConfiguration? {
        var log: [String] = []
        var accepted: HardwareEncoderConfiguration?
        search: for profile in VideoToolboxProfile.ladder(codec) {
            for setup in VideoToolboxSetup.ladder(codec) {
                let configuration = HardwareEncoderConfiguration(profile: profile, setup: setup)
                do {
                    let encoder = try VideoToolboxEncoder(configuration: configuration, width: probeWidth, height: probeHeight,
                                                          fps: probeFps, bitrateKbps: probeKbps)
                    let gate = AccessUnitGate(codec: codec, headerMaxWidth: probeWidth, headerMaxHeight: probeHeight)
                    var passed = 0
                    for frame in 0..<probeFrames {
                        let picture = testPicture(width: probeWidth, height: probeHeight, frame: frame)
                        guard let unit = try encoder.encode(picture, presentationTimeUs: Int64(frame) * 33_333, forceKeyFrame: frame == 0) else { continue }
                        let verdict = gate.check(unit.data, flags: unit.keyFrame ? StreamProtocol.flagKeyFrame : 0, nowMs: Int64(frame) * 33)
                        guard case .accept = verdict else { throw VideoCodecError.failed("frame \(frame): \(verdict)") }
                        passed += 1
                    }
                    guard passed >= probeFrames - 1 else { throw VideoCodecError.failed("only \(passed) of \(probeFrames) access units") }
                    log.append("\(configuration.label): passed")
                    accepted = configuration
                    break search
                } catch {
                    log.append("\(configuration.label): \(error)")
                }
            }
        }
        lock.lock(); attempts[codec] = log; lock.unlock()
        return accepted
    }
}
