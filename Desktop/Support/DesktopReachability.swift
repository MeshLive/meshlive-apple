import Foundation

/// What the Mac's menu bar item reports. Live (red) wins over a call, so broadcasting is never hidden.
public enum DesktopReachabilityState: String, Equatable {
    case notReachable, reachable, inCall, live

    public var title: String {
        switch self {
        case .notReachable: return "Not reachable"
        case .reachable: return "Reachable"
        case .inCall: return "In call"
        case .live: return "Live"
        }
    }
}

/// A snapshot of the app state the reachability policy needs. Filled by the native app from AppModel; plain values so
/// the rules are testable without Bluetooth, media or AppKit.
public struct DesktopPresence: Equatable {
    public enum Call: Equatable { case none, incomingRinging, other }
    /// Bluetooth is powered on and the radio reports no problem.
    public var radioReady = false
    /// Settings › Allow calls.
    public var allowCalls = false
    public var call: Call = .none
    /// The call (once past ringing) carries video in either direction.
    public var callVideo = false
    public var liveSource = false
    public var liveVideo = false
    public var watching = false
    public var watchVideo = false
    /// This Mac passes someone else's call on (call relay hop).
    public var relayingCall = false
    /// MeshLive is the frontmost app.
    public var appActive = true

    public init(radioReady: Bool = false, allowCalls: Bool = false, call: Call = .none, callVideo: Bool = false,
                liveSource: Bool = false, liveVideo: Bool = false, watching: Bool = false, watchVideo: Bool = false,
                relayingCall: Bool = false, appActive: Bool = true) {
        self.radioReady = radioReady; self.allowCalls = allowCalls; self.call = call; self.callVideo = callVideo
        self.liveSource = liveSource; self.liveVideo = liveVideo; self.watching = watching; self.watchVideo = watchVideo
        self.relayingCall = relayingCall; self.appActive = appActive
    }

    /// A call, a live stream (sending or watching/listening) or a relayed call is running.
    public var hasMedia: Bool { call != .none || liveSource || watching || relayingCall }
    public var reachable: Bool { radioReady && allowCalls }
    /// Video is on screen, so the display should not idle-sleep while the media activity is held.
    public var showsVideo: Bool { (call == .other && callVideo) || (liveSource && liveVideo) || (watching && watchVideo) }
}

/// The Mac's reachability switches. Keys are the UserDefaults names; every default is off except the menu bar item.
public struct DesktopReachabilitySettings: Equatable {
    public static let menuBarKey = "desktopShowMenuBar"
    public static let activityDuringMediaKey = "experimentalDesktopActivityDuringMedia"
    public static let noAppNapWhileReachableKey = "experimentalDesktopNoAppNapWhileReachable"
    public static let keepAwakeWhileReachableKey = "desktopKeepAwakeWhileReachable"
    public static let ringWindowKey = "experimentalDesktopRingWindow"
    /// EXPERIMENTAL, off: the call offer is advertised only while a MeshLive window is open (not closed, minimised or
    /// hidden), so the Mac's fixed Bluetooth address is on air for shorter windows.
    public static let advertiseOnlyWithWindowKey = "experimentalDesktopAdvertiseOnlyWithWindow"

    public var activityDuringMedia = false
    public var noAppNapWhileReachable = false
    public var keepAwakeWhileReachable = false
    public var ringWindow = false

    public init(activityDuringMedia: Bool = false, noAppNapWhileReachable: Bool = false,
                keepAwakeWhileReachable: Bool = false, ringWindow: Bool = false) {
        self.activityDuringMedia = activityDuringMedia; self.noAppNapWhileReachable = noAppNapWhileReachable
        self.keepAwakeWhileReachable = keepAwakeWhileReachable; self.ringWindow = ringWindow
    }

    public init(defaults: UserDefaults) {
        self.init(activityDuringMedia: defaults.bool(forKey: Self.activityDuringMediaKey),
                  noAppNapWhileReachable: defaults.bool(forKey: Self.noAppNapWhileReachableKey),
                  keepAwakeWhileReachable: defaults.bool(forKey: Self.keepAwakeWhileReachableKey),
                  ringWindow: defaults.bool(forKey: Self.ringWindowKey))
    }

    /// The menu bar item is on unless the user turned it off (an absent key means on).
    public static func showsMenuBar(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: menuBarKey) == nil ? true : defaults.bool(forKey: menuBarKey)
    }
}

/// One ProcessInfo activity the app should hold (nil: none).
public struct DesktopActivity: Equatable {
    public let options: ProcessInfo.ActivityOptions
    public let reason: String
    public init(options: ProcessInfo.ActivityOptions, reason: String) { self.options = options; self.reason = reason }
}

public enum DesktopReachabilityPolicy {
    public static func state(_ p: DesktopPresence) -> DesktopReachabilityState {
        if p.liveSource { return .live }
        if p.call != .none { return .inCall }
        if p.watching { return .live }
        return p.reachable ? .reachable : .notReachable
    }

    /// Apple's activity options (Foundation NSProcessInfo.h, Energy Efficiency Guide for Mac Apps, "App Nap"):
    /// - media (call, ringing, live, watching/listening, relayed call): `.userInitiated`, which disables App Nap,
    ///   timer coalescing and idle system sleep, plus `.idleDisplaySleepDisabled` only while video is shown.
    ///   Never `.latencyCritical`: Core Audio I/O already runs on real-time threads, and Apple reserves it for
    ///   the few apps that need maximum timer/I/O precision at a large energy cost.
    /// - reachable, user chose "Keep Mac awake": `.userInitiated` (the Mac still sleeps when the lid closes).
    /// - reachable otherwise: `.userInitiatedAllowingIdleSystemSleep` keeps the 0.1 s link and discovery timers
    ///   unthrottled behind other apps while the Mac may still idle-sleep.
    /// Without a matching switch nothing is held, as before this policy existed.
    public static func activity(_ p: DesktopPresence, _ s: DesktopReachabilitySettings) -> DesktopActivity? {
        if p.hasMedia && s.activityDuringMedia {
            var options: ProcessInfo.ActivityOptions = .userInitiated
            if p.showsVideo { options.insert(.idleDisplaySleepDisabled) }
            return DesktopActivity(options: options, reason: p.showsVideo ? "MeshLive video call or live stream" : "MeshLive call or live audio")
        }
        guard p.reachable else { return nil }
        if s.keepAwakeWhileReachable { return DesktopActivity(options: .userInitiated, reason: "MeshLive keeps this Mac awake to stay reachable") }
        if s.noAppNapWhileReachable { return DesktopActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "MeshLive reachable for nearby calls") }
        return nil
    }

    /// The incoming-call window appears only while a call rings and another app is in front.
    public static func showsRingWindow(_ p: DesktopPresence, _ s: DesktopReachabilitySettings) -> Bool {
        s.ringWindow && p.call == .incomingRinging && !p.appActive
    }
}

/// Holds at most one ProcessInfo activity and swaps it only when the wanted activity changes. The new activity begins
/// before the old one ends, so there is no gap in which App Nap could apply. Main thread only.
public final class DesktopActivityHolder {
    public typealias Begin = (ProcessInfo.ActivityOptions, String) -> NSObjectProtocol
    public typealias End = (NSObjectProtocol) -> Void
    private let begin: Begin
    private let end: End
    private var token: NSObjectProtocol?
    public private(set) var current: DesktopActivity?

    public init(begin: @escaping Begin = { ProcessInfo.processInfo.beginActivity(options: $0, reason: $1) },
                end: @escaping End = { ProcessInfo.processInfo.endActivity($0) }) {
        self.begin = begin; self.end = end
    }

    /// Returns true when the held activity changed.
    @discardableResult
    public func apply(_ activity: DesktopActivity?) -> Bool {
        guard activity != current else { return false }
        let old = token
        token = activity.map { begin($0.options, $0.reason) }
        current = activity
        if let old { end(old) }
        return true
    }

    deinit { if let token { end(token) } }
}
