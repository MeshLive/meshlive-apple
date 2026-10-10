import Foundation
import CryptoKit

// BMS1 hop records and the sans-I/O authenticated link (Android SecureBluetoothLink.kt).

public enum SecureRecordType: UInt8 {
    case endToEndHandshake = 4, endToEndContent = 5, linkHeartbeat = 6, meshEnvelope = 7
    case groupControl = 8, routeControl = 9, routeControlAck = 10
    /// Experimental store-and-forward; rejected unless a reader explicitly opts in.
    case storeForward = 11
    /// EXPERIMENTAL rotating discovery IDs: the BDO1 link opening, only as the first hop record each way when
    /// both link hellos carry bit 3; anywhere else it is rejected like an unknown type.
    case discoveryOpening = 13
}

public struct SecureRecord: Equatable {
    public let type: SecureRecordType
    public let payload: Data
    public init(type: SecureRecordType, payload: Data) { self.type = type; self.payload = payload }
}

public enum SecureRecordProtocol {
    public static let magic = Data("BMS1".utf8)
    public static let headerBytes = 17
    /// Android StreamProtocol.MAX_PAYLOAD_BYTES + 128.
    public static let maxPlaintextBytes = 4 * 1024 * 1024 + 128

    public static func header(type: SecureRecordType, sequence: UInt64, ciphertextBytes: Int) -> Data {
        var w = BinaryWriter(capacity: headerBytes)
        w.bytes(magic); w.byte(type.rawValue); w.u64(sequence); w.u32(UInt32(ciphertextBytes)); return w.data
    }
}

/// Seals BMS1 records in strict sequence order. One per direction per link.
public final class SecureRecordSealer {
    private let key: SymmetricKey
    public private(set) var nextSequence: UInt64 = 0
    public init(key: SymmetricKey) { self.key = key }
    public func seal(_ type: SecureRecordType, _ payload: Data) throws -> Data {
        guard payload.count <= SecureRecordProtocol.maxPlaintextBytes else { throw ProtocolError.limit("Secure record is too large") }
        let header = SecureRecordProtocol.header(type: type, sequence: nextSequence, ciphertextBytes: payload.count + MeshAead.tagBytes)
        let ciphertext = try MeshAead.encrypt(key: key, sequence: nextSequence, plaintext: payload, associatedData: header)
        nextSequence += 1
        return header + ciphertext
    }
}

/// Incremental BMS1 reader: accepts arbitrary byte-stream fragments, emits whole authenticated records.
public final class SecureRecordOpener {
    private let key: SymmetricKey
    private var buffer = Data()
    public private(set) var nextSequence: UInt64 = 0
    public var acceptStoreForward = false
    /// Hop type 13 (BDO1) parses only for a reader whose own link hello carries bit 3; its position is
    /// enforced by MeshConnection (first record each way when both hellos carry the bit).
    public var acceptDiscoveryOpening = false
    public var bufferedBytes: Int { buffer.count }
    public init(key: SymmetricKey) { self.key = key }

    public func feed(_ data: Data) throws -> [SecureRecord] {
        buffer.append(data)
        var out: [SecureRecord] = []
        while buffer.count >= SecureRecordProtocol.headerBytes {
            let header = buffer.prefix(SecureRecordProtocol.headerBytes).rebased
            var r = BinaryReader(header)
            guard try r.bytes(4) == SecureRecordProtocol.magic else { throw ProtocolError.malformed("Invalid secure record magic") }
            let typeValue = try r.byte()
            guard let type = SecureRecordType(rawValue: typeValue), type != .storeForward || acceptStoreForward,
                  type != .discoveryOpening || acceptDiscoveryOpening else {
                throw ProtocolError.malformed("Unknown secure record type \(typeValue)")
            }
            let sequence = try r.u64()
            guard sequence <= UInt64(Int64.max) else { throw ProtocolError.malformed("Invalid secure record sequence") }
            guard sequence == nextSequence else { throw ProtocolError.replay }
            let size = Int(try r.i32())
            guard size >= MeshAead.tagBytes, size <= SecureRecordProtocol.maxPlaintextBytes + MeshAead.tagBytes else {
                throw ProtocolError.malformed("Invalid secure record size \(size)")
            }
            guard buffer.count >= SecureRecordProtocol.headerBytes + size else { break }
            let ciphertext = buffer.subdata(in: buffer.startIndex + SecureRecordProtocol.headerBytes ..< buffer.startIndex + SecureRecordProtocol.headerBytes + size)
            let plaintext = try MeshAead.decrypt(key: key, sequence: sequence, ciphertext: ciphertext, associatedData: header)
            buffer = buffer.dropFirst(SecureRecordProtocol.headerBytes + size).rebased
            nextSequence += 1
            out.append(SecureRecord(type: type, payload: plaintext))
        }
        return out
    }
}

/// Link heartbeat payloads (PROTOCOL "Lifecycle, liveness and route withdrawal").
public struct LinkCapacityReport: Equatable {
    public var arrivalKbps: Int
    public var linkLate: Bool
    public var addedDelayMs: Int
    public var receivedBytes: UInt32?
    public var clockMs: UInt32?
    public var deliveryOnly: Bool
    public init(arrivalKbps: Int, linkLate: Bool, addedDelayMs: Int = 0, receivedBytes: UInt32? = nil, clockMs: UInt32? = nil, deliveryOnly: Bool = false) {
        self.arrivalKbps = arrivalKbps; self.linkLate = linkLate; self.addedDelayMs = addedDelayMs
        self.receivedBytes = receivedBytes; self.clockMs = clockMs; self.deliveryOnly = deliveryOnly
    }
}

public enum LinkHeartbeat {
    public static let version1 = Data([1])
    public static func encode(_ report: LinkCapacityReport) -> Data {
        let kbps = UInt16(clamping: max(0, report.arrivalKbps)), delay = UInt16(clamping: max(0, report.addedDelayMs))
        var flags: UInt8 = report.linkLate ? 1 : 0
        let delivery = report.receivedBytes != nil && report.clockMs != nil
        if delivery && report.deliveryOnly { flags |= 2 }
        var w = BinaryWriter(); w.byte(delivery ? 3 : 2); w.u16(kbps); w.byte(flags); w.u16(delay)
        if delivery { w.u32(report.receivedBytes!); w.u32(report.clockMs!) }
        return w.data
    }
    /// Validates a heartbeat exactly as Android does; returns a report when one is carried.
    public static func decode(_ payload: Data) throws -> LinkCapacityReport? {
        let p = payload.rebased
        if p == version1 { return nil }
        if p.count == 6 && p[0] == 2 {
            guard p[3] & ~1 == 0 else { throw ProtocolError.malformed("Invalid link report flags") }
            return LinkCapacityReport(arrivalKbps: Int(p[1]) << 8 | Int(p[2]), linkLate: p[3] & 1 != 0, addedDelayMs: Int(p[4]) << 8 | Int(p[5]))
        }
        if !p.isEmpty && p[0] >= 3 {
            guard (14...64).contains(p.count) else { throw ProtocolError.malformed("Invalid link report length") }
            var r = BinaryReader(p.subdata(in: 6..<14))
            return LinkCapacityReport(arrivalKbps: Int(p[1]) << 8 | Int(p[2]), linkLate: p[3] & 1 != 0, addedDelayMs: Int(p[4]) << 8 | Int(p[5]),
                                      receivedBytes: try r.u32(), clockMs: try r.u32(), deliveryOnly: p[3] & 2 != 0)
        }
        throw ProtocolError.malformed("Unsupported link heartbeat")
    }
}

/// Sans-I/O BMH2 link: handshake (u32-length-prefixed hellos), then BMS1 records in both directions.
/// The initiator (central/caller/stream source) writes first; the responder answers after verifying.
public final class SecureLink {
    public enum Output: Equatable {
        case send(Data)
        case established
        case record(SecureRecord)
    }
    public static let maxHelloBytes = 2_048
    public let role: HandshakeRole
    private let identity: SigningIdentity
    private let capabilities: NodeCapabilities
    private var pending: PendingHandshake?
    private var helloBuffer = Data()
    private var sealer: SecureRecordSealer?
    private var opener: SecureRecordOpener?
    public private(set) var peerHello: SignedHandshakeHello?
    public var peerNodeId: NodeId? { peerHello?.nodeId }
    public var peerCapabilities: NodeCapabilities? { peerHello?.capabilities }
    public var isEstablished: Bool { sealer != nil }
    public var acceptDiscoveryOpening = false
    public var acceptStoreForward: Bool {
        get { opener?.acceptStoreForward ?? false }
        set { opener?.acceptStoreForward = newValue }
    }

    public init(role: HandshakeRole, identity: SigningIdentity, capabilities: NodeCapabilities) {
        self.role = role; self.identity = identity; self.capabilities = capabilities
    }

    static func frame(_ hello: SignedHandshakeHello) throws -> Data {
        let bytes = try hello.encoded()
        guard bytes.count <= maxHelloBytes else { throw ProtocolError.limit("Handshake message is too large") }
        var w = BinaryWriter(); w.u32(UInt32(bytes.count)); w.bytes(bytes); return w.data
    }

    /// Initiator: returns its framed hello. Responder: returns nil and waits.
    public func start(ephemeral: P256.KeyAgreement.PrivateKey = .init()) throws -> Data? {
        guard role == .initiator else { return nil }
        let p = try MeshHandshake.start(identity: identity, role: .initiator, capabilities: capabilities, purpose: .link, ephemeral: ephemeral)
        pending = p
        return try SecureLink.frame(p.hello)
    }

    public func receive(_ data: Data) throws -> [Output] {
        if let opener { return try opener.feed(data).map { .record($0) } }
        helloBuffer.append(data)
        guard helloBuffer.count >= 4 else { return [] }
        var r = BinaryReader(helloBuffer.prefix(4).rebased)
        let size = Int(try r.i32())
        guard (1...SecureLink.maxHelloBytes).contains(size) else { throw ProtocolError.malformed("Invalid handshake message size") }
        guard helloBuffer.count >= 4 + size else { return [] }
        let remote = try SignedHandshakeHello(decoding: helloBuffer.subdata(in: helloBuffer.startIndex + 4 ..< helloBuffer.startIndex + 4 + size))
        let rest = helloBuffer.dropFirst(4 + size).rebased
        helloBuffer = Data()
        var outputs: [Output] = []
        let keys: MeshSessionKeys
        switch role {
        case .initiator:
            guard let pending else { throw ProtocolError.state("Link handshake not started") }
            keys = try MeshHandshake.finish(pending, remote: remote)
        case .responder:
            guard remote.role == .initiator else { throw ProtocolError.state("Expected an initiator handshake") }
            let p = try MeshHandshake.start(identity: identity, role: .responder, capabilities: capabilities, purpose: .link)
            keys = try MeshHandshake.finish(p, remote: remote)
            outputs.append(.send(try SecureLink.frame(p.hello)))
        }
        pending = nil
        peerHello = remote
        sealer = SecureRecordSealer(key: keys.sendKey)
        opener = SecureRecordOpener(key: keys.receiveKey)
        opener?.acceptDiscoveryOpening = acceptDiscoveryOpening
        outputs.append(.established)
        if !rest.isEmpty { outputs += try opener!.feed(rest).map { .record($0) } }
        return outputs
    }

    public func seal(_ type: SecureRecordType, _ payload: Data) throws -> Data {
        guard let sealer else { throw ProtocolError.state("Link is not authenticated") }
        return try sealer.seal(type, payload)
    }
    public var sentRecords: UInt64 { sealer?.nextSequence ?? 0 }
    public var receivedRecords: UInt64 { opener?.nextSequence ?? 0 }
}
