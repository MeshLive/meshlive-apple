import Foundation

// Relay-child media age (Android BoundedMediaAge.kt / MeshCore.kt RelayChildQueue; SWITCHES "Relay-child media age",
// ON by default since the 2026-10-09 design decision): a forwarding viewer's queue for its one child sheds stale
// video codec-safely (skip to a keyframe) instead of letting the child fall behind until it is withdrawn. Audio,
// configuration, rotation, lifecycle, headers and terminal records are never dropped; the child accepts the
// increasing mesh/BME1 sequence gap. Recovery keyframe requests back off from 1.5 s to one per 15 s while sheds
// recur, reset after a calm minute. Calls and direct senders stay no-loss.

public enum BoundedMediaAge {
    public static let streamAgeBudgetMs: Int64 = 2_000
    /// Never below the backlog the rate controller already treats as congestion (Android CONGESTED_BACKLOG_MS).
    public static let minStreamQueueMs: Int64 = 400
    /// Assumed starting playout delay of a stream viewer (Android's Auto profile, 250 ms).
    public static let assumedViewerBaseDelayMs: Int64 = 250
    public static let streamShedCooldown: TimeInterval = 4
    public static let keyFrameRerequest: TimeInterval = 1.5
    public static let relayRecoveryMaxInterval: TimeInterval = 15
    public static let relayRecoveryCalm: TimeInterval = 60
    /// A keyframe that just left needed its airtime; the frames behind it aged by design.
    public static let relayKeyFrameGrace: TimeInterval = 3

    /// How long a child queue may hold media: the stream budget minus what the child's playout already holds.
    public static func streamQueueBudgetMs(viewerAddedDelayMs: Int, viewerBaseDelayMs: Int64 = assumedViewerBaseDelayMs) -> Int64 {
        max(minStreamQueueMs, streamAgeBudgetMs - viewerBaseDelayMs - Int64(max(0, viewerAddedDelayMs)))
    }
}

public enum ShedClass: Equatable { case keep, video, keyFrame }

/// What a relay's child queue treats an envelope as (the BME1 type byte is plaintext associated data).
public func relayEnvelopeShedClass(_ envelope: MeshEnvelope) -> ShedClass {
    let keepFlags = MeshEnvelope.flagAudio | MeshEnvelope.flagControl | MeshEnvelope.flagCodecConfig | MeshEnvelope.flagTerminal | StreamProtocol.flagDisplayRotation
    if envelope.flags & keepFlags != 0 { return .keep }
    guard (try? EndToEndContentProtocol.inspect(envelope.payload, acceptVideoFragments: true, acceptLabels: true).type) == .mediaPacket else { return .keep }
    return envelope.flags & MeshEnvelope.flagKeyFrame != 0 ? .keyFrame : .video
}

public struct ShedPlan: Equatable {
    /// Indices (queue order) to remove.
    public let drop: [Int]
    /// No usable keyframe stays queued: later non-key video is dropped until one arrives (and one is requested).
    public let awaitKeyFrame: Bool
}

/// With a usable keyframe queued, all video before the newest usable one goes; without one, all queued video goes and
/// the caller waits for the next keyframe. Non-video is never touched.
public func planCodecSafeShed(_ classes: [ShedClass], usable: [Bool]) -> ShedPlan {
    if let newest = classes.indices.last(where: { classes[$0] == .keyFrame && usable[$0] }) {
        return ShedPlan(drop: classes.indices.filter { $0 < newest && classes[$0] != .keep }, awaitKeyFrame: false)
    }
    return ShedPlan(drop: classes.indices.filter { classes[$0] != .keep }, awaitKeyFrame: true)
}

/// Per-queue shedding state: when to shed and the wait for a decodable point afterwards.
public struct MediaAgeShedder {
    public let cooldown: TimeInterval
    private var lastShedAt: TimeInterval?
    public private(set) var awaitingKeyFrame = false
    public private(set) var shedEvents = 0, shedFrames = 0, keyFrameWaitFrames = 0
    public init(cooldown: TimeInterval) { self.cooldown = cooldown }

    /// An arriving video item while a shed waits for a keyframe: true means drop it; a keyframe ends the wait.
    public mutating func dropArrivingVideo(keyFrame: Bool) -> Bool {
        guard awaitingKeyFrame else { return false }
        if keyFrame { awaitingKeyFrame = false; return false }
        keyFrameWaitFrames += 1; shedFrames += 1
        return true
    }

    public func shouldShed(queueAgeMs: Int64, budgetMs: Int64, keyFrameGrace: Bool, now: TimeInterval) -> Bool {
        !awaitingKeyFrame && !keyFrameGrace && queueAgeMs > budgetMs && (lastShedAt.map { now - $0 >= cooldown } ?? true)
    }

    public mutating func recordShed(_ plan: ShedPlan, removed: Int, now: TimeInterval) {
        lastShedAt = now; shedEvents += 1; shedFrames += removed
        if plan.awaitKeyFrame { awaitingKeyFrame = true }
    }
}

/// Per-child pacing of recovery keyframe requests: the first after a calm period at once, then doubling from 1.5 s to
/// 15 s while sheds recur; reset after 60 s without a request.
public struct RelayRecoveryBackoff {
    private var lastRequestAt: TimeInterval?
    public private(set) var interval = BoundedMediaAge.keyFrameRerequest
    public private(set) var requests = 0, suppressed = 0
    public init() {}

    public mutating func tryRequest(now: TimeInterval) -> Bool {
        if let last = lastRequestAt {
            let since = now - last
            if since >= BoundedMediaAge.relayRecoveryCalm { interval = BoundedMediaAge.keyFrameRerequest }
            else if since < interval { suppressed += 1; return false }
            else { interval = min(interval * 2, BoundedMediaAge.relayRecoveryMaxInterval) }
        }
        lastRequestAt = now; requests += 1
        return true
    }
}
