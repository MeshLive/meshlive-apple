import Foundation
import os
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Structured diagnostics log in the app container (Documents/logs/), Android-style `BENCHMARK <event>: k=v | k=v`
/// lines, also mirrored to the unified log (subsystem org.nearbyintercom, category app). Pull with
/// `Scripts/pull-logs.sh`. Contains no keys, message text or media; peers appear by 12-hex prefix and handle.
enum AppLog {
    private static let queue = DispatchQueue(label: "org.nearbyintercom.log", qos: .utility)
    private static let logger = Logger(subsystem: "org.nearbyintercom", category: "app")
    private static var handle: FileHandle?
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static let uptimeStart = ProcessInfo.processInfo.systemUptime
    private(set) static var fileURL: URL?

    static func start() {
        guard !DesktopPreview.enabled else { return }
        queue.sync {
            guard handle == nil else { return }
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("logs", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
        startWatchdogs()
        let info = Bundle.main.infoDictionary ?? [:]
        #if os(macOS)
        event("app_start", ["version": "\(info["CFBundleShortVersionString"] ?? "?")", "build": "\(info["CFBundleVersion"] ?? "?")",
                            "device": "Mac", "macos": ProcessInfo.processInfo.operatingSystemVersionString,
                            "args": ProcessInfo.processInfo.arguments.dropFirst().joined(separator: " "),
                            "microphone": MediaPermissions.microphone, "camera": MediaPermissions.camera])
        #else
        event("app_start", ["version": "\(info["CFBundleShortVersionString"] ?? "?")", "build": "\(info["CFBundleVersion"] ?? "?")",
                            "device": UIDevice.current.model, "ios": UIDevice.current.systemVersion,
                            "args": ProcessInfo.processInfo.arguments.dropFirst().joined(separator: " "),
                            "microphone": MediaPermissions.microphone, "camera": MediaPermissions.camera])
        #endif
    }

    /// `BENCHMARK <name>: k=v | k=v` (values sanitized to one line).
    static func event(_ name: String, _ fields: KeyValuePairs<String, String> = [:]) {
        let body = fields.map { "\($0.key)=\($0.value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "/"))" }.joined(separator: " | ")
        write("BENCHMARK \(name): \(body)")
    }

    static func event(_ name: String, _ fields: [String: String]) {
        let body = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "/"))" }.joined(separator: " | ")
        write("BENCHMARK \(name): \(body)")
    }

    static func info(_ message: String) { write(message) }

    private static func write(_ line: String) {
        let uptime = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - uptimeStart)
        let full = "\(formatter.string(from: Date())) +\(uptime)s \(line)\n"
        logger.info("\(line, privacy: .public)")
        queue.async { handle?.write(Data(full.utf8)) }
    }

    static func flush() { queue.sync { try? handle?.synchronize() } }

    private static var watchdog: DispatchSourceTimer?
    private static var lifecycleObservers: [NSObjectProtocol] = []

    /// Logs `main_stall` when the main queue (Core Bluetooth, link pumps, heartbeats) answers more than 750 ms
    /// late, and `app_state` for every lifecycle change, including the device locking.
    static func startWatchdogs() {
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
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in files.dropFirst(20) { try? FileManager.default.removeItem(at: old) }
    }
}
