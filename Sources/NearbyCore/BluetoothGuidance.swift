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
        mac ? "MeshLive can't use Bluetooth right now. Turn Bluetooth off and on (Control Center or System Settings), then try again. If that doesn't help, restart your Mac."
            : "MeshLive can't use Bluetooth right now. Turn Bluetooth off and on in Control Center, then try again. If that doesn't help, restart your iPhone."
    }

    public static func needsRestart(state: State, secondsInState: Double, hostingFailed: Bool) -> Bool {
        switch state {
        case .poweredOff, .unauthorized, .unsupported: return false
        case .resetting, .unknown: return secondsInState >= stuckSeconds
        case .poweredOn: return hostingFailed
        }
    }
}
