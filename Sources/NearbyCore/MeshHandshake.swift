import Foundation
import CryptoKit

// Android-compatible BMH2 authentication (Android MeshSecurity.kt / MeshControlMessages.kt).
// Persistent P-256 ECDSA identity, fresh P-256 ECDH ephemeral keys, HKDF-SHA-256 directional keys.

public struct NodeId: Hashable, CustomStringConvertible {
    public static let byteCount = 16
    public static let prefixBytes = 6
    public let bytes: Data
    public init(bytes: Data) throws {
        guard bytes.count == NodeId.byteCount else { throw ProtocolError.malformed("A node ID must be 16 bytes") }
        self.bytes = bytes.rebased
    }
    /// First 16 bytes of SHA-256 over the identity key's DER SubjectPublicKeyInfo.
    public static func fromPublicKey(_ spki: Data) -> NodeId {
        try! NodeId(bytes: Data(SHA256.hash(data: spki)).prefix(byteCount))
    }
    public var prefix: Data { bytes.prefix(NodeId.prefixBytes).rebased }
    public var hex: String { bytes.hex }
    public var shortLabel: String { String(hex.prefix(12)) }
    public var description: String { hex }
}

/// The local persistent identity. Production uses the Secure Enclave or a Keychain key (App layer).
public protocol SigningIdentity: AnyObject {
    /// DER SubjectPublicKeyInfo, byte-identical to Java's `PublicKey.encoded`.
    var publicKeyEncoded: Data { get }
    /// DER ECDSA-with-SHA-256 signature over `message`, as Java's `SHA256withECDSA`.
    func sign(_ message: Data) throws -> Data
}

public extension SigningIdentity {
    var nodeId: NodeId { NodeId.fromPublicKey(publicKeyEncoded) }
    var fingerprint: IdentityFingerprint { IdentityFingerprint(publicKey: publicKeyEncoded) }
}

/// Software P-256 identity (tests, simulator, and devices without a Secure Enclave).
public final class SoftwareSigningIdentity: SigningIdentity {
    public let privateKey: P256.Signing.PrivateKey
    public let publicKeyEncoded: Data
    public init(privateKey: P256.Signing.PrivateKey = .init()) {
        self.privateKey = privateKey
        publicKeyEncoded = privateKey.publicKey.derRepresentation
    }
    public convenience init(rawScalar: Data) throws {
        self.init(privateKey: try P256.Signing.PrivateKey(rawRepresentation: rawScalar))
    }
    public func sign(_ message: Data) throws -> Data { try privateKey.signature(for: message).derRepresentation }
}

public struct NodeCapabilities: Equatable {
    public static let encodedBytes = 7
    public static let version: UInt8 = 1
    public static let transportClassic: UInt8 = 1
    public static let transportL2CAP: UInt8 = 1 << 1
    public static let transportGATT: UInt8 = 1 << 2
    /// Android private-call relay chain capability (signed in link hellos only).
    /// EXPERIMENTAL rotating discovery IDs: sends and accepts BDO1 as the first hop record (link hellos only).
    public static let transportDiscoveryOpening: UInt8 = 1 << 3
    public static let transportCallRelay: UInt8 = 1 << 6
    /// Experimental call video fragments (end-to-end hellos only).
    public static let transportVideoFragments: UInt8 = 1 << 7
    public static let codecVP9: UInt8 = 1
    public static let codecAV1: UInt8 = 1 << 1
    /// Proposed (PROTOCOL addendum B, not yet in Android): H.264.
    public static let codecH264: UInt8 = 1 << 2
    public static let codecMask: UInt8 = codecVP9 | codecAV1 | codecH264
    /// End-to-end call hello decode mask: prefer VP9 when the peer can encode it.
    public static let decodePrefersVP9: UInt8 = 1 << 7
    /// Proposed (addendum B): prefer H.264.
    public static let decodePrefersH264: UInt8 = 1 << 6

    public var transportMask: UInt8
    public var encodeCodecMask: UInt8
    public var decodeCodecMask: UInt8
    public var maxBitrateKbps: UInt16
    public var maxChildren: UInt8
    public init(transportMask: UInt8, encodeCodecMask: UInt8, decodeCodecMask: UInt8, maxBitrateKbps: UInt16, maxChildren: UInt8) {
        self.transportMask = transportMask; self.encodeCodecMask = encodeCodecMask; self.decodeCodecMask = decodeCodecMask
        self.maxBitrateKbps = maxBitrateKbps; self.maxChildren = maxChildren
    }
    public var encoded: Data {
        var w = BinaryWriter(); w.byte(NodeCapabilities.version); w.byte(transportMask); w.byte(encodeCodecMask)
        w.byte(decodeCodecMask); w.u16(maxBitrateKbps); w.byte(maxChildren); return w.data
    }
    public init(decoding data: Data) throws {
        guard data.count == NodeCapabilities.encodedBytes else { throw ProtocolError.malformed("Invalid capability message length") }
        var r = BinaryReader(data)
        guard try r.byte() == NodeCapabilities.version else { throw ProtocolError.incompatible("Unsupported capability version") }
        transportMask = try r.byte(); encodeCodecMask = try r.byte(); decodeCodecMask = try r.byte()
        maxBitrateKbps = try r.u16(); maxChildren = try r.byte()
    }
    public func supports(transport bit: UInt8) -> Bool { transportMask & bit != 0 }
}

public enum HandshakeRole: UInt8 { case initiator = 1, responder = 2 }

public enum HandshakePurpose {
    case link, endToEnd
    var signatureContext: Data {
        Data((self == .link ? "BluetoothVideoMesh/LinkHandshake/1" : "BluetoothVideoMesh/EndToEndHandshake/1").utf8)
    }
    var keyContext: Data {
        Data((self == .link ? "BluetoothVideoMesh/LinkSession/1" : "BluetoothVideoMesh/EndToEndSession/1").utf8)
    }
}

public struct SignedHandshakeHello: Equatable {
    public static let magic = Data("BMH2".utf8)
    public static let nonceBytes = 32
    static let maxKeyBytes = 512
    static let maxSignatureBytes = 256
    public var role: HandshakeRole
    public var nodeId: NodeId
    public var identityPublicKey: Data
    public var ephemeralPublicKey: Data
    public var nonce: Data
    public var capabilities: NodeCapabilities
    public var signature: Data

    public var unsignedEncoding: Data {
        var w = BinaryWriter(capacity: 256)
        w.bytes(SignedHandshakeHello.magic); w.byte(role.rawValue); w.bytes(nodeId.bytes)
        w.u16(UInt16(identityPublicKey.count)); w.bytes(identityPublicKey)
        w.u16(UInt16(ephemeralPublicKey.count)); w.bytes(ephemeralPublicKey)
        w.bytes(nonce); w.bytes(capabilities.encoded)
        return w.data
    }
    public func encoded() throws -> Data {
        guard (1...SignedHandshakeHello.maxKeyBytes).contains(identityPublicKey.count),
              (1...SignedHandshakeHello.maxKeyBytes).contains(ephemeralPublicKey.count),
              nonce.count == SignedHandshakeHello.nonceBytes,
              (1...SignedHandshakeHello.maxSignatureBytes).contains(signature.count) else {
            throw ProtocolError.malformed("Invalid handshake field length")
        }
        var w = BinaryWriter(); w.bytes(unsignedEncoding); w.u16(UInt16(signature.count)); w.bytes(signature); return w.data
    }
    public init(role: HandshakeRole, nodeId: NodeId, identityPublicKey: Data, ephemeralPublicKey: Data, nonce: Data, capabilities: NodeCapabilities, signature: Data) {
        self.role = role; self.nodeId = nodeId; self.identityPublicKey = identityPublicKey.rebased
        self.ephemeralPublicKey = ephemeralPublicKey.rebased; self.nonce = nonce.rebased
        self.capabilities = capabilities; self.signature = signature.rebased
    }
    public init(decoding data: Data) throws {
        var r = BinaryReader(data)
        guard try r.bytes(4) == SignedHandshakeHello.magic else { throw ProtocolError.malformed("Invalid handshake message") }
        guard let role = HandshakeRole(rawValue: try r.byte()) else { throw ProtocolError.malformed("Invalid handshake role") }
        self.role = role
        nodeId = try NodeId(bytes: try r.bytes(NodeId.byteCount))
        func bounded(_ maximum: Int) throws -> Data {
            let size = Int(try r.u16())
            guard (1...maximum).contains(size) else { throw ProtocolError.malformed("Invalid handshake field length") }
            return try r.bytes(size)
        }
        identityPublicKey = try bounded(SignedHandshakeHello.maxKeyBytes)
        ephemeralPublicKey = try bounded(SignedHandshakeHello.maxKeyBytes)
        nonce = try r.bytes(SignedHandshakeHello.nonceBytes)
        capabilities = try NodeCapabilities(decoding: try r.bytes(NodeCapabilities.encodedBytes))
        signature = try bounded(SignedHandshakeHello.maxSignatureBytes)
        try r.end()
    }
}

public struct MeshSessionKeys {
    public let peerNodeId: NodeId
    public let sendKey: SymmetricKey
    public let receiveKey: SymmetricKey
}

public final class PendingHandshake {
    public let hello: SignedHandshakeHello
    let ephemeral: P256.KeyAgreement.PrivateKey
    let purpose: HandshakePurpose
    init(hello: SignedHandshakeHello, ephemeral: P256.KeyAgreement.PrivateKey, purpose: HandshakePurpose) {
        self.hello = hello; self.ephemeral = ephemeral; self.purpose = purpose
    }
}

public enum MeshHandshake {
    public static func start(
        identity: SigningIdentity,
        role: HandshakeRole,
        capabilities: NodeCapabilities,
        purpose: HandshakePurpose = .link,
        ephemeral: P256.KeyAgreement.PrivateKey = .init(),
        nonce: Data? = nil
    ) throws -> PendingHandshake {
        let nonceBytes = nonce ?? randomBytes(SignedHandshakeHello.nonceBytes)
        var hello = SignedHandshakeHello(
            role: role, nodeId: identity.nodeId, identityPublicKey: identity.publicKeyEncoded,
            ephemeralPublicKey: ephemeral.publicKey.derRepresentation, nonce: nonceBytes,
            capabilities: capabilities, signature: Data()
        )
        hello.signature = try identity.sign(purpose.signatureContext + hello.unsignedEncoding)
        return PendingHandshake(hello: hello, ephemeral: ephemeral, purpose: purpose)
    }

    public static func verify(_ hello: SignedHandshakeHello, purpose: HandshakePurpose) throws {
        guard hello.nonce.count == SignedHandshakeHello.nonceBytes else { throw ProtocolError.malformed("Invalid handshake nonce") }
        guard NodeId.fromPublicKey(hello.identityPublicKey) == hello.nodeId else {
            throw ProtocolError.authentication
        }
        let key: P256.Signing.PublicKey
        let signature: P256.Signing.ECDSASignature
        do {
            key = try P256.Signing.PublicKey(derRepresentation: hello.identityPublicKey)
            signature = try P256.Signing.ECDSASignature(derRepresentation: hello.signature)
        } catch { throw ProtocolError.authentication }
        guard key.isValidSignature(signature, for: purpose.signatureContext + hello.unsignedEncoding) else {
            throw ProtocolError.authentication
        }
    }

    public static func finish(_ local: PendingHandshake, remote: SignedHandshakeHello) throws -> MeshSessionKeys {
        guard local.hello.role != remote.role else { throw ProtocolError.state("Handshake peers must have opposite roles") }
        try verify(remote, purpose: local.purpose)
        let remoteEphemeral: P256.KeyAgreement.PublicKey
        do { remoteEphemeral = try P256.KeyAgreement.PublicKey(derRepresentation: remote.ephemeralPublicKey) }
        catch { throw ProtocolError.authentication }
        let shared = try local.ephemeral.sharedSecretFromKeyAgreement(with: remoteEphemeral)
        let initiator = local.hello.role == .initiator ? local.hello : remote
        let responder = local.hello.role == .responder ? local.hello : remote
        let transcript = try initiator.encoded() + responder.encoded()
        let salt = Data(SHA256.hash(data: initiator.nonce + responder.nonce))
        let info = local.purpose.keyContext + Data(SHA256.hash(data: transcript))
        let material = shared.withUnsafeBytes { raw in
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(raw)), salt: salt, info: info, outputByteCount: 64)
        }
        let bytes = material.withUnsafeBytes { Data($0) }
        let i2r = SymmetricKey(data: bytes.prefix(32)), r2i = SymmetricKey(data: bytes.suffix(32))
        return local.hello.role == .initiator
            ? MeshSessionKeys(peerNodeId: remote.nodeId, sendKey: i2r, receiveKey: r2i)
            : MeshSessionKeys(peerNodeId: remote.nodeId, sendKey: r2i, receiveKey: i2r)
    }
}

public func randomBytes(_ count: Int) -> Data {
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
    precondition(status == errSecSuccess, "Secure random generator failed")
    return data
}

/// AES-256-GCM with a 96-bit nonce of four zero bytes followed by the big-endian 64-bit sequence.
public enum MeshAead {
    public static let keyBytes = 32
    public static let tagBytes = 16
    static func nonce(_ sequence: UInt64) -> AES.GCM.Nonce {
        var w = BinaryWriter(); w.u32(0); w.u64(sequence)
        return try! AES.GCM.Nonce(data: w.data)
    }
    public static func encrypt(key: SymmetricKey, sequence: UInt64, plaintext: Data, associatedData: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce(sequence), authenticating: associatedData)
        return box.ciphertext + box.tag
    }
    public static func decrypt(key: SymmetricKey, sequence: UInt64, ciphertext: Data, associatedData: Data) throws -> Data {
        guard ciphertext.count >= tagBytes else { throw ProtocolError.authentication }
        do {
            let box = try AES.GCM.SealedBox(nonce: nonce(sequence), ciphertext: ciphertext.dropLast(tagBytes), tag: ciphertext.suffix(tagBytes))
            return try AES.GCM.open(box, using: key, authenticating: associatedData)
        } catch { throw ProtocolError.authentication }
    }
}
