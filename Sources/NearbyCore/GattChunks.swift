import Foundation

// Android GATT byte stream (GattVideoTransport.kt): each write/notification is
// `0x01 | u32 big-endian chunk sequence | payload`, sequences from 0 per direction.
// Type 0x02 values are ignored (reserved keepalive). Late duplicates are ignored and a bounded
// number of early chunks is held for reordering, exactly as GattBytePipe.

public enum GattChunk {
    public static let headerBytes = 5
    public static let typeData: UInt8 = 1
    public static let typeIgnored: UInt8 = 2
    public static let maxAttributeBytes = 512
    /// Payload bytes per chunk for an ATT value limit (`maximumWriteValueLength` / `maximumUpdateValueLength`).
    public static func payloadBytes(valueLimit: Int) -> Int { max(1, min(valueLimit, maxAttributeBytes) - headerBytes) }
}

public struct GattChunkWriter {
    public private(set) var nextSequence: UInt32 = 0
    public init() {}
    /// Splits stream bytes into chunk values; the caller writes them strictly in order.
    public mutating func chunks(_ bytes: Data, valueLimit: Int) -> [Data] {
        let capacity = GattChunk.payloadBytes(valueLimit: valueLimit)
        var out: [Data] = []; var offset = bytes.startIndex
        while offset < bytes.endIndex {
            let end = min(offset + capacity, bytes.endIndex)
            var w = BinaryWriter(capacity: GattChunk.headerBytes + end - offset)
            w.byte(GattChunk.typeData); w.u32(nextSequence); w.bytes(bytes[offset..<end])
            out.append(w.data); nextSequence &+= 1; offset = end
        }
        return out
    }
}

public struct GattChunkReader {
    static let recentHistory = 4_096
    static let maxReordered = 4_096
    static let maxReorderDistance: UInt32 = 4_096
    public private(set) var nextSequence: UInt32 = 0
    private var recent: [UInt32] = []
    private var recentSet = Set<UInt32>()
    private var pending: [UInt32: Data] = [:]
    public init() {}

    /// Returns in-order stream bytes made available by this value (possibly empty).
    public mutating func accept(_ value: Data) throws -> Data {
        let v = value.rebased
        guard !v.isEmpty else { throw ProtocolError.malformed("Empty GATT value") }
        if v[0] == GattChunk.typeIgnored { return Data() }
        guard v.count >= GattChunk.headerBytes, v[0] == GattChunk.typeData else { throw ProtocolError.malformed("Invalid GATT chunk header") }
        let sequence = UInt32(v[1]) << 24 | UInt32(v[2]) << 16 | UInt32(v[3]) << 8 | UInt32(v[4])
        if recentSet.contains(sequence) || pending[sequence] != nil { return Data() }
        if sequence > nextSequence {
            guard sequence - nextSequence <= GattChunkReader.maxReorderDistance, pending.count < GattChunkReader.maxReordered else {
                throw ProtocolError.malformed("Received chunk \(sequence); expected \(nextSequence)")
            }
            pending[sequence] = v; return Data()
        }
        guard sequence == nextSequence else { throw ProtocolError.malformed("Received chunk \(sequence); expected \(nextSequence)") }
        var out = Data(v.dropFirst(GattChunk.headerBytes)); advance()
        while let next = pending.removeValue(forKey: nextSequence) { out.append(next.dropFirst(GattChunk.headerBytes)); advance() }
        return out
    }

    private mutating func advance() {
        if recent.count >= GattChunkReader.recentHistory { recentSet.remove(recent.removeFirst()) }
        recent.append(nextSequence); recentSet.insert(nextSequence); nextSequence &+= 1
    }
}
