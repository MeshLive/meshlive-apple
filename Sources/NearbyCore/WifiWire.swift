import Foundation

/// Design WF revision 3 wire, as Android WifiWire.kt and WifiRoles.kt (AW1: Apple is a Wi-Fi Direct guest only).
public enum WifiWire {
    public static let magic = Data("BWF1".utf8)
    /// BMH3 LINK extension 8 `WIFI`, value = version 1, initiator block (msg3) only.
    public static let markerType: UInt8 = 8
    public static let markerVersion: UInt8 = 1
    public static let minRecordBytes = 5
    public static let maxRecordBytes = 96
    public static let bitAware: UInt8 = 1, bitAwareIcm: UInt8 = 2, bitDirectOwner: UInt8 = 4, bitDirectClient: UInt8 = 8
    public static let bearerAware: UInt8 = 1, bearerDirect: UInt8 = 2
    public static let maxValidMs = 20_000
    public static let min5GhzMhz = 4_900
    public static let maxFree: UInt8 = 7
    /// AW2 (Android WifiWire.WIFI_FIRST_RELEASE): the release number both BMH2 link hellos of a stream or relay hop must
    /// sign before that hop may carry BWF1. A debug build signs it while a Wi-Fi switch is on.
    public static let firstRelease = 11
}

/// The vector error names (`errors` in wifi-vectors.json).
public enum WifiWireError: String, Error, Equatable {
    case length = "LENGTH", magic = "MAGIC", kind = "KIND", bodyLength = "BODY_LENGTH", field = "FIELD", version = "VERSION"
}

public enum DeclineReason: UInt8 {
    case notEligible = 1, busy = 2, wifiUnavailable = 3, limit = 4, power = 5, setupFailed = 6, band = 7
}

/// One `BWF1` record (hop type 16). Integers big-endian; `reserved` fields are written 0 and ignored on receipt.
public enum Bwf1: Equatable {
    case caps(bearers: UInt8, freeHost: UInt8, freeGuest: UInt8)
    case host(status: UInt8, bearer: UInt8, ticket: Data, validMs: Int, freqMhz: Int)
    case decline(ticket: Data, reason: UInt8)
    case pick(ticket: Data, challenge: Data)
    case armed(ticket: Data)
    case bind(role: UInt8, ticket: Data)
    case ready(recvCeilingKbps: Int, familyCapKbps: Int, transportBudgetKbps: Int)
    case switchTo(gen: UInt32, ticket: Data, e2eBoundary: UInt64, meshBoundary: UInt64)
    case resume(gen: UInt32, ticket: Data, e2eNext: UInt64, meshNext: UInt64)
    case close(reason: UInt8)
    case creds(ticket: Data, port: UInt16, ipv4: UInt32)

    public var kind: UInt8 {
        switch self {
        case .caps: return 1
        case .host: return 2
        case .decline: return 3
        case .pick: return 4
        case .armed: return 5
        case .bind: return 6
        case .ready: return 7
        case .switchTo: return 8
        case .resume: return 9
        case .close: return 10
        case .creds: return 11
        }
    }

    static func bodyBytes(_ kind: UInt8) -> Int? {
        [1: 4, 2: 16, 3: 9, 4: 24, 5: 8, 6: 9, 7: 8, 8: 28, 9: 28, 10: 1, 11: 14][kind]
    }

    public func encoded() -> Data {
        var w = BinaryWriter(capacity: 5 + (Bwf1.bodyBytes(kind) ?? 0))
        w.bytes(WifiWire.magic); w.byte(kind)
        switch self {
        case .caps(let bearers, let freeHost, let freeGuest): w.byte(bearers); w.byte(freeHost); w.byte(freeGuest); w.byte(0)
        case .host(let status, let bearer, let ticket, let validMs, let freqMhz):
            w.byte(status); w.byte(bearer); w.bytes(ticket); w.u16(UInt16(validMs)); w.u16(UInt16(freqMhz)); w.u16(0)
        case .decline(let ticket, let reason): w.bytes(ticket); w.byte(reason)
        case .pick(let ticket, let challenge): w.bytes(ticket); w.bytes(challenge)
        case .armed(let ticket): w.bytes(ticket)
        case .bind(let role, let ticket): w.byte(role); w.bytes(ticket)
        case .ready(let ceiling, let cap, let budget): w.u16(UInt16(ceiling)); w.u16(UInt16(cap)); w.u16(UInt16(budget)); w.u16(0)
        case .switchTo(let gen, let ticket, let e2e, let mesh): w.u32(gen); w.bytes(ticket); w.u64(e2e); w.u64(mesh)
        case .resume(let gen, let ticket, let e2e, let mesh): w.u32(gen); w.bytes(ticket); w.u64(e2e); w.u64(mesh)
        case .close(let reason): w.byte(reason)
        case .creds(let ticket, let port, let ipv4): w.bytes(ticket); w.u16(port); w.u32(ipv4)
        }
        return w.data
    }

    /// Checks in Android's order: total length, magic, kind, body length, fields. An unknown kind throws `.kind`
    /// (the caller ignores it); every other error is a protocol violation.
    public static func decode(_ value: Data) throws -> Bwf1 {
        let v = value.rebased
        guard v.count >= WifiWire.minRecordBytes, v.count <= WifiWire.maxRecordBytes else { throw WifiWireError.length }
        guard v.prefix(4) == WifiWire.magic else { throw WifiWireError.magic }
        let kind = v[4]
        guard let body = bodyBytes(kind) else { throw WifiWireError.kind }
        guard v.count == 5 + body else { throw WifiWireError.bodyLength }
        var r = BinaryReader(v.subdata(in: 5..<v.count))
        let maxBoundary = UInt64(Int64.max)
        switch kind {
        case 1:
            let bearers = try r.byte(), freeHost = try r.byte(), freeGuest = try r.byte()
            guard freeHost <= WifiWire.maxFree, freeGuest <= WifiWire.maxFree else { throw WifiWireError.field }
            return .caps(bearers: bearers & 0x0F, freeHost: freeHost, freeGuest: freeGuest)
        case 2:
            let status = try r.byte(), bearer = try r.byte(), ticket = try r.bytes(8)
            let validMs = Int(try r.u16()), freqMhz = Int(try r.u16())
            guard status <= 1, bearer == WifiWire.bearerAware || bearer == WifiWire.bearerDirect else { throw WifiWireError.field }
            if status == 1 {
                guard (1...WifiWire.maxValidMs).contains(validMs) else { throw WifiWireError.field }
            } else {
                guard validMs == 0, freqMhz == 0 else { throw WifiWireError.field }
            }
            if bearer == WifiWire.bearerAware { guard freqMhz == 0 else { throw WifiWireError.field } }
            else { guard freqMhz == 0 || freqMhz >= WifiWire.min5GhzMhz else { throw WifiWireError.field } }
            return .host(status: status, bearer: bearer, ticket: ticket, validMs: validMs, freqMhz: freqMhz)
        case 3:
            let ticket = try r.bytes(8), reason = try r.byte()
            guard (1...7).contains(reason) else { throw WifiWireError.field }
            return .decline(ticket: ticket, reason: reason)
        case 4: return .pick(ticket: try r.bytes(8), challenge: try r.bytes(16))
        case 5: return .armed(ticket: try r.bytes(8))
        case 6:
            let role = try r.byte(), ticket = try r.bytes(8)
            guard role == 1 || role == 2 else { throw WifiWireError.field }
            return .bind(role: role, ticket: ticket)
        case 7: return .ready(recvCeilingKbps: Int(try r.u16()), familyCapKbps: Int(try r.u16()), transportBudgetKbps: Int(try r.u16()))
        case 8, 9:
            let gen = try r.u32(), ticket = try r.bytes(8), e2e = try r.u64(), mesh = try r.u64()
            guard gen >= 1, e2e <= maxBoundary, mesh <= maxBoundary else { throw WifiWireError.field }
            return kind == 8 ? .switchTo(gen: gen, ticket: ticket, e2eBoundary: e2e, meshBoundary: mesh)
                             : .resume(gen: gen, ticket: ticket, e2eNext: e2e, meshNext: mesh)
        case 10: return .close(reason: try r.byte())
        default:
            let ticket = try r.bytes(8), port = try r.u16(), ipv4 = try r.u32()
            guard port != 0, ipv4 != 0 else { throw WifiWireError.field }
            return .creds(ticket: ticket, port: port, ipv4: ipv4)
        }
    }
}

/// Android WifiRoles.choose: the bearer and roles both CAPS allow, fixed for the hop.
public enum WifiRoles {
    public struct Tuple: Equatable {
        public let bearer: UInt8
        public let localIsHost: Bool
        public init(bearer: UInt8, localIsHost: Bool) { self.bearer = bearer; self.localIsHost = localIsHost }
    }
    public typealias Caps = (bearers: UInt8, freeHost: UInt8, freeGuest: UInt8)

    public static func choose(local: Caps, peer: Caps, localIsLinkInitiator: Bool) -> Tuple? {
        let responder = localIsLinkInitiator ? peer : local
        let initiator = localIsLinkInitiator ? local : peer
        // localIsHost: the responder hosts and this side is the responder, or the initiator hosts and this side is it.
        func tuple(_ bearer: UInt8, responderHosts: Bool) -> Tuple { Tuple(bearer: bearer, localIsHost: responderHosts != localIsLinkInitiator) }
        if responder.bearers & WifiWire.bitAware != 0, initiator.bearers & WifiWire.bitAware != 0 {
            if responder.freeHost > 0, initiator.freeGuest > 0 { return tuple(WifiWire.bearerAware, responderHosts: true) }
            if initiator.freeHost > 0, responder.freeGuest > 0 { return tuple(WifiWire.bearerAware, responderHosts: false) }
        }
        if responder.bearers & WifiWire.bitDirectOwner != 0, initiator.bearers & WifiWire.bitDirectClient != 0 {
            return tuple(WifiWire.bearerDirect, responderHosts: true)
        }
        if initiator.bearers & WifiWire.bitDirectOwner != 0, responder.bearers & WifiWire.bitDirectClient != 0 {
            return tuple(WifiWire.bearerDirect, responderHosts: false)
        }
        return nil
    }
}

/// BWU1 frames on a fresh Wi-Fi socket (PROTOCOL "Binding"). Encoding and length/magic/type/point-prefix checks only;
/// every key and MAC computation is in WifiKeys.swift.
public enum Bwu1Wire {
    public static let magic = Data("BWU1".utf8)
    public static let frame1Bytes = 21, frame2Bytes = 126, frame3Bytes = 102

    /// Frame 1 -> the host's 16-byte challenge.
    public static func challenge(fromFrame1 value: Data) throws -> Data {
        let v = value.rebased
        guard v.count == frame1Bytes else { throw WifiWireError.length }
        guard v.prefix(4) == magic else { throw WifiWireError.magic }
        guard v[4] == 1 else { throw WifiWireError.kind }
        return v.subdata(in: 5..<21)
    }

    public static func frame2(ticket: Data, guestPoint: Data, guestNonce: Data, pre: Data) -> Data {
        var w = BinaryWriter(capacity: frame2Bytes)
        w.bytes(magic); w.byte(2); w.bytes(ticket); w.bytes(guestPoint); w.bytes(guestNonce); w.bytes(pre)
        return w.data
    }

    /// Frame 2 parts (host side; here for the vectors): ticket, e_G, n_G, pre.
    public static func parts(ofFrame2 value: Data) throws -> (ticket: Data, point: Data, nonce: Data, pre: Data) {
        let v = value.rebased
        guard v.count == frame2Bytes else { throw WifiWireError.length }
        guard v.prefix(4) == magic else { throw WifiWireError.magic }
        guard v[4] == 2 else { throw WifiWireError.kind }
        guard v[13] == 0x04 else { throw WifiWireError.field }
        return (v.subdata(in: 5..<13), v.subdata(in: 13..<78), v.subdata(in: 78..<110), v.subdata(in: 110..<126))
    }

    /// Frame 3 -> e_H (65 bytes, uncompressed) and n_H (32 bytes). Curve validation is WifiKeys' job.
    public static func parts(ofFrame3 value: Data) throws -> (point: Data, nonce: Data) {
        let v = value.rebased
        guard v.count == frame3Bytes else { throw WifiWireError.length }
        guard v.prefix(4) == magic else { throw WifiWireError.magic }
        guard v[4] == 3 else { throw WifiWireError.kind }
        guard v[5] == 0x04 else { throw WifiWireError.field }
        return (v.subdata(in: 5..<70), v.subdata(in: 70..<102))
    }
}
