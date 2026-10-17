import Foundation

/// The app's AppLog interface for MeshPeer (the app's AppLog.swift uses UIKit): the same BENCHMARK lines, on stdout.
enum AppLog {
    static func event(_ name: String, _ fields: KeyValuePairs<String, String> = [:]) {
        write("BENCHMARK \(name): " + fields.map { "\($0.key)=\($0.value)" }.joined(separator: " | "))
    }
    static func event(_ name: String, _ fields: [String: String]) {
        write("BENCHMARK \(name): " + fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " | "))
    }
    static func info(_ message: String) { write(message) }
    static func flush() { fflush(stdout) }
    private static func write(_ line: String) {
        print(String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + line.replacingOccurrences(of: "\n", with: " ")); fflush(stdout)
    }
}
