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
    /// NodeCapabilities decode mask: VP9 is always decodable (VideoToolbox or bundled libvpx).
    public static var decodeMask: UInt8 {
        var mask: UInt8 = 0
        if VP9Encoder.isAvailable || videoToolboxVP9 { mask |= NodeCapabilities.codecVP9 }
        if videoToolboxAV1 { mask |= NodeCapabilities.codecAV1 }
        return mask
    }
    /// Encode mask: libvpx VP9 only.
    public static var encodeMask: UInt8 { VP9Encoder.isAvailable ? NodeCapabilities.codecVP9 : 0 }

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
    public var name: String { codecId == StreamProtocol.codecAV1 ? "VideoToolbox AV1" : "VideoToolbox VP9" }
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private var configuration: Data?
    /// The latest out-of-band codec config (AV1 sequence header from a codec-config record), replaced, never appended.
    private var outOfBandConfig: Data?
    public private(set) var failures = 0

    public func replaceCodecConfig(_ data: Data) { outOfBandConfig = data }

    public init(codecId: UInt8) throws {
        guard codecId == StreamProtocol.codecVP9 || codecId == StreamProtocol.codecAV1 else { throw VideoCodecError.unavailable("Unsupported codec") }
        self.codecId = codecId
        if codecId == StreamProtocol.codecVP9, !VideoDecoderSupport.videoToolboxVP9 { throw VideoCodecError.unavailable("No VideoToolbox VP9 decoder") }
        if codecId == StreamProtocol.codecAV1, !VideoDecoderSupport.videoToolboxAV1 { throw VideoCodecError.unavailable("No AV1 hardware decoder") }
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

    public func decode(_ data: Data, presentationTimeUs: Int64, keyFrame: Bool) throws {
        try ensureSession(for: data, keyFrame: keyFrame)
        guard let session, let format else { return }
        var block: CMBlockBuffer?
        let length = data.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { throw VideoCodecError.failed("Block buffer allocation failed") }
        _ = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) }
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
