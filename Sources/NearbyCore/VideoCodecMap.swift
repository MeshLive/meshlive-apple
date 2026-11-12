import Foundation

/// AB5 (Design HC; Android `VideoCodecMap`): the one mapping table of PROTOCOL "Draft: HEVC and H.264 video codecs"
/// between a `BTV3` codec ID, its hello mask bit (link and end-to-end hellos) and its announcement `capabilitySummary`
/// bit. The hello and summary bits differ (summary bit 3 is Android's dual-listening hint and bit 4 relay consent), so a
/// hello mask is never copied into a summary: every summary site goes through `helloMaskToSummary` or `summaryBit`, and
/// every reader through `summaryToHelloMask` or `summaryDecodable`. With both masters off no hello mask carries bit 2 or
/// 3, so every mapped summary equals the bytes sent before AB5.
public enum VideoCodecMap {
    private struct Row {
        let codecId: UInt8
        let helloBit: UInt8
        let summaryBit: UInt8
        let label: String
    }

    private static let rows: [Row] = [
        Row(codecId: StreamProtocol.codecVP9, helloBit: NodeCapabilities.codecVP9, summaryBit: 0x01, label: "VP9"),
        Row(codecId: StreamProtocol.codecAV1, helloBit: NodeCapabilities.codecAV1, summaryBit: 0x02, label: "AV1"),
        Row(codecId: StreamProtocol.codecH264, helloBit: NodeCapabilities.codecH264, summaryBit: 0x04, label: "H264"),
        Row(codecId: StreamProtocol.codecHEVC, helloBit: NodeCapabilities.codecHEVC, summaryBit: 0x80, label: "HEVC"),
    ]

    /// Every hello bit that names a codec (bits 0-3); bits 4 and 7 are end-to-end preferences, not codecs.
    public static let helloCodecBits: UInt8 = rows.reduce(0) { $0 | $1.helloBit }
    /// Every summary bit that names a codec (`0x87`).
    public static let summaryCodecBits: UInt8 = rows.reduce(0) { $0 | $1.summaryBit }
    /// The codec bits a compact (iPhone and Mac) UUID carries while owner question Q-HC2 is open: VP9 and AV1 only.
    /// HEVC has no compact bit, and bit 56 (H.264, pencilled) is never sent (PROTOCOL "Compact discovery").
    public static let compactSummaryCodecBits: UInt8 = 0x03

    /// The hello mask bit of `codecId`, or 0 for an unknown codec.
    public static func helloBit(codecId: UInt8) -> UInt8 { rows.first { $0.codecId == codecId }?.helloBit ?? 0 }

    /// The announcement summary bit of `codecId`, or 0 for an unknown codec.
    public static func summaryBit(codecId: UInt8) -> UInt8 { rows.first { $0.codecId == codecId }?.summaryBit ?? 0 }

    /// Log label: VP9, AV1, H264, HEVC (anything else is labelled VP9, as Android's two-codec labels were).
    public static func label(codecId: UInt8) -> String { rows.first { $0.codecId == codecId }?.label ?? "VP9" }

    /// A hello codec mask as summary codec bits; preference bits (4, 7) and unknown bits are dropped.
    public static func helloMaskToSummary(_ helloMask: UInt8) -> UInt8 {
        rows.reduce(0) { helloMask & $1.helloBit != 0 ? $0 | $1.summaryBit : $0 }
    }

    /// Summary codec bits as a hello mask (to intersect with a decode mask); non-codec summary bits are dropped.
    public static func summaryToHelloMask(_ summary: UInt8) -> UInt8 {
        rows.reduce(0) { summary & $1.summaryBit != 0 ? $0 | $1.helloBit : $0 }
    }

    /// Whether an offer's `summary` names a codec in this device's hello decode mask. The summary is normalised to hello
    /// bits first: summary bit 3 (dual listening) never matches HEVC, and summary bit 7 (HEVC) needs decode bit 3.
    public static func summaryDecodable(_ summary: UInt8, localDecodeHelloMask: UInt8) -> Bool {
        summary != 0 && summaryToHelloMask(summary) & localDecodeHelloMask != 0
    }

    /// The summary of a compact announcement built from a hello mask (call offers and viewer requests of this device).
    public static func compactSummary(helloMask: UInt8) -> UInt8 { helloMaskToSummary(helloMask) & compactSummaryCodecBits }

    /// Codec 4 (H.264) or 5 (HEVC): parameter sets travel in-band in every IDR, and no codec-config packet is allowed.
    public static func isInBandParameterSetCodec(_ codecId: UInt8) -> Bool {
        codecId == StreamProtocol.codecH264 || codecId == StreamProtocol.codecHEVC
    }
}
