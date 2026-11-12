import Foundation
import CryptoKit

public enum WifiKeyError: Error, Equatable { case badLength, badPoint, badFrame, badState }

/// Design WF keys and names (PROTOCOL "Keys, names and passwords"), written from the specification; Android's
/// WifiKeys.kt and tools/wifi_reference.py produce the same bytes (Tests/NearbyCoreTests/Fixtures/wifi-vectors.json).
public enum WifiKeys {
    static let keyInfo = Data("BluetoothVideoMesh/WifiUpgrade/1/key".utf8)
    static let bindDomain = Data("BluetoothVideoMesh/WifiUpgrade/1/bind".utf8)
    static let g2hInfo = Data("BluetoothVideoMesh/WifiUpgrade/1/g2h".utf8)
    static let h2gInfo = Data("BluetoothVideoMesh/WifiUpgrade/1/h2g".utf8)
    static let hopSalt = Data("BluetoothVideoMesh/WifiUpgrade/1/hop".utf8)
    /// Share app nearby's 31-character alphabet (no i, l, o, 0, 1).
    static let directAlphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
    public static let keyBytes = 32, ticketBytes = 8, nonceBytes = 32, challengeBytes = 16, preBytes = 16

    /// UW of a call: HKDF-Expand(EXP_e2e, "BluetoothVideoMesh/WifiUpgrade/1/key", 32).
    public static func uwCall(exporter: Data) throws -> Data {
        guard exporter.count == keyBytes else { throw WifiKeyError.badLength }
        return Bmh3Crypto.expand(exporter.rebased, keyInfo)
    }

    /// AW2: UW of a stream or relay hop: HKDF-Expand(HKDF-Extract(salt "BluetoothVideoMesh/WifiUpgrade/1/hop",
    /// IKM = min(kA, kB) | max(kA, kB)), "BluetoothVideoMesh/WifiUpgrade/1/key", 32), the hop's two directional BMS1 keys
    /// ordered bytewise (unsigned) so both ends agree. Equal keys are refused.
    public static func uwHop(keyA: Data, keyB: Data) throws -> Data {
        let a = keyA.rebased, b = keyB.rebased
        guard a.count == keyBytes, b.count == keyBytes else { throw WifiKeyError.badLength }
        // The first differing byte decides; every byte is visited (the keys are secret).
        var order = 0
        for i in 0..<keyBytes {
            let difference = Int(a[i]) - Int(b[i])
            order = order != 0 ? order : difference
        }
        guard order != 0 else { throw WifiKeyError.badState }
        return Bmh3Crypto.expand(Bmh3Crypto.extract(salt: hopSalt, ikm: order < 0 ? a + b : b + a), keyInfo)
    }

    /// "DIRECT-" | a2 | "-" | a6: successive big-endian 16-bit values of HMAC(UW, "ssid" | ticket), each mod 31.
    public static func directSsid(uw: Data, ticket: Data) throws -> String {
        let mac = try attemptMac(uw, "ssid", ticket)
        let chars = (0..<8).map { i -> Character in
            let value = Int(mac[2 * i]) << 8 | Int(mac[2 * i + 1])
            return directAlphabet[value % directAlphabet.count]
        }
        return "DIRECT-" + String(chars[0..<2]) + "-" + String(chars[2..<8])
    }

    /// base64url(HMAC(UW, "psk" | ticket)) without padding: 43 characters.
    public static func directPsk(uw: Data, ticket: Data) throws -> String {
        let text = try attemptMac(uw, "psk", ticket).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return String(text.prefix(43))
    }

    /// pre = HMAC(UW, "pre" | ticket | challenge | e_G | n_G)[0:16].
    static func pre(uw: Data, ticket: Data, challenge: Data, guestPoint: Data, guestNonce: Data) throws -> Data {
        try checkAttempt(uw, ticket)
        guard challenge.count == challengeBytes, guestPoint.count == 65, guestNonce.count == nonceBytes else { throw WifiKeyError.badLength }
        return Bmh3Crypto.hmac(uw, Data("pre".utf8), ticket, challenge, guestPoint, guestNonce).prefix(preBytes).rebased
    }

    /// th = SHA-256("BluetoothVideoMesh/WifiUpgrade/1/bind" | 0x00 | frame1 | frame2 | frame3), whole frames.
    static func transcriptHash(frame1: Data, frame2: Data, frame3: Data) -> Data {
        Bmh3Crypto.sha256(bindDomain + Data([0]) + frame1 + frame2 + frame3)
    }

    /// K = HKDF-Extract(salt = HMAC(UW, "bind" | ticket | th), IKM = dh).
    static func bindSecret(uw: Data, ticket: Data, th: Data, dh: Data) throws -> Data {
        try checkAttempt(uw, ticket)
        guard th.count == 32, dh.count == 32 else { throw WifiKeyError.badLength }
        return Bmh3Crypto.extract(salt: Bmh3Crypto.hmac(uw, Data("bind".utf8), ticket, th), ikm: dh)
    }

    /// The carrier's directional BMS1 keys: k_g2h and k_h2g from K.
    static func carrierKeys(secret: Data, isGuest: Bool) -> WifiCarrierKeys {
        let g2h = Bmh3Crypto.expand(secret, g2hInfo), h2g = Bmh3Crypto.expand(secret, h2gInfo)
        return isGuest ? WifiCarrierKeys(send: g2h, receive: h2g) : WifiCarrierKeys(send: h2g, receive: g2h)
    }

    private static func checkAttempt(_ uw: Data, _ ticket: Data) throws {
        guard uw.count == keyBytes, ticket.count == ticketBytes else { throw WifiKeyError.badLength }
    }

    private static func attemptMac(_ uw: Data, _ label: String, _ ticket: Data) throws -> Data {
        try checkAttempt(uw, ticket)
        return Bmh3Crypto.hmac(uw.rebased, Data(label.utf8), ticket.rebased)
    }
}

/// The BMS1 keys of a bound Wi-Fi carrier, from this side's view (a guest sends with k_g2h, receives with k_h2g).
public struct WifiCarrierKeys: Equatable {
    public let send: Data
    public let receive: Data
    public init(send: Data, receive: Data) { self.send = send; self.receive = receive }
}

/// Fresh randomness of one BWU1 binding; tests inject the vectors' values.
public protocol Bwu1Entropy {
    func ephemeral() -> P256.KeyAgreement.PrivateKey
    func nonce() -> Data
}

public struct SecureBwu1Entropy: Bwu1Entropy {
    public init() {}
    public func ephemeral() -> P256.KeyAgreement.PrivateKey { .init() }
    public func nonce() -> Data { randomBytes(32) }
}

/// The guest half of a BWU1 binding, as the agent drives it.
public protocol Bwu1GuestSession: AnyObject {
    /// Frame 1 (21 bytes) in, frame 2 (126 bytes) out.
    func respond(toFrame1 frame1: Data) throws -> Data
    /// Frame 3 (102 bytes) in: the carrier's keys (point validated, ECDH, th, K, k_g2h, k_h2g).
    func finish(frame3: Data) throws -> WifiCarrierKeys
}

/// BWU1 guest (PROTOCOL "Binding"): one use, frame 1 then frame 3; any error leaves it spent.
public final class Bwu1Guest: Bwu1GuestSession {
    private let uw: Data, ticket: Data, entropy: Bwu1Entropy
    private var ephemeral: P256.KeyAgreement.PrivateKey?
    private var frames: Data?
    private var spent = false

    public init(uw: Data, ticket: Data, entropy: Bwu1Entropy = SecureBwu1Entropy()) {
        self.uw = uw.rebased; self.ticket = ticket.rebased; self.entropy = entropy
    }

    public func respond(toFrame1 frame1: Data) throws -> Data {
        guard !spent, ephemeral == nil else { throw WifiKeyError.badState }
        spent = true
        let challenge: Data
        do { challenge = try Bwu1Wire.challenge(fromFrame1: frame1) } catch { throw WifiKeyError.badFrame }
        let key = entropy.ephemeral(), nonce = entropy.nonce()
        let point = key.publicKey.x963Representation
        let pre = try WifiKeys.pre(uw: uw, ticket: ticket, challenge: challenge, guestPoint: point, guestNonce: nonce)
        let frame2 = Bwu1Wire.frame2(ticket: ticket, guestPoint: point, guestNonce: nonce, pre: pre)
        ephemeral = key; frames = frame1.rebased + frame2; spent = false
        return frame2
    }

    public func finish(frame3: Data) throws -> WifiCarrierKeys {
        guard !spent, let key = ephemeral, let frames else { throw WifiKeyError.badState }
        spent = true; ephemeral = nil; self.frames = nil
        let hostPoint: Data
        do { hostPoint = try Bwu1Wire.parts(ofFrame3: frame3).point } catch { throw WifiKeyError.badFrame }
        // Both coordinates below p and on the curve, as BMH3 (Bmh3Crypto.isOnCurve).
        guard Bmh3Crypto.isOnCurve(hostPoint) else { throw WifiKeyError.badPoint }
        let dh: Data
        do { dh = try Bmh3Crypto.agree(key, hostPoint) } catch { throw WifiKeyError.badPoint }
        let th = WifiKeys.transcriptHash(frame1: frames.prefix(Bwu1Wire.frame1Bytes).rebased,
                                         frame2: frames.suffix(Bwu1Wire.frame2Bytes).rebased, frame3: frame3.rebased)
        let secret = try WifiKeys.bindSecret(uw: uw, ticket: ticket, th: th, dh: dh)
        return WifiKeys.carrierKeys(secret: secret, isGuest: true)
    }
}
