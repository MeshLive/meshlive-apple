import Foundation

/// Video frame size (width x height, in encoder orientation).
public struct VideoResolution: Equatable, Hashable, CustomStringConvertible {
    public let width: Int, height: Int
    public init(_ width: Int, _ height: Int) { self.width = width; self.height = height }
    public var pixels: Int { width * height }
    public var description: String { "\(width)x\(height)" }
}

/// Call resolution ladder, a port of Android's CallResolutionLadder (design decision 2026-10-10, default on for
/// user calls). Rate control alone lowers only the bitrate; WebRTC instead picks the send size from the target
/// rate. Its default singlecast limits (encoder_info_settings.cc GetDefaultSinglecastBitrateLimits, webrtc
/// a05204958f9d, BSD-3) give each frame size a minimum start bitrate; a size uses the smallest table entry at
/// least as large.
/// - Rungs: same aspect ratio (2 %), no larger than the call's start geometry (the header, which stays the
///   maximum and is never re-sent), at least 320x180 pixels, one per limit bucket (the largest).
/// - Down after the target stayed below the current rung's limit for 3 s (and 5 s since the last change), to
///   the largest rung the target meets. Up one rung after the target held 1.25 x the larger rung's limit for
///   10 s and 15 s passed since the last change. The encoder restarts at the new size with a keyframe.
public final class CallResolutionLadder {
    public static let downHold: Int64 = 3_000, downMinInterval: Int64 = 5_000
    public static let upHold: Int64 = 10_000, upMinInterval: Int64 = 15_000
    public static let upHeadroom = 1.25, aspectTolerance = 0.02
    public static let floorPixels = 320 * 180

    static let vp9Limits: [(pixels: Int, bps: Int)] = [(320 * 180, 0), (480 * 270, 120_000), (640 * 360, 190_000),
                                                        (960 * 540, 350_000), (1280 * 720, 480_000), (1920 * 1080, 1_000_000)]
    static let av1Limits: [(pixels: Int, bps: Int)] = [(320 * 180, 0), (480 * 270, 176_000), (640 * 360, 256_000),
                                                        (960 * 540, 384_000), (1280 * 720, 576_000), (1920 * 1080, 1_000_000)]

    public struct Decision: Equatable { public let resolution: VideoResolution; public let reason: String }

    public let requested: VideoResolution
    public let codecId: UInt8
    /// Largest to smallest; the first is always `requested`.
    public let rungs: [VideoResolution]
    public private(set) var current: VideoResolution
    private var lowSince: Int64 = -1, highSince: Int64 = -1, lastChange: Int64 = Int64.min / 2
    public var active: Bool { rungs.count > 1 }

    public init(requested: VideoResolution, offered: [VideoResolution], codecId: UInt8) {
        self.requested = requested; self.codecId = codecId
        rungs = CallResolutionLadder.buildRungs(requested: requested, offered: offered, codecId: codecId)
        current = requested
    }

    private static func limits(_ codecId: UInt8) -> [(pixels: Int, bps: Int)] { codecId == StreamProtocol.codecAV1 ? av1Limits : vp9Limits }
    private static func bucket(_ codecId: UInt8, _ pixels: Int) -> Int {
        let table = limits(codecId)
        return table.firstIndex { $0.pixels >= pixels } ?? table.count - 1
    }
    public static func minStartBps(codecId: UInt8, _ r: VideoResolution) -> Int { limits(codecId)[bucket(codecId, r.pixels)].bps }

    static func buildRungs(requested: VideoResolution, offered: [VideoResolution], codecId: UInt8) -> [VideoResolution] {
        let aspect = Double(requested.width) / Double(requested.height)
        let requestedBucket = bucket(codecId, requested.pixels)
        var seen = Set<Int>()
        let smaller = offered
            .filter { abs(Double($0.width) / Double($0.height) - aspect) / aspect <= aspectTolerance }
            .filter { $0.pixels < requested.pixels && $0.pixels >= floorPixels }
            .filter { bucket(codecId, $0.pixels) < requestedBucket }
            .sorted { $0.pixels > $1.pixels }
            .filter { seen.insert(bucket(codecId, $0.pixels)).inserted }
        return [requested] + smaller
    }

    /// The start rung for the start rate.
    public func start(targetBps: Int, nowMs: Int64) -> Decision {
        let chosen = largestRung(for: targetBps)
        current = chosen; lastChange = nowMs; lowSince = -1; highSince = -1
        return Decision(resolution: chosen, reason: reason(chosen == requested ? "start" : "start_low_rate", targetBps, chosen))
    }

    /// One rate-control sample: the encoder's current video target. Returns a change or nil.
    public func onTarget(targetBps: Int, nowMs: Int64) -> Decision? {
        guard active, let index = rungs.firstIndex(of: current) else { return nil }
        let currentLimit = Self.minStartBps(codecId: codecId, current)
        if targetBps < currentLimit && index < rungs.count - 1 {
            highSince = -1
            if lowSince < 0 { lowSince = nowMs }
            if nowMs - lowSince >= Self.downHold && nowMs - lastChange >= Self.downMinInterval {
                return change(to: largestRung(for: targetBps), "weak_link", targetBps, nowMs)
            }
            return nil
        }
        lowSince = -1
        guard index > 0 else { highSince = -1; return nil }
        let larger = rungs[index - 1]
        if Double(targetBps) >= Double(Self.minStartBps(codecId: codecId, larger)) * Self.upHeadroom {
            if highSince < 0 { highSince = nowMs }
            if nowMs - highSince >= Self.upHold && nowMs - lastChange >= Self.upMinInterval {
                return change(to: larger, "link_recovered", targetBps, nowMs)
            }
        } else {
            highSince = -1
        }
        return nil
    }

    private func change(to: VideoResolution, _ why: String, _ targetBps: Int, _ nowMs: Int64) -> Decision? {
        guard to != current else { return nil }
        current = to; lastChange = nowMs; lowSince = -1; highSince = -1
        return Decision(resolution: to, reason: reason(why, targetBps, to))
    }

    private func reason(_ why: String, _ targetBps: Int, _ to: VideoResolution) -> String {
        "\(why)(targetKbps=\(targetBps / 1_000),limitKbps=\(Self.minStartBps(codecId: codecId, to) / 1_000))"
    }

    private func largestRung(for targetBps: Int) -> VideoResolution {
        rungs.first { Self.minStartBps(codecId: codecId, $0) <= targetBps } ?? rungs[rungs.count - 1]
    }
}
