import Foundation

/// One logical live stream, whichever route (source or forwarder) offers it (Android `LogicalStreamTarget`).
public struct LogicalStreamTarget: Hashable {
    public let token: UInt32
    public let codecCapability: UInt8
    public init(token: UInt32, codecCapability: UInt8) { self.token = token; self.codecCapability = codecCapability }
    public init(_ offer: DiscoveryAnnouncement) {
        self.init(token: StreamRouteToken.logical(routeToken: offer.streamToken, prefix: offer.nodeIdPrefix), codecCapability: offer.capabilitySummary)
    }
    public func matches(_ offer: DiscoveryAnnouncement) -> Bool {
        offer.isStreamOffer && LogicalStreamTarget(offer) == self
    }
}

/// A live join that failed before it became active (Android `StreamJoinRetry`, 2026-10-21): the app says
/// "Couldn't join <title>." with Try again, and retries once by itself when the stream is listed again within
/// 30 s. A join that worked makes the automatic retry available again for a later failure.
public final class StreamJoinRetry<T: Hashable> {
    public struct Pending: Equatable {
        public let target: T
        public let notBefore: TimeInterval
        public let expires: TimeInterval
        public let auto: Bool
    }

    /// Longer than the 8 s failed-route cooldown plus a few offer intervals.
    public static var window: TimeInterval { 30 }

    public private(set) var pending: Pending?
    private var autoUsed = Set<T>()
    private let enabled: () -> Bool

    public init(enabled: @escaping () -> Bool = { true }) { self.enabled = enabled }

    /// A join to `target` failed before it became active: the automatic retry, or nil when none is due.
    @discardableResult
    public func onJoinFailed(_ target: T, now: TimeInterval) -> Pending? {
        guard enabled(), !autoUsed.contains(target) else { return nil }
        autoUsed.insert(target)
        pending = Pending(target: target, notBefore: now, expires: now + Self.window, auto: true)
        return pending
    }

    /// The user pressed Try again.
    @discardableResult
    public func onTryAgain(_ target: T, now: TimeInterval) -> Pending {
        let value = Pending(target: target, notBefore: now, expires: now + Self.window, auto: false)
        pending = value
        return value
    }

    /// A join to `target` became active: its automatic retry is available again for a later failure.
    public func onJoined(_ target: T) { autoUsed.remove(target) }

    public func cancel() { pending = nil }

    /// The listed stream to join now for the pending join, if one is due; the pending join is used up.
    public func take<P>(now: TimeInterval, listed: [P], matches: (T, P) -> Bool) -> P? {
        guard let due = pending else { return nil }
        if now > due.expires { pending = nil; return nil }
        guard now >= due.notBefore, let found = listed.first(where: { matches(due.target, $0) }) else { return nil }
        pending = nil
        return found
    }

    public static func failureMessage(title: String?) -> String {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return "Couldn't join the stream." }
        return "Couldn't join \(title)."
    }
}

/// As Android (ReceiverJoinWait): a viewer's join keeps waiting after a connection that failed before its hop
/// handshake (a stranger, a stale dial, noise), within the same deadline; an authenticated link that failed ends it.
public enum StreamJoinWait {
    public static func keepWaiting(enabled: Bool, hopAuthenticated: Bool, joined: Bool, stoppedByUser: Bool, ended: Bool,
                                   secondsLeft: Double) -> Bool {
        enabled && !hopAuthenticated && !joined && !stoppedByUser && !ended && secondsLeft > 0
    }
}
