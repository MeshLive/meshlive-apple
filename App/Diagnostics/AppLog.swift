import Foundation
import os
import NearbyCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Structured diagnostics log in the app container (Documents/logs/), Android-style `BENCHMARK <event>: k=v | k=v`
/// lines, also mirrored to the unified log (subsystem io.github.meshlive.app, category app). Pull with
/// `Scripts/pull-logs.sh`. Contains no keys, message text or media; peers appear by 12-hex prefix and handle.
/// A Release build keeps no log file and writes nothing to the unified log; its launch deletes an older log folder.
enum AppLog {
    private static let policy = ReleaseLogPolicy(debugBuild: LabSwitch.isDebugBuild)
    private static let queue = DispatchQueue(label: "io.github.meshlive.app.log", qos: .utility)
    private static let logger = Logger(subsystem: "io.github.meshlive.app", category: "app")
    private static var handle: FileHandle?
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static let uptimeStart = ProcessInfo.processInfo.systemUptime
    private(set) static var fileURL: URL?

    static func start() {
        guard !DesktopPreview.enabled else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("logs", isDirectory: true)
        guard policy.prepare(logDirectory: dir) else { return }
        queue.sync {
            guard handle == nil, !fileLoggingStopped else { return }
            let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = dir.appendingPathComponent("nearby-\(stamp).log")
            #if os(iOS)
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            #else
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            #endif
            handle = try? FileHandle(forWritingTo: url)
            fileURL = url
            prune(dir)
        }
        if policy.runsWatchdogs { startWatchdogs() }
        let info = Bundle.main.infoDictionary ?? [:]
        #if os(macOS)
        event("app_start", ["version": "\(info["CFBundleShortVersionString"] ?? "?")", "build": "\(info["CFBundleVersion"] ?? "?")",
                            "device": "Mac", "macos": ProcessInfo.processInfo.operatingSystemVersionString,
                            "args": ProcessInfo.processInfo.arguments.dropFirst().joined(separator: " "),
                            "bluetooth": MediaPermissions.bluetooth, "microphone": MediaPermissions.microphone, "camera": MediaPermissions.camera,
                            "processAgeMs": "\(processAgeMs)"])
        #else
        event("app_start", ["version": "\(info["CFBundleShortVersionString"] ?? "?")", "build": "\(info["CFBundleVersion"] ?? "?")",
                            "device": UIDevice.current.model, "ios": UIDevice.current.systemVersion,
                            "args": ProcessInfo.processInfo.arguments.dropFirst().joined(separator: " "),
                            "bluetooth": MediaPermissions.bluetooth, "microphone": MediaPermissions.microphone, "camera": MediaPermissions.camera])
        #endif
    }

    /// Whole milliseconds between two uptimes (default: now), for timing fields.
    static func ms(since start: TimeInterval, until end: TimeInterval = ProcessInfo.processInfo.systemUptime) -> String {
        "\(Int(((end - start) * 1000).rounded()))"
    }

    #if os(macOS)
    /// How long this process had run (since exec) when this was read; -1 if unknown. At `app_start` it separates
    /// a slow launch (dyld, AppKit, SwiftUI scene setup) from slow work in the app's own startup.
    static var processAgeMs: Int {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let started = info.kp_proc.p_starttime
        return Int((Date().timeIntervalSince1970 - (Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)) * 1000)
    }
    #endif

    /// The emergency wipe: close the log file and write no more lines to disk in this run.
    static func stopFileLogging() {
        guard policy.writesFile else { return }
        queue.sync { try? handle?.close(); handle = nil; fileURL = nil; fileLoggingStopped = true }
    }
    private static var fileLoggingStopped = false

    /// `BENCHMARK <name>: k=v | k=v` (values sanitized to one line).
    static func event(_ name: String, _ fields: KeyValuePairs<String, String> = [:]) {
        guard policy.writesFile else { return }
        let body = fields.map { "\($0.key)=\($0.value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "/"))" }.joined(separator: " | ")
        write("BENCHMARK \(name): \(body)")
    }

    static func event(_ name: String, _ fields: [String: String]) {
        guard policy.writesFile else { return }
        let body = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "/"))" }.joined(separator: " | ")
        write("BENCHMARK \(name): \(body)")
    }

    static func info(_ message: String) {
        guard policy.writesFile else { return }
        write(message)
    }

    private static func write(_ line: String) {
        guard policy.writesFile else { return }
        // After the user's emergency wipe nothing more is logged in this run, not even to the unified log (lines
        // name peers by prefix).
        if EmergencyWipe.happened { return }
        let uptime = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - uptimeStart)
        let full = "\(formatter.string(from: Date())) +\(uptime)s \(line)\n"
        if policy.mirrorsToSystemLog { logger.info("\(line, privacy: .public)") }
        queue.async { handle?.write(Data(full.utf8)) }
    }

    static func flush() {
        guard policy.writesFile else { return }
        queue.sync { try? handle?.synchronize() }
    }

    private static var watchdog: DispatchSourceTimer?
    private static var lifecycleObservers: [NSObjectProtocol] = []

    /// Logs `main_stall` when the main queue (Core Bluetooth, link pumps, heartbeats) answers more than 750 ms
    /// late, and `app_state` for every lifecycle change, including the device locking.
    static func startWatchdogs() {
        guard policy.runsWatchdogs else { return }
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 0.25)
        var pending = false
        timer.setEventHandler {
            guard !pending else { return }
            pending = true
            let sent = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                pending = false
                let delay = ProcessInfo.processInfo.systemUptime - sent
                if delay > 0.75 { event("main_stall", ["ms": "\(Int(delay * 1000))"]) }
            }
        }
        timer.resume()
        watchdog = timer
        let center = NotificationCenter.default
        #if os(iOS)
        let names: [(Notification.Name, String)] = [
            (UIApplication.willResignActiveNotification, "inactive"), (UIApplication.didBecomeActiveNotification, "active"),
            (UIApplication.didEnterBackgroundNotification, "background"), (UIApplication.willEnterForegroundNotification, "foreground"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "device_locked"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "device_unlocked"),
            (UIApplication.didReceiveMemoryWarningNotification, "memory_warning")]
        for (name, label) in names {
            lifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                event("app_state", ["state": label, "backgroundTimeRemaining": label == "background" ? String(format: "%.0f", min(UIApplication.shared.backgroundTimeRemaining, 9999)) : "-"])
            })
        }
        #else
        for (name, label) in [(NSApplication.willResignActiveNotification, "inactive"),
                              (NSApplication.didBecomeActiveNotification, "active"),
                              (NSApplication.willTerminateNotification, "quit")] {
            lifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                event("app_state", ["state": label])
            })
        }
        #endif
    }

    /// Keeps the newest 20 logs.
    private static func prune(_ dir: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in ReleaseLogPolicy.namesToPrune(names) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
