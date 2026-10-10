import Foundation
#if canImport(NearbyCore)
import NearbyCore
#endif

public struct VideoConfiguration: Equatable {
    public let sps: Data
    public let pps: Data
    public init(sps: Data, pps: Data) throws {
        guard (1...1024).contains(sps.count), (1...1024).contains(pps.count), sps[0] & 31 == 7, pps[0] & 31 == 8 else { throw ProtocolError.malformed("Invalid H.264 parameter sets") }
        self.sps = sps; self.pps = pps
    }
    public var encoded: Data {
        var w = BinaryWriter(); w.byte(1); w.u16(160); w.u16(120); w.byte(5); w.u32(32_000); w.byte(0)
        w.u16(UInt16(sps.count)); w.bytes(sps); w.u16(UInt16(pps.count)); w.bytes(pps); return w.data
    }
    public init(decoding: Data) throws {
        var r = BinaryReader(decoding)
        guard try r.byte() == 1, try r.u16() == 160, try r.u16() == 120, try r.byte() == 5,
              try r.u32() == 32_000, try r.byte() == 0 else { throw ProtocolError.incompatible("Unsupported H.264 configuration") }
        let s = try r.bytes(Int(r.u16())); let p = try r.bytes(Int(r.u16())); try r.end(); try self.init(sps: s, pps: p)
    }
}
public struct VideoFrame {
    public let timestamp: UInt64 // microseconds from local video experiment start
    public let keyframe: Bool
    public let discontinuity: Bool
    public let avcc: Data
    public init(timestamp: UInt64, keyframe: Bool, discontinuity: Bool, avcc: Data) throws {
        guard timestamp <= UInt64(Int64.max), avcc.count > 0, avcc.count <= 24_000, !discontinuity || keyframe else { throw ProtocolError.malformed("Invalid video timestamp, frame size or discontinuity") }
        var r = BinaryReader(avcc); var count = 0; var idr = false
        while r.remaining > 0 {
            let size = Int(try r.u32()); guard size > 0 else { throw ProtocolError.malformed("Empty H.264 NAL") }
            let nal = try r.bytes(size); let type = nal[0] & 31
            guard nal[0] & 128 == 0, [1,5,6,7,8,9,12].contains(type) else { throw ProtocolError.malformed("Unsupported H.264 NAL") }
            count += 1; guard count <= 32 else { throw ProtocolError.limit("Too many NAL units") }; idr = idr || type == 5
        }
        guard keyframe == idr else { throw ProtocolError.malformed("Keyframe flag disagrees with IDR NAL") }
        self.timestamp = timestamp; self.keyframe = keyframe; self.discontinuity = discontinuity; self.avcc = avcc
    }
    public var encoded: Data { var w = BinaryWriter(); w.u64(timestamp); w.byte((keyframe ? 1 : 0) | (discontinuity ? 2 : 0)); w.bytes(avcc); return w.data }
    public init(decoding: Data) throws {
        var r = BinaryReader(decoding); let timestamp = try r.u64(); let flags = try r.byte()
        guard flags & ~3 == 0 else { throw ProtocolError.malformed("Unknown video flags") }
        try self.init(timestamp: timestamp, keyframe: flags & 1 != 0, discontinuity: flags & 2 != 0, avcc: r.bytes(r.remaining))
    }
}
public struct VideoDependencyGate {
    private var lastTimestamp: UInt64?
    private var requiresIDR = true
    public init() {}
    public mutating func configurationChanged() { requiresIDR = true; lastTimestamp = nil }
    public mutating func accept(_ frame: VideoFrame) throws -> Bool {
        if let lastTimestamp, frame.timestamp <= lastTimestamp, !frame.discontinuity { throw ProtocolError.replay }
        if frame.discontinuity { requiresIDR = true }
        if requiresIDR && !frame.keyframe { return false }
        requiresIDR = false; lastTimestamp = frame.timestamp; return true
    }
    public mutating func decoderFailed() { requiresIDR = true }
}
