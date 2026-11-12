import XCTest
@testable import NearbyCore

/// Export diagnostics: only Android's kinds of fact, each value checked, nothing that names a person or a device owner.
final class DiagnosticsReportTests: XCTestCase {
    private func facts(model: String = "iPhone15,2", commit: String? = "1a2b3c4", crash: String? = nil) -> DiagnosticsReport.Facts {
        DiagnosticsReport.Facts(appVersion: "0.3.0", appBuild: "3", debugBuild: false, sourceCommit: commit, modelIdentifier: model, mac: false,
                                systemVersion: "27.0", bluetoothPermission: "granted", extendedScanAndConnect: true,
                                codecs: "video decode VP9, hardware; video encode VP9, software; voice Opus 48 kHz", lastCrash: crash)
    }

    func testEveryLineIsAnAndroidKindOfFact() {
        let report = DiagnosticsReport.build(facts())
        let lines = report.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.first, DiagnosticsReport.subject)
        for line in lines.dropFirst() {
            let key = line.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            XCTAssertTrue(DiagnosticsReport.keys.contains(key), "unexpected line: \(line)")
        }
        XCTAssertTrue(report.contains("device: Apple iPhone15,2"))
        XCTAssertTrue(report.contains("last_crash: none"))
    }

    func testADeviceNameOrAnythingElseInTheModelFieldIsNeverExported() {
        for leaked in ["Sam's iPhone", "Asha iPhone", "a1b2c3d4e5f6", "ABCDE-FGHIJ", "me@example.com"] {
            let report = DiagnosticsReport.build(facts(model: leaked))
            XCTAssertFalse(report.contains(leaked), leaked)
            XCTAssertTrue(report.contains("device: Apple unknown"))
        }
    }

    func testOnlyAShortCommitHashIsExported() {
        XCTAssertTrue(DiagnosticsReport.build(facts(commit: "1A2B3C4D")).contains("source_commit: 1a2b3c4d"))
        for bad in [nil, "", "main", "1a2b3c4 extra", String(repeating: "a", count: 40)] {
            XCTAssertTrue(DiagnosticsReport.build(facts(commit: bad)).contains("source_commit: not recorded"), "\(bad ?? "nil")")
        }
    }

    func testTheNewestCrashIsIncludedAndTheReportStaysBounded() {
        let crash = "MeshLive crash report\nCrash: signal 11\nCrashed thread:\n0 MeshLive +0x1234 (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE)"
        let report = DiagnosticsReport.build(facts(crash: crash))
        XCTAssertTrue(report.hasSuffix(crash), "the code locations stay as kept")
        let huge = DiagnosticsReport.build(facts(crash: String(repeating: "x", count: 40_000)))
        XCTAssertLessThanOrEqual(huge.count, DiagnosticsReport.maxCharacters)
    }

    func testCallRowsAreFilteredLikeACrashText() {
        let text = DiagnosticsReport.withCall("MeshLive diagnostics", rows: ["Encrypted end to end", "peer 00:11:22:33:44:55 at me@example.com", ""])
        XCTAssertTrue(text.hasPrefix("MeshLive diagnostics\ncall:\nEncrypted end to end"))
        XCTAssertFalse(text.contains("00:11:22:33:44:55"))
        XCTAssertFalse(text.contains("me@example.com"))
    }

    func testTheCrashFilterRemovesWhatAndroidsFilterRemoves() {
        let scrubbed = CrashReport.scrub("open https://example.org/x failed for \"Asha\" and 'Ravi' at 00:11:22:33:44:55 key QUJDREVGR0hJSktMTU5PUFFSUw1")
        for leaked in ["https://example.org/x", "Asha", "Ravi", "00:11:22:33:44:55", "QUJDREVGR0hJSktMTU5PUFFSUw1"] {
            XCTAssertFalse(scrubbed.contains(leaked), leaked)
        }
    }
}
