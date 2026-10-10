import Foundation
import CoreVideo
#if canImport(CNearbyVPX)
import CNearbyVPX
#endif

/// Planar 8-bit 4:2:0 picture owned by Swift (encoder input / software decoder output).
public struct I420Picture {
    public let width: Int, height: Int
    public var y: [UInt8], u: [UInt8], v: [UInt8]
    public var chromaWidth: Int { (width + 1) / 2 }
    public var chromaHeight: Int { (height + 1) / 2 }
    public init(width: Int, height: Int) {
        self.width = width; self.height = height
        y = [UInt8](repeating: 16, count: width * height)
        u = [UInt8](repeating: 128, count: ((width + 1) / 2) * ((height + 1) / 2))
        v = u
    }
}

public enum VideoCodecError: Error, CustomStringConvertible {
    case unavailable(String), failed(String)
    public var description: String { switch self { case .unavailable(let s), .failed(let s): return s } }
}

public struct EncodedVideoFrame {
    public let data: Data
    public let keyFrame: Bool
    public let presentationTimeUs: Int64
}

/// libvpx VP9 real-time encoder (iPhones have no VP9 hardware encoder; Android accepts only VP9/AV1).
public final class VP9Encoder {
    private let handle: OpaquePointer
    public let width: Int, height: Int, fps: Int
    public private(set) var bitrateKbps: Int
    private var output = [UInt8](repeating: 0, count: 1 << 20)

    public static var isAvailable: Bool { nearby_vpx_available() == 1 }

    public init(width: Int, height: Int, fps: Int, bitrateKbps: Int, threads: Int = 2, speed: Int = 8) throws {
        var error: Int32 = 0
        guard let h = nearby_vp9_encoder_create(Int32(width), Int32(height), Int32(fps), Int32(bitrateKbps), Int32(threads), Int32(speed), &error) else {
            throw VideoCodecError.unavailable(error == -100 ? "libvpx is not linked" : "VP9 encoder setup failed (\(error))")
        }
        handle = h; self.width = width; self.height = height; self.fps = fps; self.bitrateKbps = bitrateKbps
    }
    deinit { nearby_vp9_encoder_destroy(handle) }

    public func setBitrate(kbps: Int) { if nearby_vp9_encoder_set_bitrate(handle, Int32(kbps)) == 0 { bitrateKbps = kbps } }

    public func encode(_ picture: I420Picture, presentationTimeUs: Int64, forceKeyFrame: Bool) throws -> EncodedVideoFrame? {
        precondition(picture.width == width && picture.height == height)
        var keyframe: Int32 = 0
        let count: Int32 = picture.y.withUnsafeBufferPointer { y in
            picture.u.withUnsafeBufferPointer { u in
                picture.v.withUnsafeBufferPointer { v in
                    var frame = NearbyI420Frame(width: Int32(width), height: Int32(height), y: y.baseAddress, u: u.baseAddress, v: v.baseAddress,
                                                y_stride: Int32(width), u_stride: Int32(picture.chromaWidth), v_stride: Int32(picture.chromaWidth))
                    return output.withUnsafeMutableBufferPointer { out in
                        nearby_vp9_encode(handle, &frame, presentationTimeUs, Int32(1_000_000 / max(1, fps)), forceKeyFrame ? 1 : 0,
                                          out.baseAddress, Int32(out.count), &keyframe)
                    }
                }
            }
        }
        if count < 0 { throw VideoCodecError.failed("VP9 encode failed: \(String(cString: nearby_vp9_encoder_error(handle)))") }
        if count == 0 { return nil }
        return EncodedVideoFrame(data: Data(output[0..<Int(count)]), keyFrame: keyframe == 1, presentationTimeUs: presentationTimeUs)
    }
}

/// libvpx VP9 software decoder: fallback where VideoToolbox has no VP9 decoder.
public final class VP9SoftwareDecoder {
    private let handle: OpaquePointer
    public init(threads: Int = 2) throws {
        var error: Int32 = 0
        guard let h = nearby_vp9_decoder_create(Int32(threads), &error) else {
            throw VideoCodecError.unavailable(error == -100 ? "libvpx is not linked" : "VP9 decoder setup failed (\(error))")
        }
        handle = h
    }
    deinit { nearby_vp9_decoder_destroy(handle) }

    /// Decodes one access unit; returns the shown picture (copied) or nil when none is shown.
    public func decode(_ data: Data) throws -> I420Picture? {
        var frame = NearbyI420Frame()
        let status: Int32 = data.withUnsafeBytes { raw in
            nearby_vp9_decode(handle, raw.bindMemory(to: UInt8.self).baseAddress, Int32(raw.count), &frame)
        }
        if status < 0 { throw VideoCodecError.failed("VP9 decode failed: \(String(cString: nearby_vp9_decoder_error(handle)))") }
        if status == 0 { return nil }
        let w = Int(frame.width), h = Int(frame.height)
        var picture = I420Picture(width: w, height: h)
        func copy(_ src: UnsafePointer<UInt8>?, _ stride: Int32, _ cw: Int, _ ch: Int, into dst: inout [UInt8]) {
            guard let src else { return }
            dst.withUnsafeMutableBufferPointer { out in
                for row in 0..<ch { (out.baseAddress! + row * cw).update(from: src + row * Int(stride), count: cw) }
            }
        }
        copy(frame.y, frame.y_stride, w, h, into: &picture.y)
        copy(frame.u, frame.u_stride, picture.chromaWidth, picture.chromaHeight, into: &picture.u)
        copy(frame.v, frame.v_stride, picture.chromaWidth, picture.chromaHeight, into: &picture.v)
        return picture
    }
}

/// Conversions between I420 and NV12 (`420v`/`420f`) pixel buffers.
public enum PixelConversion {
    public static func pixelBuffer(from p: I420Picture, fullRange: Bool = false) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let format = fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard CVPixelBufferCreate(nil, p.width, p.height, format, attrs as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let yDst = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        p.y.withUnsafeBufferPointer { y in for row in 0..<p.height { (yDst + row * yStride).update(from: y.baseAddress! + row * p.width, count: p.width) } }
        let uvDst = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let cw = p.chromaWidth
        for row in 0..<p.chromaHeight {
            let line = uvDst + row * uvStride
            for x in 0..<cw { line[2 * x] = p.u[row * cw + x]; line[2 * x + 1] = p.v[row * cw + x] }
        }
        return buffer
    }

    /// NV12 (or any biplanar 4:2:0) pixel buffer to I420 at the target size (nearest-neighbour scaling, even sizes).
    public static func i420(from buffer: CVPixelBuffer, width: Int, height: Int) -> I420Picture? {
        guard CVPixelBufferGetPlaneCount(buffer) == 2 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let sw = CVPixelBufferGetWidth(buffer), sh = CVPixelBufferGetHeight(buffer)
        guard let ySrc = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self),
              let uvSrc = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        var p = I420Picture(width: width, height: height)
        // Centre crop to the target aspect, then sample.
        let targetAspect = Double(width) / Double(height), sourceAspect = Double(sw) / Double(sh)
        var cropW = sw, cropH = sh
        if sourceAspect > targetAspect { cropW = Int(Double(sh) * targetAspect) } else { cropH = Int(Double(sw) / targetAspect) }
        let x0 = (sw - cropW) / 2, y0 = (sh - cropH) / 2
        p.y.withUnsafeMutableBufferPointer { y in
            for row in 0..<height {
                let sy = y0 + row * cropH / height
                let line = ySrc + sy * yStride
                for x in 0..<width { y[row * width + x] = line[x0 + x * cropW / width] }
            }
        }
        let cw = p.chromaWidth, ch = p.chromaHeight
        for row in 0..<ch {
            let sy = (y0 / 2) + row * (cropH / 2) / ch
            let line = uvSrc + min(sy, sh / 2 - 1) * uvStride
            for x in 0..<cw {
                let sx = (x0 / 2) + x * (cropW / 2) / cw
                p.u[row * cw + x] = line[2 * sx]; p.v[row * cw + x] = line[2 * sx + 1]
            }
        }
        return p
    }
}
