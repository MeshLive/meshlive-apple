import Foundation

/// The App Store build's gates (S0). Each is off in a release build, so a store build never shows or runs the feature;
/// a DEBUG build turns one on with the launch argument `-<key> YES` (or a stored default), as every lab switch
/// (`LabSwitch.read`). Nothing reads these yet: each track puts its feature behind its gate and a test flips it.
enum ReleaseGates {
    /// Relaying and forwarding video for others, and starting a stream as the source's first hop. DEBUG `-appleSourceRoles YES`.
    static var sourceRoles: Bool { LabSwitch.read("appleSourceRoles", shipped: false) }
    /// The Wi-Fi guest path for calls and streams. DEBUG `-appleWifiGuest YES`.
    static var wifiGuest: Bool { LabSwitch.read("appleWifiGuest", shipped: false) }
    /// Hardware HEVC/H.264 encode and decode choices. On since 2026-11-12: the Mac <-> Android device checks passed
    /// (HEVC chosen against Android 0.5.0 defaults, forced H.264 and HEVC both ways on an M31 and an A15s). DEBUG control
    /// arm `-appleHardwareCodecs NO`.
    static var hardwareCodecs: Bool { LabSwitch.read("appleHardwareCodecs", shipped: true) }
    /// In-call link renewal. DEBUG `-appleLinkRenewal YES`.
    static var linkRenewal: Bool { LabSwitch.read("appleLinkRenewal", shipped: false) }
    /// D1 viewer join keys (Design SI phase 1, viewer side): each watch session presents a throwaway key, never this
    /// device's identity. On since 2026-11-12: L5 on the Mac with an M31 and an A15s source (a fresh key per watch,
    /// the source authenticated the throwaway key) and the M31 snoop found no real key of the Mac on the air. DEBUG
    /// control arm `-appleStreamJoinKeys NO`.
    static var streamJoinKeys: Bool { LabSwitch.read("appleStreamJoinKeys", shipped: true) }
}
