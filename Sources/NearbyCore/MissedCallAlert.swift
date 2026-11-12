import Foundation

/// Missed-call notifications (Android MissedCallNotification, 2026-10-21): an incoming call that stopped ringing
/// without being answered here (the ring timed out, the caller cancelled or the link dropped) leaves one notification
/// per caller, counting the calls missed while it is still showing, with a Call back action. A call declined here is
/// not "missed". Nothing is sent anywhere; it needs the same notification permission as call alerts.
public enum MissedCallAlert {
    public static let categoryIdentifier = "MISSED_CALL"
    /// A missed call from someone who is not a verified contact: no Call back action (nothing to call by).
    public static let plainCategoryIdentifier = "MISSED_CALL_PLAIN"
    public static func isMissedCategory(_ identifier: String) -> Bool { identifier == categoryIdentifier || identifier == plainCategoryIdentifier }
    public static let callBackAction = "CALL_BACK"
    /// What a locked device shows instead of the text (Android `NotificationPrivacy.publicText(MISSED_CALL)`).
    public static let lockedPlaceholder = "Missed call"
    public static let prefixKey = "prefix", videoKey = "video", countKey = "count"

    /// Post only for an incoming call that rang here, never became active and was not declined here.
    public static func isMissed(incoming: Bool, rang: Bool, wasActive: Bool, declinedHere: Bool) -> Bool {
        incoming && rang && !wasActive && !declinedHere
    }

    /// One notification per caller, so a second caller does not replace the first.
    public static func identifier(prefixHex: String?) -> String { "missed:" + (prefixHex?.lowercased() ?? "unknown") }

    /// One more while that caller's notification is still showing, else 1.
    public static func nextCount(stillShowing: Bool, previous: Int) -> Int { stillShowing ? max(previous, 0) + 1 : 1 }

    /// "Missed call", "Missed call from Asha", "3 missed calls" or "3 missed calls from Asha". A stranger behind a
    /// throwaway key has no name to show; names are cleaned and shortened as for call alerts.
    public static func title(peerName: String?, stranger: Bool, count: Int) -> String {
        let count = max(count, 1)
        let name = stranger ? nil : CallAlertPolicy.sanitizedName(peerName)
        switch (name, count) {
        case (nil, 1): return "Missed call"
        case (nil, _): return "\(count) missed calls"
        case (let name?, 1): return "Missed call from \(name)"
        case (let name?, _): return "\(count) missed calls from \(name)"
        }
    }
}

// MARK: - Calls and Recent (Android RecentCalls, StrangerCallFollowup, CallRinger, CallProximityCameraPause)

/// How a recent call ended (Android `CallResult`), kept with the record so Recent can say "↗ Answered / Video, 5 min ago".
public enum RecentCallOutcome: String, Codable, CaseIterable {
    case answered, missed, declined, noAnswer, failed

    /// Android `recentCallResult`: answered first; an incoming call that rang unanswered here is missed; a decline here,
    /// the other side's decline or a busy decline is declined; a cancel or the ring timeout is no answer; else failed.
    public static func of(answered: Bool, missed: Bool, declinedHere: Bool, cancelledHere: Bool, reason: String?) -> RecentCallOutcome {
        if answered { return .answered }
        if missed { return .missed }
        let r = (reason ?? "").lowercased()
        if declinedHere || r.contains("declined") { return .declined }
        if cancelledHere || r.contains("cancelled") || r.contains("canceled") || r.contains("no answer")
            || (r.contains("ring") && r.contains("timeout")) {
            return .noAnswer
        }
        return .failed
    }

    /// A record saved before outcomes were kept (Android reads its legacy entries as answered).
    public static func legacy(missed: Bool) -> RecentCallOutcome { missed ? .missed : .answered }

    /// Android `recent_answered`, `recent_missed`, `recent_declined`, `recent_no_answer`, `recent_failed`.
    public var label: String {
        switch self {
        case .answered: return "Answered"
        case .missed: return "Missed"
        case .declined: return "Declined"
        case .noAnswer: return "No answer"
        case .failed: return "Failed"
        }
    }

    /// Android `recent_outcome` "<arrow> <outcome> / <text>" (↗ outgoing, ↙ incoming); with complete Recent off (the
    /// control arm) the text alone.
    public static func line(outgoing: Bool, outcome: RecentCallOutcome, detail: String, complete: Bool) -> String {
        guard complete else { return detail }
        return "\(outgoing ? "\u{2197}" : "\u{2199}") \(outcome.label) / \(detail)"
    }
}

/// Android `StrangerCallFollowup.offer`: after a call with someone who is not saved (and not blocked), the name to offer
/// "Add <name> as a contact?" with: their generated name, else the handle of an unsaved fixed ID; nil for nobody.
public enum StrangerCallFollowUp {
    public static func name(enabled: Bool, blocked: Bool, isContact: Bool, generatedName: String?, handle: String?) -> String? {
        guard enabled, !blocked, !isContact else { return nil }
        if let generated = generatedName?.trimmingCharacters(in: .whitespaces), !generated.isEmpty {
            return GeneratedNameText.display(generated)
        }
        if let handle, !handle.isEmpty { return handle }
        return nil
    }
}

/// Android `ProximityCameraPausePolicy.shouldPause`: the outgoing camera pauses only while the user's camera is on, the
/// sound is on the earpiece and the proximity sensor reads near.
public enum EarCameraPause {
    public static func shouldPause(enabled: Bool, userCameraOn: Bool, earpiece: Bool, near: Bool) -> Bool {
        enabled && userCameraOn && earpiece && near
    }
}

/// iOS stops the camera while the app is in the background: a video call sends Camera off when the app leaves and turns
/// the camera on again once the app is active, when the user's camera was on. A second background before the app became
/// active (unlock, then straight to the home screen) keeps what the first one saved.
public struct BackgroundCameraRestore: Equatable {
    public private(set) var backgrounded = false
    public private(set) var cameraWasOn = false
    public init() {}

    public mutating func enterBackground(cameraOn: Bool) {
        if !backgrounded { cameraWasOn = cameraOn }
        backgrounded = true
    }

    /// True when the camera must be turned on again now.
    public mutating func enterForeground(cameraOn: Bool, callEnded: Bool) -> Bool {
        let restore = backgrounded && cameraWasOn && !cameraOn && !callEnded
        backgrounded = false
        cameraWasOn = false
        return restore
    }
}

/// Android `updatePrivateCallRingback`: the caller hears ringing only while the other phone rings.
public enum CallTones {
    public static func ringbackPlays(enabled: Bool, phase: PrivateCallPhase) -> Bool { enabled && phase == .outgoingRinging }
}
