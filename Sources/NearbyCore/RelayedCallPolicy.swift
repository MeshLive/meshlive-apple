import Foundation

// EXPERIMENTAL relayed calls under the BMH3 pseudonym defaults (Android RelayIdentityPolicy). Pure rules: what a target does with a relayed call before it rings, and the ring status of a relayed
// stranger call.

public enum RelayedCallPolicy {
    public enum Incoming: String {
        case ring
        case declineRelayingOff = "decline_relaying_off"
        case declineStranger = "decline_stranger"
    }

    /// What a target does with an incoming call before it rings. A relayed call (the authenticated link peer is not the
    /// call peer, or the Invite says so) rings only while this phone's relayed calls are on: a dishonest relay can ignore
    /// the consent bit in an advert, so the target enforces it. A relayed call from a stranger (the end-to-end caller is a
    /// throwaway) rings only with relayed stranger calls on; a relay can sit in the middle of such a call.
    public static func incoming(viaRelay: Bool, relayedCallsOn: Bool, callerPseudonymous: Bool, strangerCallsOn: Bool) -> Incoming {
        if !viaRelay { return .ring }
        if !relayedCallsOn { return .declineRelayingOff }
        if callerPseudonymous && !strangerCallsOn { return .declineStranger }
        return .ring
    }

    /// The status line of a ring from an unverified stranger; `viaRelay` names the possible relay in the middle.
    public static func strangerRingStatus(viaRelay: Bool) -> String {
        viaRelay
            ? "Incoming call from an unverified stranger via a phone nearby: if you answer, your identity is revealed to whoever holds the call, which may be a relaying phone"
            : "Incoming call from an unverified stranger: your identity is revealed only if you answer"
    }

    /// The short ring status of any relayed call.
    public static let viaRelayStatus = "via a phone nearby"
}
