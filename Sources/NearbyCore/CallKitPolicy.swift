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

    /// CallKit refused to show a call. Do Not Disturb, a Focus or the block list filtered it: it stays silent, as a
    /// phone call would. Any other error: it rings with the local alert and the app's ringer instead.
    public enum Refusal: Equatable { case silent, ringLocally }
    public static func refusal(filteredByFocusOrBlockList: Bool) -> Refusal { filteredByFocusOrBlockList ? .silent : .ringLocally }

    /// CallKit reset its provider: the call it showed cannot go on without it, so MeshLive ends it too.
    public enum ResetAction: Equatable { case decline, end }
    public static func resetAction(ringing: Bool) -> ResetAction { ringing ? .decline : .end }

    /// Keeps the native screen's mute button and the microphone in step, both ways, without echoing a change back.
    /// `callKitMuted` is what the native screen shows; hold-to-talk opens the microphone, so it shows unmuted meanwhile.
    public struct MuteSync: Equatable {
        public private(set) var callKitMuted = false
        public init() {}
        /// The microphone changed in the app (Mute, hold-to-talk, an audio interruption). True: ask CallKit to show it.
        public mutating func appChanged(micMuted: Bool) -> Bool {
            guard micMuted != callKitMuted else { return false }
            callKitMuted = micMuted
            return true
        }
        /// CallKit performed a mute action. True: apply it to the call. False: it only confirms what the app asked for.
        public mutating func callKitAction(muted: Bool) -> Bool {
            guard muted != callKitMuted else { return false }
            callKitMuted = muted
            return true
        }
    }
}
