import Foundation
import Security
import NearbyCore

/// EXPERIMENTAL rotating discovery IDs (Settings > Advanced, off): the phone's presence key P (Keychain, this
/// device only, never synced or sent in phase 1), the RV4 epoch clock, the opening pins, the stranger tarpit and
/// the Visible-by-handle window. Call-ready presence advertises the role-0 RDI as compact UUID v2.
final class RotatingDiscoveryRuntime {
    private let defaults = UserDefaults.standard
    let pins = OpeningPins()
    let tarpit = StrangerTarpit()
    private var clock: DiscoveryEpochClock
    private static let keyAccount = "presence-key"

    init() {
        let state = (defaults.data(forKey: "rotatingEpochClock")).flatMap { try? JSONDecoder().decode(EpochClockState.self, from: $0) } ?? EpochClockState()
        let defaults = self.defaults
        clock = DiscoveryEpochClock(state: state, bootId: RotatingDiscoveryRuntime.bootId) { s in
            defaults.set(try? JSONEncoder().encode(s), forKey: "rotatingEpochClock")
        }
    }

    static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static var elapsedMs: Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }

    /// Boot identifier (kern.boottime): monotonic time is comparable only within one boot.
    static var bootId: String {
        var tv = timeval(), size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return "unknown" }
        return "\(tv.tv_sec).\(tv.tv_usec)"
    }

    /// The epoch to advertise now (a new generation replaces P).
    func currentEpoch() -> Int64 {
        let reading = clock.read(wallMs: Self.nowMs, elapsedMs: Self.elapsedMs)
        if reading.newGeneration {
            AppLog.event("rotating_ids", ["event": "new_generation", "generation": "\(clock.state.generation)"])
            _ = presenceKey(regenerate: true)
        }
        return reading.epoch
    }

    /// Role-0 entry for this epoch (salts keyed by this week's lease key, RV11).
    func callEntry(nodeId: NodeId) -> OpeningEntry {
        RotatingDiscoveryIds.ownEntry(presenceKey: presenceKey(), nodeId: nodeId.bytes, epoch: currentEpoch(), role: RotatingDiscoveryIds.roleCallOffer)
    }

    /// 32 random bytes, Keychain, AfterFirstUnlockThisDeviceOnly; removed by the emergency wipe with every item.
    func presenceKey(regenerate: Bool = false) -> Data {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.nearbyintercom.rotating",
                                   kSecAttrAccount as String: Self.keyAccount]
        if !regenerate {
            var query = base; query[kSecReturnData as String] = true
            var out: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data, data.count == 32 { return data }
        }
        SecItemDelete(base as CFDictionary)
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        var add = base
        add[kSecValueData as String] = Data(bytes)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
        return Data(bytes)
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
    var visibleWindowEnds: Date? { windowEndEpoch >= 0 ? Date(timeIntervalSince1970: TimeInterval(windowEndEpoch * RotatingDiscoveryIds.epochSeconds)) : nil }
}
