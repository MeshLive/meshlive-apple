import Foundation

/// Plain Bluetooth-restart guidance (Android `people_bluetooth_restart_*`, 2026-10-21): when Bluetooth is allowed and
/// switched on but the system stack cannot be used (stuck while resetting or starting, or it refused to host
/// MeshLive's service), say what helps in plain words instead of an error code: turn Bluetooth off and on, then
/// restart the device. Off, not allowed and unsupported keep their own messages.
public enum BluetoothGuidance {
    public enum State: Equatable { case poweredOn, poweredOff, unauthorized, unsupported, resetting, unknown }

    /// How long "resetting" or "unknown" may last before it counts as stuck (a normal start or reset takes about 1 s).
    public static let stuckSeconds: Double = 10

    public static let restartTitle = "Bluetooth needs a restart to find nearby people"
    public static func restartText(mac: Bool) -> String {
        mac ? "MeshLive can't search for nearby people right now. Turn Bluetooth off and on (Control Center or System Settings), then try again. If that doesn't help, restart your Mac."
            : "MeshLive can't search for nearby people right now. Turn Bluetooth off and on in Control Center, then try again. If that doesn't help, restart your iPhone."
    }

    public static func needsRestart(state: State, secondsInState: Double, hostingFailed: Bool) -> Bool {
        switch state {
        case .poweredOff, .unauthorized, .unsupported: return false
        case .resetting, .unknown: return secondsInState >= stuckSeconds
        case .poweredOn: return hostingFailed
        }
    }
}

/// Android WifiAdvicePolicy and WifiCoexistence (user-perspective audit 2026-10-21): 2.4 GHz Wi-Fi time-shares the radio
/// with Bluetooth (an M31 on 2,472 MHz measured about half its Bluetooth goodput), so before video the app suggests a
/// 5 GHz network or Wi-Fi off: at most once a day (the answer is kept), never before voice. Apple: the Mac only (the
/// iPhone cannot read the band); the Mac reads the band without asking for Location and says nothing when macOS does
/// not tell it (gap audit Q4).
public enum WifiAdvice {
    public enum Band: String { case ghz2_4 = "2.4", ghz5 = "5", ghz6 = "6", unknown }

    public static let title = "Turn off Wi-Fi for smoother video"
    public static let message = "Your 2.4 GHz Wi-Fi connection may slow Bluetooth. Try a 5 GHz network or turn Wi-Fi off to improve video."
    public static let openSettings = "Open Wi-Fi settings"
    public static let continueAnyway = "Continue anyway"

    /// An answer keeps the advice quiet for this long (Android `QUIET_MS`).
    public static let quietSeconds: TimeInterval = 24 * 60 * 60

    /// Whether to ask before an action: only on 2.4 GHz, never before voice (or audio only), once a day; a clock that moved
    /// back asks again rather than staying quiet for ever.
    public static func shouldAsk(enabled: Bool, band: Band, voice: Bool, now: TimeInterval, answeredAt: TimeInterval) -> Bool {
        guard enabled, band == .ghz2_4, !voice else { return false }
        if answeredAt <= 0 || now < answeredAt { return true }
        return now - answeredAt >= quietSeconds
    }
}
