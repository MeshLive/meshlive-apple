import Foundation

/// Export diagnostics (Android Help and feedback > Export diagnostics, `CoreDiagnosticsUi.build`): one short text the
/// user reads, copies or shares. It holds only what Android's export holds, with Apple's facts: versions, the source
/// commit, the device model identifier, the OS version, Bluetooth support, the codecs and the newest crash report.
/// Never media, messages, names, IDs, handles, prefixes, addresses, keys, titles, paths or log lines: the facts are
/// typed fields, and each value must match its pattern or it becomes "unknown".
public enum DiagnosticsReport {
    public static let subject = "MeshLive diagnostics"
    /// Android's 16 KB bound.
    public static let maxCharacters = 16_000

    public struct Facts: Equatable {
        public var appVersion: String
        public var appBuild: String
        public var debugBuild: Bool
        public var sourceCommit: String?
        /// The hardware model identifier ("iPhone15,2", "Mac14,2"); never the device's user-given name.
        public var modelIdentifier: String
        public var mac: Bool
        public var systemVersion: String
        /// The Bluetooth permission word (`granted`, `denied`, `restricted`, `undetermined`, `unknown`).
        public var bluetoothPermission: String
        /// `true`, `false` or nil (unknown on this platform).
        public var extendedScanAndConnect: Bool?
        public var codecs: String
        /// The newest kept crash report (already filtered by `CrashReport`), or nil.
        public var lastCrash: String?

        public init(appVersion: String, appBuild: String, debugBuild: Bool, sourceCommit: String?, modelIdentifier: String, mac: Bool,
                    systemVersion: String, bluetoothPermission: String, extendedScanAndConnect: Bool?, codecs: String, lastCrash: String?) {
            self.appVersion = appVersion; self.appBuild = appBuild; self.debugBuild = debugBuild; self.sourceCommit = sourceCommit
            self.modelIdentifier = modelIdentifier; self.mac = mac; self.systemVersion = systemVersion
            self.bluetoothPermission = bluetoothPermission; self.extendedScanAndConnect = extendedScanAndConnect
            self.codecs = codecs; self.lastCrash = lastCrash
        }
    }

    /// The keys a report line may start with, in Android's order (the reviewer and the tests check against it).
    public static let keys = ["app_version", "source_commit", "device", "ios", "macos", "bluetooth", "bluetooth_le",
                              "l2cap_channels", "le_extended_scan_and_connect", "codecs", "device_policy", "recent_connections", "last_crash"]

    public static func build(_ facts: Facts) -> String {
        var lines = [subject]
        lines.append("app_version: \(pick(facts.appVersion, versionPattern)) (\(pick(facts.appBuild, buildPattern)), \(facts.debugBuild ? "debug" : "release"))")
        lines.append("source_commit: \(commit(facts.sourceCommit) ?? "not recorded")")
        lines.append("device: Apple \(pick(facts.modelIdentifier, modelPattern))")
        lines.append("\(facts.mac ? "macos" : "ios"): \(pick(facts.systemVersion, versionPattern))")
        lines.append("bluetooth: \(pick(facts.bluetoothPermission, wordPattern))")
        lines.append("bluetooth_le: true")
        lines.append("l2cap_channels: true")
        lines.append("le_extended_scan_and_connect: \(facts.extendedScanAndConnect.map { $0 ? "true" : "false" } ?? "unknown")")
        lines.append("codecs: \(pick(facts.codecs, codecPattern))")
        lines.append("device_policy: (not included in this build)")
        lines.append("recent_connections: (not included in this build)")
        if let crash = facts.lastCrash, !crash.isEmpty {
            lines.append("")
            lines.append("last_crash:")
            lines.append(crash)
        } else {
            lines.append("last_crash: none")
        }
        let text = lines.joined(separator: "\n")
        return text.count > maxCharacters ? String(text.prefix(maxCharacters)) : text
    }

    /// Android's Link health "Copy diagnostics": the report, then "call:" and the call sheet's rows. Each row passes
    /// the crash filter and is one line; the whole stays within the bound.
    public static func withCall(_ report: String, rows: [String]) -> String {
        let call = rows.map { CrashReport.scrub($0) }.filter { !$0.isEmpty }.joined(separator: "\n")
        let text = report + "\ncall:\n" + call
        return text.count > maxCharacters ? String(text.prefix(maxCharacters)) : text
    }

    static let versionPattern = #"^[0-9]{1,4}(\.[0-9]{1,4}){0,3}$"#
    static let buildPattern = #"^[0-9]{1,9}(\.[0-9]{1,4}){0,2}$"#
    /// "iPhone15,2", "iPad13,4", "Mac14,2", "MacBookPro18,3", a simulator's "arm64" or "x86_64".
    static let modelPattern = #"^([A-Za-z]{2,20}[0-9]{1,3},[0-9]{1,3}|arm64|x86_64)$"#
    static let wordPattern = #"^[a-z]{1,20}$"#
    static let codecPattern = #"^[A-Za-z0-9 ,;.]{1,120}$"#
    static let commitPattern = #"^[0-9a-f]{7,12}$"#

    /// The value when it matches `pattern`, else "unknown".
    static func pick(_ value: String, _ pattern: String) -> String {
        value.range(of: pattern, options: .regularExpression) != nil ? value : "unknown"
    }

    /// A short lowercase commit hash, else nil.
    static func commit(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              value.range(of: commitPattern, options: .regularExpression) != nil else { return nil }
        return value
    }
}

/// AB5 R7: the codec rows of About and Manual video and the export's `codecs:` value, from typed facts. HEVC and H.264 are
/// named only while their Experimental master is on and this device passed the probe, exactly when the hello advertises
/// them, so the rows never claim more than the wire. The export uses the long form while it passes
/// `DiagnosticsReport.codecPattern` (120 characters), else a short form (at most 86 characters).
public struct CodecRows: Equatable {
    public enum Decoder: Equatable { case none, hardware, software }
    public var vp9: Decoder, av1Hardware: Bool, hevc: Decoder, h264: Decoder
    public var vp9Encoder: Bool, hevcEncoder: Bool, h264Encoder: Bool, opus: Bool

    public init(vp9: Decoder, av1Hardware: Bool, hevc: Decoder, h264: Decoder,
                vp9Encoder: Bool, hevcEncoder: Bool, h264Encoder: Bool, opus: Bool) {
        self.vp9 = vp9; self.av1Hardware = av1Hardware; self.hevc = hevc; self.h264 = h264
        self.vp9Encoder = vp9Encoder; self.hevcEncoder = hevcEncoder; self.h264Encoder = h264Encoder; self.opus = opus
    }

    private static func name(_ codec: String, _ decoder: Decoder, short: Bool) -> String? {
        switch decoder {
        case .none: return nil
        case .hardware: return codec + (short ? " hw" : ", hardware")
        case .software: return codec + (short ? " sw" : ", software")
        }
    }

    private func decoders(short: Bool) -> [String] {
        [Self.name("VP9", vp9, short: short), Self.name("AV1", av1Hardware ? .hardware : .none, short: short),
         Self.name("HEVC", hevc, short: short), Self.name("H.264", h264, short: short)].compactMap { $0 }
    }

    private func encoders(short: Bool) -> [String] {
        [Self.name("VP9", vp9Encoder ? .software : .none, short: short), Self.name("HEVC", hevcEncoder ? .hardware : .none, short: short),
         Self.name("H.264", h264Encoder ? .hardware : .none, short: short)].compactMap { $0 }
    }

    /// About "Video decode" and Manual video "Decoders on this phone/Mac".
    public var decode: String {
        let names = decoders(short: false)
        return names.isEmpty ? "Unavailable" : names.joined(separator: "; ")
    }

    /// About "Video encode" and Manual video "Encoder".
    public var encode: String {
        let names = encoders(short: false)
        return names.isEmpty ? "Unavailable" : names.joined(separator: "; ")
    }

    /// About "Voice".
    public var voice: String { opus ? "Opus 48 kHz" : "Unavailable" }

    /// The export's `codecs:` value.
    public var export: String {
        let long = "video decode \(decode); video encode \(encode); voice \(voice)"
        if DiagnosticsReport.pick(long, DiagnosticsReport.codecPattern) == long { return long }
        let d = decoders(short: true), e = encoders(short: true)
        return "decode \(d.isEmpty ? "none" : d.joined(separator: ", ")); encode \(e.isEmpty ? "none" : e.joined(separator: ", ")); voice \(opus ? "Opus" : "none")"
    }
}
