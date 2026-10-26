import XCTest
@testable import NearbyCore

/// Crash reports made from a MetricKit payload: the crash location and versions, nothing personal.
final class CrashReportTests: XCTestCase {
    private func payload(reason: String) -> Data {
        let json: [String: Any] = [
            "timeStampBegin": "2026-10-26 23:00:00", "timeStampEnd": "2026-10-26 23:59:00",
            "crashDiagnostics": [[
                "version": "1.0.0",
                "diagnosticMetaData": [
                    "appVersion": "0.3.1", "appBuildVersion": "4", "osVersion": "macOS 26.6.2 (25G83)", "deviceType": "Mac16,1",
                    "platformArchitecture": "arm64", "exceptionType": 1, "exceptionCode": 0, "signal": 11,
                    "terminationReason": reason, "pid": 4242, "regionFormat": "IN",
                    "virtualMemoryRegionInfo": "0 is not in any region. Bytes before following region: 4307861504",
                ],
                "callStackTree": ["callStackPerThread": true, "callStacks": [
                    ["threadAttributed": false, "callStackRootFrames": [["binaryName": "libsystem_kernel.dylib", "offsetIntoBinaryTextSegment": 100,
                                                                          "binaryUUID": "11111111-2222-3333-4444-555555555555", "address": 7000000000]]],
                    ["threadAttributed": true, "callStackRootFrames": [[
                        "binaryName": "MeshLive", "offsetIntoBinaryTextSegment": 4660, "binaryUUID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                        "address": 4300000000, "sampleCount": 1,
                        "subFrames": [["binaryName": "/System/Library/Frameworks/SwiftUI.framework/SwiftUI", "offsetIntoBinaryTextSegment": 255,
                                       "binaryUUID": "FFFFFFFF-0000-1111-2222-333333333333", "address": 6400000000]],
                    ]]],
                ]],
            ]],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func testReportHasTheCrashLocationAndVersions() {
        let reports = CrashReport.reports(fromPayloadJSON: payload(reason: "Namespace SIGNAL, Code 11"))
        XCTAssertEqual(reports.count, 1)
        let text = reports[0]
        XCTAssertTrue(text.contains("0.3.1") && text.contains("Mac16,1") && text.contains("signal 11"))
        XCTAssertTrue(text.contains("MeshLive +0x1234 (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE)"), "the crashed thread, innermost frame first")
        XCTAssertTrue(text.contains("SwiftUI +0xff"), "frames name the binary, never its path")
        XCTAssertFalse(text.contains("libsystem_kernel"), "only the crashed thread")
    }

    func testNothingPersonalOrIdentifyingIsKept() {
        let reason = "Assertion failed for person@example.com at /Users/someone/Library/x.swift id 0xdeadbeef node a1b2c3d4e5f6a7b8 call 7F1C6A2E-1111-2222-3333-444455556666 pid 1234567"
        let text = CrashReport.reports(fromPayloadJSON: payload(reason: reason))[0]
        for secret in ["person@example.com", "/Users/someone", "0xdeadbeef", "a1b2c3d4e5f6a7b8", "7F1C6A2E-1111", "1234567", "4242", "4307861504"] {
            XCTAssertFalse(text.contains(secret), "\(secret) must not appear")
        }
        XCTAssertFalse(text.contains("4300000000"), "no addresses")
    }

    func testPayloadWithoutCrashesGivesNoReport() {
        let hangs = try! JSONSerialization.data(withJSONObject: ["hangDiagnostics": [["diagnosticMetaData": [:]]]])
        XCTAssertTrue(CrashReport.reports(fromPayloadJSON: hangs).isEmpty)
        XCTAssertTrue(CrashReport.reports(fromPayloadJSON: Data("not json".utf8)).isEmpty)
    }
}
