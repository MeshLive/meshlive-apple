import Foundation

/// The release logging rule, kept in NearbyCore so the package tests run it: a Release build keeps no log file and
/// writes nothing to the unified log, and the first launch of it deletes logs left by an older build. A DEBUG build
/// keeps today's file, system-log mirror and watchdogs.
public struct ReleaseLogPolicy {
    /// The newest log files a DEBUG build keeps (the stamp in the file name sorts by time).
    public static let keptLogFiles = 20

    public let debugBuild: Bool

    public init(debugBuild: Bool) {
        self.debugBuild = debugBuild
    }

    /// Whether a log file may be created and written.
    public var writesFile: Bool { debugBuild }
    /// Whether every line is also mirrored to the unified log.
    public var mirrorsToSystemLog: Bool { debugBuild }
    /// Whether the main-stall and lifecycle watchdogs run (they only log).
    public var runsWatchdogs: Bool { debugBuild }

    /// Prepares the log folder for this run. DEBUG creates it and prunes old logs, and returns true. Release removes
    /// the folder with everything in it (a missing folder is fine) and returns false: logging may not start.
    public func prepare(logDirectory: URL, fileManager: FileManager = .default) -> Bool {
        guard debugBuild else {
            if fileManager.fileExists(atPath: logDirectory.path) {
                try? fileManager.removeItem(at: logDirectory)
            }
            return false
        }
        try? fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let names = (try? fileManager.contentsOfDirectory(atPath: logDirectory.path)) ?? []
        for name in ReleaseLogPolicy.namesToPrune(names) {
            try? fileManager.removeItem(at: logDirectory.appendingPathComponent(name))
        }
        return true
    }

    /// The files to delete from the given names: only `*.log` names are considered, and all but the newest
    /// `keptLogFiles` by descending name are returned. A non-log name is never returned.
    public static func namesToPrune(_ names: [String]) -> [String] {
        let logs = names.filter { $0.hasSuffix(".log") }.sorted(by: >)
        return Array(logs.dropFirst(keptLogFiles))
    }
}
