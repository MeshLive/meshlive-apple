import Foundation
import CryptoKit

// EXPERIMENTAL BMH3 identity-hiding handshake (Android Bmh3.kt; PROTOCOL "Experimental BMH3 identity-hiding link
// handshake"; executable specification tools/bmh3_reference.py in the Android repository). Pure state machines over
// byte arrays, byte-for-byte checked against the Android vectors (Bmh3VectorTests). SIGMA in both reveal orders:
// R_FIRST (three messages, the responder's identity block in msg2) and I_FIRST (four messages). The identity key only
// signs; the key agreement is ephemeral P-256, the schedule HKDF-SHA-256 shaped like TLS 1.3, and each handshake
// message is sealed by AES-256-GCM under a one-use key with the all-zero nonce.

public enum Bmh3Purpose: UInt8 {
    case link = 1, endToEnd = 2
    var domain: Data { Data((self == .link ? "BluetoothVideoMesh/BMH3/Link" : "BluetoothVideoMesh/BMH3/EndToEnd").utf8) }
}

public enum Bmh3Order: Equatable { case rFirst, iFirst }

/// What a responder is willing to reveal: everyone (R_FIRST) or only a holder of its lease key.
public enum Bmh3ResponderMode { case everyone, contactsOnly }

/// A handshake failure. The connection closes without any message; `reason` is a fixed class, never an identifier.
public struct Bmh3Failure: Error, Equatable, CustomStringConvertible {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { "BMH3 handshake failed: \(reason)" }
}

public enum Bmh3Wire {
    public static let version: UInt8 = 1
    public static let offerP256: UInt8 = 1
    public static let headerBytes = 8
    public static let ephemeralBytes = 65
    public static let nonceBytes = 32
    public static let tagBytes = 16
    public static let bindingBytes = 11
    public static let spkiBytes = 91
    public static let extensionBytes = 112
    public static let signatureBytes = 64
    public static let macBytes = 32
    public static let msg1Bytes = headerBytes + 1 + ephemeralBytes + nonceBytes + tagBytes
    public static let msg2ClearBytes = headerBytes + ephemeralBytes + nonceBytes
    public static let blockBytes = 2 + spkiBytes + NodeCapabilities.encodedBytes + 2 + extensionBytes + signatureBytes + macBytes
    public static let msg3Bytes = headerBytes + blockBytes + MeshAead.tagBytes
    public static let msg2RFirstBytes = msg2ClearBytes + blockBytes + MeshAead.tagBytes
    public static let flagMayRevealFirst: UInt8 = 0x01
    public static let flagRFirst: UInt8 = 0x01
    public static let magic = Data("BMH3".utf8)
    public static let p256SpkiPrefix = Data([
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08,
        0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ])

    /// True when `frame` starts with the BMH3 magic (the responder's dispatch on the first frame or record).
    public static func isBmh3(_ frame: Data) -> Bool { frame.count >= 4 && frame.prefix(4).rebased == magic }
}

/// The updater's build tag (Android BuildTag): bit 15 = project release key, bits 14..0 = release number 1..32767.
public struct BuildTag: Equatable {
    public let releaseKey: Bool
    public let release: Int
    public init?(releaseKey: Bool, release: Int) {
        guard (1...32767).contains(release) else { return nil }
        self.releaseKey = releaseKey; self.release = release
    }
    public init?(encoded value: UInt16) { self.init(releaseKey: value & 0x8000 != 0, release: Int(value & 0x7fff)) }
    public var encoded: UInt16 { (releaseKey ? 0x8000 : 0) | UInt16(release) }
}

/// Fresh randomness of one handshake. Production draws every value from the platform CSPRNG; tests inject vectors.
public protocol Bmh3Entropy {
    func ephemeral() -> P256.KeyAgreement.PrivateKey
    func nonce() -> Data
    func randomTag() -> Data
}

public struct SecureBmh3Entropy: Bmh3Entropy {
    public init() {}
    public func ephemeral() -> P256.KeyAgreement.PrivateKey { .init() }
    public func nonce() -> Data { randomBytes(Bmh3Wire.nonceBytes) }
    public func randomTag() -> Data { randomBytes(Bmh3Wire.tagBytes) }
}

/// A key and capability set a phone signs one block with; `pseudonym` declares the key a throwaway (extension PSEUDONYM).
public struct Bmh3Presentation {
    public let identity: SigningIdentity
    public let capabilities: NodeCapabilities
    public let pseudonym: Bool
    public init(identity: SigningIdentity, capabilities: NodeCapabilities, pseudonym: Bool = false) throws {
        guard Bmh3Crypto.isCanonicalSpki(identity.publicKeyEncoded) else { throw Bmh3Failure("identity key is not the canonical P-256 SPKI") }
        self.identity = identity; self.capabilities = capabilities; self.pseudonym = pseudonym
    }
}

/// The identity and capabilities this phone presents in one handshake.
public struct Bmh3Config {
    public let purpose: Bmh3Purpose
    public let real: Bmh3Presentation
    public let entropy: Bmh3Entropy
    /// Carried in this phone's encrypted block of a LINK handshake only.
    public let buildTag: BuildTag?
    /// What this phone presents to a peer that is not a recognised contact (rule P); nil: the real identity to everyone.
    public let stranger: Bmh3Presentation?
    public var identity: SigningIdentity { real.identity }

    public init(purpose: Bmh3Purpose, identity: SigningIdentity, capabilities: NodeCapabilities,
                entropy: Bmh3Entropy = SecureBmh3Entropy(), buildTag: BuildTag? = nil, stranger: Bmh3Presentation? = nil) throws {
        self.purpose = purpose
        real = try Bmh3Presentation(identity: identity, capabilities: capabilities, pseudonym: false)
        self.entropy = entropy
        self.buildTag = purpose == .link ? buildTag : nil
        self.stranger = stranger
    }
}

/// Known extensions of one identity block; the area itself is always 112 bytes.
public struct Bmh3Extensions: Equatable {
    public static let typePad: UInt8 = 0, typeOpening: UInt8 = 1, typeIntent: UInt8 = 2, typeBuildTag: UInt8 = 3, typePseudonym: UInt8 = 4
    public static let criticalBit: UInt8 = 0x80
    public static let none = Bmh3Extensions()

    /// The OPENING value `count (1, 0..2) | count x entry (43)`, responder blocks only.
    public var opening: Data?
    /// The INTENT value, msg3 under I_FIRST only.
    public var intent: UInt8?
    public var buildTag: BuildTag?
    /// True when a BUILD_TAG extension was on the wire, even one that decodes to no valid tag.
    var buildTagSeen = false
    public var pseudonym = false

    public init(opening: Data? = nil, intent: UInt8? = nil, buildTag: BuildTag? = nil, pseudonym: Bool = false) {
        self.opening = opening?.rebased; self.intent = intent; self.buildTag = buildTag
        self.buildTagSeen = buildTag != nil; self.pseudonym = pseudonym
    }

    static func validOpening(_ value: Data) -> Bool {
        let v = value.rebased
        return !v.isEmpty && v[0] <= 2 && v.count == 1 + OpeningEntry.bytes * Int(v[0])
    }

    /// The 112-byte area: a PAD of zeros, then the extensions in ascending type order.
    public func encodeArea() throws -> Data {
        var body = BinaryWriter()
        if let opening {
            guard Self.validOpening(opening) else { throw Bmh3Failure("opening malformed") }
            body.byte(Self.typeOpening); body.u16(UInt16(opening.count)); body.bytes(opening)
        }
        if let intent { body.byte(Self.typeIntent); body.u16(1); body.byte(intent) }
        if let buildTag { body.byte(Self.typeBuildTag); body.u16(2); body.u16(buildTag.encoded) }
        if pseudonym { body.byte(Self.typePseudonym); body.u16(0) }
        let spare = Bmh3Wire.extensionBytes - body.data.count
        guard spare >= 0, spare == 0 || spare >= 3 else { throw Bmh3Failure("Extensions do not fit the 112-byte area") }
        var area = BinaryWriter(capacity: Bmh3Wire.extensionBytes)
        if spare > 0 { area.byte(Self.typePad); area.u16(UInt16(spare - 3)); area.bytes(Data(count: spare - 3)) }
        area.bytes(body.data)
        return area.data
    }

    /// Strict parse of a 112-byte area (ascending types, zero padding, no unknown critical type).
    public static func parse(_ area: Data) throws -> Bmh3Extensions {
        let a = area.rebased
        guard a.count == Bmh3Wire.extensionBytes else { throw Bmh3Failure("extension area length") }
        var out = Bmh3Extensions()
        var position = 0
        var last = -1
        while position < a.count {
            guard position + 3 <= a.count else { throw Bmh3Failure("truncated extension") }
            let type = a[position]
            let length = Int(a[position + 1]) << 8 | Int(a[position + 2])
            guard position + 3 + length <= a.count else { throw Bmh3Failure("truncated extension value") }
            guard Int(type) > last else { throw Bmh3Failure("extensions not ascending") }
            last = Int(type)
            let value = a.subdata(in: (position + 3)..<(position + 3 + length))
            switch type {
            case typePad: guard value.allSatisfy({ $0 == 0 }) else { throw Bmh3Failure("non-zero padding") }
            case typeOpening:
                guard validOpening(value) else { throw Bmh3Failure("opening malformed") }
                out.opening = value
            case typeIntent:
                guard value.count == 1 else { throw Bmh3Failure("intent malformed") }
                out.intent = value[value.startIndex]
            case typeBuildTag:
                guard value.count == 2 else { throw Bmh3Failure("build tag malformed") }
                out.buildTagSeen = true
                // A value that is not a valid tag (release 0) is a peer without one, never a failure.
                out.buildTag = BuildTag(encoded: UInt16(value[value.startIndex]) << 8 | UInt16(value[value.startIndex + 1]))
            case typePseudonym:
                guard value.isEmpty else { throw Bmh3Failure("pseudonym marker malformed") }
                out.pseudonym = true
            default:
                if type & criticalBit != 0 { throw Bmh3Failure("unknown critical extension") }
            }
            position += 3 + length
        }
        return out
    }
}

/// The authenticated peer of a handshake, as the local checks see it.
public struct Bmh3Peer {
    /// The canonical 91-byte SPKI.
    public let spki: Data
    public let nodeId: NodeId
    public let capabilities: NodeCapabilities
    public let extensions: Bmh3Extensions
    public var buildTag: BuildTag? { extensions.buildTag }
    /// True when the peer's block declared its key a throwaway: never admit, pin or display it as an identity.
    public var pseudonymous: Bool { extensions.pseudonym }
    public var fingerprint: IdentityFingerprint { IdentityFingerprint(publicKey: spki) }
    /// The opening entries the peer proved in its block, or nil when it sent none.
    public func openingEntries() throws -> [OpeningEntry]? {
        guard let opening = extensions.opening else { return nil }
        return try DiscoveryOpeningCodec.decode(DiscoveryOpeningCodec.magic + Data([DiscoveryOpeningCodec.version]) + opening)
    }
}

/// Session keys and the peer after a completed handshake.
public struct Bmh3Result {
    public let order: Bmh3Order
    public let peer: Bmh3Peer
    public let sendKey: Data
    public let receiveKey: Data
    public let exporter: Data
    /// Responder only: msg1's tag matched one of its lease keys.
    public let tagMatched: Bool
    /// True when this phone itself presented a pseudonym in this handshake.
    public let ownPseudonymous: Bool
    /// The SPKI this phone presented (what a later reveal names as its pseudonym).
    public let ownSpki: Data
}

/// Per-process memory of the last msg1 ephemerals, so a replayed msg1 costs the responder one hash (SR11).
public final class Bmh3ReplayCache {
    private let capacity: Int
    private var order: [Data] = []
    private var seen = Set<Data>()
    private let lock = NSLock()
    public init(capacity: Int = 4_096) { self.capacity = capacity }
    /// True the first time `ephemeral` is seen, false for a repeat.
    public func firstUse(_ ephemeral: Data) -> Bool {
        let key = Data(SHA256.hash(data: ephemeral))
        lock.lock(); defer { lock.unlock() }
        guard seen.insert(key).inserted else { return false }
        order.append(key)
        if order.count > capacity { seen.remove(order.removeFirst()) }
        return true
    }
}

/// One contact tag: `key` is K_tag (from a day lease key), `binding` the advert it is bound to.
public struct Bmh3ContactTag {
    public let key: Data
    public let binding: Data
    /// Initiator side: the contact the selected advert was recognised as; its full node ID must be the answerer's.
    public let expectedPeer: NodeId?
    public init(key: Data, binding: Data, expectedPeer: NodeId? = nil) throws {
        guard key.count == 32, binding.count == Bmh3Wire.bindingBytes else { throw Bmh3Failure("tag key or binding length") }
        self.key = key.rebased; self.binding = binding.rebased; self.expectedPeer = expectedPeer
    }
}

public enum Bmh3Crypto {
    /// P-256 field prime p and group order n, big-endian.
    static let p = Data(hex: "ffffffff00000001000000000000000000000000ffffffffffffffffffffffff")!
    static let n = Data(hex: "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")!
    static let tagInfo = Data("BluetoothVideoMesh/BMH3/ContactTag/1".utf8)

    public static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    public static func hmac(_ key: Data, _ parts: Data...) -> Data {
        var mac = HMAC<SHA256>(key: SymmetricKey(data: key))
        for part in parts { mac.update(data: part) }
        return Data(mac.finalize())
    }

    public static func extract(salt: Data, ikm: Data) -> Data { hmac(salt, ikm) }

    /// One 32-byte HKDF-Expand block: HMAC(prk, info | 0x01).
    public static func expand(_ prk: Data, _ info: Data) -> Data { hmac(prk, info, Data([1])) }

    static func label(_ purpose: Bmh3Purpose, _ secret: Data, _ label: String) -> Data {
        expand(secret, purpose.domain + Data("/".utf8) + Data(label.utf8))
    }

    static func th(_ purpose: Bmh3Purpose, _ bytes: Data) -> Data { sha256(purpose.domain + Data([0]) + bytes) }

    public static func signatureContext(_ purpose: Bmh3Purpose, role: String, transcriptHash: Data) -> Data {
        purpose.domain + Data("/\(role) signature".utf8) + Data([0]) + transcriptHash
    }

    public static func contactTagKey(leaseKey: Data) throws -> Data {
        guard leaseKey.count == 32 else { throw Bmh3Failure("A lease key is 32 bytes") }
        return expand(leaseKey, tagInfo)
    }

    static func contactTag(_ purpose: Bmh3Purpose, tagKey: Data, msg1WithZeroTag: Data, binding: Data) -> Data {
        hmac(tagKey, th(purpose, msg1WithZeroTag), binding).prefix(Bmh3Wire.tagBytes).rebased
    }

    /// The selected advert's 6 bytes, the role and, for a version 2 (fixed prefix) advert only, the initiator's wall epoch.
    public static func advertBinding(selected6: Data, role: UInt8, wallEpoch: Int64?) -> Data {
        var w = BinaryWriter(); w.bytes(selected6.prefix(6).rebased); w.byte(role); w.u32(UInt32(truncatingIfNeeded: wallEpoch ?? 0))
        return w.data
    }

    /// True when `a < b` as big-endian unsigned integers of equal length.
    static func less(_ a: Data, _ b: Data) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x < y }
        return false
    }

    /// A 65-byte SEC1 point: `04`, both coordinates below p, on the curve (CryptoKit validates the curve equation).
    public static func isOnCurve(_ point: Data) -> Bool {
        let pt = point.rebased
        guard pt.count == Bmh3Wire.ephemeralBytes, pt[0] == 4 else { return false }
        guard less(pt.subdata(in: 1..<33), p), less(pt.subdata(in: 33..<65), p) else { return false }
        return (try? P256.KeyAgreement.PublicKey(x963Representation: pt)) != nil
    }

    public static func isCanonicalSpki(_ spki: Data) -> Bool {
        let s = spki.rebased
        guard s.count == Bmh3Wire.spkiBytes, s.prefix(Bmh3Wire.p256SpkiPrefix.count).rebased == Bmh3Wire.p256SpkiPrefix else { return false }
        return isOnCurve(s.suffix(from: Bmh3Wire.p256SpkiPrefix.count).rebased)
    }

    /// DER `SEQUENCE { INTEGER r, INTEGER s }` to the raw 64-byte `r | s`.
    public static func derToRaw(_ der: Data) throws -> Data {
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: der) else { throw Bmh3Failure("signature encoding") }
        return signature.rawRepresentation
    }

    /// Raw `r | s` to DER, after the explicit `0 < r, s < n` range check.
    public static func rawToDer(_ raw: Data) throws -> Data {
        try rawSignature(raw).derRepresentation
    }

    static func rawSignature(_ raw: Data) throws -> P256.Signing.ECDSASignature {
        let r = raw.rebased
        guard r.count == Bmh3Wire.signatureBytes else { throw Bmh3Failure("signature length") }
        let rr = r.prefix(32).rebased, ss = r.suffix(32).rebased
        guard rr.contains(where: { $0 != 0 }), ss.contains(where: { $0 != 0 }), less(rr, n), less(ss, n) else {
            throw Bmh3Failure("signature range")
        }
        guard let signature = try? P256.Signing.ECDSASignature(rawRepresentation: r) else { throw Bmh3Failure("signature encoding") }
        return signature
    }

    /// Verifies a raw P1363 signature by the canonical SPKI `spki` over `message`.
    public static func verify(spki: Data, message: Data, raw: Data) throws -> Bool {
        let signature = try rawSignature(raw)
        guard let key = try? P256.Signing.PublicKey(derRepresentation: spki) else { throw Bmh3Failure("identity key invalid") }
        return key.isValidSignature(signature, for: message)
    }

    /// ECDH x coordinate, as Java's KeyAgreement("ECDH").
    static func agree(_ privateKey: P256.KeyAgreement.PrivateKey, _ peerPoint: Data) throws -> Data {
        guard isOnCurve(peerPoint), let peer = try? P256.KeyAgreement.PublicKey(x963Representation: peerPoint) else { throw Bmh3Failure("point not on curve") }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return shared.withUnsafeBytes { Data($0) }
    }

    static func seal(_ key: Data, aad: Data, _ plaintext: Data) throws -> Data {
        try MeshAead.encrypt(key: SymmetricKey(data: key), sequence: 0, plaintext: plaintext, associatedData: aad)
    }

    static func unseal(_ key: Data, aad: Data, _ ciphertext: Data) throws -> Data {
        do { return try MeshAead.decrypt(key: SymmetricKey(data: key), sequence: 0, ciphertext: ciphertext, associatedData: aad) }
        catch { throw Bmh3Failure("aead") }
    }
}

/// State shared by both roles: transcript, handshake keys, identity block build and open.
public class Bmh3Party {
    let config: Bmh3Config
    let role: String
    var transcript = Data()
    var ephemeral: P256.KeyAgreement.PrivateKey?
    var hs = Data(), keyHsI2r = Data(), keyHsR2i = Data(), finishedI = Data(), finishedR = Data(), derived = Data()
    var peer: Bmh3Peer?
    var order: Bmh3Order?
    var result: Bmh3Result?
    /// What this phone presents in its block: the real identity until a role decides to present the stranger one.
    var presented: Bmh3Presentation

    init(config: Bmh3Config, role: String) {
        self.config = config; self.role = role; presented = config.real
    }

    /// The order chosen once msg1 (responder) or msg2 (initiator) was processed.
    public var chosenOrder: Bmh3Order? { order }
    /// True once the session keys exist.
    public var isComplete: Bool { result != nil }
    public func finalResult() throws -> Bmh3Result {
        guard let result else { throw ProtocolError.state("BMH3 handshake not complete") }
        return result
    }

    func ephemeralPublic() -> Data { ephemeral!.publicKey.x963Representation }

    func deriveHandshakeKeys(peerEphemeral: Data) throws {
        guard let ephemeral else { throw ProtocolError.state("BMH3 ephemeral missing") }
        let dh = try Bmh3Crypto.agree(ephemeral, peerEphemeral)
        let th2 = Bmh3Crypto.th(config.purpose, transcript)
        hs = Bmh3Crypto.extract(salt: th2, ikm: dh)
        keyHsI2r = Bmh3Crypto.label(config.purpose, hs, "hs i2r")
        keyHsR2i = Bmh3Crypto.label(config.purpose, hs, "hs r2i")
        finishedI = Bmh3Crypto.label(config.purpose, hs, "finished i")
        finishedR = Bmh3Crypto.label(config.purpose, hs, "finished r")
        derived = Bmh3Crypto.label(config.purpose, hs, "derived")
    }

    /// This phone's identity block over the transcript so far plus the carrying message's cleartext part.
    func buildBlock(carrierPrefix: Data, extensions: Bmh3Extensions) throws -> Data {
        var prefix = BinaryWriter(capacity: Bmh3Wire.blockBytes)
        prefix.u16(UInt16(Bmh3Wire.spkiBytes))
        prefix.bytes(presented.identity.publicKeyEncoded)
        prefix.bytes(presented.capabilities.encoded)
        prefix.u16(UInt16(Bmh3Wire.extensionBytes))
        // A pseudonymous block never carries an opening: the salt of a rotating ID confirms the owner of a node ID.
        let own = Bmh3Extensions(opening: presented.pseudonym ? nil : extensions.opening, intent: extensions.intent,
                                 buildTag: config.buildTag, pseudonym: presented.pseudonym)
        prefix.bytes(try own.encodeArea())
        let prefixBytes = prefix.data
        let thSig = Bmh3Crypto.th(config.purpose, transcript + carrierPrefix + prefixBytes)
        let der = try presented.identity.sign(Bmh3Crypto.signatureContext(config.purpose, role: role, transcriptHash: thSig))
        let signature = try Bmh3Crypto.derToRaw(der)
        let key = role == "Initiator" ? finishedI : finishedR
        let mac = Bmh3Crypto.hmac(key, Bmh3Crypto.th(config.purpose, transcript + carrierPrefix + prefixBytes + signature))
        let block = prefixBytes + signature + mac
        guard block.count == Bmh3Wire.blockBytes else { throw ProtocolError.state("BMH3 block size") }
        return block
    }

    /// Opens the peer's block: structure, signature under the peer's role label, finished MAC, extension rules, self-connection.
    func openBlock(carrierPrefix: Data, block raw: Data, peerRole: String, message: Int, blockOrder: Bmh3Order) throws -> Bmh3Peer {
        let block = raw.rebased
        guard block.count == Bmh3Wire.blockBytes else { throw Bmh3Failure("identity block length") }
        var r = BinaryReader(block)
        guard Int(try r.u16()) == Bmh3Wire.spkiBytes else { throw Bmh3Failure("identity length") }
        let spki = try r.bytes(Bmh3Wire.spkiBytes)
        let capabilityBytes = try r.bytes(NodeCapabilities.encodedBytes)
        guard Int(try r.u16()) == Bmh3Wire.extensionBytes else { throw Bmh3Failure("extension area length") }
        let extensionBytes = try r.bytes(Bmh3Wire.extensionBytes)
        let prefixBytes = block.prefix(r.offset).rebased
        let signature = try r.bytes(Bmh3Wire.signatureBytes)
        let mac = try r.bytes(Bmh3Wire.macBytes)
        guard Bmh3Crypto.isCanonicalSpki(spki) else { throw Bmh3Failure("identity key invalid") }
        let capabilities: NodeCapabilities
        do { capabilities = try NodeCapabilities(decoding: capabilityBytes) } catch { throw Bmh3Failure("capabilities") }
        let prefixTranscript = transcript + carrierPrefix + prefixBytes
        let context = Bmh3Crypto.signatureContext(config.purpose, role: peerRole, transcriptHash: Bmh3Crypto.th(config.purpose, prefixTranscript))
        guard try Bmh3Crypto.verify(spki: spki, message: context, raw: signature) else { throw Bmh3Failure("signature") }
        let peerFinished = peerRole == "Initiator" ? finishedI : finishedR
        let expected = Bmh3Crypto.hmac(peerFinished, Bmh3Crypto.th(config.purpose, prefixTranscript + signature))
        guard constantTimeEqual(expected, mac) else { throw Bmh3Failure("finished mac") }
        let extensions = try Bmh3Extensions.parse(extensionBytes)
        try checkPlacement(extensions, responderBlock: peerRole == "Responder", message: message, blockOrder: blockOrder)
        if spki == config.identity.publicKeyEncoded || (config.stranger.map { spki == $0.identity.publicKeyEncoded } ?? false) {
            throw Bmh3Failure("self-connection")
        }
        return Bmh3Peer(spki: spki, nodeId: NodeId.fromPublicKey(spki), capabilities: capabilities, extensions: extensions)
    }

    private func checkPlacement(_ extensions: Bmh3Extensions, responderBlock: Bool, message: Int, blockOrder: Bmh3Order) throws {
        if extensions.buildTagSeen && config.purpose != .link { throw Bmh3Failure("build tag outside the link handshake") }
        if extensions.opening != nil && !responderBlock { throw Bmh3Failure("opening outside a responder block") }
        // A throwaway key must not open a rotating ID: the salt would let a prober confirm the owner of a node ID.
        if extensions.opening != nil && extensions.pseudonym { throw Bmh3Failure("opening in a pseudonymous block") }
        if extensions.intent != nil && (responderBlock || message != 3 || blockOrder != .iFirst) {
            throw Bmh3Failure("intent outside msg3 of an I_FIRST handshake")
        }
    }

    func finishSession(peer: Bmh3Peer, order: Bmh3Order, initiator: Bool, tagMatched: Bool) -> Bmh3Result {
        let thFinal = Bmh3Crypto.th(config.purpose, transcript)
        let ms = Bmh3Crypto.extract(salt: thFinal, ikm: derived)
        let i2r = Bmh3Crypto.label(config.purpose, ms, "app i2r")
        let r2i = Bmh3Crypto.label(config.purpose, ms, "app r2i")
        let exporter = Bmh3Crypto.label(config.purpose, ms, "exporter")
        hs = Data(); derived = Data(); keyHsI2r = Data(); keyHsR2i = Data(); finishedI = Data(); finishedR = Data()
        ephemeral = nil
        return Bmh3Result(order: order, peer: peer, sendKey: initiator ? i2r : r2i, receiveKey: initiator ? r2i : i2r,
                          exporter: exporter, tagMatched: tagMatched, ownPseudonymous: presented.pseudonym,
                          ownSpki: presented.identity.publicKeyEncoded)
    }

    func header(_ message: UInt8, _ flags: UInt8) -> Data {
        Bmh3Wire.magic + Data([Bmh3Wire.version, config.purpose.rawValue, message, flags])
    }

    /// Validates magic, version, purpose and message number; returns the flags byte.
    func parseHeader(_ bytes: Data, _ message: UInt8) throws -> UInt8 {
        let b = bytes.rebased
        guard b.count >= Bmh3Wire.headerBytes, Bmh3Wire.isBmh3(b) else { throw Bmh3Failure("magic") }
        guard b[4] == Bmh3Wire.version else { throw Bmh3Failure("version") }
        guard b[5] == config.purpose.rawValue else { throw Bmh3Failure("purpose") }
        guard b[6] == message else { throw Bmh3Failure("message number") }
        return b[7]
    }
}

/// The initiator. `mayRevealFirst` stays false (SR1): I_FIRST is refused. `contactTag` is the selected contact's K_tag
/// (else 16 random bytes are sent); with a tag only R_FIRST is acceptable. `checkResponder` runs after the responder's
/// block verified and before this side reveals anything: it throws to abort.
public final class Bmh3Initiator: Bmh3Party {
    private let mayRevealFirst: Bool
    private let contactTag: Bmh3ContactTag?
    private let intent: UInt8?
    private let checkResponder: (Bmh3Peer) throws -> Void
    private var msg1 = Data()

    public init(config: Bmh3Config, mayRevealFirst: Bool = false, contactTag: Bmh3ContactTag? = nil, intent: UInt8? = nil,
                checkResponder: @escaping (Bmh3Peer) throws -> Void = { _ in }) {
        self.mayRevealFirst = mayRevealFirst; self.contactTag = contactTag; self.intent = intent; self.checkResponder = checkResponder
        super.init(config: config, role: "Initiator")
        // Rule P: the real key goes only to the contact the caller looked for; anyone else meets the stranger presentation.
        if contactTag == nil, let stranger = config.stranger { presented = stranger }
    }

    public func message1() throws -> Data {
        guard msg1.isEmpty else { throw ProtocolError.state("message1 already produced") }
        ephemeral = config.entropy.ephemeral()
        let nonce = config.entropy.nonce()
        let body = header(1, mayRevealFirst ? Bmh3Wire.flagMayRevealFirst : 0) + Data([Bmh3Wire.offerP256]) + ephemeralPublic() + nonce
        let tag = contactTag.map { Bmh3Crypto.contactTag(config.purpose, tagKey: $0.key, msg1WithZeroTag: body + Data(count: Bmh3Wire.tagBytes), binding: $0.binding) }
            ?? config.entropy.randomTag()
        msg1 = body + tag
        guard msg1.count == Bmh3Wire.msg1Bytes else { throw ProtocolError.state("BMH3 msg1 size") }
        transcript.append(msg1)
        return msg1
    }

    /// Returns msg3. After it, `isComplete` is true for R_FIRST; for I_FIRST msg4 is still expected.
    public func onMessage2(_ raw: Data) throws -> Data {
        guard !msg1.isEmpty, order == nil else { throw ProtocolError.state("unexpected message2") }
        let message = raw.rebased
        let flags = try parseHeader(message, 2)
        guard flags & ~Bmh3Wire.flagRFirst == 0 else { throw Bmh3Failure("reserved msg2 flags") }
        guard message.count >= Bmh3Wire.msg2ClearBytes else { throw Bmh3Failure("short msg2") }
        let clear = message.prefix(Bmh3Wire.msg2ClearBytes).rebased
        let rest = message.suffix(from: Bmh3Wire.msg2ClearBytes).rebased
        let peerEphemeral = clear.subdata(in: Bmh3Wire.headerBytes..<(Bmh3Wire.headerBytes + Bmh3Wire.ephemeralBytes))
        guard Bmh3Crypto.isOnCurve(peerEphemeral) else { throw Bmh3Failure("ephemeral") }
        guard peerEphemeral != ephemeralPublic() else { throw Bmh3Failure("reflected ephemeral") }
        transcript.append(clear)
        try deriveHandshakeKeys(peerEphemeral: peerEphemeral)
        if flags & Bmh3Wire.flagRFirst != 0 {
            order = .rFirst
            guard rest.count == Bmh3Wire.blockBytes + MeshAead.tagBytes else { throw Bmh3Failure("msg2 length") }
            let block = try Bmh3Crypto.unseal(keyHsR2i, aad: clear, rest)
            let responder = try openBlock(carrierPrefix: Data(), block: block, peerRole: "Responder", message: 2, blockOrder: .rFirst)
            transcript.append(block)
            peer = responder
            try checkResponder(responder)
            // Defence in depth: a real key never answers a throwaway (a contact's node ID cannot be one).
            if responder.pseudonymous && !presented.pseudonym { throw Bmh3Failure("pseudonymous answerer to a real caller") }
            return try buildMessage3(.rFirst)
        }
        order = .iFirst
        guard rest.isEmpty else { throw Bmh3Failure("I_FIRST msg2 carries ciphertext") }
        if contactTag != nil { throw Bmh3Failure("tag sent, I_FIRST answered") }
        if !mayRevealFirst { throw Bmh3Failure("I_FIRST refused") }
        return try buildMessage3(.iFirst)
    }

    private func buildMessage3(_ chosen: Bmh3Order) throws -> Data {
        let h3 = header(3, 0)
        let extensions = chosen == .iFirst ? Bmh3Extensions(intent: intent) : .none
        let block = try buildBlock(carrierPrefix: h3, extensions: extensions)
        let message3 = h3 + (try Bmh3Crypto.seal(keyHsI2r, aad: h3, block))
        transcript.append(h3); transcript.append(block)
        if chosen == .rFirst, let peer { result = finishSession(peer: peer, order: chosen, initiator: true, tagMatched: false) }
        return message3
    }

    public func onMessage4(_ raw: Data) throws {
        guard order == .iFirst, result == nil else { throw ProtocolError.state("unexpected message4") }
        let message = raw.rebased
        guard try parseHeader(message, 4) == 0 else { throw Bmh3Failure("reserved msg4 flags") }
        guard message.count == Bmh3Wire.headerBytes + Bmh3Wire.blockBytes + MeshAead.tagBytes else { throw Bmh3Failure("msg4 length") }
        let h4 = message.prefix(Bmh3Wire.headerBytes).rebased
        let block = try Bmh3Crypto.unseal(keyHsR2i, aad: h4, message.suffix(from: Bmh3Wire.headerBytes).rebased)
        let responder = try openBlock(carrierPrefix: h4, block: block, peerRole: "Responder", message: 4, blockOrder: .iFirst)
        transcript.append(h4); transcript.append(block)
        peer = responder
        // I_FIRST: this phone revealed first, but the answerer is still bound to the selected advert before keys exist.
        try checkResponder(responder)
        result = finishSession(peer: responder, order: .iFirst, initiator: true, tagMatched: false)
    }
}

/// The responder. `mode` picks the order (SR4); `tagChecks` are the K_tag values of its own lease keys.
/// `beforeReply` runs for an R_FIRST msg1 without a matching tag, before a key is drawn or a signature made (the signing
/// budget); it may throw. `admitInitiator` runs after the initiator's block verified: false refuses it.
public final class Bmh3Responder: Bmh3Party {
    private let mode: Bmh3ResponderMode
    private let tagChecks: [Bmh3ContactTag]
    private let opening: Data?
    private let replayCache: Bmh3ReplayCache?
    private let beforeReply: (Bool) throws -> Void
    private let admitInitiator: (Bmh3Peer, Bool) throws -> Bool
    private var started = false
    public private(set) var contactTagMatched = false

    public init(config: Bmh3Config, mode: Bmh3ResponderMode = .everyone, tagChecks: [Bmh3ContactTag] = [], opening: Data? = nil,
                replayCache: Bmh3ReplayCache? = nil, beforeReply: @escaping (Bool) throws -> Void = { _ in },
                admitInitiator: @escaping (Bmh3Peer, Bool) throws -> Bool = { _, _ in true }) {
        self.mode = mode; self.tagChecks = tagChecks; self.opening = opening?.rebased; self.replayCache = replayCache
        self.beforeReply = beforeReply; self.admitInitiator = admitInitiator
        super.init(config: config, role: "Responder")
    }

    /// Returns msg2. A `Bmh3Failure` means: close silently, send nothing.
    public func onMessage1(_ raw: Data) throws -> Data {
        guard !started else { throw ProtocolError.state("message1 already handled") }
        started = true
        let message = raw.rebased
        let flags = try parseHeader(message, 1)
        guard flags & ~Bmh3Wire.flagMayRevealFirst == 0 else { throw Bmh3Failure("reserved msg1 flags") }
        guard message.count == Bmh3Wire.msg1Bytes else { throw Bmh3Failure("msg1 length") }
        guard message[Bmh3Wire.headerBytes] == Bmh3Wire.offerP256 else { throw Bmh3Failure("suite") }
        let peerEphemeral = message.subdata(in: (Bmh3Wire.headerBytes + 1)..<(Bmh3Wire.headerBytes + 1 + Bmh3Wire.ephemeralBytes))
        guard Bmh3Crypto.isOnCurve(peerEphemeral) else { throw Bmh3Failure("ephemeral") }
        if let replayCache, !replayCache.firstUse(peerEphemeral) { throw Bmh3Failure("replay") }
        let body = message.prefix(Bmh3Wire.msg1Bytes - Bmh3Wire.tagBytes).rebased
        let tag = message.suffix(Bmh3Wire.tagBytes).rebased
        // Evaluate every candidate (no early exit): the cost does not depend on which key matched.
        var matched = false
        for check in tagChecks {
            let expected = Bmh3Crypto.contactTag(config.purpose, tagKey: check.key, msg1WithZeroTag: body + Data(count: Bmh3Wire.tagBytes), binding: check.binding)
            if constantTimeEqual(expected, tag) { matched = true }
        }
        contactTagMatched = matched
        let chosen: Bmh3Order = mode == .everyone || matched ? .rFirst : .iFirst
        if chosen == .iFirst && flags & Bmh3Wire.flagMayRevealFirst == 0 { throw Bmh3Failure("order conflict") }
        if chosen == .rFirst && !matched { try beforeReply(false) }
        order = chosen
        // Rule P: an R_FIRST answer to a msg1 whose tag did not match is the stranger presentation, if there is one.
        if chosen == .rFirst && !matched, let stranger = config.stranger { presented = stranger }
        // Fresh values for every handshake (SR5): one instance serves one msg1 only.
        ephemeral = config.entropy.ephemeral()
        guard ephemeralPublic() != peerEphemeral else { throw Bmh3Failure("reflected ephemeral") }
        let nonce = config.entropy.nonce()
        transcript.append(message)
        let msg2Clear = header(2, chosen == .rFirst ? Bmh3Wire.flagRFirst : 0) + ephemeralPublic() + nonce
        transcript.append(msg2Clear)
        try deriveHandshakeKeys(peerEphemeral: peerEphemeral)
        if chosen == .iFirst { return msg2Clear }
        let block = try buildBlock(carrierPrefix: Data(), extensions: Bmh3Extensions(opening: opening))
        transcript.append(block)
        return msg2Clear + (try Bmh3Crypto.seal(keyHsR2i, aad: msg2Clear, block))
    }

    /// Returns msg4 for I_FIRST, nil for R_FIRST (the handshake is complete).
    public func onMessage3(_ raw: Data) throws -> Data? {
        guard let chosen = order, result == nil else { throw ProtocolError.state("unexpected message3") }
        let message = raw.rebased
        guard try parseHeader(message, 3) == 0 else { throw Bmh3Failure("reserved msg3 flags") }
        guard message.count == Bmh3Wire.msg3Bytes else { throw Bmh3Failure("msg3 length") }
        let h3 = message.prefix(Bmh3Wire.headerBytes).rebased
        let block = try Bmh3Crypto.unseal(keyHsI2r, aad: h3, message.suffix(from: Bmh3Wire.headerBytes).rebased)
        let initiator = try openBlock(carrierPrefix: h3, block: block, peerRole: "Initiator", message: 3, blockOrder: chosen)
        transcript.append(h3); transcript.append(block)
        peer = initiator
        guard try admitInitiator(initiator, contactTagMatched) else {
            throw Bmh3Failure(chosen == .rFirst ? "initiator refused" : "stranger gets a silent close")
        }
        if chosen == .rFirst {
            result = finishSession(peer: initiator, order: chosen, initiator: false, tagMatched: contactTagMatched)
            return nil
        }
        let h4 = header(4, 0)
        let block4 = try buildBlock(carrierPrefix: h4, extensions: Bmh3Extensions(opening: opening))
        let message4 = h4 + (try Bmh3Crypto.seal(keyHsR2i, aad: h4, block4))
        transcript.append(h4); transcript.append(block4)
        result = finishSession(peer: initiator, order: chosen, initiator: false, tagMatched: contactTagMatched)
        return message4
    }
}
