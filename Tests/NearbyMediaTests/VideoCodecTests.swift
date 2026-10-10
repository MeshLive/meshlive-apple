import XCTest
import CoreVideo
@testable import NearbyCore
@testable import NearbyMedia

/// IVF container reader for test clips (generated with ffmpeg libvpx-vp9 / libaom-av1 test patterns).
private func ivfFrames(_ name: String) throws -> [Data] {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "ivf", subdirectory: "Fixtures"))
    let data = try Data(contentsOf: url)
    XCTAssertEqual(data.prefix(4), Data("DKIF".utf8))
    let headerSize = Int(data[6]) | Int(data[7]) << 8
    var offset = headerSize, frames: [Data] = []
    while offset + 12 <= data.count {
        let size = Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
        offset += 12
        frames.append(data.subdata(in: offset..<offset + size)); offset += size
    }
    return frames
}

final class VideoCodecTests: XCTestCase {
    func testVP9HeaderParsingAndVpcC() throws {
        let frames = try ivfFrames("vp9-426x240")
        let info = try VP9Bitstream.inspect(frames[0])
        XCTAssertTrue(info.keyFrame); XCTAssertEqual(info.width, 426); XCTAssertEqual(info.height, 240)
        XCTAssertEqual(info.profile, 0); XCTAssertEqual(info.bitDepth, 8)
        XCTAssertFalse(try VP9Bitstream.inspect(frames[1]).keyFrame)
        let vpcc = VP9Bitstream.vpcC(info)
        XCTAssertEqual(vpcc.count, 12); XCTAssertEqual(vpcc[0], 1); XCTAssertEqual(vpcc[6] >> 4, 8)
        XCTAssertThrowsError(try VP9Bitstream.inspect(Data([0xff])))
    }

    func testAV1SequenceHeaderAndAv1C() throws {
        let frames = try ivfFrames("av1-640x360")
        let seq = try XCTUnwrap(try AV1Bitstream.sequenceHeader(in: frames[0]))
        XCTAssertEqual(seq.profile, 0); XCTAssertEqual(seq.maxWidth, 640); XCTAssertEqual(seq.maxHeight, 360)
        XCTAssertFalse(seq.monochrome); XCTAssertTrue(seq.subsamplingX && seq.subsamplingY)
        let config = AV1Bitstream.av1C(seq)
        XCTAssertEqual(config[0], 0x81); XCTAssertEqual(config.dropFirst(4), seq.sequenceHeaderOBU)
    }

    func testLibvpxEncodeDecodeRoundTrip() throws {
        guard VP9Encoder.isAvailable else { throw XCTSkip("libvpx not prepared (Scripts/prepare-libvpx.sh)") }
        let encoder = try VP9Encoder(width: 426, height: 240, fps: 15, bitrateKbps: 300)
        let decoder = try VP9SoftwareDecoder()
        var bytes = 0, keyFrames = 0, decoded = 0
        for i in 0..<30 {
            var picture = I420Picture(width: 426, height: 240)
            for y in 0..<240 { for x in 0..<426 { picture.y[y * 426 + x] = UInt8((x + y + i * 4) & 0xff) } }
            guard let frame = try encoder.encode(picture, presentationTimeUs: Int64(i) * 66_666, forceKeyFrame: i == 20) else { continue }
            bytes += frame.data.count
            if frame.keyFrame { keyFrames += 1; XCTAssertTrue(try VP9Bitstream.inspect(frame.data).keyFrame) }
            if let out = try decoder.decode(frame.data) { decoded += 1; XCTAssertEqual(out.width, 426); XCTAssertEqual(out.height, 240) }
        }
        XCTAssertEqual(keyFrames, 2, "first frame and the forced keyframe")
        XCTAssertEqual(decoded, 30)
        // 2 seconds at 300 kbps CBR is ~75 KB; allow the keyframes' overshoot.
        XCTAssertLessThan(bytes, 140_000)
        // Android's ffmpeg/libvpx-produced clip decodes too.
        var clipFrames = 0
        for f in try ivfFrames("vp9-426x240") { if try decoder.decode(f) != nil { clipFrames += 1 } }
        XCTAssertEqual(clipFrames, 15)
    }

    func testVideoToolboxDecodesVP9WithGeneratedVpcCWhenAvailable() throws {
        guard VideoDecoderSupport.videoToolboxVP9 else { throw XCTSkip("No VideoToolbox VP9 decoder on this machine") }
        let decoder = try VideoToolboxDecoder(codecId: StreamProtocol.codecVP9)
        var pictures = 0
        decoder.onPicture = { buffer, _ in
            pictures += 1
            XCTAssertEqual(CVPixelBufferGetWidth(buffer), 426); XCTAssertEqual(CVPixelBufferGetHeight(buffer), 240)
        }
        for (i, f) in try ivfFrames("vp9-426x240").enumerated() {
            try decoder.decode(f, presentationTimeUs: Int64(i) * 66_666, keyFrame: try VP9Bitstream.inspect(f).keyFrame)
        }
        XCTAssertEqual(pictures, 15)
    }

    func testVideoToolboxDecodesAV1WhenHardwarePresent() throws {
        guard VideoDecoderSupport.videoToolboxAV1 else { throw XCTSkip("No AV1 hardware decoder on this machine") }
        let decoder = try VideoToolboxDecoder(codecId: StreamProtocol.codecAV1)
        var pictures = 0
        decoder.onPicture = { _, _ in pictures += 1 }
        for (i, f) in try ivfFrames("av1-640x360").enumerated() { try decoder.decode(f, presentationTimeUs: Int64(i) * 66_666, keyFrame: i == 0) }
        XCTAssertGreaterThan(pictures, 10)
    }

    func testPixelConversionRoundTrip() throws {
        var picture = I420Picture(width: 64, height: 48)
        for i in 0..<picture.y.count { picture.y[i] = UInt8(i & 0xff) }
        for i in 0..<picture.u.count { picture.u[i] = UInt8((i * 3) & 0xff); picture.v[i] = UInt8((i * 5) & 0xff) }
        let buffer = try XCTUnwrap(PixelConversion.pixelBuffer(from: picture))
        let back = try XCTUnwrap(PixelConversion.i420(from: buffer, width: 64, height: 48))
        XCTAssertEqual(back.y, picture.y); XCTAssertEqual(back.u, picture.u); XCTAssertEqual(back.v, picture.v)
        let scaled = try XCTUnwrap(PixelConversion.i420(from: buffer, width: 32, height: 24))
        XCTAssertEqual(scaled.y.count, 32 * 24)
        XCTAssertNotEqual(VideoDecoderSupport.decodeMask & NodeCapabilities.codecVP9, 0)
    }
}
