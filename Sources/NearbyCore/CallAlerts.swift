import Foundation

/// Local incoming-call alerts (iPhone counterpart of Android's call notifications, NotificationPrivacy.kt). Pure rules,
/// unit-tested; the app layer (App/Notifications/CallNotifier.swift) posts them with UNUserNotificationCenter.
///
/// There is no internet push in MeshLive, so a call can only ring while the app runs: in the foreground, while it is
/// inactive (Control Center, Notification Center, a system alert over it), or briefly after the user leaves the app
/// during a ringing call. A call to a closed app is impossible on iOS (no PushKit/APNs server by design).
public enum CallAlertPolicy {
    public enum Authorization: Equatable { case notDetermined, denied, authorized }
    public static let categoryIdentifier = "INCOMING_CALL"
    public static let acceptAction = "ACCEPT"
    public static let declineAction = "DECLINE"
    /// What a locked phone shows instead of the alert (Android `PUBLIC_INCOMING_CALL_TEXT`).
    public static let lockedPlaceholder = "Incoming call"
    /// Android `HIDDEN_PEER_TEXT`: the alert's text when there is no name to show.
    public static let hiddenPeerText = "Open the app to see who is calling."
    /// Android `MAX_PEER_NAME_CHARS`: a hostile label cannot fill the notification.
    public static let maxPeerNameCharacters = 40

    public struct Content: Equatable {
        public let title: String
        public let body: String
    }

    /// Android `call_incoming_video` / `call_incoming_voice` as the title, the caller's name (or the hidden-peer text)
    /// as the body. A stranger behind a throwaway key has no name to show.
    public static func content(voice: Bool, peerName: String?, stranger: Bool) -> Content {
        let title = voice ? "Incoming voice call" : "Incoming video call"
        guard !stranger, let name = sanitizedName(peerName) else { return Content(title: title, body: hiddenPeerText) }
        return Content(title: title, body: name)
    }

    /// Left behind when a call rang out in the background unanswered; same name rules as the ringing alert.
    public static func missedContent(peerName: String?, stranger: Bool) -> Content {
        guard !stranger, let name = sanitizedName(peerName) else { return Content(title: "Missed call", body: hiddenPeerText) }
        return Content(title: "Missed call", body: name)
    }

    /// Trimmed, control and format characters removed, at most 40 characters.
    public static func sanitizedName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let scalars = raw.unicodeScalars.filter { s in
            switch s.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned: return false
            default: return true
            }
        }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return cleaned.count > maxPeerNameCharacters ? String(cleaned.prefix(maxPeerNameCharacters - 1)) + "…" : cleaned
    }

    /// Post only for a ringing incoming call while the app is not frontmost and alerts are allowed (in the foreground
    /// the call screen and the ringer already show it).
    public static func shouldPost(ringing: Bool, appActive: Bool, authorization: Authorization) -> Bool {
        ringing && !appActive && authorization == .authorized
    }

    /// When to ask: once, at a moment the user understands (they just turned "Reachable for calls" on, or a call they
    /// took part in just ended), never while a call rings (the system prompt would cover Accept).
    public enum Moment { case reachableTurnedOn, callEnded, settingsButton, launch }
    public static func shouldRequest(_ moment: Moment, authorization: Authorization, alreadyAsked: Bool) -> Bool {
        guard authorization == .notDetermined else { return false }
        switch moment {
        case .settingsButton: return true
        case .reachableTurnedOn, .callEnded: return !alreadyAsked
        case .launch: return false
        }
    }

    /// The Settings row text for each state.
    public static func statusText(_ authorization: Authorization) -> String {
        switch authorization {
        case .authorized: return "On. A call that rings while MeshLive is in the background shows an alert with Accept and Decline."
        case .denied: return "Off. Calls ring only on the MeshLive screen. Turn alerts on in iPhone Settings > Notifications > MeshLive."
        case .notDetermined: return "Shows an alert with Accept and Decline when a call rings while MeshLive is in the background."
        }
    }
}
