import Foundation

/// Bluetooth readiness as the title-bar status sees it (Android `HomeReadiness`, plus Apple's restart guidance).
public enum StatusReadiness: Equatable {
    case ready, bluetoothOff, permissionsNeeded, unsupported
    /// Apple only: Bluetooth is on and allowed but stuck or failing (`BluetoothGuidance`, radio errors).
    case bluetoothProblem
}

/// Which screen owns the radio now (Android `ReachabilityScreen`, the part the status uses).
public enum StatusScreen: Equatable { case home, watching, live }

/// What the small status indicator in every title bar says (Android `StatusKind`). One at a time; `of` picks the first
/// match in Android's order. The raw value is an automation identifier, never shown.
public enum StatusKind: String, CaseIterable {
    case ready, bluetoothUnavailable, bluetoothOff, permissions, bluetoothProblem, watching, live, callsUnavailable, hidden, relayPaused, hot

    /// Anything but ready: the chip may show its word.
    public var problem: Bool { self != .ready }

    /// The word beside the dot (Android `status_*` strings); nil when all is well and only the dot shows.
    public func word(mac: Bool) -> String? {
        switch self {
        case .ready: return nil
        case .bluetoothUnavailable: return "No Bluetooth"
        case .bluetoothOff: return "Bluetooth off"
        case .permissions: return "Permissions needed"
        case .bluetoothProblem: return "Bluetooth problem"
        case .watching: return "Calls paused while you watch"
        case .live: return "Calls paused while you're live"
        case .callsUnavailable: return "Calls unavailable"
        case .hidden: return "Hidden"
        case .relayPaused: return "Relay paused"
        case .hot: return mac ? "Mac hot" : "Phone hot"
        }
    }

    /// Android `statusKind`: Bluetooth (or its permission) first, then the screen that owns the radio, then calls wanted
    /// but the call service not hosted (`callsUnavailable`, Android `CALLS_UNAVAILABLE`), then not reachable for calls,
    /// then relaying paused by the battery, then heat.
    public static func of(readiness: StatusReadiness, hidden: Bool, relayPaused: Bool, hot: Bool,
                          screen: StatusScreen = .home, callsUnavailable: Bool = false) -> StatusKind {
        switch readiness {
        case .unsupported: return .bluetoothUnavailable
        case .bluetoothOff: return .bluetoothOff
        case .permissionsNeeded: return .permissions
        case .bluetoothProblem: return .bluetoothProblem
        case .ready: break
        }
        switch screen {
        case .watching: return .watching
        case .live: return .live
        case .home: break
        }
        if callsUnavailable { return .callsUnavailable }
        if hidden { return .hidden }
        if relayPaused { return .relayPaused }
        if hot { return .hot }
        return .ready
    }
}

/// Why calls cannot reach this device although Allow calls is on and Bluetooth is ready (Android
/// `CallsUnavailableReason`). Apple has one: the call service (the GATT services and the L2CAP channel) was not hosted in
/// time, as when the Bluetooth stack stops answering. A service the stack refused is Apple's restart guidance
/// (`BluetoothGuidance`, "Bluetooth problem"), which the status shows first.
public enum CallsUnavailableReason: String, Equatable {
    case stalled

    /// The status sheet's Allow calls value and the Live card's text (Android `status_value_calls_stalled`, with this
    /// device's word).
    public func statusValue(mac: Bool) -> String {
        "Unavailable. Bluetooth stopped responding. Turn Bluetooth off and on. If that doesn't help, restart your \(mac ? "Mac" : "phone")."
    }
}

/// Android `CallsAvailabilityTracker` (on since 2026-11-05): calls are unavailable while they are wanted and the call
/// service has not been hosted for `stallSeconds`. Before this, a stack that never answered left the status at Ready while
/// nobody could call the device. The app samples it every 2 s; hosting, or calls not wanted, clears it and restarts the
/// clock.
public struct CallsEndpointWatch {
    /// Android's 5 s (its listen watchdog deadline); a normal start takes about a second.
    public static let stallSeconds: TimeInterval = 5
    private var notReadySince: TimeInterval?

    public init() {}

    /// `enabled`: the control arm; `wanted`: Allow calls on and Bluetooth ready with no other Bluetooth problem shown;
    /// `endpointReady`: the call service is hosted (`MeshRadio.peripheralReady`); `now`: uptime in seconds.
    public mutating func observe(enabled: Bool, wanted: Bool, endpointReady: Bool, now: TimeInterval) -> CallsUnavailableReason? {
        guard enabled, wanted, !endpointReady else { notReadySince = nil; return nil }
        let since = notReadySince ?? now
        notReadySince = since
        return now - since >= Self.stallSeconds ? .stalled : nil
    }
}
