import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
#if canImport(NearbyCore)
import NearbyCore
#endif

/// Which Android codecs this iPhone can actually decode, and how.
public enum VideoDecoderSupport {
    /// VP9 through VideoToolbox: Apple's supplemental decoder (iOS 26.2+, macOS 11+), hardware where present.
    public static var videoToolboxVP9: Bool {
        if #available(iOS 26.2, macOS 11.0, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
            return VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9) || probe(kCMVideoCodecType_VP9)
        }
        return false
    }
    /// AV1 hardware decoding (A17 Pro / M3 and later). The probe matters on virtual Macs, which report AV1
    /// hardware but cannot open the decoder (-12906); without it the AV1 decode bit would be advertised wrongly.
    public static var videoToolboxAV1: Bool {
        if #available(iOS 17.0, macOS 14.0, *) { return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) && probe(kCMVideoCodecType_AV1) }
        return false
    }
    /// AB5 (Design HC): HEVC decoding (hardware, or the platform's software decoder): VideoToolbox opens a session for
    /// Android's HEVC parameter sets (the M31 hardware encoder's Main 352x288 VPS, SPS and PPS).
    public static let videoToolboxHEVC: Bool = probeParameterSets(.hevc, [
        "40010c01ffff0160000003000003000003000003003c2c09",
        "4201010160000003000003000003000003003ca00b080485a2d2bb04bb9a8101010040",
        "4401c0667c0cc640",
    ])
    /// AB5: H.264 decoding: VideoToolbox opens a session for a Constrained Baseline 640x480 SPS and PPS (it also decodes
    /// Main and High, the whole envelope the H.264 bit promises).
    public static let videoToolboxH264: Bool = probeParameterSets(.h264, ["6742c01eda0280f640", "68ce3c80"])

    /// NodeCapabilities decode mask: VP9 is always decodable (VideoToolbox or bundled libvpx); AV1 with VideoToolbox
    /// hardware; HEVC and H.264 only with their AB5 master on and a probed VideoToolbox decoder.
    public static var decodeMask: UInt8 {
        var mask: UInt8 = 0
        if VP9Encoder.isAvailable || videoToolboxVP9 { mask |= NodeCapabilities.codecVP9 }
        if videoToolboxAV1 { mask |= NodeCapabilities.codecAV1 }
        if StreamProtocol.hevcEnabled && videoToolboxHEVC { mask |= NodeCapabilities.codecHEVC }
        if StreamProtocol.h264Enabled && videoToolboxH264 { mask |= NodeCapabilities.codecH264 }
        return mask
    }
    /// Encode mask: libvpx VP9; HEVC and H.264 only with their AB5 master on and a hardware encoder whose output passed
    /// the receiver rules (`HardwareEncoderSupport`).
    public static var encodeMask: UInt8 {
        var mask: UInt8 = VP9Encoder.isAvailable ? NodeCapabilities.codecVP9 : 0
        if StreamProtocol.hevcEnabled && HardwareEncoderSupport.isEligible(.hevc) { mask |= NodeCapabilities.codecHEVC }
        if StreamProtocol.h264Enabled && HardwareEncoderSupport.isEligible(.h264) { mask |= NodeCapabilities.codecH264 }
        return mask
    }

    private static func probeParameterSets(_ codec: AnnexBCodec, _ hexSets: [String]) -> Bool {
        guard let format = try? VideoToolboxDecoder.formatDescription(codec: codec, sets: hexSets.compactMap { Data(hex: $0) }) else { return false }
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: nil,
                                                  outputCallback: nil, decompressionSessionOut: &session)
        if let session { VTDecompressionSessionInvalidate(session) }
        return status == noErr
    }

    /// Main profile, 8-bit 4:2:0, 640x360: the sequence header OBU of Tests/NearbyMediaTests/Fixtures/av1-640x360.ivf.
    static let av1ProbeSequenceHeader = Data([0x0a, 0x0b, 0x00, 0x00, 0x00, 0x0c, 0xc4, 0xff, 0x67, 0x36, 0xbe, 0x40, 0x10])

    private static func probe(_ codec: CMVideoCodecType) -> Bool {
        var format: CMFormatDescription?
        let atoms: [String: CFData], width: Int32, height: Int32
        if codec == kCMVideoCodecType_AV1 {
            guard let seq = try? AV1Bitstream.sequenceHeader(in: av1ProbeSequenceHeader) else { return false }
            atoms = ["av1C": AV1Bitstream.av1C(seq) as CFData]; width = Int32(seq.maxWidth); height = Int32(seq.maxHeight)
        } else {
            atoms = ["vpcC": VP9Bitstream.vpcC(VP9FrameInfo(profile: 0, keyFrame: true, showFrame: true, bitDepth: 8, colorSpace: 2, fullRange: false,
                                                            subsamplingX: true, subsamplingY: true, width: 320, height: 240)) as CFData]
            width = 320; height = 240
        }
        let ext = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms] as CFDictionary
        guard CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec, width: width, height: height, extensions: ext, formatDescriptionOut: &format) == noErr,
              let format else { return false }
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: nil,
                                                  outputCallback: nil, decompressionSessionOut: &session)
        if let session { VTDecompressionSessionInvalidate(session) }
        return status == noErr
    }
}

public protocol VideoFrameDecoder: AnyObject {
    /// Decodes one BTV3 video access unit. Pictures arrive through `onPicture` (any thread).
    func decode(_ data: Data, presentationTimeUs: Int64, keyFrame: Bool) throws
    /// A codec-config record (e.g. an AV1 sequence header); a new one replaces the previous one.
    func replaceCodecConfig(_ data: Data)
    var onPicture: ((CVPixelBuffer, Int64) -> Void)? { get set }
    var name: String { get }
    func invalidate()
}

/// VideoToolbox VP9/AV1 decoder. The format description is (re)built from each key frame's header.
public extension VideoFrameDecoder {
    func replaceCodecConfig(_ data: Data) {}
}

public final class VideoToolboxDecoder: VideoFrameDecoder {
    public let codecId: UInt8
    public var onPicture: ((CVPixelBuffer, Int64) -> Void)?
    public var name: String { "VideoToolbox \(VideoCodecMap.label(codecId: codecId))" }
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private var configuration: Data?
    /// The latest out-of-band codec config (AV1 sequence header from a codec-config record), replaced, never appended.
    private var outOfBandConfig: Data?
    public private(set) var failures = 0

    public func replaceCodecConfig(_ data: Data) { outOfBandConfig = data }

    public init(codecId: UInt8) throws {
        let codecs = [StreamProtocol.codecVP9, StreamProtocol.codecAV1, StreamProtocol.codecH264, StreamProtocol.codecHEVC]
        guard codecs.contains(codecId) else { throw VideoCodecError.unavailable("Unsupported codec") }
        self.codecId = codecId
        if codecId == StreamProtocol.codecVP9, !VideoDecoderSupport.videoToolboxVP9 { throw VideoCodecError.unavailable("No VideoToolbox VP9 decoder") }
        if codecId == StreamProtocol.codecAV1, !VideoDecoderSupport.videoToolboxAV1 { throw VideoCodecError.unavailable("No AV1 hardware decoder") }
        if codecId == StreamProtocol.codecHEVC, !VideoDecoderSupport.videoToolboxHEVC { throw VideoCodecError.unavailable("No VideoToolbox HEVC decoder") }
        if codecId == StreamProtocol.codecH264, !VideoDecoderSupport.videoToolboxH264 { throw VideoCodecError.unavailable("No VideoToolbox H.264 decoder") }
    }
    deinit { invalidate() }

    public func invalidate() { if let session { VTDecompressionSessionInvalidate(session) }; session = nil; format = nil }

    private func ensureSession(for data: Data, keyFrame: Bool) throws {
        guard keyFrame else {
            if session == nil { throw VideoCodecError.failed("Waiting for a key frame") }
            return
        }
        let codecType: CMVideoCodecType, atomName: String, config: Data, width: Int, height: Int
        if codecId == StreamProtocol.codecVP9 {
            let info = try VP9Bitstream.inspect(data)
            guard info.keyFrame else { if session == nil { throw VideoCodecError.failed("Waiting for a key frame") }; return }
            codecType = kCMVideoCodecType_VP9; atomName = "vpcC"; config = VP9Bitstream.vpcC(info); width = info.width; height = info.height
        } else {
            guard let seq = try AV1Bitstream.sequenceHeader(in: data) ?? outOfBandConfig.flatMap({ try? AV1Bitstream.sequenceHeader(in: $0) }) else {
                if session == nil { throw VideoCodecError.failed("Waiting for an AV1 sequence header") }
                return
            }
            codecType = kCMVideoCodecType_AV1; atomName = "av1C"; config = AV1Bitstream.av1C(seq); width = seq.maxWidth; height = seq.maxHeight
        }
        let identity = config + Data([UInt8(width >> 8), UInt8(width & 255), UInt8(height >> 8), UInt8(height & 255)])
        if session != nil, identity == configuration { return }
        invalidate()
        let ext = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [atomName: config as CFData] as CFDictionary] as CFDictionary
        var newFormat: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: nil, codecType: codecType, width: Int32(width), height: Int32(height), extensions: ext, formatDescriptionOut: &newFormat)
        guard status == noErr, let newFormat else { throw VideoCodecError.failed("Video format description failed (\(status))") }
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var newSession: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(allocator: nil, formatDescription: newFormat, decoderSpecification: nil,
                                                   imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &newSession)
        guard created == noErr, let newSession else { throw VideoCodecError.failed("VideoToolbox session failed (\(created))") }
        session = newSession; format = newFormat; configuration = identity
    }

    /// Codecs 4 and 5 (AB5; PROTOCOL "Decoder input", Apple): the access unit arrives validated by the engine's gate (Annex
    /// B, 4-byte start codes, no SEI). A keyframe's in-band parameter sets build the format description, and the session
    /// is rebuilt when they change; the slice goes to VideoToolbox length-prefixed, without the sets.
    private func ensureParameterSetSession(for data: Data, codec: AnnexBCodec, keyFrame: Bool) throws -> Data {
        guard case .ok(let nals) = AnnexB.scan(data, codec: codec) else { throw VideoCodecError.failed("Malformed \(codec.label) access unit") }
        let slices = nals.filter { codec.isSlice($0.type) }.map(\.bytes)
        guard !slices.isEmpty else { throw VideoCodecError.failed("No \(codec.label) slice") }
        let sets = nals.filter { codec.isParameterSet($0.type) }.map(\.bytes)
        if keyFrame, !sets.isEmpty {
            let identity = AnnexB.annexB(sets)
            if session == nil || identity != configuration {
                invalidate()
                let newFormat = try Self.formatDescription(codec: codec, sets: sets)
                let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                              kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
                var newSession: VTDecompressionSession?
                let created = VTDecompressionSessionCreate(allocator: nil, formatDescription: newFormat, decoderSpecification: nil,
                                                           imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                                           decompressionSessionOut: &newSession)
                guard created == noErr, let newSession else { throw VideoCodecError.failed("VideoToolbox \(codec.label) session failed (\(created))") }
                session = newSession; format = newFormat; configuration = identity
            }
        } else if session == nil {
            throw VideoCodecError.failed("Waiting for a key frame")
        }
        return AnnexB.lengthPrefixed(slices)
    }

    /// A format description from parameter sets (HEVC VPS, SPS, PPS; H.264 SPS, PPS) with 4-byte NAL lengths.
    static func formatDescription(codec: AnnexBCodec, sets: [Data]) throws -> CMFormatDescription {
        guard !sets.isEmpty, sets.allSatisfy({ !$0.isEmpty }) else { throw VideoCodecError.failed("No \(codec.label) parameter sets") }
        let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: buffer, count: set.count)
            return buffer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var format: CMFormatDescription?
        let status: OSStatus
        if codec == .hevc {
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                                                                         parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil,
                                                                         formatDescriptionOut: &format)
        } else {
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                                                                         parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        }
        guard status == noErr, let format else { throw VideoCodecError.failed("\(codec.label) format description failed (\(status))") }
        return format
    }

    public func decode(_ data: Data, presentationTimeUs: Int64, keyFrame: Bool) throws {
        let sampleData: Data
        if let codec = AnnexBCodec(codecId: codecId) {
            sampleData = try ensureParameterSetSession(for: data, codec: codec, keyFrame: keyFrame)
        } else {
            try ensureSession(for: data, keyFrame: keyFrame)
            sampleData = data
        }
        guard let session, let format else { return }
        var block: CMBlockBuffer?
        let length = sampleData.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { throw VideoCodecError.failed("Block buffer allocation failed") }
        _ = sampleData.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: presentationTimeUs, timescale: 1_000_000), decodeTimeStamp: .invalid)
        var size = length
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { throw VideoCodecError.failed("Sample buffer creation failed") }
        let handler = onPicture
        var outputStatus: OSStatus = noErr
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, pts, _ in
            outputStatus = status
            if status == noErr, let image { handler?(image, pts.isValid ? Int64(pts.seconds * 1_000_000) : presentationTimeUs) }
        }
        if status != noErr || outputStatus != noErr {
            failures += 1
            if status == kVTInvalidSessionErr { invalidate() }
            throw VideoCodecError.failed("VideoToolbox decode failed (\(status != noErr ? status : outputStatus))")
        }
    }
}

/// libvpx-backed VP9 decoder producing NV12 pixel buffers.
public final class SoftwareVP9FrameDecoder: VideoFrameDecoder {
    private let decoder: VP9SoftwareDecoder
    public var onPicture: ((CVPixelBuffer, Int64) -> Void)?
    public var name: String { "libvpx VP9" }
    public init() throws { decoder = try VP9SoftwareDecoder() }
    public func decode(_ data: Data, presentationTimeUs: Int64, keyFrame: Bool) throws {
        if let picture = try decoder.decode(data), let buffer = PixelConversion.pixelBuffer(from: picture) { onPicture?(buffer, presentationTimeUs) }
    }
    public func invalidate() {}
}

public enum VideoDecoderFactory {
    /// Hardware/system decoder first, then the bundled software VP9 decoder.
    public static func make(codecId: UInt8, preferSoftware: Bool = false) throws -> VideoFrameDecoder {
        if !preferSoftware, let vt = try? VideoToolboxDecoder(codecId: codecId) { return vt }
        if codecId == StreamProtocol.codecVP9 { return try SoftwareVP9FrameDecoder() }
        throw VideoCodecError.unavailable("This iPhone cannot decode \(codecId == StreamProtocol.codecAV1 ? "AV1" : "codec \(codecId)")")
    }
}
