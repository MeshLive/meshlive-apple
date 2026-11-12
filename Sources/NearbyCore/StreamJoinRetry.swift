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

// MARK: - Viewer recovery after an unexpected loss (Android returnToStreamBrowser, change ledger 2cbdafb1)

/// Android: an active stream lost without the source's end record looks for the same stream again on any route, keeping
/// the screen and the last picture. A route that failed waits 0, 1, 2, 4, then 8 s after its 1st, 2nd, ... consecutive
/// failure (`UNEXPECTED_LOSS_RETRY_DELAYS_MS`); other routes may be tried at once.
public enum ViewerRecovery {
    public static let delays: [TimeInterval] = [0, 1, 2, 4, 8]

    public static func delay(afterFailures count: Int) -> TimeInterval { delays[min(max(count - 1, 0), delays.count - 1)] }

    /// A rejoin that has not delivered the stream's header by then is a failure of that route (Android's
    /// pre-authentication attempts time out after 12 s).
    public static let rejoinTimeout: TimeInterval = 12

    /// A route its parent withdrew waits this long (Android `WITHDRAWN_ROUTE_SUPPRESSION_MS`).
    public static let withdrawnRouteWait: TimeInterval = 30

    /// While recovering, the model looks again at least this often: an offer that is only seen again raises no list change.
    public static let recheckInterval: TimeInterval = 0.5

    /// Android `streamCapacityGenerationAdvanced`: the offer's 7-bit capacity generation moved forward by 1 to 63.
    public static func capacityAdvanced(from previous: UInt8, to current: UInt8) -> Bool {
        (1...63).contains((current &- previous) & DiscoveryAnnouncement.sequenceGenerationMask)
    }

    /// Android's reconnection order (`streamRouteRank`): fewest relays first, then the transport of the lost route, then
    /// the advertised ID; equal routes keep their listed order.
    public static func ordered<P>(_ listed: [P], offer: (P) -> DiscoveryAnnouncement, preferredTransport: MeshTransport?) -> [P] {
        listed.enumerated().sorted { a, b in
            let x = offer(a.element), y = offer(b.element)
            if x.routeCost != y.routeCost { return x.routeCost < y.routeCost }
            let tx = x.transport == preferredTransport ? 0 : 1, ty = y.transport == preferredTransport ? 0 : 1
            if tx != ty { return tx < ty }
            if x.prefixHex != y.prefixHex { return x.prefixHex < y.prefixHex }
            return a.offset < b.offset
        }.map { $0.element }
    }

    /// Android `streamCapacityWithdrawalNotice`: the viewer's text after its parent withdrew the route.
    public static func withdrawalNotice(routeCost: UInt8) -> String {
        routeCost == 0 ? "No free connection slot on this source. Finding another route..."
            : "The relay connection became unstable. Finding another route..."
    }

    /// Only an active stream (its header arrived), or a route its parent withdrew (Android allows a reconnect after
    /// `LOCAL_CAPACITY` before the header), recovers, and only when nothing ended it on purpose.
    public static func recovers(enabled: Bool, joined: Bool, sourceEnded: Bool, stoppedByUser: Bool, ended: Bool,
                                routeWithdrawn: Bool = false) -> Bool {
        enabled && (joined || routeWithdrawn) && !sourceEnded && !stoppedByUser && !ended
    }

    /// One route of one stream for the back-off: the advertising address, the advertised ID and the route token.
    public static func routeKey(_ route: StreamRoutePenalties.Route) -> String { "\(route.address)|\(route.prefixHex)|\(route.routeToken)" }

    /// Android `watch_connection_lost`, `watch_rejoining`, `audio_live_listen_state_reconnecting`, and the frozen-picture
    /// label while recovering (Android ViewerFrameAge "Signal lost").
    public static let lostText = "Connection lost. Looking for the stream again\u{2026}"
    public static let rejoiningText = "Found another way to reach the stream. Reconnecting\u{2026}"
    public static let listenerReconnectingText = "Reconnecting\u{2026}"
    public static let signalLostTitle = "Signal lost \u{2014} reconnecting"
}

// MARK: - The 60 s end of a lost-stream search (Android a45080f6, StreamSearchBound.kt)

/// A viewer's search for a lost stream is bounded: the first loss starts the clock, failed reconnect attempts inside
/// the same search do not restart it, and the stream playing again ends the search (the next loss gets a full bound).
/// `enabled` is the lab switch; when it is off the search is unbounded, as at BASE.
public struct StreamSearchBound {
    public static let defaultBound: TimeInterval = 60
    /// Android `watch_stream_lost`, verbatim.
    public static let lostNotice = "The stream was lost. Showing nearby broadcasts."

    public init(bound: TimeInterval = StreamSearchBound.defaultBound, enabled: @escaping () -> Bool = { true }) {
        self.bound = bound
        self.enabled = enabled
    }

    private let bound: TimeInterval
    private let enabled: () -> Bool
    private var startedAt: TimeInterval?

    /// Starts the clock only if no search is running.
    public mutating func begin(now: TimeInterval) {
        guard enabled(), startedAt == nil else { return }
        startedAt = now
    }

    /// The stream is back, or the viewer left: the next loss starts a new clock.
    public mutating func end() { startedAt = nil }

    /// nil: no search running or the bound is off; else the time left, never below zero.
    public func remaining(now: TimeInterval) -> TimeInterval? {
        guard enabled(), let startedAt else { return nil }
        return max(0, startedAt + bound - now)
    }

    public func expired(now: TimeInterval) -> Bool { remaining(now: now) == 0 }
}

/// The routes a recovering viewer may try for one stream, with Android's per-route back-off.
public final class ViewerRecoveryRoutes<Target: Hashable> {
    public private(set) var target: Target?
    private var failures: [String: Int] = [:]
    private var waitUntil: [String: TimeInterval] = [:]
    /// When each route last failed: it is tried again only after a fresh sighting of its offer (Android drops the cached
    /// offer of a failed route).
    private var failedAt: [String: TimeInterval] = [:]
    /// A withdrawn route's capacity generation when it was joined.
    private var withdrawnGeneration: [String: UInt8] = [:]

    public init() {}

    /// The stream was lost on `route`, or a rejoin through it failed. A different stream starts a fresh back-off.
    public func onFailure(target next: Target, route: String, now: TimeInterval) {
        if target != next { cancel(); target = next }
        let count = (failures[route] ?? 0) + 1
        failures[route] = count
        waitUntil[route] = now + ViewerRecovery.delay(afterFailures: count)
        failedAt[route] = now
    }

    /// The route's parent withdrew it (Android `onRouteWithdrawn`): it waits at least 30 s, unless its offer shows a
    /// capacity generation after `generation` (the generation of the offer that was joined).
    public func onWithdrawn(target next: Target, route: String, generation: UInt8, now: TimeInterval) {
        if target != next { cancel(); target = next }
        waitUntil[route] = max(waitUntil[route] ?? now, now + ViewerRecovery.withdrawnRouteWait)
        withdrawnGeneration[route] = generation
    }

    /// The first listed route of the stream whose wait has passed and which, if it failed before, was seen again after
    /// that failure; nil when none. `seenAt` is the offer's last sighting (nil: unknown, never held back); `generation`
    /// its capacity generation (a withdrawn route whose generation moved on is free at once, as Android).
    public func candidate<P>(now: TimeInterval, listed: [P], matches: (Target, P) -> Bool, route: (P) -> String,
                             seenAt: (P) -> TimeInterval? = { _ in nil }, generation: (P) -> UInt8? = { _ in nil }) -> P? {
        guard let target else { return nil }
        for item in listed where matches(target, item) {
            let key = route(item)
            if let joined = withdrawnGeneration[key], let current = generation(item),
               ViewerRecovery.capacityAdvanced(from: joined, to: current) {
                withdrawnGeneration[key] = nil; waitUntil[key] = nil
            }
            if let wait = waitUntil[key], wait > now { continue }
            if let failed = failedAt[key], let seen = seenAt(item), seen <= failed { continue }
            return item
        }
        return nil
    }

    /// Seconds until the next waiting route may be tried, or nil when none waits.
    public func nextOpening(now: TimeInterval) -> TimeInterval? {
        guard target != nil else { return nil }
        return waitUntil.values.filter { $0 > now }.min().map { $0 - now }
    }

    public func cancel() { target = nil; failures = [:]; waitUntil = [:]; failedAt = [:]; withdrawnGeneration = [:] }
}

/// Android's relayed-child parent-link watch (`relayParentSilent`, `RelayParentTrickle`): a relayed route (cost above 0)
/// is dead when no byte arrived for 5 s since the later of the last byte and the link start (never while paused), or,
/// with the trickle test on, when a whole 5 s window after the stream header delivered less than 1/8 of the stream's
/// bitrate (a window that saw a pause, or an unknown bitrate, is not judged). Clock and byte total are passed in.
public struct RelayParentWatch {
    public static let silence: TimeInterval = 5
    public static let floorDivisor = 8
    public enum Verdict: Equatable { case fine, silent, trickle(kbps: Int) }

    public var streamKbps: Int
    private let startedAt: TimeInterval
    private var lastBytes: UInt64 = 0
    private var lastByteAt: TimeInterval?
    private var windowStart: TimeInterval
    private var windowStartBytes: UInt64 = 0
    private var pausedInWindow = false

    public init(streamKbps: Int, now: TimeInterval) { self.streamKbps = streamKbps; startedAt = now; windowStart = now }

    /// `bytes` is the link's running receive total; `armed` that the stream header arrived on this link.
    public mutating func tick(now: TimeInterval, bytes: UInt64, paused: Bool, armed: Bool, trickle: Bool) -> Verdict {
        if bytes > lastBytes { lastBytes = bytes; lastByteAt = now }
        if !paused, now - max(lastByteAt ?? startedAt, startedAt) >= Self.silence { return .silent }
        guard trickle else { return .fine }
        guard armed else { windowStart = now; windowStartBytes = bytes; pausedInWindow = false; return .fine }
        if paused { pausedInWindow = true }
        let elapsed = now - windowStart
        guard elapsed >= Self.silence else { return .fine }
        let kbps = Int(Double(bytes &- windowStartBytes) * 8 / elapsed / 1000)
        let judged = !pausedInWindow && streamKbps > 0
        windowStart = now; windowStartBytes = bytes; pausedInWindow = paused
        return judged && kbps * Self.floorDivisor < streamKbps ? .trickle(kbps: kbps) : .fine
    }
}

/// Android `relayAutoPaused`: "Relay video for others" does not forward a join started below 20 % battery while not
/// charging, or in Battery Saver (Apple: Low Power Mode). An unknown level (-1) never pauses.
public enum RelayBatteryPause {
    public static let minBatteryPercent = 20

    public static func paused(batteryPercent: Int, charging: Bool, lowPowerMode: Bool) -> Bool {
        lowPowerMode || (!charging && (0..<minBatteryPercent).contains(batteryPercent))
    }
}

/// Android `supportsAdvertisedCodec`: an audio-only offer needs audio live; a video offer needs a local decoder for a
/// codec its summary advertises (an empty or unknown summary cannot be played); a malformed offer never plays.
public enum StreamPlayability {
    public static func playable(offer: DiscoveryAnnouncement, decodeMask: UInt8, audioLive: Bool) -> Bool {
        switch offer.streamOfferKind {
        case .audioOnly: return audioLive
        case .video: return VideoCodecMap.summaryDecodable(offer.capabilitySummary, localDecodeHelloMask: decodeMask)
        case .malformed: return false
        }
    }
}

/// Android End live (`live_end_confirm_title`): ask first only while at least one viewer or listener is connected.
public enum LiveEndConfirm {
    public static func asks(viewers: Int, enabled: Bool) -> Bool { enabled && viewers > 0 }
    public static func title(viewers: Int) -> String { viewers == 1 ? "End live for 1 viewer?" : "End live for \(viewers) viewers?" }
}

/// Android broadcaster status lines for a video live (`live_status_bluetooth_off`, `live_status_paused_viewers`,
/// `live_status_waiting`), in that order; nil when the top bar says enough.
public enum LiveStatusLine {
    public static func video(running: Bool, paused: Bool, viewers: Int, bluetoothOff: Bool) -> String? {
        guard running else { return nil }
        if bluetoothOff { return "Bluetooth is off. Your stream comes back when Bluetooth is on." }
        if paused { return "Paused. Viewers stay connected." }
        if viewers == 0 { return "You're live. Waiting for viewers." }
        return nil
    }
}
