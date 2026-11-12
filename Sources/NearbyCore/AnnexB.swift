import Foundation

/// AB5 (Design HC): the two codecs whose parameter sets travel in-band, by `BTV3` codec ID (PROTOCOL "Draft: HEVC and
/// H.264 video codecs"). Written from ITU-T H.264 and H.265 and the PROTOCOL rules only.
public enum AnnexBCodec: UInt8, CaseIterable {
    case h264 = 4
    case hevc = 5

    public init?(codecId: UInt8) { self.init(rawValue: codecId) }

    public var label: String { self == .hevc ? "HEVC" : "H264" }
    /// NAL unit header length: 2 bytes for HEVC, 1 for H.264.
    public var headerBytes: Int { self == .hevc ? 2 : 1 }

    /// The NAL unit type from the first header byte.
    public func nalType(_ first: UInt8) -> Int { self == .hevc ? Int((first >> 1) & 0x3f) : Int(first & 0x1f) }
}

/// One NAL unit: its type and its escaped bytes (header included, no start code).
public struct NalUnit: Equatable {
    public let type: Int
    public let bytes: Data
    public init(type: Int, bytes: Data) { self.type = type; self.bytes = bytes }
}

/// A violated rule of PROTOCOL "Access-unit validation" (rules 1 to 11). Rejects are expected input, not crashes.
public struct RuleViolation: Error, Equatable, CustomStringConvertible {
    public let rule: Int
    public let reason: String
    /// The offending NAL unit type, -1 when none applies.
    public let nalType: Int
    public init(rule: Int, reason: String, nalType: Int = -1) { self.rule = rule; self.reason = reason; self.nalType = nalType }
    public var description: String { "rule \(rule): \(reason)" }
}

public enum AnnexBScan: Equatable {
    case ok([NalUnit])
    /// `partial`: the NAL units found before the failure (used only to recognise an IDR).
    case fail(String, partial: [NalUnit])
}

public enum AnnexB {
    public static let maxNalsPerAccessUnit = 8
    public static let parameterSetBudget = 512
    public static let sliceHeaderBudget = 64
    public static let maxParameterSetNalBytes = 1024
    public static let startCode = Data([0, 0, 0, 1])

    /// PROTOCOL rule 1 and "Scanning and escapes". The payload starts with a 3- or 4-byte start code. Inside a NAL unit
    /// `00 00 03` followed by `00`-`03` is an escape, `00 00 03` as the last bytes is allowed, `00 00 03` followed by a
    /// byte above `03` and `00 00 02` reject, `00 00 00` and `00 00 01` end the NAL unit (zero bytes before a start code
    /// are trailing zeros). Fails at the first NAL unit beyond `maxNals`.
    public static func scan(_ payload: Data, codec: AnnexBCodec, maxNals: Int = maxNalsPerAccessUnit) -> AnnexBScan {
        let p = [UInt8](payload)
        let n = p.count
        guard n > 0 else { return .fail("empty_payload", partial: []) }
        var out: [NalUnit] = []
        var s: Int
        if n >= 3, p[0] == 0, p[1] == 0, p[2] == 1 {
            s = 3
        } else if n >= 4, p[0] == 0, p[1] == 0, p[2] == 0, p[3] == 1 {
            s = 4
        } else {
            return .fail("no_start_code", partial: out)
        }
        while true {
            if out.count >= maxNals { return .fail("too_many_nals", partial: out) }
            var k = s
            var end = -1
            var next = -1
            scanning: while k < n {
                if p[k] != 0 || k + 1 >= n || p[k + 1] != 0 {
                    k += 1
                    continue
                }
                if k + 2 >= n {
                    end = k
                    break scanning
                }
                switch p[k + 2] {
                case 0:
                    var q = k + 2
                    while q < n && p[q] == 0 { q += 1 }
                    if q >= n {
                        end = k
                    } else if p[q] == 1 {
                        end = k
                        next = q + 1
                    } else {
                        return .fail("forbidden_zero_run", partial: out)
                    }
                    break scanning
                case 1:
                    end = k
                    next = k + 3
                    break scanning
                case 2:
                    return .fail("forbidden_000002", partial: out)
                case 3:
                    if k + 3 < n && p[k + 3] > 3 { return .fail("bad_escape", partial: out) }
                    k += 3
                default:
                    k += 3
                }
            }
            if end < 0 {
                end = n
                while end > s && p[end - 1] == 0 { end -= 1 }
            }
            if end - s < codec.headerBytes { return .fail("short_nal", partial: out) }
            out.append(NalUnit(type: codec.nalType(p[s]), bytes: Data(p[s..<end])))
            if next < 0 { break }
            s = next
        }
        return .ok(out)
    }

    /// The unescaped bytes of `nal` after its `from`-byte header, at most `budget` of them (the parse budget: a field
    /// beyond it reads past the end and rejects). Only the `03` of an emulation-prevention `00 00 03` is removed.
    public static func unescape(_ nal: Data, from: Int, budget: Int) -> [UInt8] {
        let b = [UInt8](nal)
        var out: [UInt8] = []
        out.reserveCapacity(max(0, min(budget, b.count - from)))
        var zeros = 0
        var i = from
        while i < b.count && out.count < budget {
            let x = b[i]
            i += 1
            if zeros >= 2 && x == 3 {
                zeros = 0
                continue
            }
            out.append(x)
            zeros = x == 0 ? zeros + 1 : 0
        }
        return out
    }

    /// Annex B with 4-byte start codes: the wire form of codecs 4 and 5 (PROTOCOL "Sender rules").
    public static func annexB(_ nals: [Data]) -> Data {
        var out = Data()
        for nal in nals {
            out.append(startCode)
            out.append(nal)
        }
        return out
    }

    /// NAL units behind 4-byte big-endian lengths: VideoToolbox sample data (`nalUnitHeaderLength` 4).
    public static func lengthPrefixed(_ nals: [Data]) -> Data {
        var out = Data()
        for nal in nals {
            let n = UInt32(nal.count)
            out.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)])
            out.append(nal)
        }
        return out
    }

    /// Splits VideoToolbox sample data (big-endian lengths of `lengthSize` 1, 2 or 4 bytes) into NAL units. A zero
    /// length, a length past the end or a truncated length throws.
    public static func nalUnits(lengthPrefixed data: Data, lengthSize: Int = 4) throws -> [Data] {
        guard [1, 2, 4].contains(lengthSize) else { throw ProtocolError.malformed("NAL length size \(lengthSize)") }
        let b = [UInt8](data)
        var i = 0
        var out: [Data] = []
        while i < b.count {
            guard i + lengthSize <= b.count else { throw ProtocolError.malformed("Truncated NAL length") }
            var n = 0
            for j in 0..<lengthSize { n = n << 8 | Int(b[i + j]) }
            i += lengthSize
            guard n > 0, i + n <= b.count else { throw ProtocolError.malformed("Invalid NAL length \(n)") }
            out.append(Data(b[i..<(i + n)]))
            i += n
        }
        return out
    }
}

/// Bit reader over unescaped, budget-limited bytes. Every failure throws a `RuleViolation` of `rule`.
public struct AnnexBBitReader {
    private let data: [UInt8]
    private var bit = 0
    private let rule: Int
    private let nalType: Int

    public init(_ data: [UInt8], rule: Int, nalType: Int = -1) {
        self.data = data
        self.rule = rule
        self.nalType = nalType
    }

    private func violation(_ reason: String) -> RuleViolation { RuleViolation(rule: rule, reason: reason, nalType: nalType) }

    public var bitsLeft: Int { data.count * 8 - bit }

    /// `n` in 0...32 bits, most significant first.
    public mutating func bits(_ n: Int) throws -> UInt64 {
        precondition((0...32).contains(n))
        if n == 0 { return 0 }
        guard bit + n <= data.count * 8 else { throw violation("read past end or parse budget") }
        var v: UInt64 = 0
        for _ in 0..<n {
            v = v << 1 | UInt64((data[bit >> 3] >> UInt8(7 - (bit & 7))) & 1)
            bit += 1
        }
        return v
    }

    public mutating func u(_ n: Int) throws -> Int { Int(try bits(n)) }

    public mutating func flag() throws -> Bool { try bits(1) == 1 }

    public mutating func skip(_ n: Int) throws {
        guard n >= 0, bit + n <= data.count * 8 else { throw violation("skip past end or parse budget") }
        bit += n
    }

    /// Unsigned Exp-Golomb: more than 31 leading zeros rejects, so the value always fits 32 bits.
    public mutating func ue() throws -> UInt64 {
        var zeros = 0
        while true {
            guard bit < data.count * 8 else { throw violation("ue past end or parse budget") }
            let b = (data[bit >> 3] >> UInt8(7 - (bit & 7))) & 1
            bit += 1
            if b == 1 { break }
            zeros += 1
            if zeros > 31 { throw violation("ue with more than 31 leading zeros") }
        }
        let suffix = try bits(zeros)
        return (UInt64(1) << UInt64(zeros)) - 1 + suffix
    }

    /// `ue(v)` that must not exceed `max`.
    public mutating func ue(max: Int) throws -> Int {
        let v = try ue()
        guard v <= UInt64(max) else { throw violation("ue value \(v) above \(max)") }
        return Int(v)
    }

    /// Signed Exp-Golomb (32-bit range).
    public mutating func se() throws -> Int64 {
        let k = try ue()
        return k & 1 == 1 ? Int64((k + 1) / 2) : -Int64(k / 2)
    }
}
