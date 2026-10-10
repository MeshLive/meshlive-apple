import Foundation
#if canImport(NearbyCore)
import NearbyCore
#endif
import CryptoKit

/// Noise XX, revision 34, using only CryptoKit primitives. Not an independently audited implementation.
public final class NoiseXX {
    public enum Role { case initiator, responder }
    private let role: Role
    private let s: Curve25519.KeyAgreement.PrivateKey
    private let e: Curve25519.KeyAgreement.PrivateKey
    private var re: Curve25519.KeyAgreement.PublicKey?
    private var rs: Curve25519.KeyAgreement.PublicKey?
    private var ck: Data
    public private(set) var hash: Data
    private var cipher = NoiseCipher()
    private var step = 0
    public var complete: Bool { step == 3 }
    public var remoteIdentity: Data? { rs?.rawRepresentation }

    public init(role: Role, identity: Curve25519.KeyAgreement.PrivateKey, prologue: Data,
                ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil) {
        self.role = role; s = identity; e = ephemeral ?? .init()
        let name = Data("Noise_XX_25519_ChaChaPoly_SHA256".utf8)
        hash = name.count <= 32 ? name + Data(repeating: 0, count: 32 - name.count) : Data(SHA256.hash(data: name))
        ck = hash; mixHash(prologue)
    }

    public func write(payload: Data) throws -> Data {
        guard step < 3, (step == 1) == (role == .responder), payload.count <= 256 else { throw ProtocolError.state("Noise write out of order") }
        var message = Data()
        for token in pattern {
            switch token {
            case "e": let p = e.publicKey.rawRepresentation; message.append(p); mixHash(p)
            case "s": message.append(try encryptAndHash(s.publicKey.rawRepresentation))
            default: try mixDH(token)
            }
        }
        message.append(try encryptAndHash(payload)); step += 1; return message
    }

    public func read(_ message: Data) throws -> Data {
        guard step < 3, (step == 1) == (role == .initiator), message.count <= 512 else { throw ProtocolError.state("Noise read out of order") }
        var reader = BinaryReader(message)
        for token in pattern {
            switch token {
            case "e": let p = try reader.bytes(32); re = try .init(rawRepresentation: p); mixHash(p)
            case "s": rs = try .init(rawRepresentation: decryptAndHash(reader.bytes(cipher.hasKey ? 48 : 32)))
            default: try mixDH(token)
            }
        }
        let payload = try decryptAndHash(reader.bytes(reader.remaining))
        guard payload.count <= 256 else { throw ProtocolError.limit("Noise payload exceeds 256 bytes") }
        step += 1; return payload
    }

    public func split(expectedPeer: Data? = nil) throws -> (send: NoiseCipher, receive: NoiseCipher) {
        guard complete, let peer = remoteIdentity else { throw ProtocolError.state("Incomplete Noise handshake") }
        if let expectedPeer, peer != expectedPeer { throw ProtocolError.authentication }
        let keys = Self.hkdf(ck: ck, input: Data())
        let a = NoiseCipher(key: keys.0), b = NoiseCipher(key: keys.1)
        return role == .initiator ? (a, b) : (b, a)
    }

    private var pattern: [String] {
        switch step { case 0: return ["e"]; case 1: return ["e", "ee", "s", "es"]; default: return ["s", "se"] }
    }
    private func mixHash(_ data: Data) { hash = Data(SHA256.hash(data: hash + data)) }
    private func mixDH(_ token: String) throws {
        guard let re else { throw ProtocolError.state("Missing ephemeral") }
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let publicKey: Curve25519.KeyAgreement.PublicKey
        switch token {
        case "ee": privateKey = e; publicKey = re
        case "es":
            if role == .initiator { guard let rs else { throw ProtocolError.state("Missing static key") }; privateKey = e; publicKey = rs }
            else { privateKey = s; publicKey = re }
        case "se":
            if role == .initiator { privateKey = s; publicKey = re }
            else { guard let rs else { throw ProtocolError.state("Missing static key") }; privateKey = e; publicKey = rs }
        default: throw ProtocolError.state("Unknown Noise token")
        }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let keys = Self.hkdf(ck: ck, input: shared.withUnsafeBytes { Data($0) })
        ck = keys.0; cipher = NoiseCipher(key: keys.1)
    }
    private func encryptAndHash(_ plaintext: Data) throws -> Data {
        let encrypted = try cipher.encrypt(plaintext, ad: hash); mixHash(encrypted); return encrypted
    }
    private func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let decrypted = try cipher.decrypt(ciphertext, ad: hash); mixHash(ciphertext); return decrypted
    }
    static func hkdf(ck: Data, input: Data) -> (Data, Data) {
        let temp = SymmetricKey(data: HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: ck)))
        let first = Data(HMAC<SHA256>.authenticationCode(for: Data([1]), using: temp))
        let second = Data(HMAC<SHA256>.authenticationCode(for: first + Data([2]), using: temp))
        return (first, second)
    }
}

public final class NoiseCipher {
    private let key: SymmetricKey?
    public private(set) var counter: UInt64 = 0
    var hasKey: Bool { key != nil }
    init(key: Data? = nil) { self.key = key.map(SymmetricKey.init(data:)) }
    private func nonce() throws -> ChaChaPoly.Nonce {
        guard counter < 1_000_000_000 else { throw ProtocolError.limit("Session nonce limit reached; reconnect") }
        var bytes = Data(repeating: 0, count: 4)
        for shift in stride(from: 0, through: 56, by: 8) { bytes.append(UInt8((counter >> shift) & 255)) }
        return try ChaChaPoly.Nonce(data: bytes)
    }
    public func encrypt(_ plaintext: Data, ad: Data) throws -> Data {
        guard let key else { return plaintext }
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce(), authenticating: ad)
        counter += 1; return box.ciphertext + box.tag
    }
    public func decrypt(_ ciphertext: Data, ad: Data) throws -> Data {
        guard let key else { return ciphertext }
        guard ciphertext.count >= 16 else { throw ProtocolError.authentication }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonce(), ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
            let plaintext = try ChaChaPoly.open(box, using: key, authenticating: ad); counter += 1; return plaintext
        } catch { throw ProtocolError.authentication }
    }
}
