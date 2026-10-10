import Foundation

/// Human-friendly handle of an identity (naming design under review, display only, no wire change):
/// Crockford Base32 of the 48-bit node prefix, `XXXXX-XXXXX`; the short form is the first 5 symbols.
/// Before connecting it is an unauthenticated advert hint; after BMH2 it is authenticated to 48 bits.
/// Only the full fingerprint (QR / safety code) is a security check: a handle is never "verified".
public enum IdentityHandle {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func handle(prefix: Data) -> String? {
        guard prefix.count == NodeId.prefixBytes else { return nil }
        var value: UInt64 = 0
        for byte in prefix { value = value << 8 | UInt64(byte) }
        value <<= 2 // 50 bits: 10 symbols of 5 bits, most significant first
        let symbols = (0..<10).map { i in alphabet[Int((value >> UInt64(45 - 5 * i)) & 0x1f)] }
        return String(symbols[0..<5]) + "-" + String(symbols[5..<10])
    }

    public static func shortHandle(prefix: Data) -> String? { handle(prefix: prefix).map { String($0.prefix(5)) } }

    /// Canonical symbols of typed text (I/L -> 1, O -> 0, hyphens/spaces ignored), or nil on another character.
    static func canonicalSymbols(_ text: String) -> [Character]? {
        var out: [Character] = []
        for ch in text.uppercased() {
            switch ch {
            case "-", " ": continue
            case "I", "L": out.append("1")
            case "O": out.append("0")
            default: guard alphabet.contains(ch) else { return nil }; out.append(ch)
            }
        }
        return out
    }

    /// Parses a typed or spoken full handle: exactly 10 symbols with a zero tail. Returns the 6-byte prefix.
    public static func parse(_ text: String) -> Data? {
        guard let symbols = canonicalSymbols(text), symbols.count == 10 else { return nil }
        var value: UInt64 = 0
        for c in symbols { value = value << 5 | UInt64(alphabet.firstIndex(of: c)!) }
        guard value & 0x3 == 0 else { return nil }
        value >>= 2
        return Data((0..<6).map { UInt8((value >> UInt64(40 - 8 * $0)) & 0xff) })
    }

    /// A five-symbol short handle in canonical form, or nil.
    public static func parseShort(_ text: String) -> String? {
        guard let symbols = canonicalSymbols(text), symbols.count == 5 else { return nil }
        return String(symbols)
    }

    /// Canonical display form of a typed handle.
    public static func canonical(_ text: String) -> String? { parse(text).flatMap { handle(prefix: $0) } }
}
