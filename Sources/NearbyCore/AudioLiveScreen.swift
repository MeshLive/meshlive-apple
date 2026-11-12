import Foundation

/// Android `AudioLiveReminderPolicy` (AudioLiveBackground.kt): a forgotten open microphone stops. A reminder is due
/// after 30 minutes in a row without a listener, or after 2 hours on the air since the start or the last answer; a
/// reminder nobody answers within 5 minutes stops the broadcast. The user coming back answers it.
public struct AudioLiveReminderPolicy {
    public enum Decision: Equatable { case none, remind, stop }

    /// The reminder notification's category and its one action (Android `audio_live_notification_stop`).
    public static let categoryIdentifier = "AUDIO_LIVE_REMINDER"
    public static let stopAction = "STOP"
    /// What a locked device shows instead of the reminder text (Android public version "Broadcasting audio").
    public static let lockedPlaceholder = "Broadcasting audio"

    public let noListenerSeconds: TimeInterval
    public let totalSeconds: TimeInterval
    public let unansweredStopSeconds: TimeInterval
    private var lastAnswered: TimeInterval
    private var emptySince: TimeInterval?
    private var remindedAt: TimeInterval?

    /// `unitSeconds` replaces the 5-minute unit (DEBUG `-NearbyRadioReminderUnit`): 30 min = 6 units, 2 h = 24 units,
    /// 5 min = 1 unit. nil or not positive: Android's times.
    public init(start: TimeInterval, unitSeconds: TimeInterval? = nil) {
        let unit = unitSeconds.flatMap { $0 > 0 ? $0 : nil } ?? 300
        noListenerSeconds = 6 * unit
        totalSeconds = 24 * unit
        unansweredStopSeconds = unit
        lastAnswered = start
        emptySince = start
    }

    /// A reminder is waiting for an answer.
    public var reminderOutstanding: Bool { remindedAt != nil }

    /// The listener count now (Android `onListeners`): a listener clears the empty time; the first moment with none
    /// starts it.
    public mutating func onListeners(_ count: Int, now: TimeInterval) {
        if count > 0 { emptySince = nil } else if emptySince == nil { emptySince = now }
    }

    /// Android `decide`: `.remind` once when due (recorded), `.stop` once the outstanding reminder is 5 minutes old.
    public mutating func decide(now: TimeInterval) -> Decision {
        if let remindedAt { return now - remindedAt >= unansweredStopSeconds ? .stop : .none }
        let empty = emptySince.map { now - $0 >= noListenerSeconds } ?? false
        guard now - lastAnswered >= totalSeconds || empty else { return .none }
        remindedAt = now
        return .remind
    }

    /// Android `onUserPresent`: the user is here; the 2 hours count again from now, and so does an empty time.
    public mutating func onUserPresent(now: TimeInterval) {
        lastAnswered = now
        remindedAt = nil
        if emptySince != nil { emptySince = now }
    }
}

/// Android `AudioLiveLevel.rms` (AudioLiveSourceCore.kt): the RMS of one 20 ms frame against about -24 dBFS as full
/// scale (4000 of 32768 for 16-bit samples), clamped to 0...1. The samples here are floats in -1...1.
public enum AudioLiveLevel {
    static let fullScale = 4000.0 / 32768.0

    public static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples where sample.isFinite { sum += Double(sample) * Double(sample) }
        let value = (sum / Double(samples.count)).squareRoot() / fullScale
        return min(1, max(0, value))
    }
}
