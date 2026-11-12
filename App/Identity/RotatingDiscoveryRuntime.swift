import Foundation
import Security
import NearbyCore

/// EXPERIMENTAL rotating discovery IDs (Settings > Advanced, off): the presence vault (day keys and leases), the monotonic epoch clock, the opening pins, the stranger tarpit and
/// the Visible-by-handle window. Call-ready presence advertises the role-0 RDI as compact UUID v2.
final class RotatingDiscoveryRuntime {
    private let defaults = DesktopPreview.preferences
    let pins = OpeningPins()
    /// Phase 1b: a waiting viewer's role-2 request, its boundary rotation and its own pins (separate from the call role's).
    let viewerRequest = RotatingViewerRequest()
    /// AB4 (Experimental, `-rotatingSource`): this device's own rotating stream offer, its boundary rotation and its
    /// role-1 pins (separate from the call role's and the viewer role's).
    let streamOffer = RotatingStreamOffer()
    let tarpit = StrangerTarpit()
    private var clock: DiscoveryEpochClock

    init() {
        RotatingDiscoveryRuntime.applyDebugEpochLength()
        let state = (defaults.data(forKey: "rotatingEpochClock")).flatMap { try? JSONDecoder().decode(EpochClockState.self, from: $0) } ?? EpochClockState()
        let defaults = self.defaults
        clock = DiscoveryEpochClock(state: state, bootId: RotatingDiscoveryRuntime.bootId) { s in
            defaults.set(try? JSONEncoder().encode(s), forKey: "rotatingEpochClock")
        }
        Self.deleteLegacyPresenceKey()
    }

    static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static var elapsedMs: Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }

    /// AB4: DEBUG `-NearbyRotidEpochS <60...900>` (Android `test_rotid_epoch_s`), read once per process before the epoch
    /// clock loads its state. Release builds never read it (`RootView.debugArgument` is nil there, and
    /// `DiscoveryEpochLength` refuses a non-DEBUG build). Give the other phone of the test the same value.
    private static var epochLengthChecked = false
    static func applyDebugEpochLength() {
        guard !epochLengthChecked else { return }
        epochLengthChecked = true
        guard let value = RootView.debugArgument("-NearbyRotidEpochS") else { return }
        let applied = DiscoveryEpochLength.set(Int64(value) ?? 0, debugBuild: LabSwitch.isDebugBuild, started: false)
        AppLog.event("rotid_epoch_s", ["requested": value, "epochSeconds": "\(RotatingDiscoveryIds.epochSeconds)", "applied": "\(applied)"])
    }

    /// Boot identifier (kern.boottime): monotonic time is comparable only within one boot.
    static var bootId: String {
        var tv = timeval(), size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return "unknown" }
        return "\(tv.tv_sec).\(tv.tv_usec)"
    }

    /// Phase 2: the day-key window, the generation and the contacts' leases (Keychain, this device only).
    let vault = PresenceVault(epoch: RotatingDiscoveryIds.currentWallEpoch)

    /// The epoch to advertise now (a forward-jump recovery starts a new presence generation: a new key window).
    func currentEpoch() -> Int64 {
        let reading = clock.read(wallMs: Self.nowMs, elapsedMs: Self.elapsedMs)
        if reading.newGeneration {
            AppLog.event("rotating_ids", ["event": "new_generation", "generation": "\(clock.state.generation)"])
            vault.newGeneration(epoch: reading.epoch, reason: "forward_jump")
        }
        return reading.epoch
    }

    /// Role-0 entry for this epoch: the salt keyed by today's independent random day key (Android protocol reference "Keys and epochs").
    func callEntry(nodeId: NodeId) -> OpeningEntry {
        vault.entry(nodeId: nodeId, epoch: currentEpoch(), role: RotatingDiscoveryIds.roleCallOffer)
    }

    /// The phase 1 presence key P (one long-lived key, weekly derivation) is no longer used: delete it once.
    static func deleteLegacyPresenceKey() {
        #if os(macOS)
        #if DEBUG
        // An ephemeral-identity DEBUG run never touches the login Keychain either.
        DesktopLegacyPresenceCleanup.run(preview: DesktopPreview.enabled || KeychainItem.ephemeral)
        #else
        DesktopLegacyPresenceCleanup.run(preview: DesktopPreview.enabled)
        #endif
        #else
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: KeychainServices.legacyPresence] as CFDictionary)
        #endif
    }

    // MARK: Visible by handle (compact v1 until the first boundary at least 10 min later; 25 min monotonic cap)

    private var windowEndEpoch: Int64 = -1
    private var windowStartedElapsedMs: Int64 = 0
    var visibleWindowActive: Bool {
        guard windowEndEpoch >= 0 else { return false }
        let active = VisibleByHandleWindow.isActive(endEpoch: windowEndEpoch, nowUnixSeconds: Self.nowMs / 1000)
            && Self.elapsedMs - windowStartedElapsedMs < VisibleByHandleWindow.maxMs
        if !active { windowEndEpoch = -1 }      // latched off once over
        return active
    }
    func startVisibleWindow() {
        windowEndEpoch = VisibleByHandleWindow.endEpoch(startUnixSeconds: Self.nowMs / 1000)
        windowStartedElapsedMs = Self.elapsedMs
        AppLog.event("rotating_ids", ["event": "visible_by_handle", "endEpoch": "\(windowEndEpoch)"])
    }
}
