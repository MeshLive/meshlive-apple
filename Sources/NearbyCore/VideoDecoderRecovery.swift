import Foundation

/// B1.5 (Android DecoderStallDetector / DecoderStallEscalation / CallVideoStallRestart): pure rules for a failing remote
/// decoder. B1F step 4: ordinary loss never climbs the ladder. A key frame that fails is a failure; errors before a good
/// key frame (the decoders' "Waiting for a key frame") are not; three errors after a good key frame, or an invalid
/// session, are. The first failure rebuilds, the second tries the other decoder (or stops video), the third stops video.
public struct VideoDecoderHealth {
    public enum Event {
        case error(keyFramePacket: Bool, invalidSession: Bool)
        /// A key-frame packet decoded without throwing (its picture may follow separately).
        case keyFrame
        case picture
        case rebuilt
    }

    private var errors = 0
    private var sawKeyFrame = false

    public init() {}

    /// True when this event is a failure. Errors before any key frame are the decoders' normal "waiting for a key frame".
    public mutating func apply(_ event: Event) -> Bool {
        switch event {
        case .rebuilt:
            errors = 0
            sawKeyFrame = false
            return false
        case .keyFrame, .picture:
            errors = 0
            sawKeyFrame = true
            return false
        case .error(let keyFramePacket, let invalidSession):
            if invalidSession { errors = 0; return true }
            // A key frame that cannot decode is the failure, not a boundary: the next deltas are still loss.
            if keyFramePacket { errors = 0; return true }
            guard sawKeyFrame else { return false }
            errors += 1
            guard errors >= 3 else { return false }
            errors = 0
            return true
        }
    }
}

/// A decoder that took input but produced no output for at least max(8, 2 * fps) inputs and 1.5 s.
public struct VideoDecoderStallDetector {
    public struct Stall: Equatable {
        public let inputs: Int
        public let withoutOutputMs: Int
    }

    private var inputsSinceOutput = 0
    private var firstInputAt: TimeInterval?
    private var lastOutputAt: TimeInterval?

    public init() {}

    public mutating func onInput(at uptime: TimeInterval) {
        if inputsSinceOutput == 0 { firstInputAt = uptime }
        inputsSinceOutput += 1
    }

    public mutating func onOutput(at uptime: TimeInterval) {
        inputsSinceOutput = 0
        firstInputAt = nil
        lastOutputAt = uptime
    }

    /// After a rebuild: the clock starts at the first input of the new decoder.
    public mutating func onReset(at uptime: TimeInterval) {
        inputsSinceOutput = 0
        firstInputAt = nil
        lastOutputAt = uptime
    }

    public func check(at uptime: TimeInterval, fps: Int, suspended: Bool) -> Stall? {
        guard !suspended, inputsSinceOutput >= max(8, 2 * max(1, fps)) else { return nil }
        let start = firstInputAt ?? lastOutputAt ?? uptime
        let age = uptime - start
        guard age >= 1.5 else { return nil }
        return Stall(inputs: inputsSinceOutput, withoutOutputMs: Int(age * 1000))
    }
}

public struct VideoDecoderRecovery {
    public enum Action: Equatable { case rebuildSame, tryOther, stopVideo }

    public let healthyPictures: Int
    public let maxFailures: Int
    public private(set) var failureCount = 0
    public private(set) var picturesSinceRecovery = 0
    public private(set) var videoStopped = false

    /// B1F step 5: "Video stopped on this phone" is final; a later stream header must not rebuild a decoder.
    public var acceptsNewStream: Bool { !videoStopped }

    public init(healthyPictures: Int = 60, maxFailures: Int = 3) {
        self.healthyPictures = healthyPictures
        self.maxFailures = maxFailures
    }

    /// B1F step 3: an invalid session while backgrounded asks for one silent rebuild at foreground, never a failure.
    public private(set) var silentRebuildPending = false
    private var backgroundRebuildActive = false

    public mutating func onBackgroundInvalidSession() -> Bool {
        guard !videoStopped, !silentRebuildPending, !backgroundRebuildActive else { return false }
        silentRebuildPending = true
        return true
    }

    public mutating func takeSilentRebuild() -> Bool {
        guard silentRebuildPending, !videoStopped else { return false }
        silentRebuildPending = false
        backgroundRebuildActive = true
        return true
    }

    /// The first picture of the silently rebuilt decoder: the next background period may ask for a rebuild again.
    public mutating func onForegroundKeyFrame() {
        backgroundRebuildActive = false
    }

    public mutating func onFailure(otherDecoderExists: Bool) -> Action {
        guard !videoStopped else { return .stopVideo }
        failureCount += 1
        picturesSinceRecovery = 0
        if failureCount >= maxFailures {
            videoStopped = true
            return .stopVideo
        }
        if failureCount == 1 { return .rebuildSame }
        guard otherDecoderExists else {
            videoStopped = true
            return .stopVideo
        }
        return .tryOther
    }

    /// Sixty pictures after a recovery forget the earlier failures.
    public mutating func onPicture() {
        guard !videoStopped else { return }
        picturesSinceRecovery += 1
        guard picturesSinceRecovery >= healthyPictures else { return }
        failureCount = 0
        picturesSinceRecovery = 0
    }
}

public enum VideoRecoveryNotice {
    public static let recovering = "Recovering remote video; audio and call remain connected"
    public static let stopped = "Video stopped on this phone; voice continues"
}
