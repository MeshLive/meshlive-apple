import Foundation
import CryptoKit

// BME1 endpoint content and the BMH2 endpoint handshake carried in BMS1 type 4
// (Android EndToEndVideoSecurity.kt).

public enum EndToEndContentType: UInt8 {
    case streamHeader = 1, mediaPacket = 2, streamState = 4, keyFrameRequest = 5
    case privateCallSignal = 6, groupKey = 7, streamEndAck = 8
    /// Experimental call video fragments: accepted only by an endpoint that advertised them.
    case videoFragment = 9
    /// Experimental peer labels (BLB1 container): accepted only by an endpoint that advertised hello bit 5.
    case labels = 10
}

public enum StreamLifecycleState: UInt8 {
    case live = 1, paused = 2, ended = 3
    public var encoded: Data { Data([rawValue]) }
    public init(decoding payload: Data) throws {
        guard payload.count == 1, let state = StreamLifecycleState(rawValue: payload.first!) else {
            throw ProtocolError.malformed("Invalid stream-state message")
        }
        self = state
    }
}

public enum RouteWithdrawal: UInt8 {
    case localCapacity = 1
    public init(decoding payload: Data) throws {
        guard payload.count == 1, let value = RouteWithdrawal(rawValue: payload.first!) else {
            throw ProtocolError.malformed("Invalid route-control message")
        }
        self = value
    }
    public var encoded: Data { Data([rawValue]) }
}

public struct EndToEndContentRecord: Equatable {
    public let type: EndToEndContentType
    public let sequence: UInt64
    public let flags: UInt8
    public let payload: Data
}

public enum EndToEndContentProtocol {
    public static let magic = Data("BME1".utf8)
    public static let headerBytes = 18
    /// StreamProtocol.MAX_PAYLOAD_BYTES + packet header.
    public static let maxPlaintextBytes = StreamProtocol.maxPayloadBytes + StreamProtocol.packetHeaderBytes

    static func header(type: EndToEndContentType, sequence: UInt64, flags: UInt8, ciphertextBytes: Int) -> Data {
        var w = BinaryWriter(capacity: headerBytes)
        w.bytes(magic); w.byte(type.rawValue); w.u64(sequence); w.byte(flags); w.u32(UInt32(ciphertextBytes)); return w.data
    }

    public struct Metadata { public let type: EndToEndContentType; public let sequence: UInt64; public let flags: UInt8; public let ciphertextBytes: Int }

    /// Validates the clear header exactly as Android's `inspect` (relays can call this without keys).
    public static func inspect(_ encoded: Data, acceptVideoFragments: Bool = false, acceptLabels: Bool = false) throws -> Metadata {
        guard encoded.count >= headerBytes else { throw ProtocolError.malformed("Truncated end-to-end content") }
        var r = BinaryReader(encoded.prefix(headerBytes).rebased)
        guard try r.bytes(4) == magic else { throw ProtocolError.malformed("Invalid end-to-end content magic") }
        let typeValue = try r.byte()
        guard let type = EndToEndContentType(rawValue: typeValue), type != .videoFragment || acceptVideoFragments, type != .labels || acceptLabels else {
            throw ProtocolError.malformed("Unknown end-to-end content type \(typeValue)")
        }
        let sequence = try r.u64()
        guard sequence <= UInt64(Int64.max) else { throw ProtocolError.malformed("Invalid end-to-end content sequence") }
        let flags = try r.byte()
        let size = Int(try r.i32())
        guard size >= MeshAead.tagBytes, size <= maxPlaintextBytes + MeshAead.tagBytes else {
            throw ProtocolError.malformed("Invalid end-to-end content size \(size)")
        }
        guard encoded.count == headerBytes + size else { throw ProtocolError.malformed("Truncated end-to-end content payload") }
        guard type == .mediaPacket || type == .videoFragment || flags == 0 else {
            throw ProtocolError.malformed("Non-media end-to-end content cannot carry packet flags")
        }
        return Metadata(type: type, sequence: sequence, flags: flags, ciphertextBytes: size)
    }
}

public final class EndToEndContentSealer {
    private let key: SymmetricKey
    public private(set) var nextSequence: UInt64 = 0
    public init(key: SymmetricKey) { self.key = key }
    public func seal(_ type: EndToEndContentType, flags: UInt8 = 0, _ payload: Data) throws -> Data {
        guard payload.count <= EndToEndContentProtocol.maxPlaintextBytes else { throw ProtocolError.limit("End-to-end content is too large") }
        let header = EndToEndContentProtocol.header(type: type, sequence: nextSequence, flags: flags, ciphertextBytes: payload.count + MeshAead.tagBytes)
        let ciphertext = try MeshAead.encrypt(key: key, sequence: nextSequence, plaintext: payload, associatedData: header)
        nextSequence += 1
        return header + ciphertext
    }
}

/// Accepts increasing sequence gaps (media drops) but rejects replay and reordering.
public final class EndToEndContentOpener {
    private let key: SymmetricKey
    public private(set) var nextSequence: UInt64 = 0
    public var acceptVideoFragments = false
    public var acceptLabels = false
    public init(key: SymmetricKey) { self.key = key }
    /// Copy of the key for a forwarded-stream grant (viewer-forwarder only).
    public var keyBytes: Data { key.withUnsafeBytes { Data($0) } }
    public func open(_ encoded: Data) throws -> EndToEndContentRecord {
        let data = encoded.rebased
        let meta = try EndToEndContentProtocol.inspect(data, acceptVideoFragments: acceptVideoFragments, acceptLabels: acceptLabels)
        guard meta.sequence >= nextSequence else { throw ProtocolError.replay }
        let header = data.prefix(EndToEndContentProtocol.headerBytes)
        let plaintext = try MeshAead.decrypt(key: key, sequence: meta.sequence, ciphertext: data.dropFirst(EndToEndContentProtocol.headerBytes), associatedData: header)
        nextSequence = meta.sequence + 1
        return EndToEndContentRecord(type: meta.type, sequence: meta.sequence, flags: meta.flags, payload: plaintext)
    }
}

public struct EndToEndSession {
    public let peerNodeId: NodeId
    public let peerCapabilities: NodeCapabilities
    public let peerFingerprint: IdentityFingerprint
    public let sealer: EndToEndContentSealer
    public let opener: EndToEndContentOpener
}

/// Optional gate run on every endpoint handshake before any content key is used (verified contacts).
public protocol PeerIdentityGate: AnyObject {
    /// Throw to refuse (for example a verified contact's prefix with another key).
    func admit(peer: NodeId, fingerprint: IdentityFingerprint) throws
    /// A forwarded stream's original source, known only by its 128-bit node ID from the BFG1 grant.
    func admitForwardedSource(_ source: NodeId) throws
}

public extension PeerIdentityGate {
    func admitForwardedSource(_ source: NodeId) throws {}
}

/// Endpoint handshake (separate signature/KDF domain) over an authenticated link.
public final class EndToEndHandshake {
    public let role: HandshakeRole
    private let identity: SigningIdentity
    private let capabilities: NodeCapabilities
    private var pending: PendingHandshake?
    private weak var gate: PeerIdentityGate?
    public init(role: HandshakeRole, identity: SigningIdentity, capabilities: NodeCapabilities, gate: PeerIdentityGate? = nil) {
        self.role = role; self.identity = identity; self.capabilities = capabilities; self.gate = gate
    }
    /// Initiator: the BMS1 type-4 payload to send first.
    public func initiatorHello(ephemeral: P256.KeyAgreement.PrivateKey = .init()) throws -> Data {
        precondition(role == .initiator)
        let p = try MeshHandshake.start(identity: identity, role: .initiator, capabilities: capabilities, purpose: .endToEnd, ephemeral: ephemeral)
        pending = p
        return try p.hello.encoded()
    }
    /// Consumes the peer's type-4 payload. A responder also returns its own hello payload to send.
    public func receive(_ payload: Data) throws -> (session: EndToEndSession, reply: Data?) {
        let remote = try SignedHandshakeHello(decoding: payload)
        let keys: MeshSessionKeys
        var reply: Data?
        switch role {
        case .initiator:
            guard let pending else { throw ProtocolError.state("Endpoint handshake not started") }
            keys = try MeshHandshake.finish(pending, remote: remote)
        case .responder:
            guard remote.role == .initiator else { throw ProtocolError.state("Expected an end-to-end initiator") }
            let p = try MeshHandshake.start(identity: identity, role: .responder, capabilities: capabilities, purpose: .endToEnd)
            keys = try MeshHandshake.finish(p, remote: remote)
            reply = try p.hello.encoded()
        }
        pending = nil
        let fingerprint = IdentityFingerprint(publicKey: remote.identityPublicKey)
        try gate?.admit(peer: keys.peerNodeId, fingerprint: fingerprint)
        let session = EndToEndSession(peerNodeId: keys.peerNodeId, peerCapabilities: remote.capabilities, peerFingerprint: fingerprint,
                                      sealer: EndToEndContentSealer(key: keys.sendKey), opener: EndToEndContentOpener(key: keys.receiveKey))
        return (session, reply)
    }
}
