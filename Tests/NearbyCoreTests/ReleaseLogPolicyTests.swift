import XCTest
@testable import NearbyCore

/// The release logging rule: a Release build keeps no log file and writes nothing to the unified log, and the first
/// launch of it deletes logs left by an older build. A DEBUG build keeps today's file, mirror and watchdogs.
final class ReleaseLogPolicyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ReleaseLogPolicyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var logDirectory: URL { root.appendingPathComponent("logs", isDirectory: true) }

    private func write(_ names: [String], in directory: URL? = nil) throws {
        let directory = directory ?? logDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in names {
            try Data("line\n".utf8).write(to: directory.appendingPathComponent(name))
        }
    }

    private func names(in directory: URL? = nil) -> [String] {
        let directory = directory ?? logDirectory
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private func logNames(_ count: Int) -> [String] {
        (0..<count).map { String(format: "nearby-2026-01-01T00-00-%02d.000Z.log", $0) }
    }

    func testAReleaseBuildWritesNoFileAndMirrorsNothing() {
        let policy = ReleaseLogPolicy(debugBuild: false)
        XCTAssertFalse(policy.writesFile)
        XCTAssertFalse(policy.mirrorsToSystemLog)
        XCTAssertFalse(policy.runsWatchdogs)
        XCTAssertFalse(policy.prepare(logDirectory: logDirectory), "release logging may not start")
        XCTAssertFalse(FileManager.default.fileExists(atPath: logDirectory.path), "release creates no log folder")
    }

    func testADebugBuildKeepsTheLogFileTheSystemLogAndTheWatchdogs() {
        let policy = ReleaseLogPolicy(debugBuild: true)
        XCTAssertTrue(policy.writesFile)
        XCTAssertTrue(policy.mirrorsToSystemLog)
        XCTAssertTrue(policy.runsWatchdogs)
    }

    func testTheFirstReleaseLaunchDeletesEveryExistingLogAndTheFolder() throws {
        try write(logNames(25) + ["notes.txt"])
        let sibling = root.appendingPathComponent("crash-reports", isDirectory: true)
        try write(["report.txt"], in: sibling)
        let policy = ReleaseLogPolicy(debugBuild: false)

        XCTAssertFalse(policy.prepare(logDirectory: logDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logDirectory.path), "the whole log folder is gone")
        XCTAssertEqual(names(in: sibling), ["report.txt"], "a sibling folder is untouched")

        XCTAssertFalse(policy.prepare(logDirectory: logDirectory), "a second launch with no folder is still false")
        XCTAssertFalse(FileManager.default.fileExists(atPath: logDirectory.path))
    }

    func testAReleaseLaunchNeverRecreatesTheFolder() {
        let policy = ReleaseLogPolicy(debugBuild: false)
        XCTAssertFalse(policy.prepare(logDirectory: logDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logDirectory.path))
    }

    func testADebugLaunchKeepsTheNewestTwentyLogsAndNothingElse() throws {
        let all = logNames(25)
        try write(all + ["notes.txt"])
        let policy = ReleaseLogPolicy(debugBuild: true)

        XCTAssertTrue(policy.prepare(logDirectory: logDirectory))
        let remaining = names()
        XCTAssertEqual(remaining.filter { $0.hasSuffix(".log") }, Array(all.suffix(20)), "the 20 newest names stay")
        XCTAssertTrue(remaining.contains("notes.txt"), "a non-log file is never deleted")
        XCTAssertEqual(remaining.count, 21)
    }

    func testPruningOnlyEverNamesLogFiles() {
        let all = logNames(25)
        let pruned = ReleaseLogPolicy.namesToPrune(all + ["notes.txt", "nearby.log.bak"])
        XCTAssertEqual(Set(pruned), Set(all.prefix(5)), "the five oldest log names")
        XCTAssertTrue(pruned.allSatisfy { $0.hasSuffix(".log") })
        XCTAssertTrue(ReleaseLogPolicy.namesToPrune(Array(all.prefix(20))).isEmpty)
        XCTAssertTrue(ReleaseLogPolicy.namesToPrune(["notes.txt", "nearby.log.bak"]).isEmpty)
    }
}
