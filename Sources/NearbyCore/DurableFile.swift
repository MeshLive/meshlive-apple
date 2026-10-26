import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A small file replaced atomically, reported as stored only once flushed: the new bytes go to a temporary file in the
/// same directory, which is flushed with `F_FULLFSYNC` (the drive's write cache included), renamed over the target,
/// and the directory is flushed with `F_FULLFSYNC` so the rename itself is on the disk. `write` returns only when every
/// step succeeded; any failure (including a file system that refuses `F_FULLFSYNC`, with no fallback to a weaker
/// `fsync`) throws, so the caller treats the record as not stored and fails closed. After a crash the target holds the
/// old bytes or the new ones; after a throw it may hold either.
public enum DurableFile {
    public struct Failure: Error, CustomStringConvertible {
        public let step: String, code: Int32
        public var description: String { "\(step) failed (errno \(code))" }
    }

    /// - Parameter options: extra write options for the new bytes (file protection on iOS).
    public static func write(_ data: Data, to url: URL, options: Data.WritingOptions = []) throws {
        try write(data, to: url, options: options, fullSync: { fcntl($0, F_FULLFSYNC) })
    }

    /// `fullSync` is the flush call (tests inject a failing one).
    static func write(_ data: Data, to url: URL, options: Data.WritingOptions, fullSync: (Int32) -> Int32) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: options.subtracting(.atomic).union(.withoutOverwriting))
            try flush(temporary.path, flags: O_RDWR, fullSync: fullSync)
            guard rename(temporary.path, url.path) == 0 else { throw Failure(step: "rename", code: errno) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        try flush(directory.path, flags: O_RDONLY, fullSync: fullSync)
    }

    /// The flush of `path`; throws when it cannot be done (no silent fallback).
    private static func flush(_ path: String, flags: Int32, fullSync: (Int32) -> Int32) throws {
        let fd = open(path, flags)
        guard fd >= 0 else { throw Failure(step: "open", code: errno) }
        defer { close(fd) }
        guard fullSync(fd) == 0 else { throw Failure(step: "F_FULLFSYNC", code: errno) }
    }
}
