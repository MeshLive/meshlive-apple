import Foundation

/// How switches are read from UserDefaults (the app and the MeshPeer test tool).
enum LabSwitch {
    /// A stored switch with a default. `bool(forKey:)` reads both a stored Bool and a launch argument, which arrives as
    /// a string ("NO", "0"): `object(forKey:) as? Bool` is nil for it, so `-key NO` would silently keep the default.
    static func flag(_ key: String, default value: Bool, in store: UserDefaults = .standard) -> Bool {
        store.object(forKey: key) == nil ? value : store.bool(forKey: key)
    }

    /// A switch with no Settings row (a test control arm or a lab experiment): DEBUG builds read `key` (launch argument
    /// `-key YES/NO` or a stored default); release builds always use `shipped`, as Android honours its `test_*` extras
    /// only in debug builds. Settings toggles do not use this.
    static func read(_ key: String, shipped: Bool, in store: UserDefaults = .standard) -> Bool {
        #if DEBUG
        return flag(key, default: shipped, in: store)
        #else
        return shipped
        #endif
    }
}
