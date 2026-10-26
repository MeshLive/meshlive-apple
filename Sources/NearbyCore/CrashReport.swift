import Foundation

/// Crash reports from MetricKit (Android CrashReports, 2026-10-21): the system hands the app a diagnostic payload
/// after a crash, usually at the next launch. MeshLive keeps a short text made from it and asks the user whether to
/// share it; nothing is sent automatically, and the user picks where it goes.
///
/// What a report holds: the app version and build, the OS version, the device model and architecture, the exception
/// type, code and signal, a scrubbed termination reason, and the crashed thread's frames as code locations (binary
/// name, offset, binary UUID, which is what symbolication needs). What it never holds: names, messages, keys, node or
/// stream IDs, addresses, file paths or the process ID; `scrub` removes anything in the free text that looks like one.
public enum CrashReport {
    public static let maxFrames = 40
    public static let maxReasonCharacters = 200
    public static let maxReportCharacters = 16_000
    /// Kept this long, then deleted unshared.
    public static let keepSeconds: TimeInterval = 7 * 24 * 3600

    public static let promptTitle = "MeshLive closed unexpectedly"
    public static let promptText = "Share a crash report? It lists where the app failed, its version and the device model. It has no names, messages, keys or IDs, and you choose where to send it."

    /// One text per crash in a MetricKit diagnostic payload (`MXDiagnosticPayload.jsonRepresentation()`); [] when it
    /// holds no crash or cannot be read.
    public static func reports(fromPayloadJSON json: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let crashes = root["crashDiagnostics"] as? [[String: Any]] else { return [] }
        return crashes.compactMap(report(fromCrash:))
    }

    static func report(fromCrash crash: [String: Any]) -> String? {
        let meta = crash["diagnosticMetaData"] as? [String: Any] ?? [:]
        func field(_ key: String) -> String? {
            switch meta[key] {
            case let s as String: return scrub(s)
            case let n as NSNumber: return n.stringValue
            default: return nil
            }
        }
        var lines = ["MeshLive crash report"]
        let app = [field("appVersion").map { "MeshLive \($0)" }, field("appBuildVersion").map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        let device = [field("osVersion"), field("deviceType"), field("platformArchitecture")].compactMap { $0 }.joined(separator: " · ")
        if !app.isEmpty { lines.append(app) }
        if !device.isEmpty { lines.append(device) }
        var kind: [String] = []
        if let type = field("exceptionType") { kind.append("exception type \(type)") }
        if let code = field("exceptionCode") { kind.append("code \(code)") }
        if let signal = field("signal") { kind.append("signal \(signal)") }
        if !kind.isEmpty { lines.append("Crash: " + kind.joined(separator: ", ")) }
        if let reason = field("terminationReason") { lines.append("Reason: " + String(reason.prefix(maxReasonCharacters))) }
        let frames = crashedThreadFrames(crash["callStackTree"] as? [String: Any])
        guard !frames.isEmpty || kind.count > 0 else { return nil }
        lines.append("Crashed thread:")
        lines += frames.enumerated().map { "\($0.offset) \($0.element)" }
        let text = lines.joined(separator: "\n")
        return text.count > maxReportCharacters ? String(text.prefix(maxReportCharacters)) : text
    }

    /// The attributed (crashed) thread's frames, innermost first, as `binary +0xoffset (uuid)`.
    static func crashedThreadFrames(_ tree: [String: Any]?) -> [String] {
        guard let stacks = tree?["callStacks"] as? [[String: Any]] else { return [] }
        let stack = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
        var frames: [String] = []
        var level = stack?["callStackRootFrames"] as? [[String: Any]] ?? []
        while let frame = level.first, frames.count < maxFrames {
            let name = (frame["binaryName"] as? String).map(binaryName) ?? "?"
            let offset = (frame["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value ?? 0
            let uuid = (frame["binaryUUID"] as? String).flatMap { UUID(uuidString: $0)?.uuidString } ?? "?"
            frames.append("\(name) +0x\(String(offset, radix: 16)) (\(uuid))")
            level = frame["subFrames"] as? [[String: Any]] ?? []
        }
        return frames
    }

    /// A binary's file name only (never a path), limited to plain characters.
    static func binaryName(_ raw: String) -> String {
        let last = raw.split(separator: "/").last.map(String.init) ?? raw
        let kept = last.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "._-+".unicodeScalars.contains($0) }
        let name = String(String.UnicodeScalarView(kept.prefix(64)))
        return name.isEmpty ? "?" : name
    }

    /// Free text from the system: paths, long hex or digit runs (addresses, IDs) and e-mail-like strings removed.
    public static func scrub(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "\n", with: " ")
        let rules: [(String, String)] = [
            (#"[\w.+-]+@[\w-]+\.[\w.-]+"#, "<email>"),
            (#"(~|/)[^\s,;:]*/[^\s,;:]*"#, "<path>"),
            (#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#, "<id>"),
            (#"0x[0-9A-Fa-f]+"#, "<hex>"),
            (#"\b[0-9A-Fa-f]{8,}\b"#, "<hex>"),
            (#"\d{6,}"#, "<number>"),
        ]
        for (pattern, replacement) in rules {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
