import Foundation

/// A call that arrives while the user is dialling (Android DialCollision). No wire change: Decline with BUSY (2).
/// - A call from anyone else while the user's own dial is still looking for its person is declined as busy at once
///   (no ring), and the dial goes on.
/// - A call from the very person being dialled is that conversation: it rings and the user's own dial stops. This is
///   the deterministic answer to two devices dialling each other: whichever Invite arrives first while the other is
///   still looking becomes the call.
/// The caller is matched by its real node prefix (a stranger's throwaway never matches a dial target).
public enum DialCollision {
    public enum Action: Equatable { case ring, declineBusy }

    /// - Parameters:
    ///   - dialling: a dial of this device is still looking for its person (not yet connected).
    ///   - target: that person's real 12-hex prefix when known (a contact, a fixed prefix, a recognised rotating ID).
    ///   - callerPrefix: the incoming caller's authenticated real prefix; nil for a throwaway.
    public static func decide(dialling: Bool, target: String?, callerPrefix: String?) -> Action {
        guard dialling, let target, let callerPrefix else { return .declineBusy }
        return target.lowercased() == callerPrefix.lowercased() ? .ring : .declineBusy
    }
}
