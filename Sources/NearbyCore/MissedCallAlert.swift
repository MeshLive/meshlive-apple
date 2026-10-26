import Foundation

/// Missed-call notifications (Android MissedCallNotification, 2026-10-21): an incoming call that stopped ringing
/// without being answered here (the ring timed out, the caller cancelled or the link dropped) leaves one notification
/// per caller, counting the calls missed while it is still showing, with a Call back action. A call declined here is
/// not "missed". Nothing is sent anywhere; it needs the same notification permission as call alerts.
public enum MissedCallAlert {
    public static let categoryIdentifier = "MISSED_CALL"
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
