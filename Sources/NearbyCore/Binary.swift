import Foundation

public enum ProtocolError: Error, Equatable, CustomStringConvertible {
    case malformed(String), incompatible(String), state(String), limit(String), authentication, replay
    public var description: String {
        switch self {
        case .malformed(let s), .incompatible(let s), .state(let s), .limit(let s): return s
        case .authentication: return "Authentication failed"
        case .replay: return "Sequence mismatch or replay"
        }
    }
}

/// Big-endian (network order) writer, matching Java's DataOutputStream/ByteBuffer defaults.
public struct BinaryWriter {
    public private(set) var data = Data()
    public init(capacity: Int = 0) { data.reserveCapacity(capacity) }
    public mutating func byte(_ value: UInt8) { data.append(value) }
    public mutating func bytes(_ value: Data) { data.append(value) }
    public mutating func bytes(_ value: [UInt8]) { data.append(contentsOf: value) }
    public mutating func u16(_ value: UInt16) { byte(UInt8(value >> 8)); byte(UInt8(value & 255)) }
    public mutating func u32(_ value: UInt32) { for shift in stride(from: 24, through: 0, by: -8) { byte(UInt8((value >> UInt32(shift)) & 255)) } }
    public mutating func u64(_ value: UInt64) { for shift in stride(from: 56, through: 0, by: -8) { byte(UInt8((value >> UInt64(shift)) & 255)) } }
    public mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
    public mutating func i64(_ value: Int64) { u64(UInt64(bitPattern: value)) }
}

public struct BinaryReader {
    private let data: Data
    public private(set) var offset = 0
    public var remaining: Int { data.count - offset }
    public init(_ data: Data) { self.data = Data(data) }
    public mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw ProtocolError.malformed("Truncated field") }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
    public mutating func byte() throws -> UInt8 { try bytes(1).first! }
    public mutating func u16() throws -> UInt16 { UInt16(try byte()) << 8 | UInt16(try byte()) }
    public mutating func u32() throws -> UInt32 { var v: UInt32 = 0; for _ in 0..<4 { v = (v << 8) | UInt32(try byte()) }; return v }
    public mutating func u64() throws -> UInt64 { var v: UInt64 = 0; for _ in 0..<8 { v = (v << 8) | UInt64(try byte()) }; return v }
    public mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    public mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }
    public mutating func rest() throws -> Data { try bytes(remaining) }
    public func end() throws { guard remaining == 0 else { throw ProtocolError.malformed("Trailing bytes") } }
}

public extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2); var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let value = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(value); index = next
        }
        self = out
    }
    /// Copy whose indices start at zero (slices of Data keep their parent's indices).
    var rebased: Data { Data(self) }
}

/// Constant-time comparison for secrets and fingerprints.
public func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for (x, y) in zip(a, b) { diff |= x ^ y }
    return diff == 0
}
