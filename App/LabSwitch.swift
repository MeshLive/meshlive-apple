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

    /// DEBUG `-NearbyPlaybackGain <0...1>` (the owner's minimum-volume rule for test devices): the fraction every sound the
    /// app plays is scaled to, under the system volume (which a remote test cannot lower on an iPhone). Clamped to 0...1;
    /// a missing, unparsable or non-finite value, and every release build, give 1 (no scaling). `debugBuild` is a seam for
    /// the release rule.
    static func playbackGain(arguments: [String] = ProcessInfo.processInfo.arguments,
                             debugBuild: Bool = LabSwitch.isDebugBuild) -> Float {
        guard debugBuild, let i = arguments.firstIndex(of: "-NearbyPlaybackGain"), i + 1 < arguments.count,
              let value = Float(arguments[i + 1]), value.isFinite else { return 1 }
        return min(1, max(0, value))
    }

    /// Whether this is a DEBUG build (the only builds that read lab switches).
    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// An integer lab value with no Settings row (launch argument `-key N` or a stored default): DEBUG builds read `key`,
    /// release builds always use `shipped`, as `read`. `debugBuild` is a seam for the tests of the release rule.
    static func integer(_ key: String, shipped: Int, in store: UserDefaults = .standard,
                        debugBuild: Bool = LabSwitch.isDebugBuild) -> Int {
        guard debugBuild, store.object(forKey: key) != nil else { return shipped }
        return store.integer(forKey: key)
    }

    /// A promoted switch (always on, or always off, with no Settings row since its promotion; Android ignores the
    /// stored choice of a removed switch the same way): a value an old Settings row stored is ignored in every build.
    /// DEBUG builds still honour the launch argument `-key YES/NO` (a control arm, such as the interop runner's
    /// `-experimentalRotatingIds NO`), read from the launch-argument domain only; release builds always use `shipped`.
    static func promoted(_ key: String, shipped: Bool,
                         arguments: [String: Any] = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)) -> Bool {
        #if DEBUG
        switch arguments[key] {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        case let value as String: return (value as NSString).boolValue
        default: return shipped
        }
        #else
        return shipped
        #endif
    }
}

/// DEBUG `-NearbyAutoLive video|audio` [`-NearbyAutoLiveTitle <text>`] (`Automation`, keys without `-Nearby`): which
/// "Go live" choice to start. `debugBuild` is a seam for the release rule (release builds never act on it).
enum AutoLiveRequest: Equatable {
    case go(audioOnly: Bool, title: String?)
    case invalid(String)

    static func from(_ args: [String: String], debugBuild: Bool = LabSwitch.isDebugBuild) -> AutoLiveRequest? {
        guard debugBuild, let mode = args["AutoLive"] else { return nil }
        let title = args["AutoLiveTitle"].map { $0 == "-" ? "" : $0 }
        switch mode {
        case "video": return .go(audioOnly: false, title: title)
        case "audio": return .go(audioOnly: true, title: title)
        default: return .invalid(mode)
        }
    }
}
