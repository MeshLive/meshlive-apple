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

/// Android ChunkGapPolicy (option A of the lost-chunk design, default on): a receiving host can lose one whole ATT
/// value (legacy Android fragmenters drop a 0-1 byte ACL start fragment). The reader then parks every later chunk and
/// delivers nothing, and the call used to end 8 s later as "peer stopped responding". Now the stream ends when a gap
/// is held 1 s or behind 128 later chunks, with a reason. The window still allows a brief reorder across ATT bearers.
public enum ChunkGapPolicy {
    public static let gapSeconds: TimeInterval = 1
    public static let gapChunks = 128
    public static func lost(heldSeconds: TimeInterval, parkedChunks: Int) -> Bool { heldSeconds >= gapSeconds || parkedChunks >= gapChunks }
    public static func reason(missing: UInt32, parkedChunks: Int, heldSeconds: TimeInterval) -> String {
        "GATT chunk \(missing) was lost (\(parkedChunks) later chunks waited \(Int((heldSeconds * 1000).rounded())) ms)"
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
    /// ChunkGapPolicy; false is the control arm (wait as before, up to 4,096 parked chunks).
    public let failFast: Bool
    /// When the current gap opened (the first chunk parked behind a missing one).
    public private(set) var gapOpenedAt: TimeInterval?
    public init(failFast: Bool = true) { self.failFast = failFast }

    /// Ends the stream when the current gap has been held too long (call it when the gap's deadline passes).
    public func check(now: TimeInterval) throws {
        guard failFast, let opened = gapOpenedAt, ChunkGapPolicy.lost(heldSeconds: now - opened, parkedChunks: pending.count) else { return }
        throw ProtocolError.malformed(ChunkGapPolicy.reason(missing: nextSequence, parkedChunks: pending.count, heldSeconds: now - opened))
    }

    /// Returns in-order stream bytes made available by this value (possibly empty).
    public mutating func accept(_ value: Data, now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> Data {
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
            pending[sequence] = v
            if gapOpenedAt == nil { gapOpenedAt = now }
            try check(now: now)
            return Data()
        }
        guard sequence == nextSequence else { throw ProtocolError.malformed("Received chunk \(sequence); expected \(nextSequence)") }
        var out = Data(v.dropFirst(GattChunk.headerBytes)); advance()
        while let next = pending.removeValue(forKey: nextSequence) { out.append(next.dropFirst(GattChunk.headerBytes)); advance() }
        // The gap filled: a second gap left behind it starts its own clock.
        gapOpenedAt = pending.isEmpty ? nil : now
        return out
    }

    private mutating func advance() {
        if recent.count >= GattChunkReader.recentHistory { recentSet.remove(recent.removeFirst()) }
        recent.append(nextSequence); recentSet.insert(nextSequence); nextSequence &+= 1
    }
}
