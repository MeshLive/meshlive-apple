import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A small file replaced atomically and durably: the new bytes go to a temporary file in the same directory, which is
/// flushed to the disk (`F_FULLFSYNC`, falling back to `fsync`) and renamed over the target before `write` returns
/// (the directory is flushed too, where the file system allows). A crash leaves the old file or the new one.
public enum DurableFile {
    public struct Failure: Error, CustomStringConvertible {
        public let step: String, code: Int32
        public var description: String { "\(step) failed (errno \(code))" }
    }

    /// - Parameter options: extra write options for the new bytes (file protection on iOS).
    public static func write(_ data: Data, to url: URL, options: Data.WritingOptions = []) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: options.subtracting(.atomic).union(.withoutOverwriting))
            try flush(temporary.path, flags: O_RDWR)
            guard rename(temporary.path, url.path) == 0 else { throw Failure(step: "rename", code: errno) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        // The rename is atomic; flushing the directory makes it durable where the file system allows it.
        try? flush(directory.path, flags: O_RDONLY)
    }

    private static func flush(_ path: String, flags: Int32) throws {
        let fd = open(path, flags)
        guard fd >= 0 else { throw Failure(step: "open", code: errno) }
        defer { close(fd) }
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        guard fsync(fd) == 0 else { throw Failure(step: "fsync", code: errno) }
    }
}
