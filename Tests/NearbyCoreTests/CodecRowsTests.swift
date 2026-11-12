import XCTest
@testable import NearbyCore

/// AB5 R7: About, Manual video and Export diagnostics name the codecs this device can use, never more than its hello
/// advertises, and the export's codec line always survives the report's 120-character check.
final class CodecRowsTests: XCTestCase {
    private func rows(hevc: CodecRows.Decoder = .none, h264: CodecRows.Decoder = .none,
                      hevcEncoder: Bool = false, h264Encoder: Bool = false) -> CodecRows {
        CodecRows(vp9: .hardware, av1Hardware: true, hevc: hevc, h264: h264,
                  vp9Encoder: true, hevcEncoder: hevcEncoder, h264Encoder: h264Encoder, opus: true)
    }

    private func report(codecs: String) -> String {
        DiagnosticsReport.build(DiagnosticsReport.Facts(appVersion: "0.3.0", appBuild: "3", debugBuild: true, sourceCommit: "1a2b3c4",
                                                        modelIdentifier: "Mac17,1", mac: true, systemVersion: "27.2",
                                                        bluetoothPermission: "granted", extendedScanAndConnect: nil,
                                                        codecs: codecs, lastCrash: nil))
    }

    func testWithTheMastersOffNoHardwareCodecIsNamed() {
        let off = rows()
        for text in [off.decode, off.encode, off.export] {
            XCTAssertFalse(text.contains("HEVC"), text)
            XCTAssertFalse(text.contains("H.264"), text)
            XCTAssertTrue(text.contains("VP9"), text)
        }
        XCTAssertTrue(report(codecs: off.export).contains("codecs: " + off.export), "the masters-off line is exported as it is")
    }

    func testAnEncoderWhoseProbeFailedIsNotNamed() {
        // The AB5B finding on the M5: HEVC decodes, but its encoder output failed the gate; H.264 passed both.
        let mac = rows(hevc: .hardware, h264: .hardware, h264Encoder: true)
        XCTAssertTrue(mac.decode.contains("HEVC"))
        XCTAssertTrue(mac.decode.contains("H.264"))
        XCTAssertFalse(mac.encode.contains("HEVC"), "never offered for encode")
        XCTAssertTrue(mac.encode.contains("H.264"))
        XCTAssertTrue(mac.export.contains("H.264"))
    }

    func testNothingAvailableSaysSo() {
        let none = CodecRows(vp9: .none, av1Hardware: false, hevc: .none, h264: .none,
                             vp9Encoder: false, hevcEncoder: false, h264Encoder: false, opus: false)
        XCTAssertFalse(none.decode.isEmpty)
        XCTAssertFalse(none.encode.isEmpty)
        XCTAssertFalse(none.voice.isEmpty)
        XCTAssertFalse(report(codecs: none.export).contains("codecs: unknown"))
    }

    func testTheExportKeepsEveryCodecWithinTheReportRule() {
        let decoders: [CodecRows.Decoder] = [.none, .hardware, .software]
        let flags = [false, true]
        for vp9 in decoders { for hevc in decoders { for h264 in decoders { for av1 in flags {
            for vp9Encoder in flags { for hevcEncoder in flags { for h264Encoder in flags { for opus in flags {
                let r = CodecRows(vp9: vp9, av1Hardware: av1, hevc: hevc, h264: h264,
                                  vp9Encoder: vp9Encoder, hevcEncoder: hevcEncoder, h264Encoder: h264Encoder, opus: opus)
                XCTAssertTrue(report(codecs: r.export).contains("codecs: " + r.export), "exported as it is: \(r.export)")
                XCTAssertEqual(r.export.contains("HEVC"), hevc != .none || hevcEncoder, r.export)
                XCTAssertEqual(r.export.contains("H.264"), h264 != .none || h264Encoder, r.export)
                XCTAssertEqual(r.export.contains("AV1"), av1, r.export)
            } } } }
        } } } }
    }
}
