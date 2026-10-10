import Foundation
import CryptoKit

// Full-fingerprint identity verification (Android IdentityVerification.kt): fingerprint,
// Signal-style safety code, BVMID1 QR payload. Computed locally from BMH2-authenticated keys.

public struct IdentityFingerprint: Hashable, CustomStringConvertible {
    public static let byteCount = 32
    public let bytes: Data
    public init(publicKey spki: Data) { bytes = Data(SHA256.hash(data: spki)) }
    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else { throw ProtocolError.malformed("A fingerprint must be 32 bytes") }
        self.bytes = bytes.rebased
    }
    /// Exactly 64 lowercase hex digits.
    public init(hex: String) throws {
        guard hex.count == 64, hex.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }), let data = Data(hex: hex) else {
            throw ProtocolError.malformed("A fingerprint must be 64 lowercase hex digits")
        }
        bytes = data
    }
    public var hex: String { bytes.hex }
    public var nodeId: NodeId { try! NodeId(bytes: bytes.prefix(16)) }
    public var nodePrefixHex: String { String(hex.prefix(12)) }
    /// 16 groups of four hex digits.
    public var grouped: String { stride(from: 0, to: 64, by: 4).map { i in String(Array(hex)[i..<i + 4]) }.joined(separator: " ") }
    public var description: String { hex }
    public static func == (a: Self, b: Self) -> Bool { constantTimeEqual(a.bytes, b.bytes) }
    public func hash(into h: inout Hasher) { h.combine(bytes) }
}

public enum SafetyCode {
    public static let iterations = 5_200
    static let context = Data("BluetoothVideoMesh/IdentityVerification/SafetyCode/2".utf8)

    /// One party's 30 digits: SHA-512 iterated over the context and fingerprint, six 40-bit groups mod 100000.
    public static func half(_ fingerprint: IdentityFingerprint) -> String {
        let key = fingerprint.bytes
        var state = Data(SHA512.hash(data: context + key))
        for _ in 1..<iterations { state = Data(SHA512.hash(data: state + key)) }
        return (0..<6).map { group -> String in
            var chunk: UInt64 = 0
            for i in 0..<5 { chunk = chunk << 8 | UInt64(state[group * 5 + i]) }
            let s = String(chunk % 100_000)
            return String(repeating: "0", count: 5 - s.count) + s
        }.joined(separator: " ")
    }
    /// The pair code: both halves sorted as strings; identical on both phones.
    public static func derive(_ a: IdentityFingerprint, _ b: IdentityFingerprint) -> String {
        [half(a), half(b)].sorted().joined(separator: " ")
    }
}

public struct IdentityQrPayload: Equatable {
    public let fingerprint: IdentityFingerprint
    public let displayName: String
    public init(fingerprint: IdentityFingerprint, displayName: String) { self.fingerprint = fingerprint; self.displayName = displayName }
}

public enum IdentityQrCodec {
    public static let magic = "BVMID1"
    public static let maxNameBytes = 64
    static let maxTextChars = magic.count + 2 + 64 + 88

    public static func encode(_ payload: IdentityQrPayload) throws -> String {
        let name = try normalizeName(payload.displayName)
        return "\(magic).\(payload.fingerprint.hex.uppercased()).\(base64url(Data(name.utf8)))"
    }

    public static func parse(_ text: String) throws -> IdentityQrPayload {
        guard text.count <= maxTextChars else { throw ProtocolError.malformed("QR text is too long") }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { throw ProtocolError.malformed("QR text must have three fields") }
        guard parts[0] == magic else { throw ProtocolError.malformed("Not an identity QR code or unsupported version") }
        let hex = parts[1]
        let upper = hex.allSatisfy { ("0"..."9").contains($0) || ("A"..."F").contains($0) }
        let lower = hex.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
        guard upper || lower, let fingerprint = try? IdentityFingerprint(hex: hex.lowercased()) else { throw ProtocolError.malformed("Malformed fingerprint") }
        let field = parts[2]
        guard field.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              let nameBytes = base64urlDecode(field), base64url(nameBytes) == field else {
            throw ProtocolError.malformed("Malformed display name encoding")
        }
        guard let name = String(data: nameBytes, encoding: .utf8), Data(name.utf8) == nameBytes else {
            throw ProtocolError.malformed("Display name is not valid UTF-8")
        }
        return IdentityQrPayload(fingerprint: fingerprint, displayName: try normalizeName(name))
    }

    /// NFC; rejects blank, over 64 UTF-8 bytes, control, format, private-use, surrogate, unassigned, line/paragraph separators.
    public static func normalizeName(_ name: String) throws -> String {
        let normalized = name.precomposedStringWithCanonicalMapping
        guard !normalized.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) else { throw ProtocolError.malformed("Display name is empty") }
        guard normalized.utf8.count <= maxNameBytes else { throw ProtocolError.malformed("Display name exceeds 64 bytes") }
        for scalar in normalized.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .privateUse, .surrogate, .unassigned, .lineSeparator, .paragraphSeparator:
                throw ProtocolError.malformed("Display name contains a control, format, private-use or unassigned character")
            default: break
            }
        }
        return normalized
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func base64urlDecode(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

/// Verified contacts: full fingerprints the user confirmed by QR scan or safety code (persisted by the App).
public struct VerifiedContact: Codable, Equatable {
    public let fingerprintHex: String
    public var displayName: String
    public let method: String
    public let verifiedAt: Date
    public var nodePrefixHex: String { String(fingerprintHex.prefix(12)) }
    public init(fingerprint: IdentityFingerprint, displayName: String, method: String, verifiedAt: Date = Date()) {
        fingerprintHex = fingerprint.hex; self.displayName = displayName; self.method = method; self.verifiedAt = verifiedAt
    }
}

public enum VerificationState: Equatable { case unverified, verified, mismatch }

public final class VerifiedContactBook: PeerIdentityGate {
    public enum Policy { case refuse, warn }
    public private(set) var contacts: [VerifiedContact]
    public var policy: Policy = .refuse
    public var onMismatch: ((NodeId, IdentityFingerprint, VerifiedContact) -> Void)?
    public init(contacts: [VerifiedContact] = []) { self.contacts = contacts }

    public func state(of fingerprint: IdentityFingerprint) -> VerificationState {
        if contacts.contains(where: { $0.fingerprintHex == fingerprint.hex }) { return .verified }
        if contacts.contains(where: { $0.nodePrefixHex == fingerprint.nodePrefixHex }) { return .mismatch }
        return .unverified
    }
    /// Marks verified only when the confirmed fingerprint equals one authenticated in this process.
    public func markVerified(authenticated: IdentityFingerprint?, confirmed: IdentityFingerprint, name: String, method: String) throws {
        guard let authenticated else { throw ProtocolError.state("No authenticated session with this peer") }
        guard authenticated == confirmed else { throw ProtocolError.authentication }
        guard !contacts.contains(where: { $0.nodePrefixHex == confirmed.nodePrefixHex && $0.fingerprintHex != confirmed.hex }) else {
            throw ProtocolError.state("Forget the existing contact with this prefix first")
        }
        contacts.removeAll { $0.fingerprintHex == confirmed.hex }
        contacts.append(VerifiedContact(fingerprint: confirmed, displayName: name, method: method))
    }
    public func forget(_ fingerprintHex: String) { contacts.removeAll { $0.fingerprintHex == fingerprintHex } }
    /// Restores a persisted list (already verified when it was saved).
    public func restore(_ list: [VerifiedContact]) { contacts = list }
    public func reset() { contacts.removeAll() }

    public func admit(peer: NodeId, fingerprint: IdentityFingerprint) throws {
        guard state(of: fingerprint) == .mismatch, let contact = contacts.first(where: { $0.nodePrefixHex == fingerprint.nodePrefixHex }) else { return }
        onMismatch?(peer, fingerprint, contact)
        if policy == .refuse { throw ProtocolError.incompatible("SECURITY IDENTITY MISMATCH: possible impersonation of \(contact.displayName)") }
    }

    /// Equal node ID: verified; same 48-bit prefix with another node ID: mismatch (Android admitForwardedSource).
    public func admitForwardedSource(_ source: NodeId) throws {
        guard let contact = contacts.first(where: { $0.nodePrefixHex == String(source.hex.prefix(12)) }),
              String(contact.fingerprintHex.prefix(32)) != source.hex else { return }
        if policy == .refuse { throw ProtocolError.incompatible("SECURITY IDENTITY MISMATCH: forwarded source is not \(contact.displayName)") }
    }
}
