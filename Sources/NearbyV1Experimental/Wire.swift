import Foundation
#if canImport(NearbyCore)
import NearbyCore
#endif

// Experimental standalone v1 (Noise XX) protocol: default off, not Android-compatible. See README register.

public enum Wire {
    public static let version: UInt8 = 1
    public static let maxRecord = 32_768
    public static let maxText = 4_096
    public static let service = "7D2C9B68-19E6-4F03-8B41-82AE51F26790"
    public static let info = "7D2C9B68-19E6-4F03-8B41-82AE51F26791"
    public static let write = "7D2C9B68-19E6-4F03-8B41-82AE51F26792"
    public static let notify = "7D2C9B68-19E6-4F03-8B41-82AE51F26793"
    public static func utf8Prefix(_ text: String, maximum: Int) -> Data {
        var result = Data()
        for scalar in text.unicodeScalars {
            let bytes = Data(String(scalar).utf8)
            if result.count + bytes.count > maximum { break }; result.append(bytes)
        }
        return result
    }
    public static func frame(_ record: Data) throws -> Data {
        guard !record.isEmpty, record.count <= maxRecord else { throw ProtocolError.limit("Record length out of range") }
        var w = BinaryWriter(); w.u32(UInt32(record.count)); w.bytes(record); return w.data
    }
}

/// Incremental framing for both byte streams and reassembled BLE records.
public struct FrameDecoder {
    private var buffer = Data()
    public var bufferedBytes: Int { buffer.count }
    public init() {}
    public mutating func feed(_ input: Data) throws -> [Data] {
        // Each caller supplies at most one 16 KiB stream read or one bounded BLE record.
        guard input.count <= Wire.maxRecord + 4, buffer.count + input.count <= 2 * (Wire.maxRecord + 4) else {
            throw ProtocolError.limit("Receive buffer exhausted")
        }
        buffer.append(input)
        var records: [Data] = []
        while buffer.count >= 4 {
            var r = BinaryReader(buffer); let length = Int(try r.u32())
            guard length > 0, length <= Wire.maxRecord else { throw ProtocolError.malformed("Invalid record length") }
            guard buffer.count >= length + 4 else { break }
            records.append(buffer.subdata(in: 4..<(4 + length)))
            buffer = Data(buffer.dropFirst(length + 4))
        }
        return records
    }
}

/// BLE chunk framing is independent of the application frame. One record in flight per direction.
public struct GATTFragmenter {
    public static let headerSize = 9
    public static func chunks(_ framed: Data, id: UInt32, maximum: Int) throws -> [Data] {
        guard maximum > headerSize, maximum <= 65_535, framed.count <= Wire.maxRecord + 4 else {
            throw ProtocolError.limit("Invalid GATT update length")
        }
        var chunks: [Data] = []; let capacity = maximum - headerSize
        for offset in stride(from: 0, to: framed.count, by: capacity) {
            var w = BinaryWriter(); w.byte(1); w.u32(id); w.u16(UInt16(offset)); w.u16(UInt16(framed.count))
            w.bytes(framed.subdata(in: offset..<min(offset + capacity, framed.count))); chunks.append(w.data)
        }
        return chunks
    }
}

public struct GATTAssembler {
    private var id: UInt32?
    private var expectedID: UInt32 = 0
    private var total = 0
    private var buffer = Data()
    public var bufferedBytes: Int { buffer.count }
    public init() {}
    public mutating func feed(_ chunk: Data) throws -> Data? {
        var r = BinaryReader(chunk)
        guard try r.byte() == 1 else { throw ProtocolError.incompatible("Unknown BLE chunk version") }
        let incoming = try r.u32(), offset = Int(try r.u16()), size = Int(try r.u16())
        guard size >= 5, size <= Wire.maxRecord + 4, r.remaining > 0 else { throw ProtocolError.malformed("Invalid BLE chunk size") }
        if id == nil {
            guard offset == 0, incoming == expectedID else { throw ProtocolError.replay }
            id = incoming; total = size
        }
        guard id == incoming, total == size, offset == buffer.count, offset + r.remaining <= total else {
            throw ProtocolError.malformed("Out of order BLE fragment")
        }
        buffer.append(try r.bytes(r.remaining))
        if buffer.count == total {
            let result = buffer; buffer = Data(); id = nil
            guard expectedID < UInt32.max else { throw ProtocolError.limit("BLE record counter exhausted") }
            expectedID += 1; return result
        }
        return nil
    }
}

public enum TransportKind: UInt8, CaseIterable { case gatt = 1, l2cap = 2 }
public enum AudioCodec: UInt8 { case opus = 1, pcmDiagnostic = 2 }

public struct Capabilities: Equatable {
    public var transport: TransportKind
    public var opus: Bool
    public var pcm: Bool
    public var video: Bool
    public var name: String
    public init(transport: TransportKind, opus: Bool = false, pcm: Bool = true, video: Bool = false, name: String) {
        self.transport = transport; self.opus = opus; self.pcm = pcm; self.video = video; self.name = name
    }
    public var encoded: Data {
        let nameBytes = Wire.utf8Prefix(name, maximum: 48)
        var w = BinaryWriter(); w.byte(Wire.version); w.byte(transport.rawValue)
        w.byte((opus ? 1 : 0) | (pcm ? 2 : 0)); w.byte(video ? 1 : 0)
        w.byte(UInt8(nameBytes.count)); w.bytes(nameBytes); return w.data
    }
    public init(decoding data: Data) throws {
        var r = BinaryReader(data)
        guard try r.byte() == Wire.version else { throw ProtocolError.incompatible("Unsupported protocol version") }
        guard let t = TransportKind(rawValue: try r.byte()) else { throw ProtocolError.incompatible("Unsupported transport") }
        transport = t
        let a = try r.byte(), v = try r.byte(), count = Int(try r.byte())
        guard a & ~3 == 0, a != 0, v & ~1 == 0, count <= 48,
              let n = String(data: try r.bytes(count), encoding: .utf8) else { throw ProtocolError.malformed("Invalid capabilities") }
        opus = a & 1 != 0; pcm = a & 2 != 0; video = v == 1; name = n; try r.end()
    }
    public func negotiate(with peer: Self) throws -> MediaProfile {
        guard transport == peer.transport else { throw ProtocolError.incompatible("Selected transports differ") }
        if opus && peer.opus { return MediaProfile(codec: .opus, video: video && peer.video) }
        if pcm && peer.pcm { return MediaProfile(codec: .pcmDiagnostic, video: false) }
        throw ProtocolError.incompatible("No shared audio codec")
    }
}

public struct MediaProfile: Equatable {
    public let codec: AudioCodec
    public let video: Bool
    public var sampleRate: UInt32 { codec == .opus ? 48_000 : 8_000 }
    public var bitrate: UInt32 { codec == .opus ? 20_000 : 128_000 }
    public init(codec: AudioCodec, video: Bool) { self.codec = codec; self.video = video }
    public var encoded: Data {
        var w = BinaryWriter(); w.byte(codec.rawValue); w.u32(sampleRate); w.byte(1); w.u16(20); w.u32(bitrate)
        w.byte(video ? 1 : 0); return w.data
    }
}

public struct DiscoveryInfo {
    public let psm: UInt16
    public let token: Data
    public init(psm: UInt16, token: Data) { self.psm = psm; self.token = token }
    public var encoded: Data { var w = BinaryWriter(); w.byte(1); w.u16(psm); w.bytes(token); return w.data }
    public init(decoding: Data) throws {
        var r = BinaryReader(decoding)
        guard try r.byte() == 1 else { throw ProtocolError.incompatible("Unsupported discovery version") }
        psm = try r.u16(); token = try r.bytes(16); try r.end()
    }
}
