import Foundation

// BMV1 mesh envelopes (BMS1 type 7) and BFG1 forwarded-stream grants (Android MeshCore.kt,
// ForwardedStreamSecurity.kt). A viewer-forwarder copies unchanged envelopes to its children.

public struct MeshEnvelope: Equatable {
    public static let magic = Data("BMV1".utf8)
    public static let headerBytes = 50
    public static let maxPayloadBytes = 4 * 1024 * 1024
    public static let flagCodecConfig: UInt8 = 1
    public static let flagKeyFrame: UInt8 = 1 << 1
    public static let flagAudio: UInt8 = 1 << 3
    public static let flagControl: UInt8 = 1 << 4
    public static let flagTerminal: UInt8 = 1 << 5
    public static let flagDiscardable: UInt8 = 1 << 7
    public static let defaultTtl: UInt8 = 8

    public var streamId: UUID
    public var sourceNodeId: NodeId
    public var sequence: UInt64
    public var ttl: UInt8
    public var flags: UInt8
    public var payload: Data

    public init(streamId: UUID, sourceNodeId: NodeId, sequence: UInt64, ttl: UInt8, flags: UInt8, payload: Data) {
        self.streamId = streamId; self.sourceNodeId = sourceNodeId; self.sequence = sequence
        self.ttl = ttl; self.flags = flags; self.payload = payload.rebased
    }

    public var encoded: Data {
        var w = BinaryWriter(capacity: Self.headerBytes + payload.count)
        w.bytes(Self.magic); w.bytes(streamId.rawBytes); w.bytes(sourceNodeId.bytes); w.u64(sequence)
        w.byte(ttl); w.byte(flags); w.u32(UInt32(payload.count)); w.bytes(payload); return w.data
    }

    public init(decoding data: Data) throws {
        var r = BinaryReader(data)
        guard try r.bytes(4) == Self.magic else { throw ProtocolError.malformed("Invalid mesh packet") }
        streamId = UUID(rawBytes: try r.bytes(16))
        sourceNodeId = try NodeId(bytes: try r.bytes(16))
        sequence = try r.u64()
        guard sequence <= UInt64(Int64.max) else { throw ProtocolError.malformed("Sequence numbers must not be negative") }
        ttl = try r.byte(); flags = try r.byte()
        let size = Int(try r.i32())
        guard (0...Self.maxPayloadBytes).contains(size) else { throw ProtocolError.malformed("Invalid mesh payload size") }
        guard size == r.remaining else { throw ProtocolError.malformed("Truncated or trailing mesh packet data") }
        payload = try r.bytes(size)
    }

    /// Copy for a child link, or nil when the TTL is exhausted.
    public func forwarded() -> MeshEnvelope? { ttl <= 1 ? nil : MeshEnvelope(streamId: streamId, sourceNodeId: sourceNodeId, sequence: sequence, ttl: ttl - 1, flags: flags, payload: payload) }

    /// Outer flags for an inner media flag set: inner bits 4/5 (debug integrity, discontinuity) are removed.
    public static func meshFlags(mediaFlags: UInt8) -> UInt8 { mediaFlags & ~(flagControl | flagTerminal) }
}

public struct ForwardedStreamGrant: Equatable {
    public static let magic = Data("BFG1".utf8)
    public static let encodedBytes = 4 + 16 + 16 + 32
    public let sourceNodeId: NodeId
    public let streamId: UUID
    public let key: Data
    public init(sourceNodeId: NodeId, streamId: UUID, key: Data) { self.sourceNodeId = sourceNodeId; self.streamId = streamId; self.key = key.rebased }
    public var encoded: Data {
        var w = BinaryWriter(); w.bytes(Self.magic); w.bytes(sourceNodeId.bytes); w.bytes(streamId.rawBytes); w.bytes(key); return w.data
    }
    public init(decoding data: Data) throws {
        guard data.count == Self.encodedBytes else { throw ProtocolError.malformed("Invalid forwarded-stream grant length") }
        var r = BinaryReader(data)
        guard try r.bytes(4) == Self.magic else { throw ProtocolError.malformed("Invalid forwarded-stream grant") }
        sourceNodeId = try NodeId(bytes: try r.bytes(16)); streamId = UUID(rawBytes: try r.bytes(16)); key = try r.bytes(32)
    }
}

/// Bounded (stream, source, sequence) duplicate filter, as Android's DuplicateWindow.
public struct DuplicateWindow {
    private let capacity: Int
    private var order: [String] = []
    private var seen = Set<String>()
    public init(capacity: Int = 4_096) { self.capacity = capacity }
    public mutating func markIfNew(_ e: MeshEnvelope) -> Bool {
        let key = "\(e.streamId.uuidString)/\(e.sourceNodeId.hex)/\(e.sequence)"
        guard !seen.contains(key) else { return false }
        seen.insert(key); order.append(key)
        if order.count > capacity { seen.remove(order.removeFirst()) }
        return true
    }
}

/// Experimental call video fragments (BME1 type 9), Android CallVideoFragments.kt.
public enum CallVideoFragments {
    public static let fragmentBytes = 2_048
    public static let minFragmentedPacketBytes = 3_072
    public static let headerBytes = 8
    public static func shouldFragment(packetPlaintextBytes: Int, flags: UInt8) -> Bool {
        packetPlaintextBytes > minFragmentedPacketBytes && flags & StreamProtocol.flagAudio == 0 && flags & StreamProtocol.flagCodecConfig == 0
    }
    public static func split(_ packet: Data, chunkBytes: Int = fragmentBytes) throws -> [Data] {
        guard !packet.isEmpty, packet.count <= EndToEndContentProtocol.maxPlaintextBytes else { throw ProtocolError.malformed("Invalid fragmented packet size") }
        var out: [Data] = []; var offset = 0; let p = packet.rebased
        while offset < p.count {
            let length = min(chunkBytes, p.count - offset)
            var w = BinaryWriter(); w.u32(UInt32(p.count)); w.u32(UInt32(offset)); w.bytes(p.subdata(in: offset..<offset + length))
            out.append(w.data); offset += length
        }
        return out
    }
}

public struct CallVideoReassembler {
    private var total = 0, flags: UInt8 = 0, buffer = Data()
    public init() {}
    public var idle: Bool { buffer.isEmpty }
    public mutating func accept(flags recordFlags: UInt8, fragment: Data) throws -> Data? {
        var r = BinaryReader(fragment)
        let total = Int(try r.u32()), offset = Int(try r.u32())
        let chunk = try r.rest()
        guard !chunk.isEmpty, total > 0, total <= EndToEndContentProtocol.maxPlaintextBytes,
              recordFlags & StreamProtocol.flagAudio == 0, recordFlags & StreamProtocol.flagCodecConfig == 0 else {
            throw ProtocolError.malformed("Invalid call video fragment")
        }
        if buffer.isEmpty {
            guard offset == 0 else { throw ProtocolError.malformed("Call video fragment gap") }
            self.total = total; flags = recordFlags
        } else {
            guard offset == buffer.count, total == self.total, recordFlags == flags else { throw ProtocolError.malformed("Call video fragment mismatch") }
        }
        guard buffer.count + chunk.count <= total else { throw ProtocolError.malformed("Call video fragment overrun") }
        buffer.append(chunk)
        guard buffer.count == total else { return nil }
        defer { buffer = Data() }
        return buffer
    }
    public func requireIdle(_ what: String) throws { guard idle else { throw ProtocolError.malformed("\(what) arrived inside a fragmented frame") } }
}
