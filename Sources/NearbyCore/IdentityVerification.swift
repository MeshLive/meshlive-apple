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
public struct VerifiedContact: Codable, Equatable, Identifiable {
    public let fingerprintHex: String
    public var displayName: String
    public let method: String
    public let verifiedAt: Date
    /// Both phones scanned each other's BVMID2 code during one visit of Add contact (nil before; older records have none).
    public var scannedBothWaysAt: Date?
    /// Naming v2 (Android `ContactClaims`): the last verified name this contact called themselves in a call, and the one
    /// the user has seen or ignored. Sealed with the contact; never the title, never sent. Older records have none.
    public var claimedName: String?
    public var acknowledgedClaim: String?
    /// A claimed name the user has not seen yet ("<name> now calls themselves <claim>").
    public var claimPending: Bool { (claimedName ?? "").isEmpty == false && claimedName != acknowledgedClaim }
    public var id: String { fingerprintHex }
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
        let previous = contacts.first { $0.fingerprintHex == confirmed.hex }
        contacts.removeAll { $0.fingerprintHex == confirmed.hex }
        var contact = VerifiedContact(fingerprint: confirmed, displayName: name, method: method)
        contact.scannedBothWaysAt = previous?.scannedBothWaysAt
        contact.claimedName = previous?.claimedName
        contact.acknowledgedClaim = previous?.acknowledgedClaim
        contacts.append(contact)
    }
    public func forget(_ fingerprintHex: String) { contacts.removeAll { $0.fingerprintHex == fingerprintHex } }
    /// Renames a verified contact (the name only this device shows); throws when it is not a contact.
    public func rename(fingerprintHex: String, to name: String) throws {
        guard let index = contacts.firstIndex(where: { $0.fingerprintHex == fingerprintHex }) else { throw ProtocolError.state("Not a contact") }
        contacts[index].displayName = name
    }
    /// Records that both phones scanned each other; true when it changed.
    @discardableResult
    public func markScannedBothWays(fingerprintHex: String, at date: Date = Date()) -> Bool {
        guard let index = contacts.firstIndex(where: { $0.fingerprintHex == fingerprintHex }), contacts[index].scannedBothWaysAt == nil else { return false }
        contacts[index].scannedBothWaysAt = date
        return true
    }
    /// Android `ContactClaimsStore.recordClaim`: the caller passes a name from a signed label that passed the receiver
    /// checks, for a peer that is a verified contact. Only canonical person-name text is kept. The first name is
    /// acknowledged at once; a different later one waits for Use it or Ignore. True when the record changed.
    @discardableResult
    public func recordClaim(fingerprintHex: String, name: String) -> Bool {
        guard LabelText.isCanonical(.personName, name),
              let index = contacts.firstIndex(where: { $0.fingerprintHex == fingerprintHex }),
              contacts[index].claimedName != name else { return false }
        let first = (contacts[index].claimedName ?? "").isEmpty
        contacts[index].claimedName = name
        if first { contacts[index].acknowledgedClaim = name }
        return true
    }
    /// The user saw or ignored the latest claim. True when the record changed.
    @discardableResult
    public func acknowledgeClaim(fingerprintHex: String) -> Bool {
        guard let index = contacts.firstIndex(where: { $0.fingerprintHex == fingerprintHex }), contacts[index].claimPending else { return false }
        contacts[index].acknowledgedClaim = contacts[index].claimedName
        return true
    }
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

/// Android `ContactNameCheck`: a typed contact name.
public enum ContactNameCheck: Equatable {
    case blank
    /// The canonical text that would be saved.
    case valid(String)
    case invalid
}

/// What renaming a contact did (Android `RenameOutcome`), with Android's message.
public enum ContactRenameOutcome: Equatable {
    case renamed(String), empty, invalidName, nameTaken, notFound, unreadable

    public var message: String {
        switch self {
        case .renamed(let name): return "Saved as \(name)"
        case .empty: return "Name can't be empty"
        case .invalidName: return "Use a short name (up to 32 characters) in one alphabet, not an ID."
        case .nameTaken: return "Another contact already has that name. Choose a different one."
        case .notFound: return "That contact is no longer saved."
        case .unreadable: return "Could not save: your list of verified people cannot be read right now."
        }
    }
}

/// Android `ContactNames` and `ContactLabelUniqueness` for Apple's contacts. Apple saves an unnamed contact with its
/// handle as `displayName`; such a contact counts as unnamed (Android's blank name).
public enum ContactNames {
    /// The same text rules as every other person name (`LabelText`, 32 bytes).
    public static func check(_ input: String) -> ContactNameCheck {
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .blank }
        switch LabelText.normalize(.personName, input) {
        case .success(let name): return .valid(name)
        case .failure: return .invalid
        }
    }

    public static func isUnnamed(_ contact: VerifiedContact) -> Bool {
        contact.displayName.isEmpty || contact.displayName == IdentityHandle.handle(prefix: Data(hex: contact.nodePrefixHex) ?? Data())
    }

    /// The rename decision before anything is stored: unknown contact, blank, invalid, a name another contact reads the
    /// same (case- and look-alike-insensitive, `NameReading.same`), or the canonical name to save.
    public static func renameDecision(_ input: String, fingerprintHex: String, contacts: [VerifiedContact]) -> ContactRenameOutcome {
        guard contacts.contains(where: { $0.fingerprintHex == fingerprintHex }) else { return .notFound }
        switch check(input) {
        case .blank: return .empty
        case .invalid: return .invalidName
        case .valid(let name):
            let others = contacts.filter { $0.fingerprintHex != fingerprintHex && !isUnnamed($0) }
            return others.contains { NameReading.same(name, $0.displayName) } ? .nameTaken : .renamed(name)
        }
    }

    /// "Save contact as" starts with your name for them, else the name they shared in this session (canonical only),
    /// else nothing; never a handle.
    public static func suggestion(saved: VerifiedContact?, shared: String?) -> String {
        if let saved, !isUnnamed(saved) { return saved.displayName }
        if let shared, case .valid(let name) = check(shared) { return name }
        return ""
    }

    /// Named contacts first (A-Z, ignoring case), then the unnamed ones by handle.
    public static func sorted(_ contacts: [VerifiedContact]) -> [VerifiedContact] {
        contacts.sorted { a, b in
            let unnamedA = isUnnamed(a), unnamedB = isUnnamed(b)
            if unnamedA != unnamedB { return !unnamedA }
            let titleA = a.displayName.lowercased(), titleB = b.displayName.lowercased()
            if titleA != titleB { return titleA < titleB }
            return a.fingerprintHex < b.fingerprintHex
        }
    }
}

/// Android `ContactReach`: whether Contacts can find a saved contact nearby, and what to tell the user when it cannot.
/// With rotating IDs a contact is recognised only with the presence lease it gave this device; leases move in an
/// answered call or when both devices scan each other's expiring code (Design QL).
public enum ContactReach {
    public enum Hint: String {
        /// A lease is held, or recognition is off: "not found nearby yet" while absent.
        case recognisable
        /// No lease and not scanned both ways: "Ask <name> to scan your code too".
        case askToScan = "ask"
        /// No lease although both scanned: scan again or call once from Nearby.
        case scanAgain = "again"
        /// No lease and expiring codes are off: call once from Nearby.
        case callFromNearby = "nearby"
    }

    public static func hint(recognitionOn: Bool, holdsLease: Bool, scannedBothWays: Bool, meetAvailable: Bool) -> Hint {
        if !recognitionOn || holdsLease { return .recognisable }
        if !meetAvailable { return .callFromNearby }
        return scannedBothWays ? .scanAgain : .askToScan
    }
}
