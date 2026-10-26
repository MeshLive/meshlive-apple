import Foundation

// BTV3 stream header and media packets (Android StreamProtocol.kt), carried inside BME1.

public enum StreamProtocol {
    public static let packetHeaderBytes = 13
    public static let flagCodecConfig: UInt8 = 1
    public static let flagKeyFrame: UInt8 = 2
    public static let flagDisplayRotation: UInt8 = 4
    public static let flagAudio: UInt8 = 8
    public static let flagDebugIntegrity: UInt8 = 16
    public static let flagDiscontinuity: UInt8 = 32
    public static let flagAudioPair: UInt8 = 64
    public static let flagDiscardable: UInt8 = 128
    public static let codecVP9: UInt8 = 2
    public static let codecAV1: UInt8 = 3
    /// Proposed (PROTOCOL addendum B): accepted only when `h264Enabled`.
    public static let codecH264: UInt8 = 4
    public static var h264Enabled = false
    public static let audioCodecNone: UInt8 = 0
    public static let audioCodecOpus: UInt8 = 1
    public static let audioSampleRate = 48_000
    public static let audioChannelCount = 1
    public static let maxPayloadBytes = 4 * 1024 * 1024
    static let headerMagic = Data("BTV3".utf8)
    static let pairMagic = Data("BTA1".utf8)
    static let batchMagic = Data("BTA2".utf8)
    static let maxAudioAccessUnitBytes = 16 * 1024
    static let maxAudioGapUs: Int64 = 1_000_000
    static let maxBatchPackets = 20

    /// Mask bit of a BTV3 codec in NodeCapabilities encode/decode masks and announcements.
    public static func capabilityMask(codecId: UInt8) -> UInt8 {
        switch codecId {
        case codecVP9: return NodeCapabilities.codecVP9
        case codecAV1: return NodeCapabilities.codecAV1
        case codecH264: return NodeCapabilities.codecH264
        default: return 0
        }
    }
}

public struct StreamHeader: Equatable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var codecId: UInt8
    public var rotationDegrees: Int
    public var audioCodecId: UInt8
    public var audioSampleRate: Int
    public var audioChannelCount: Int
    public var hasAudio: Bool { audioCodecId != StreamProtocol.audioCodecNone }
    public var displayWidth: Int { rotationDegrees == 90 || rotationDegrees == 270 ? height : width }
    public var displayHeight: Int { rotationDegrees == 90 || rotationDegrees == 270 ? width : height }

    public init(width: Int, height: Int, fps: Int, codecId: UInt8, rotationDegrees: Int = 0, includeAudio: Bool) {
        self.width = width; self.height = height; self.fps = fps; self.codecId = codecId; self.rotationDegrees = rotationDegrees
        audioCodecId = includeAudio ? StreamProtocol.audioCodecOpus : StreamProtocol.audioCodecNone
        audioSampleRate = includeAudio ? StreamProtocol.audioSampleRate : 0
        audioChannelCount = includeAudio ? StreamProtocol.audioChannelCount : 0
    }

    public func encoded() throws -> Data {
        guard [0, 90, 180, 270].contains(rotationDegrees) else { throw ProtocolError.malformed("Invalid video rotation") }
        var w = BinaryWriter(capacity: 15)
        w.bytes(StreamProtocol.headerMagic); w.u16(UInt16(width)); w.u16(UInt16(height)); w.byte(UInt8(fps))
        w.byte(codecId); w.byte(UInt8(rotationDegrees / 90)); w.byte(audioCodecId)
        w.u16(UInt16(audioSampleRate)); w.byte(UInt8(audioChannelCount))
        return w.data
    }

    /// Strict decode of an end-to-end stream header (no trailing bytes).
    public init(decoding data: Data) throws {
        var r = BinaryReader(data)
        guard try r.bytes(4) == StreamProtocol.headerMagic else { throw ProtocolError.incompatible("Unsupported stream header") }
        width = Int(try r.u16()); height = Int(try r.u16()); fps = Int(try r.byte())
        codecId = try r.byte(); let quarterTurns = Int(try r.byte())
        audioCodecId = try r.byte(); audioSampleRate = Int(try r.u16()); audioChannelCount = Int(try r.byte())
        try r.end()
        guard (1...4096).contains(width), (1...4096).contains(height), (1...120).contains(fps) else {
            throw ProtocolError.malformed("Invalid video format \(width)x\(height) at \(fps) FPS")
        }
        let codecs: Set<UInt8> = StreamProtocol.h264Enabled ? [2, 3, 4] : [2, 3]
        guard codecs.contains(codecId) else { throw ProtocolError.incompatible("Unsupported codec ID \(codecId)") }
        guard (0...3).contains(quarterTurns) else { throw ProtocolError.malformed("Invalid video rotation") }
        rotationDegrees = quarterTurns * 90
        let none = audioCodecId == 0 && audioSampleRate == 0 && audioChannelCount == 0
        let opus = audioCodecId == 1 && audioSampleRate == StreamProtocol.audioSampleRate && audioChannelCount == 1
        guard none || opus else { throw ProtocolError.incompatible("Unsupported audio format") }
    }
}

public struct MediaPacket: Equatable {
    public var flags: UInt8
    public var presentationTimeUs: Int64
    public var payload: Data
    public init(flags: UInt8, presentationTimeUs: Int64, payload: Data) {
        self.flags = flags; self.presentationTimeUs = presentationTimeUs; self.payload = payload.rebased
    }
    public var isAudio: Bool { flags & StreamProtocol.flagAudio != 0 }
    public var isKeyFrame: Bool { flags & StreamProtocol.flagKeyFrame != 0 }
    public var isCodecConfig: Bool { flags & StreamProtocol.flagCodecConfig != 0 }

    public var encoded: Data {
        var w = BinaryWriter(capacity: StreamProtocol.packetHeaderBytes + payload.count)
        w.i32(Int32(payload.count)); w.byte(flags); w.i64(presentationTimeUs); w.bytes(payload); return w.data
    }

    /// Strict decode of a BME1 media-packet plaintext; the inner flags must equal the authenticated header flags.
    public init(decoding data: Data, authenticatedFlags: UInt8) throws {
        var r = BinaryReader(data)
        let size = Int(try r.i32())
        guard (0...StreamProtocol.maxPayloadBytes).contains(size) else { throw ProtocolError.malformed("Invalid payload size \(size)") }
        flags = try r.byte(); presentationTimeUs = try r.i64(); payload = try r.bytes(size)
        try r.end()
        guard flags == authenticatedFlags else { throw ProtocolError.malformed("End-to-end packet flags do not match authenticated metadata") }
    }

    public static func displayRotation(_ degrees: Int) throws -> MediaPacket {
        guard [0, 90, 180, 270].contains(degrees) else { throw ProtocolError.malformed("Invalid video rotation") }
        return MediaPacket(flags: StreamProtocol.flagDisplayRotation, presentationTimeUs: 0, payload: Data([UInt8(degrees / 90)]))
    }
    public func decodeDisplayRotation() throws -> Int {
        guard flags & StreamProtocol.flagDisplayRotation != 0, payload.count == 1, payload[0] <= 3 else {
            throw ProtocolError.malformed("Invalid display rotation packet")
        }
        return Int(payload[0]) * 90
    }

    /// Splits a BTA1 pair or BTA2 batch (Android `splitAudioPair`). Ordinary packets return themselves.
    public func splitAudio() throws -> [MediaPacket] {
        guard flags & StreamProtocol.flagAudioPair != 0 else { return [self] }
        guard flags == StreamProtocol.flagAudio | StreamProtocol.flagAudioPair else { throw ProtocolError.malformed("Packet is not a paired-audio record") }
        var r = BinaryReader(payload)
        func unit() throws -> Data {
            let size = Int(try r.u16())
            guard size <= StreamProtocol.maxAudioAccessUnitBytes else { throw ProtocolError.malformed("Invalid Opus access-unit size") }
            return try r.bytes(size)
        }
        func delta() throws -> Int64 {
            let value = Int64(try r.i32())
            guard (0...StreamProtocol.maxAudioGapUs).contains(value) else { throw ProtocolError.malformed("Invalid paired-audio timestamp gap") }
            // The unit's time must fit in 64 bits (a peer's timestamp near the limit is rejected, never trapped on).
            guard !presentationTimeUs.addingReportingOverflow(value).overflow else { throw ProtocolError.malformed("Audio timestamp out of range") }
            return value
        }
        let magic = try r.bytes(4)
        var out: [MediaPacket] = []
        if magic == StreamProtocol.batchMagic {
            let count = Int(try r.byte())
            guard (3...StreamProtocol.maxBatchPackets).contains(count) else { throw ProtocolError.malformed("Invalid audio batch size") }
            for _ in 0..<count {
                let d = try delta()
                out.append(MediaPacket(flags: StreamProtocol.flagAudio, presentationTimeUs: presentationTimeUs + d, payload: try unit()))
            }
        } else if magic == StreamProtocol.pairMagic {
            let d = try delta()
            out.append(MediaPacket(flags: StreamProtocol.flagAudio, presentationTimeUs: presentationTimeUs, payload: try unit()))
            out.append(MediaPacket(flags: StreamProtocol.flagAudio, presentationTimeUs: presentationTimeUs + d, payload: try unit()))
        } else {
            throw ProtocolError.malformed("Invalid paired-audio header")
        }
        try r.end()
        return out
    }

    /// BTA1 (two packets) or BTA2 (3-20 packets), as Android's `pairAudioPackets`/`batchAudioPackets`.
    public static func combineAudio(_ packets: [MediaPacket]) throws -> MediaPacket {
        guard (2...StreamProtocol.maxBatchPackets).contains(packets.count),
              packets.allSatisfy({ $0.flags == StreamProtocol.flagAudio && $0.payload.count <= StreamProtocol.maxAudioAccessUnitBytes }) else {
            throw ProtocolError.malformed("Only ordinary Opus access units can be combined")
        }
        let first = packets[0].presentationTimeUs
        let deltas = packets.map { $0.presentationTimeUs - first }
        guard deltas.allSatisfy({ (0...StreamProtocol.maxAudioGapUs).contains($0) }) else { throw ProtocolError.malformed("Invalid audio timestamp gap") }
        var w = BinaryWriter()
        if packets.count == 2 {
            w.bytes(StreamProtocol.pairMagic); w.i32(Int32(deltas[1]))
            for p in packets { w.u16(UInt16(p.payload.count)); w.bytes(p.payload) }
        } else {
            w.bytes(StreamProtocol.batchMagic); w.byte(UInt8(packets.count))
            for (p, d) in zip(packets, deltas) { w.i32(Int32(d)); w.u16(UInt16(p.payload.count)); w.bytes(p.payload) }
        }
        return MediaPacket(flags: StreamProtocol.flagAudio | StreamProtocol.flagAudioPair, presentationTimeUs: first, payload: w.data)
    }
}

/// RFC 7845 identification header: what Android's MediaCodec Opus encoder reports as csd-0 and what
/// Android's decoder setup (OpusCodecConfig.normalize) requires before the first audio packet.
public enum OpusHead {
    public static func make(channels: UInt8 = 1, preSkip: UInt16 = 312, inputSampleRate: UInt32 = 48_000) -> Data {
        var d = Data("OpusHead".utf8)
        d.append(1); d.append(channels)
        d.append(UInt8(preSkip & 0xff)); d.append(UInt8(preSkip >> 8))
        for shift in stride(from: 0, through: 24, by: 8) { d.append(UInt8((inputSampleRate >> UInt32(shift)) & 0xff)) }
        d.append(0); d.append(0) // output gain
        d.append(0)              // channel mapping family 0
        return d
    }
    public static func parse(_ data: Data) throws -> (channels: Int, preSkip: Int) {
        let d = data.rebased
        guard d.count >= 19, d.prefix(8) == Data("OpusHead".utf8), d[8] == 1 else { throw ProtocolError.incompatible("Unsupported Opus codec configuration") }
        return (Int(d[9]), Int(d[10]) | Int(d[11]) << 8)
    }
}
