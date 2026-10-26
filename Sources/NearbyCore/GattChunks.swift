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
    /// The largest LE data PDU payload (Data Length Extension) and the ATT + L2CAP headers in front of a value.
    public static let leDataPduOctets = 251
    static let attAndL2capHeaderBytes = 3 + 4
    /// The ATT value size for a limit. `aligned` (Android `test_gatt_aligned_writes`, Experimental, off) rounds it down
    /// to whole 251-octet LE data PDUs: 495 bytes fill exactly two (a 512-byte value is 251 + 251 + 17), 244 one.
    public static func valueBytes(valueLimit: Int, aligned: Bool = false) -> Int {
        let limit = max(1, min(valueLimit, maxAttributeBytes))
        guard aligned else { return limit }
        let wholePdus = (limit + attAndL2capHeaderBytes) / leDataPduOctets
        return wholePdus >= 1 ? wholePdus * leDataPduOctets - attAndL2capHeaderBytes : limit
    }
    /// Payload bytes per chunk for an ATT value limit (`maximumWriteValueLength` / `maximumUpdateValueLength`).
    public static func payloadBytes(valueLimit: Int, aligned: Bool = false) -> Int {
        max(1, valueBytes(valueLimit: valueLimit, aligned: aligned) - headerBytes)
    }
}

public struct GattChunkWriter {
    public private(set) var nextSequence: UInt32 = 0
    public init() {}
    /// Splits stream bytes into chunk values; the caller writes them strictly in order.
    public mutating func chunks(_ bytes: Data, valueLimit: Int, aligned: Bool = false) -> [Data] {
        let capacity = GattChunk.payloadBytes(valueLimit: valueLimit, aligned: aligned)
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
    /// Experimental GR1: once the peer's HELLO arrived, a gap waits for resends instead of the fail-fast.
    public var recovery: GattChunkRecovery?
    private var parkedBytes = 0
    private var recoveryFailure: String?
    public init(failFast: Bool = true, recovery: GattChunkRecovery? = nil) { self.failFast = failFast; self.recovery = recovery }

    /// Ends the stream when the current gap has been held too long (call it when the gap's deadline passes, and every
    /// recovery tick: it also sends GR1 requests that are due).
    public mutating func check(now: TimeInterval) throws {
        if let recoveryFailure { throw ProtocolError.malformed(recoveryFailure) }
        if let recovery, recovery.readerActive {
            let keys = pending.keys.sorted { Gr1.after($0, $1) < 0 }
            if let reason = recovery.update(next: nextSequence, pending: keys, parkedBytes: parkedBytes, now: now) {
                recoveryFailure = reason; throw ProtocolError.malformed(reason)
            }
            return
        }
        guard failFast, let opened = gapOpenedAt, ChunkGapPolicy.lost(heldSeconds: now - opened, parkedChunks: pending.count) else { return }
        throw ProtocolError.malformed(ChunkGapPolicy.reason(missing: nextSequence, parkedChunks: pending.count, heldSeconds: now - opened))
    }

    /// GR1 GONE from the peer: a missing chunk it no longer holds ends the stream at the next check.
    public mutating func recoveryGone(_ range: Gr1.SeqRange) {
        if let hit = recovery?.goneHit(range) { recoveryFailure = "GATT chunk \(hit) was lost and the peer no longer holds it" }
    }

    /// GR1 HIGH from the peer: a missing tail is requested at the next check.
    public mutating func recoveryHigh(_ sequence: UInt32) { _ = recovery?.onHigh(sequence, next: nextSequence) }

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
            pending[sequence] = v; parkedBytes += v.count
            if gapOpenedAt == nil { gapOpenedAt = now }
            try check(now: now)
            return Data()
        }
        guard sequence == nextSequence else { throw ProtocolError.malformed("Received chunk \(sequence); expected \(nextSequence)") }
        var out = Data(v.dropFirst(GattChunk.headerBytes)); advance()
        while let next = pending.removeValue(forKey: nextSequence) { parkedBytes -= next.count; out.append(next.dropFirst(GattChunk.headerBytes)); advance() }
        // The gap filled: a second gap left behind it starts its own clock.
        gapOpenedAt = pending.isEmpty ? nil : now
        if recovery?.readerActive == true { try check(now: now) }
        return out
    }

    private mutating func advance() {
        if recent.count >= GattChunkReader.recentHistory { recentSet.remove(recent.removeFirst()) }
        recent.append(nextSequence); recentSet.insert(nextSequence); nextSequence &+= 1
    }
}
