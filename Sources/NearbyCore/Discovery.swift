import Foundation

// BLE discovery: Android's 22-byte announcement (manufacturer data 0xFFFF), the iPhone compact
// announcement UUID (Interop/ANDROID_DISCOVERY_ADDENDUM.md section A), route tokens and the GATT/CoC UUIDs.

public enum MeshUUIDs {
    /// Advertised by Android; primary service holding the CoC PSM characteristic.
    public static let controlService = "C8D5A101-9F88-4F65-A03D-7F5A2FB921FA"
    public static let psmCharacteristic = "C8D5A102-9F88-4F65-A03D-7F5A2FB921FA"
    public static let gattWrite = "C8D5A103-9F88-4F65-A03D-7F5A2FB921FA"
    public static let gattNotify = "C8D5A104-9F88-4F65-A03D-7F5A2FB921FA"
    public static let gattDataService = "C8D5A105-9F88-4F65-A03D-7F5A2FB921FA"
    public static let meshManufacturerId: UInt16 = 0xFFFF

    public static func encodePSM(_ psm: UInt16) throws -> Data {
        guard psm != 0 else { throw ProtocolError.malformed("Invalid L2CAP PSM 0") }
        return Data([UInt8(psm >> 8), UInt8(psm & 0xff)])
    }
    public static func decodePSM(_ data: Data) throws -> UInt16 {
        let d = data.rebased
        guard d.count == 2 else { throw ProtocolError.malformed("Invalid L2CAP PSM response") }
        let psm = UInt16(d[0]) << 8 | UInt16(d[1])
        guard psm != 0 else { throw ProtocolError.malformed("Invalid L2CAP PSM 0") }
        return psm
    }
}

public enum MeshTransport: String, CaseIterable, Identifiable {
    case l2cap, gatt
    public var id: String { rawValue }
    public var capabilityBit: UInt8 { self == .l2cap ? NodeCapabilities.transportL2CAP : NodeCapabilities.transportGATT }
    /// Android BluetoothTransportOption.maxVideoBitrateKbps.
    public var maxVideoBitrateKbps: UInt16 { self == .l2cap ? 1_200 : 1_100 }
    public var label: String { self == .l2cap ? "LE L2CAP" : "LE GATT" }
}

public struct DiscoveryAnnouncement: Equatable {
    public static let encodedBytes = 22
    public static let version: UInt8 = 2
    public static let flagAcceptingConnections: UInt8 = 1
    public static let flagRelayCapable: UInt8 = 1 << 1
    public static let flagStreamAvailable: UInt8 = 1 << 2
    public static let flagGattTransport: UInt8 = 1 << 3
    public static let flagClassicTransport: UInt8 = 1 << 4
    public static let flagStreamPaused: UInt8 = 1 << 5
    public static let flagPrivateCallAvailable: UInt8 = 1 << 6
    public static let flagRouteRecovery: UInt8 = 1 << 7
    public static let sequenceSourceFull: UInt8 = 0x80
    public static let sequenceGenerationMask: UInt8 = 0x7f

    public var nodeIdPrefix: Data
    public var flags: UInt8
    public var capabilitySummary: UInt8
    public var streamToken: UInt32
    public var routeCost: UInt8
    public var sequence: UInt8
    public var streamWidth: UInt16
    public var streamHeight: UInt16
    public var streamFps: UInt8
    public var streamBitrateKbps: UInt16
    public var recoveryFromNodeIdPrefix: Data?
    /// EXPERIMENTAL rotating discovery IDs: `nodeIdPrefix` holds a 15-minute rotating ID (compact v2), not the
    /// node prefix. Such an advert is a "Nearby phone": no handle and no contact match before the handshake.
    public var rotating = false

    public init(nodeIdPrefix: Data, flags: UInt8, capabilitySummary: UInt8, streamToken: UInt32, routeCost: UInt8, sequence: UInt8 = 0,
                streamWidth: UInt16 = 0, streamHeight: UInt16 = 0, streamFps: UInt8 = 0, streamBitrateKbps: UInt16 = 0, recoveryFromNodeIdPrefix: Data? = nil) {
        self.nodeIdPrefix = nodeIdPrefix.rebased; self.flags = flags; self.capabilitySummary = capabilitySummary
        self.streamToken = streamToken; self.routeCost = routeCost; self.sequence = sequence
        self.streamWidth = streamWidth; self.streamHeight = streamHeight; self.streamFps = streamFps
        self.streamBitrateKbps = streamBitrateKbps; self.recoveryFromNodeIdPrefix = recoveryFromNodeIdPrefix?.rebased
    }

    public var isStreamOffer: Bool { flags & Self.flagStreamAvailable != 0 }
    public var isPrivateCallOffer: Bool { flags & Self.flagPrivateCallAvailable != 0 && !isStreamOffer }
    public var isFullStreamOffer: Bool { isStreamOffer && flags & Self.flagRouteRecovery == 0 && sequence & Self.sequenceSourceFull != 0 }
    public func isViewerRequest(routeToken: UInt32) -> Bool { flags & Self.flagAcceptingConnections != 0 && streamToken == routeToken }
    public var transport: MeshTransport? {
        if flags & Self.flagClassicTransport != 0 { return nil }
        return flags & Self.flagGattTransport != 0 ? .gatt : .l2cap
    }
    public var usesClassic: Bool { flags & Self.flagClassicTransport != 0 }
    public var logicalStreamToken: UInt32 { StreamRouteToken.logical(routeToken: streamToken, prefix: nodeIdPrefix) }
    public var prefixHex: String { nodeIdPrefix.hex }

    public func encoded() throws -> Data {
        guard nodeIdPrefix.count == NodeId.prefixBytes else { throw ProtocolError.malformed("Invalid node prefix") }
        guard (flags & Self.flagRouteRecovery != 0) == (recoveryFromNodeIdPrefix != nil) else {
            throw ProtocolError.malformed("Route-recovery discovery metadata and flag must agree")
        }
        var w = BinaryWriter(capacity: Self.encodedBytes)
        guard !rotating || isPrivateCallOffer || isStreamOffer else { throw ProtocolError.malformed("Only call and stream offers rotate here") }
        w.byte(rotating ? Self.rotatingVersion : Self.version); w.bytes(nodeIdPrefix); w.byte(flags); w.byte(capabilitySummary); w.u32(streamToken); w.byte(routeCost)
        if let recovery = recoveryFromNodeIdPrefix {
            guard recovery.count == NodeId.prefixBytes else { throw ProtocolError.malformed("Invalid recovery prefix") }
            w.bytes(recovery)
        } else {
            w.byte(sequence); w.u16(streamWidth); w.u16(streamHeight); w.byte(streamFps)
        }
        w.u16(streamBitrateKbps)
        return w.data
    }

    /// EXPERIMENTAL rotating discovery IDs: Android's announcement version 5 (the prefix bytes are an RDI).
    public static let rotatingVersion: UInt8 = 5

    /// - Parameter acceptRotating: the experimental switch; off, version 5 is rejected as by old builds.
    public init(decoding data: Data, acceptRotating: Bool = false) throws {
        guard data.count == Self.encodedBytes else { throw ProtocolError.malformed("Invalid discovery announcement length") }
        var r = BinaryReader(data)
        let version = try r.byte()
        guard version == Self.version || (version == Self.rotatingVersion && acceptRotating) else { throw ProtocolError.incompatible("Unsupported announcement version") }
        rotating = version == Self.rotatingVersion
        nodeIdPrefix = try r.bytes(6); flags = try r.byte(); capabilitySummary = try r.byte()
        streamToken = try r.u32(); routeCost = try r.byte()
        let compact = try r.bytes(6)
        streamBitrateKbps = try r.u16()
        if flags & Self.flagRouteRecovery != 0 {
            recoveryFromNodeIdPrefix = compact; sequence = 0; streamWidth = 0; streamHeight = 0; streamFps = 0
        } else {
            var c = BinaryReader(compact)
            recoveryFromNodeIdPrefix = nil
            sequence = try c.byte(); streamWidth = try c.u16(); streamHeight = try c.u16(); streamFps = try c.byte()
        }
        // Phase 1b: Android's version 5 stream offers (role-1 RDI, route token = logical XOR mask(RDI)) decode too, so
        // an iPhone sees default Android streams; version 5 viewer requests answer only version 5 offers (never ours).
        if rotating && !isPrivateCallOffer && !isStreamOffer { throw ProtocolError.malformed("Only call and stream offers rotate here") }
    }

    /// Android manufacturer-specific data as Core Bluetooth reports it: little-endian company ID, then the value.
    public init(manufacturerData: Data, acceptRotating: Bool = false) throws {
        let d = manufacturerData.rebased
        guard d.count == 2 + Self.encodedBytes, d[0] == 0xff, d[1] == 0xff else { throw ProtocolError.malformed("Not a mesh announcement") }
        try self.init(decoding: d.dropFirst(2).rebased, acceptRotating: acceptRotating)
    }
}

/// Route tokens: logical stream token XOR a per-advertiser FNV-1a mask with bit 31 set.
public enum StreamRouteToken {
    static let domain = Data("bluetooth-video-route-v1".utf8)
    static func mask(_ prefix: Data) -> UInt32 {
        var hash: UInt32 = 0x811c9dc5
        for byte in domain + prefix { hash = (hash ^ UInt32(byte)) &* 0x01000193 }
        return hash | 0x8000_0000
    }
    public static func forAdvertiser(logical: UInt32, prefix: Data) throws -> UInt32 {
        guard (1...UInt32(Int32.max)).contains(logical), prefix.count == NodeId.prefixBytes else {
            throw ProtocolError.malformed("Logical stream tokens must be positive")
        }
        return logical ^ mask(prefix)
    }
    public static func logical(routeToken: UInt32, prefix: Data) -> UInt32 { routeToken ^ mask(prefix) }
    /// A forwarder's own route token for the same logical stream (Android ReceiverStreamForwarder).
    public static func downstream(upstreamRouteToken: UInt32, parentPrefix: Data, ownPrefix: Data) -> UInt32 {
        logical(routeToken: upstreamRouteToken, prefix: parentPrefix) ^ mask(ownPrefix)
    }
    public static func newLogicalToken() -> UInt32 {
        while true {
            let value = randomBytes(4).reduce(0) { $0 << 8 | UInt32($1) } & 0x7fff_ffff
            if value != 0 { return value }
        }
    }
}

/// iPhone compact announcement in one 128-bit service UUID (Interop/ANDROID_DISCOVERY_ADDENDUM.md section A, version 1).
/// Decoders reject exactly: wrong magic, version != 1, kind 3, paused with kind != stream offer, a call offer with
/// any of bits 49..0 set, a viewer request with any of bits 11..0 set (review R2). Bitrate units are
/// min(floor(kbps / 25), 127) (R4); a viewer request always carries a discovered route token (R3).
public enum CompactAnnouncement {
    public static let magic: UInt16 = 0xC8D6
    /// R11: call-offer capabilitySummary bit 4 = "may be relayed" (consent for relayed discovery, phase 2).
    public static let relayConsent: UInt8 = 0x10
    public enum Kind: UInt8 { case privateCallOffer = 0, viewerRequest = 1, streamOffer = 2 }
    static let resolutions: [(UInt16, UInt16)] = [(426, 240), (640, 360), (854, 480)]
    static let fpsValues: [UInt8] = [15, 24, 30]

    /// Encodes the UUID string (canonical byte order, uppercase).
    public static func encode(_ a: DiscoveryAnnouncement) throws -> String {
        let kind: Kind
        if a.isStreamOffer { kind = .streamOffer }
        else if a.flags & DiscoveryAnnouncement.flagPrivateCallAvailable != 0 { kind = .privateCallOffer }
        else if a.flags & DiscoveryAnnouncement.flagAcceptingConnections != 0 { kind = .viewerRequest }
        else { throw ProtocolError.malformed("Announcement kind cannot be represented") }
        guard a.nodeIdPrefix.count == 6, a.routeCost <= 15, !a.usesClassic, a.recoveryFromNodeIdPrefix == nil else {
            throw ProtocolError.malformed("Announcement cannot be represented compactly")
        }
        // R11: call offers may carry capabilitySummary bit 4 (0x10, "may be relayed") as UUID bit 18.
        let allowed: UInt8 = kind == .privateCallOffer ? NodeCapabilities.codecMask | CompactAnnouncement.relayConsent : NodeCapabilities.codecMask
        // Experimental audio-only live: summary 0x40 on a stream offer with zero geometry is codec mask 0 with
        // resolution index 3 and FPS index 3 (Android CompactDiscoveryAnnouncement).
        let audioOnly = kind == .streamOffer && a.capabilitySummary == AudioLive.summaryAudioOnly
        if audioOnly, a.streamWidth != 0 || a.streamHeight != 0 || a.streamFps != 0 {
            throw ProtocolError.malformed("An audio-only offer has no video geometry")
        }
        guard audioOnly || a.capabilitySummary & ~allowed == 0 else { throw ProtocolError.malformed("Unsupported capability bits") }
        // Review R1: encoders keep the H.264 bit (56) at 0 until H.264 is negotiated; decoders carry all three.
        let codecs = audioOnly ? 0 : a.capabilitySummary & (StreamProtocol.h264Enabled ? 0x7 : 0x3)
        // Compact v2 (rotating discovery IDs, phase 1): call offers only; version bits 111..110 = 10.
        if a.rotating, kind != .privateCallOffer { throw ProtocolError.malformed("Only call offers rotate in phase 1") }
        var hi: UInt64 = UInt64(magic) << 48 | (a.rotating ? 2 : 1) << 46 | UInt64(kind.rawValue) << 44
        var prefix: UInt64 = 0
        for b in a.nodeIdPrefix { prefix = prefix << 8 | UInt64(b) }
        hi |= prefix >> 4                    // prefix bits 47..4 -> U bits 107..64
        var lo: UInt64 = (prefix & 0xf) << 60 // prefix bits 3..0 -> U bits 63..60
        if a.flags & DiscoveryAnnouncement.flagGattTransport != 0 { lo |= 1 << 59 }
        if a.flags & DiscoveryAnnouncement.flagRelayCapable != 0 { lo |= 1 << 58 }
        if a.flags & DiscoveryAnnouncement.flagStreamPaused != 0 {
            guard kind == .streamOffer else { throw ProtocolError.malformed("Only stream offers can be paused") }
            lo |= 1 << 57
        }
        lo |= UInt64(codecs) << 54
        lo |= UInt64(a.routeCost) << 50
        switch kind {
        case .privateCallOffer:
            guard a.streamToken == 0 else { throw ProtocolError.malformed("Call offers carry token 0") }
        case .viewerRequest, .streamOffer:
            guard a.streamToken & 0x8000_0000 != 0 else { throw ProtocolError.malformed("Route tokens have bit 31 set") }
            lo |= UInt64(a.streamToken & 0x7fff_ffff) << 19
        }
        let units = UInt64(min(Int(a.streamBitrateKbps) / 25, 127))
        switch kind {
        case .privateCallOffer: if a.capabilitySummary & CompactAnnouncement.relayConsent != 0 { lo |= 1 << 18 }
        case .viewerRequest: lo |= units << 12
        case .streamOffer:
            let res = resolutions.firstIndex { $0.0 == a.streamWidth && $0.1 == a.streamHeight } ?? 3
            let fps = fpsValues.firstIndex(of: a.streamFps) ?? 3
            lo |= UInt64(a.sequence) << 11 | UInt64(res) << 9 | UInt64(fps) << 7 | units
        }
        return uuidString(hi: hi, lo: lo)
    }

    /// Decodes a compact UUID into an ordinary announcement; nil when it is not one (strict checks).
    /// - Parameter acceptRotating: the experimental rotating-ID switch; off, compact v2 is rejected as before.
    public static func decode(_ uuidString: String, acceptRotating: Bool = false) -> DiscoveryAnnouncement? {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        let b = uuid.rawBytes
        let hi = b.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let lo = b.suffix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let version = (hi >> 46) & 0x3
        guard UInt16(hi >> 48) == magic, version == 1 || (version == 2 && acceptRotating), let kind = Kind(rawValue: UInt8((hi >> 44) & 0x3)) else { return nil }
        if version == 2 && kind != .privateCallOffer { return nil }
        let prefixValue = (hi & 0xfff_ffff_ffff) << 4 | lo >> 60
        var prefix = Data(); for shift in stride(from: 40, through: 0, by: -8) { prefix.append(UInt8((prefixValue >> UInt64(shift)) & 0xff)) }
        let gatt = lo >> 59 & 1 == 1, relay = lo >> 58 & 1 == 1, paused = lo >> 57 & 1 == 1
        let codecs = UInt8(lo >> 54 & 0x7), cost = UInt8(lo >> 50 & 0xf)
        let tokenField = UInt32(lo >> 19 & 0x7fff_ffff), specific = lo & 0x7ffff
        var flags: UInt8 = 0
        switch kind {
        case .privateCallOffer:
            // R11: bit 18 is carried (never rejected); bits 49..19 and 17..0 still reject.
            guard tokenField == 0, specific & ~(1 << 18) == 0, !paused else { return nil }
            flags = DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable
        case .viewerRequest:
            guard specific & 0xfff == 0, !paused else { return nil }
            flags = DiscoveryAnnouncement.flagAcceptingConnections
        case .streamOffer:
            flags = DiscoveryAnnouncement.flagStreamAvailable
        }
        if gatt { flags |= DiscoveryAnnouncement.flagGattTransport }
        if relay { flags |= DiscoveryAnnouncement.flagRelayCapable }
        if paused { flags |= DiscoveryAnnouncement.flagStreamPaused }
        let token: UInt32 = kind == .privateCallOffer ? 0 : 0x8000_0000 | tokenField
        let consent = kind == .privateCallOffer && specific & (1 << 18) != 0 ? CompactAnnouncement.relayConsent : 0
        var a = DiscoveryAnnouncement(nodeIdPrefix: prefix, flags: flags, capabilitySummary: codecs | consent, streamToken: token, routeCost: cost)
        a.rotating = version == 2
        switch kind {
        case .privateCallOffer: break
        case .viewerRequest: a.streamBitrateKbps = UInt16(specific >> 12 & 0x7f) * 25
        case .streamOffer:
            a.sequence = UInt8(specific >> 11 & 0xff)
            let res = Int(specific >> 9 & 0x3), fps = Int(specific >> 7 & 0x3)
            if codecs == 0 && res == 3 && fps == 3 { a.capabilitySummary = AudioLive.summaryAudioOnly }
            if res < 3 { a.streamWidth = resolutions[res].0; a.streamHeight = resolutions[res].1 }
            if fps < 3 { a.streamFps = fpsValues[fps] }
            a.streamBitrateKbps = UInt16(specific & 0x7f) * 25
        }
        return a
    }

    static func uuidString(hi: UInt64, lo: UInt64) -> String {
        var bytes = Data()
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((hi >> UInt64(shift)) & 0xff)) }
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((lo >> UInt64(shift)) & 0xff)) }
        return UUID(rawBytes: bytes).uuidString
    }
}
