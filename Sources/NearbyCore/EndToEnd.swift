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
    /// Experimental rotating IDs / BMH3 pseudonyms (BDX1 container): calls only, after both endpoint hellos carried bit 3.
    case discoveryExchange = 11
}

public enum StreamLifecycleState: UInt8 {
    case live = 1, paused = 2, ended = 3
    /// Android's experimental live media state (`live_media_state`, off by default): live with the microphone muted,
    /// the camera off, or both. Readers treat them as LIVE for liveness; older readers close on them, so the iPhone
    /// accepts them (and never sends them).
    case liveMuted = 4, liveCameraOff = 5, liveMutedCameraOff = 6
    public var encoded: Data { Data([rawValue]) }
    /// True for LIVE and its media variants 4-6.
    public var isLive: Bool { self == .live || rawValue >= 4 }
    public var microphoneMuted: Bool { self == .liveMuted || self == .liveMutedCameraOff }
    public var cameraOff: Bool { self == .liveCameraOff || self == .liveMutedCameraOff }
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
    public static func inspect(_ encoded: Data, acceptVideoFragments: Bool = false, acceptLabels: Bool = false,
                               acceptDiscoveryExchange: Bool = false) throws -> Metadata {
        guard encoded.count >= headerBytes else { throw ProtocolError.malformed("Truncated end-to-end content") }
        var r = BinaryReader(encoded.prefix(headerBytes).rebased)
        guard try r.bytes(4) == magic else { throw ProtocolError.malformed("Invalid end-to-end content magic") }
        let typeValue = try r.byte()
        guard let type = EndToEndContentType(rawValue: typeValue), type != .videoFragment || acceptVideoFragments, type != .labels || acceptLabels,
              type != .discoveryExchange || acceptDiscoveryExchange else {
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
    public var acceptDiscoveryExchange = false
    public init(key: SymmetricKey) { self.key = key }
    /// Copy of the key for a forwarded-stream grant (viewer-forwarder only).
    public var keyBytes: Data { key.withUnsafeBytes { Data($0) } }
    public func open(_ encoded: Data) throws -> EndToEndContentRecord {
        let data = encoded.rebased
        let meta = try EndToEndContentProtocol.inspect(data, acceptVideoFragments: acceptVideoFragments, acceptLabels: acceptLabels,
                                                       acceptDiscoveryExchange: acceptDiscoveryExchange)
        guard meta.sequence >= nextSequence else { throw ProtocolError.replay }
        let header = data.prefix(EndToEndContentProtocol.headerBytes)
        let plaintext = try MeshAead.decrypt(key: key, sequence: meta.sequence, ciphertext: data.dropFirst(EndToEndContentProtocol.headerBytes), associatedData: header)
        nextSequence = meta.sequence + 1
        return EndToEndContentRecord(type: meta.type, sequence: meta.sequence, flags: meta.flags, payload: plaintext)
    }
}

