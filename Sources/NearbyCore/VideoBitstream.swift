import Foundation

// Minimal VP9/AV1 bitstream inspection: keyframe detection, frame size and the codec configuration
// records VideoToolbox needs ('vpcC', 'av1C'). Untrusted input: every read is bounds-checked.

struct BitReader {
    private let bytes: [UInt8]
    private(set) var bit = 0
    init(_ data: Data) { bytes = [UInt8](data) }
    var bitsLeft: Int { bytes.count * 8 - bit }
    mutating func f(_ n: Int) throws -> UInt32 {
        guard n <= 32, n <= bitsLeft else { throw ProtocolError.malformed("Truncated video header") }
        var v: UInt32 = 0
        for _ in 0..<n { v = v << 1 | UInt32((bytes[bit >> 3] >> (7 - UInt8(bit & 7))) & 1); bit += 1 }
        return v
    }
    mutating func flag() throws -> Bool { try f(1) == 1 }
    /// AV1 leb128 (byte aligned).
    mutating func leb128() throws -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            let byte = UInt64(try f(8))
            value |= (byte & 0x7f) << (7 * UInt64(i))
            if byte & 0x80 == 0 { return value }
        }
        throw ProtocolError.malformed("Invalid leb128")
    }
    /// AV1 uvlc().
    mutating func uvlc() throws -> UInt32 {
        var leading = 0
        while try f(1) == 0 { leading += 1; guard leading < 32 else { throw ProtocolError.malformed("Invalid uvlc") } }
        return leading == 0 ? 0 : (try f(leading)) + (UInt32(1) << UInt32(leading)) - 1
    }
}

public struct VP9FrameInfo: Equatable {
    public var profile: Int
    public var keyFrame: Bool
    public var showFrame: Bool
    public var bitDepth: Int
    public var colorSpace: Int
    public var fullRange: Bool
    public var subsamplingX: Bool
    public var subsamplingY: Bool
    public var width: Int
    public var height: Int
    public init(profile: Int, keyFrame: Bool, showFrame: Bool, bitDepth: Int, colorSpace: Int, fullRange: Bool,
                subsamplingX: Bool, subsamplingY: Bool, width: Int, height: Int) {
        self.profile = profile; self.keyFrame = keyFrame; self.showFrame = showFrame; self.bitDepth = bitDepth
        self.colorSpace = colorSpace; self.fullRange = fullRange; self.subsamplingX = subsamplingX
        self.subsamplingY = subsamplingY; self.width = width; self.height = height
    }
}

public enum VP9Bitstream {
    /// Splits a superframe into its frames (or returns the whole access unit).
    public static func frames(_ data: Data) -> [Data] {
        let d = data.rebased
        guard let marker = d.last, marker & 0xe0 == 0xc0 else { return [d] }
        let count = Int(marker & 0x7) + 1, sizeBytes = Int((marker >> 3) & 0x3) + 1
        let indexSize = 2 + sizeBytes * count
        guard d.count >= indexSize, d[d.count - indexSize] == marker else { return [d] }
        var offset = 0, out: [Data] = []
        var pos = d.count - indexSize + 1
        for _ in 0..<count {
            var size = 0
            for b in 0..<sizeBytes { size |= Int(d[pos + b]) << (8 * b) }
            pos += sizeBytes
            guard size > 0, offset + size <= d.count - indexSize else { return [d] }
            out.append(d.subdata(in: offset..<offset + size)); offset += size
        }
        return out
    }

    /// Parses the uncompressed header of the first frame. Key frames carry colour config and size.
    public static func inspect(_ accessUnit: Data) throws -> VP9FrameInfo {
        guard let first = frames(accessUnit).first else { throw ProtocolError.malformed("Empty VP9 access unit") }
        var r = BitReader(first)
        guard try r.f(2) == 2 else { throw ProtocolError.malformed("Invalid VP9 frame marker") }
        let low = try r.f(1), high = try r.f(1)
        let profile = Int(high << 1 | low)
        if profile == 3 { _ = try r.f(1) }
        if try r.flag() { throw ProtocolError.malformed("VP9 show-existing frame has no header") }
        let keyFrame = try r.f(1) == 0
        let showFrame = try r.flag()
        _ = try r.f(1) // error_resilient_mode
        var info = VP9FrameInfo(profile: profile, keyFrame: keyFrame, showFrame: showFrame, bitDepth: 8, colorSpace: 0,
                                fullRange: false, subsamplingX: true, subsamplingY: true, width: 0, height: 0)
        guard keyFrame else { return info }
        guard try r.f(8) == 0x49, try r.f(8) == 0x83, try r.f(8) == 0x42 else { throw ProtocolError.malformed("Invalid VP9 sync code") }
        if profile >= 2 { info.bitDepth = try r.flag() ? 12 : 10 }
        info.colorSpace = Int(try r.f(3))
        if info.colorSpace != 7 {
            info.fullRange = try r.flag()
            if profile == 1 || profile == 3 { info.subsamplingX = try r.flag(); info.subsamplingY = try r.flag(); _ = try r.f(1) }
        } else {
            info.fullRange = true
            if profile == 1 || profile == 3 { info.subsamplingX = false; info.subsamplingY = false; _ = try r.f(1) }
        }
        info.width = Int(try r.f(16)) + 1
        info.height = Int(try r.f(16)) + 1
        return info
    }

    /// VPCodecConfigurationRecord ('vpcC', version 1) for VideoToolbox, from a key frame.
    public static func vpcC(_ info: VP9FrameInfo) -> Data {
        let chroma: UInt8 = info.subsamplingX && info.subsamplingY ? 1 : (info.subsamplingX ? 2 : 3)
        // VP9 colour_space -> ISO/IEC 23091-2 primaries/transfer/matrix.
        let (primaries, transfer, matrix): (UInt8, UInt8, UInt8)
        switch info.colorSpace {
        case 1: (primaries, transfer, matrix) = (5, 6, 5)  // BT.601 (625)
        case 2: (primaries, transfer, matrix) = (1, 1, 1)  // BT.709
        case 3: (primaries, transfer, matrix) = (6, 6, 6)  // SMPTE 170M
        case 4: (primaries, transfer, matrix) = (7, 7, 7)  // SMPTE 240M
        case 5: (primaries, transfer, matrix) = (9, 14, 9) // BT.2020
        case 7: (primaries, transfer, matrix) = (1, 13, 0) // sRGB
        default: (primaries, transfer, matrix) = (2, 2, 2) // unspecified
        }
        let pixels = info.width * info.height
        let level: UInt8 = pixels <= 36_864 ? 10 : pixels <= 122_880 ? 20 : pixels <= 245_760 ? 21 : pixels <= 552_960 ? 30 : pixels <= 983_040 ? 31 : pixels <= 2_228_224 ? 40 : 50
        var d = Data([1, 0, 0, 0, UInt8(info.profile), level])
        d.append(UInt8(info.bitDepth) << 4 | chroma << 1 | (info.fullRange ? 1 : 0))
        d.append(contentsOf: [primaries, transfer, matrix, 0, 0])
        return d
    }
}

public struct AV1SequenceInfo: Equatable {
    public var profile: Int
    public var level: Int
    public var tier: Int
    public var highBitDepth: Bool
    public var twelveBit: Bool
    public var monochrome: Bool
    public var subsamplingX: Bool
    public var subsamplingY: Bool
    public var chromaSamplePosition: Int
    public var maxWidth: Int
    public var maxHeight: Int
    /// The complete sequence header OBU (with size field), for av1C configOBUs.
    public var sequenceHeaderOBU: Data
}

public enum AV1Bitstream {
    /// Finds and parses the sequence header OBU in a temporal unit (low-overhead format, sizes present).
    public static func sequenceHeader(in temporalUnit: Data) throws -> AV1SequenceInfo? {
        let d = temporalUnit.rebased
        var offset = 0
        while offset < d.count {
            var header = BitReader(d.subdata(in: offset..<d.count))
            _ = try header.f(1)
            let type = Int(try header.f(4))
            let extensionFlag = try header.flag(), hasSize = try header.flag()
            _ = try header.f(1)
            if extensionFlag { _ = try header.f(8) }
            guard hasSize else { throw ProtocolError.malformed("AV1 OBU without size field") }
            let size = Int(try header.leb128())
            let headerBytes = header.bit / 8
            guard size >= 0, offset + headerBytes + size <= d.count else { throw ProtocolError.malformed("Truncated AV1 OBU") }
            if type == 1 {
                let payload = d.subdata(in: offset + headerBytes..<offset + headerBytes + size)
                var info = try parseSequenceHeader(payload)
                info.sequenceHeaderOBU = d.subdata(in: offset..<offset + headerBytes + size)
                return info
            }
            offset += headerBytes + size
        }
        return nil
    }

    static func parseSequenceHeader(_ payload: Data) throws -> AV1SequenceInfo {
        var r = BitReader(payload)
        let profile = Int(try r.f(3))
        let stillPicture = try r.flag()
        let reduced = try r.flag()
        var level = 0, tier = 0
        if reduced {
            level = Int(try r.f(5))
        } else {
            let timingInfoPresent = try r.flag()
            var decoderModelInfoPresent = false
            var bufferDelayLength = 0
            if timingInfoPresent {
                _ = try r.f(32); _ = try r.f(32)
                if try r.flag() { _ = try r.uvlc() }
                decoderModelInfoPresent = try r.flag()
                if decoderModelInfoPresent {
                    bufferDelayLength = Int(try r.f(5)) + 1
                    _ = try r.f(32); _ = try r.f(5); _ = try r.f(5)
                }
            }
            let initialDisplayDelayPresent = try r.flag()
            let count = Int(try r.f(5)) + 1
            for i in 0..<count {
                _ = try r.f(12)
                let l = Int(try r.f(5))
                var t = 0
                if l > 7 { t = Int(try r.f(1)) }
                if i == 0 { level = l; tier = t }
                if decoderModelInfoPresent, try r.flag() { _ = try r.f(bufferDelayLength); _ = try r.f(bufferDelayLength); _ = try r.f(1) }
                if initialDisplayDelayPresent, try r.flag() { _ = try r.f(4) }
            }
        }
        _ = stillPicture
        let widthBits = Int(try r.f(4)) + 1, heightBits = Int(try r.f(4)) + 1
        let maxWidth = Int(try r.f(widthBits)) + 1, maxHeight = Int(try r.f(heightBits)) + 1
        if !reduced, try r.flag() { _ = try r.f(4); _ = try r.f(3) } // frame_id_numbers_present
        _ = try r.f(1); _ = try r.f(1); _ = try r.f(1) // use_128x128_superblock, enable_filter_intra, enable_intra_edge_filter
        if !reduced {
            _ = try r.f(1); _ = try r.f(1); _ = try r.f(1); _ = try r.f(1) // interintra, masked compound, warped motion, dual filter
            let orderHint = try r.flag()
            if orderHint { _ = try r.f(1); _ = try r.f(1) }
            let chooseScreen = try r.flag()
            var forceScreen = 2
            if !chooseScreen { forceScreen = Int(try r.f(1)) }
            if forceScreen > 0 { if !(try r.flag()) { _ = try r.f(1) } }
            if orderHint { _ = try r.f(3) }
        }
        _ = try r.f(1); _ = try r.f(1); _ = try r.f(1) // enable_superres, enable_cdef, enable_restoration
        // color_config()
        let highBitDepth = try r.flag()
        var twelve = false
        if profile == 2 && highBitDepth { twelve = try r.flag() }
        let mono = profile == 1 ? false : try r.flag()
        var sx = true, sy = true, csp = 0
        let colorDescription = try r.flag()
        var primaries = 2, transfer = 2, matrix = 2
        if colorDescription { primaries = Int(try r.f(8)); transfer = Int(try r.f(8)); matrix = Int(try r.f(8)) }
        if mono {
            _ = try r.f(1)
        } else if primaries == 1 && transfer == 13 && matrix == 0 {
            sx = false; sy = false
        } else {
            _ = try r.f(1) // color_range
            if profile == 0 { sx = true; sy = true }
            else if profile == 1 { sx = false; sy = false }
            else if twelve { sx = try r.flag(); if sx { sy = try r.flag() } else { sy = false } }
            else { sx = true; sy = false }
            if sx && sy { csp = Int(try r.f(2)) }
        }
        return AV1SequenceInfo(profile: profile, level: level, tier: tier, highBitDepth: highBitDepth, twelveBit: twelve, monochrome: mono,
                               subsamplingX: sx, subsamplingY: sy, chromaSamplePosition: csp, maxWidth: maxWidth, maxHeight: maxHeight, sequenceHeaderOBU: Data())
    }

    /// AV1CodecConfigurationRecord ('av1C').
    public static func av1C(_ s: AV1SequenceInfo) -> Data {
        var d = Data([0x81])
        d.append(UInt8(s.profile) << 5 | UInt8(s.level & 0x1f))
        var b: UInt8 = UInt8(s.tier) << 7
        if s.highBitDepth { b |= 1 << 6 }
        if s.twelveBit { b |= 1 << 5 }
        if s.monochrome { b |= 1 << 4 }
        if s.subsamplingX { b |= 1 << 3 }
        if s.subsamplingY { b |= 1 << 2 }
        b |= UInt8(s.chromaSamplePosition & 3)
        d.append(b); d.append(0)
        d.append(s.sequenceHeaderOBU)
        return d
    }
}
