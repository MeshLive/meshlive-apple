import Foundation

/// EXPERIMENTAL (off): an incoming call that rings while MeshLive is in the background shows the iPhone's native call
/// screen (CallKit) instead of the local alert. Pure rules, unit-tested; App/Calls/CallKitProvider.swift reports them.
/// No PushKit: like the alert, a call can only ring while the app runs (MeshLive has no server).
public enum CallKitPolicy {
    /// Report a ringing call only while the app is not frontmost (in front, the call screen and ringer show it).
    public static func shouldReport(enabled: Bool, ringing: Bool, appActive: Bool) -> Bool {
        enabled && ringing && !appActive
    }

    public struct Update: Equatable {
        public let callerName: String?
        public let hasVideo: Bool
    }

    /// Same name rules as the alert (CallAlertPolicy): cleaned, bounded, and none for a stranger.
    public static func update(voice: Bool, peerName: String?, stranger: Bool) -> Update {
        Update(callerName: stranger ? nil : CallAlertPolicy.sanitizedName(peerName), hasVideo: !voice)
    }

    /// CXCallEndedReason, without importing CallKit here.
    public enum EndReason: Equatable { case failed, remoteEnded, unanswered, answeredElsewhere, declinedElsewhere }

    public enum Outcome: Equatable {
        case keep
        /// Tell CallKit the call ended for this reason (it did not end through CallKit's own buttons).
        case report(EndReason)
        /// The user hung up on the MeshLive screen: request CallKit's end action, as for its own End button.
        case requestEnd
    }

    /// What CallKit hears about a call it shows. `endedInApp`: declined or hung up on the MeshLive screen;
    /// `failed`: the call ended with an error before it was ever active.
    public static func outcome(ringing: Bool, ended: Bool, answeredByCallKit: Bool, endedInApp: Bool, failed: Bool) -> Outcome {
        guard ended else { return ringing || answeredByCallKit ? .keep : .report(.answeredElsewhere) }
        guard answeredByCallKit else { return .report(endedInApp ? .declinedElsewhere : .unanswered) }
        if endedInApp { return .requestEnd }
        return .report(failed ? .failed : .remoteEnded)
    }
}
