import XCTest
@testable import NearbyCore

/// AB5 step 2: Annex B framing and the bitstream conversion vectors (PROTOCOL "Access-unit validation", "Scanning and
/// escapes"; "Decoder input": Apple converts to 4-byte length-prefixed NAL units). The HEVC access unit is the M31's
/// hardware encoder output (Exynos HEVC, 352x288 Main, codec retest of 2026-10-28): its VPS, SPS and PPS, and the first
/// 40 bytes of its IDR slice.
final class AnnexBTests: XCTestCase {
    static let vps = Data(hex: "40010c01ffff0160000003000003000003000003003c2c09")!
    static let sps = Data(hex: "4201010160000003000003000003000003003ca00b080485a2d2bb04bb9a8101010040")!
    static let pps = Data(hex: "4401c0667c0cc640")!
    static let idrSlice = Data(hex: "2801af80dd2f30f8f6afffe7deaff0e9ba23a87bcc3b4df1c694b77ed974b0fd608318b51778d5e8")!
    static let keyFrame = Data(hex: "0000000140010c01ffff0160000003000003000003000003003c2c09000000014201010160000003000003000003000003003ca00b080485a2d2bb04bb9a8101010040000000014401c0667c0cc640000000012801af80dd2f30f8f6afffe7deaff0e9ba23a87bcc3b4df1c694b77ed974b0fd608318b51778d5e8")!
    static let lengthPrefixedKeyFrame = Data(hex: "0000001840010c01ffff0160000003000003000003000003003c2c09000000234201010160000003000003000003000003003ca00b080485a2d2bb04bb9a8101010040000000084401c0667c0cc640000000282801af80dd2f30f8f6afffe7deaff0e9ba23a87bcc3b4df1c694b77ed974b0fd608318b51778d5e8")!
    /// The same access unit with 3-byte start codes, a zero byte before one start code and two trailing zero bytes.
    static let threeByteKeyFrame = Data(hex: "00000140010c01ffff0160000003000003000003000003003c2c09000000014201010160000003000003000003000003003ca00b080485a2d2bb04bb9a81010100400000014401c0667c0cc6400000012801af80dd2f30f8f6afffe7deaff0e9ba23a87bcc3b4df1c694b77ed974b0fd608318b51778d5e80000")!

    private func nals(_ payload: Data, _ codec: AnnexBCodec = .hevc) throws -> [NalUnit] {
        guard case .ok(let found) = AnnexB.scan(payload, codec: codec) else { XCTFail("scan failed: \(AnnexB.scan(payload, codec: codec))"); return [] }
        return found
    }

    private func failure(_ payload: Data, _ codec: AnnexBCodec = .hevc) -> String? {
        if case .fail(let reason, _) = AnnexB.scan(payload, codec: codec) { return reason }
        return nil
    }

    func testAnnexBAndLengthPrefixedVectorsConvertBothWays() throws {
        let units = try nals(Self.keyFrame)
        XCTAssertEqual(units.map(\.type), [32, 33, 34, 20])
        XCTAssertEqual(units.map(\.bytes), [Self.vps, Self.sps, Self.pps, Self.idrSlice])
        XCTAssertEqual(AnnexB.lengthPrefixed(units.map(\.bytes)), Self.lengthPrefixedKeyFrame)
        let back = try AnnexB.nalUnits(lengthPrefixed: Self.lengthPrefixedKeyFrame)
        XCTAssertEqual(back, units.map(\.bytes))
        XCTAssertEqual(AnnexB.annexB(back), Self.keyFrame)
        // VideoToolbox may use 1- or 2-byte lengths in principle; they convert the same way.
        let twoByte = Data([0x00, 0x08]) + Self.pps
        XCTAssertEqual(try AnnexB.nalUnits(lengthPrefixed: twoByte, lengthSize: 2), [Self.pps])
    }

    func testThreeByteStartCodesAndTrailingZerosGiveTheSameUnits() throws {
        XCTAssertEqual(try nals(Self.threeByteKeyFrame).map(\.bytes), [Self.vps, Self.sps, Self.pps, Self.idrSlice])
    }

    func testMalformedLengthPrefixedDataThrows() {
        XCTAssertThrowsError(try AnnexB.nalUnits(lengthPrefixed: Data([0, 0, 0, 0])), "zero length")
        XCTAssertThrowsError(try AnnexB.nalUnits(lengthPrefixed: Data([0, 0, 0, 9, 1, 2])), "past the end")
        XCTAssertThrowsError(try AnnexB.nalUnits(lengthPrefixed: Data([0, 0, 0])), "truncated length")
        XCTAssertThrowsError(try AnnexB.nalUnits(lengthPrefixed: Self.pps, lengthSize: 3), "length size 3")
    }

    /// Escapes inside a NAL unit: `00 00 03 xx` with xx 00..03 is an escape, `00 00 03` at the end is allowed, `00 00 03 04`
    /// and `00 00 02` reject, a zero run must end in a start code.
    func testEscapesAndForbiddenSequences() {
        let start = AnnexB.startCode
        var badEscape = Self.idrSlice
        badEscape.replaceSubrange(10..<14, with: [0x00, 0x00, 0x03, 0x04])
        XCTAssertEqual(failure(start + badEscape), "bad_escape")
        XCTAssertEqual(failure(start + Data([0x02, 0x01, 0x40, 0x00, 0x00, 0x02, 0x55])), "forbidden_000002")
        XCTAssertEqual(failure(start + Data([0x02, 0x01, 0x40, 0x00, 0x00, 0x00, 0x05])), "forbidden_zero_run")
        XCTAssertNil(failure(start + Data([0x02, 0x01, 0x40, 0x00, 0x00, 0x03, 0x01, 0x55, 0x00, 0x00, 0x03])), "escape, then 00 00 03 at the end")
        XCTAssertEqual(failure(Self.keyFrame.dropFirst(4)), "no_start_code")
        XCTAssertEqual(failure(Data()), "empty_payload")
        XCTAssertEqual(failure(start + Data([0x02])), "short_nal")
        XCTAssertEqual(failure(Data((0..<9).flatMap { _ -> [UInt8] in [0, 0, 0, 1, 0x4e, 0x01, 0x05] })), "too_many_nals")
    }

    func testUnescapeRemovesOnlyEmulationPreventionBytesWithinTheBudget() {
        let nal = Data([0x42, 0x01, 0x00, 0x00, 0x03, 0x01, 0x00, 0x00, 0x03, 0x00, 0x07])
        XCTAssertEqual(AnnexB.unescape(nal, from: 2, budget: 512), [0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x07])
        XCTAssertEqual(AnnexB.unescape(nal, from: 2, budget: 3), [0x00, 0x00, 0x01])
    }

    func testBitReaderReadsExpGolombAndRejectsPastItsBudget() throws {
        // 1 | 010 | 011 | 00100 | 0001000 | 00000 (past the end): ue 0, 1, 2, 3, 7, then a rule 8 reject
        var r = AnnexBBitReader([0b1010_0110, 0b0100_0001, 0b0000_0000], rule: 8)
        XCTAssertEqual(try r.ue(), 0)
        XCTAssertEqual(try r.ue(), 1)
        XCTAssertEqual(try r.ue(), 2)
        XCTAssertEqual(try r.ue(), 3)
        XCTAssertEqual(try r.ue(), 7)
        XCTAssertThrowsError(try r.ue()) { XCTAssertEqual(($0 as? RuleViolation)?.rule, 8) }
        var signed = AnnexBBitReader([0b0100_1100], rule: 9) // se: 010 -> +1, 011 -> -1
        XCTAssertEqual(try signed.se(), 1)
        XCTAssertEqual(try signed.se(), -1)
        var zeros = AnnexBBitReader([UInt8](repeating: 0, count: 5), rule: 4) // 40 zero bits: more than 31 leading zeros
        XCTAssertThrowsError(try zeros.ue()) { XCTAssertEqual(($0 as? RuleViolation)?.rule, 4) }
        var bounded = AnnexBBitReader([0b0001_0000], rule: 10) // ue 7
        XCTAssertThrowsError(try bounded.ue(max: 6))
    }
}
