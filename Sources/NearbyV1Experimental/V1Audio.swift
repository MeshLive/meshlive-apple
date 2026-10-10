import Foundation
#if canImport(NearbyCore)
import NearbyCore
#endif

// Experimental standalone v1 audio packet and jitter buffer (not the Android BTV3 format).

public struct AudioPacket: Equatable {
    public let stream: UInt32
    public let timestamp: UInt64 // negotiated sample clock, not wall time
    public let final: Bool
    public let discontinuity: Bool
    public let validSamples: UInt16
    public let payload: Data
    public init(stream: UInt32, timestamp: UInt64, final: Bool, discontinuity: Bool, validSamples: UInt16, payload: Data) {
        self.stream = stream; self.timestamp = timestamp; self.final = final
        self.discontinuity = discontinuity; self.validSamples = validSamples; self.payload = payload
    }
    public var encoded: Data {
        var w = BinaryWriter(); w.u32(stream); w.u64(timestamp); w.byte((final ? 1 : 0) | (discontinuity ? 2 : 0))
        w.u16(validSamples); w.bytes(payload); return w.data
    }
    public init(decoding: Data, profile: MediaProfile) throws {
        var r = BinaryReader(decoding); stream = try r.u32(); timestamp = try r.u64(); let flags = try r.byte(); validSamples = try r.u16()
        let samples = Int(profile.sampleRate / 50)
        guard stream > 0, flags & ~3 == 0, validSamples <= samples, timestamp <= UInt64.max - UInt64(samples), timestamp % UInt64(samples) == 0 else {
            throw ProtocolError.malformed("Invalid audio timestamp or flags")
        }
        final = flags & 1 != 0; discontinuity = flags & 2 != 0; payload = try r.bytes(r.remaining)
        guard (validSamples == samples || final), (validSamples == 0) == payload.isEmpty else {
            throw ProtocolError.malformed("Only final audio can be partial; zero samples require an empty final marker")
        }
        if profile.codec == .pcmDiagnostic {
            guard payload.count == samples * 2 || (final && validSamples == 0 && payload.isEmpty) else {
                throw ProtocolError.malformed("Invalid PCM diagnostic packet")
            }
        } else {
            guard payload.count <= 1275, !payload.isEmpty || (final && validSamples == 0) else { throw ProtocolError.malformed("Invalid Opus packet") }
        }
        guard validSamples > 0 || final else { throw ProtocolError.malformed("Empty nonfinal audio packet") }
    }
}

/// Fixed 20 ms playout. Capacity bounds latency; discontinuity resets the sample clock.
public struct JitterBuffer {
    public private(set) var packets: [AudioPacket] = []
    public private(set) var underruns = 0
    public private(set) var overflows = 0
    public private(set) var late = 0
    public private(set) var running = false
    private var stream: UInt32?
    private var lastStream: UInt32 = 0
    private var lastTimestamp: UInt64?
    private var next: UInt64 = 0
    private let step: UInt64
    public let target = 3
    public let capacity = 10
    public var bufferedMilliseconds: Int { packets.count * 20 }
    public init(sampleRate: UInt32) { step = UInt64(sampleRate / 50) }
    public mutating func push(_ packet: AudioPacket) throws {
        if stream == nil || packet.stream != stream {
            guard packet.discontinuity, packet.timestamp == 0, packet.stream > lastStream else {
                throw ProtocolError.malformed("Audio stream lacks new discontinuity")
            }
            packets.removeAll(keepingCapacity: true); stream = packet.stream; lastStream = packet.stream; next = 0; lastTimestamp = nil; running = false
        } else if packet.discontinuity { throw ProtocolError.malformed("Unexpected audio discontinuity") }
        if let lastTimestamp, packet.timestamp <= lastTimestamp { throw ProtocolError.replay }
        lastTimestamp = packet.timestamp
        guard packet.timestamp >= next else {
            late += 1
            if packet.final { packets.removeAll(keepingCapacity: true); stream = nil; running = false }
            return
        }
        if let last = packets.last, packet.timestamp <= last.timestamp { throw ProtocolError.replay }
        if packets.count == capacity {
            // Drop oldest decoded-independent audio packet and jump the playout clock.
            packets.removeFirst(); overflows += 1; next = packets.first?.timestamp ?? packet.timestamp
        }
        packets.append(packet)
        if packets.count >= target || packet.final { running = true }
    }
    public mutating func pop() -> AudioPacket? {
        guard running else { return nil }
        if let first = packets.first, first.timestamp <= next {
            packets.removeFirst(); next = first.timestamp + step
            if first.final { stream = nil; running = false }
            return first
        }
        underruns += 1; next += step
        return nil
    }
    public mutating func interrupt() { packets.removeAll(keepingCapacity: true); stream = nil; running = false }
}
