import Foundation

// Live-stream endpoints (Android AndroidVideoReceiver.kt / BluetoothVideoSender.kt).
// Android stream sources are LE centrals: a viewer advertises a request and is the link responder.

/// Watching: link and endpoint responder. Supports direct sources (BME1 in BMS1 type 5),
/// mesh-envelope sources (type 7) and viewer-forwarders (BFG1 grant + unchanged envelopes).
public final class StreamViewerEngine: MeshConnection {
    public enum Event: Equatable {
        case linkAuthenticated(NodeId)
        case sourceAuthenticated(adjacent: NodeId, source: NodeId, fingerprint: IdentityFingerprint)
        case header(StreamHeader)
        case audio(MediaPacket)
        case video(MediaPacket)
        case rotation(Int)
        case state(StreamLifecycleState)
        /// Raw authenticated mesh envelope (for an iPhone viewer-forwarder to copy downstream).
        case envelope(MeshEnvelope)
        case routeWithdrawn(RouteWithdrawal)
        /// The broadcaster's signed stream title (experimental labels), verified against the source and stream ID.
        case title(String)
        case ended(String, error: Bool)
    }
    public static let heartbeatInterval: TimeInterval = 2
    public let labelsEnabled: Bool
    public let labelInbox = LabelInbox()
    private var expectLabels = false
    private var pendingLabels: Data?
    public var onEvent: ((Event) -> Void)?
    public private(set) var header: StreamHeader?
    public private(set) var mediaSourceNodeId: NodeId?
    public private(set) var meshStreamId: UUID?
    public private(set) var grant: ForwardedStreamGrant?
    public let expectedMediaSource: NodeId?
    private var mediaOpener: EndToEndContentOpener?
    private var awaitingGrant = false
    private var wireMesh: Bool?
    private var lastMeshSequence: Int64 = -1
    private var duplicates = DuplicateWindow()
    private var lastHeartbeatAt: TimeInterval = 0
    public private(set) var receivedMediaBytes: UInt64 = 0
    public private(set) var audioPackets = 0
    public private(set) var videoPackets = 0

    /// - Parameters:
    ///   - expectedAdjacentPrefix: the advertiser's prefix from its offer (checked against the link and endpoint).
    ///   - decodeMask: codecs this phone can actually decode.
    ///   - maxChildren: 1 when this iPhone offers to forward the stream (viewer-forwarder), else 0.
    public init(transport: MeshTransport, identity: SigningIdentity, decodeMask: UInt8, expectedAdjacentPrefix: Data?,
                expectedMediaSource: NodeId? = nil, maxChildren: UInt8 = 0, labels: Bool = false) {
        let caps = NodeCapabilities(transportMask: transport.capabilityBit, encodeCodecMask: 0, decodeCodecMask: decodeMask & NodeCapabilities.codecMask,
                                    maxBitrateKbps: transport.maxVideoBitrateKbps, maxChildren: maxChildren)
        self.expectedMediaSource = expectedMediaSource
        labelsEnabled = labels
        super.init(role: .responder, transport: transport, identity: identity, linkCapabilities: caps,
                   endpointCapabilities: PeerLabelFeature.advertise(caps, enabled: labels))
        expectedPeerPrefix = expectedAdjacentPrefix
    }

    public override func validateLinkPeer() throws {
        guard let caps = link.peerCapabilities else { return }
        if caps.maxChildren > 1 { throw ProtocolError.incompatible("Group-relay (BGK1) sources are not supported on iPhone") }
        if let expectedPeerPrefix, link.peerNodeId?.prefix != expectedPeerPrefix { throw ProtocolError.authentication }
    }

    public override func linkDidAuthenticate() { if let id = link.peerNodeId { onEvent?(.linkAuthenticated(id)) } }

    public override func endpointDidAuthenticate(_ session: EndToEndSession) throws {
        lastHeartbeatAt = now
        enqueue(.record(.linkHeartbeat, LinkHeartbeat.version1), .control)
        session.opener.acceptLabels = labelsEnabled
        if let linkPeer = link.peerNodeId {
            expectLabels = PeerLabelFeature.streamHopNegotiated(localEnabled: labelsEnabled, linkPeer: linkPeer,
                                                                endpointPeer: session.peerNodeId, peer: session.peerCapabilities)
        }
        if session.peerCapabilities.maxChildren > 0 {
            awaitingGrant = true
        } else {
            try authenticateSource(source: session.peerNodeId, opener: session.opener, session: session)
        }
    }

    private func authenticateSource(source: NodeId, opener: EndToEndContentOpener, session: EndToEndSession) throws {
        if let expectedMediaSource, expectedMediaSource != source { throw ProtocolError.incompatible("The replacement route belongs to a different stream source") }
        mediaSourceNodeId = source
        mediaOpener = opener
        onEvent?(.sourceAuthenticated(adjacent: session.peerNodeId, source: source, fingerprint: session.peerFingerprint))
    }

    public override func handleOpenRecord(_ record: SecureRecord) throws {
        guard let endpoint else { throw ProtocolError.state("No endpoint") }
        if awaitingGrant {
            guard record.type == .endToEndContent else { throw ProtocolError.state("Expected a forwarded-stream key grant") }
            let opened = try endpoint.opener.open(record.payload)
            guard opened.type == .groupKey else { throw ProtocolError.state("Expected a forwarded-stream group key") }
            let grant = try ForwardedStreamGrant(decoding: opened.payload)
            self.grant = grant
            awaitingGrant = false
            // The original source is known only by the node ID the authenticated forwarder states.
            try identityGate?.admitForwardedSource(grant.sourceNodeId)
            try authenticateSource(source: grant.sourceNodeId, opener: EndToEndContentOpener(key: .init(data: grant.key)), session: endpoint)
            return
        }
        if expectLabels {
            // Exactly one LABELS record at this fixed position (first for a direct stream, after GROUP_KEY forwarded).
            guard record.type == .endToEndContent else { throw ProtocolError.state("Expected a LABELS record") }
            let opened = try endpoint.opener.open(record.payload)
            guard opened.type == .labels else { throw ProtocolError.state("Expected a LABELS record") }
            expectLabels = false
            pendingLabels = opened.payload
            return
        }
        guard let opener = mediaOpener, let source = mediaSourceNodeId else { throw ProtocolError.state("No media source") }
        let content: EndToEndContentRecord
        switch record.type {
        case .endToEndContent:
            guard wireMesh != true else { throw ProtocolError.malformed("Mesh stream changed to direct records") }
            wireMesh = false
            content = try opener.open(record.payload)
        case .meshEnvelope:
            guard wireMesh != false else { throw ProtocolError.malformed("Direct stream changed to mesh envelopes") }
            wireMesh = true
            let envelope = try MeshEnvelope(decoding: record.payload)
            guard envelope.sourceNodeId == source else { throw ProtocolError.authentication }
            guard envelope.ttl > 0 else { throw ProtocolError.malformed("Mesh packet arrived with expired TTL") }
            if let meshStreamId { guard envelope.streamId == meshStreamId else { throw ProtocolError.malformed("Mesh stream ID changed") } }
            else {
                if let grant, grant.streamId != envelope.streamId { throw ProtocolError.malformed("Forwarded-stream grant does not match its media stream") }
                meshStreamId = envelope.streamId
            }
            guard Int64(envelope.sequence) > lastMeshSequence else { throw ProtocolError.replay }
            guard duplicates.markIfNew(envelope) else { throw ProtocolError.replay }
            lastMeshSequence = Int64(envelope.sequence)
            content = try opener.open(envelope.payload)
            onEvent?(.envelope(envelope))
        case .routeControl:
            let reason = try RouteWithdrawal(decoding: record.payload)
            enqueue(.record(.routeControlAck, reason.encoded), .control, closeAfter: true)
            onEvent?(.routeWithdrawn(reason))
            finish("Immediate parent withdrew this stream route", error: false)
            return
        default:
            throw ProtocolError.malformed("Expected end-to-end stream content, got \(record.type)")
        }
        try handleContent(content)
    }

    private func handleContent(_ content: EndToEndContentRecord) throws {
        guard let header else {
            guard content.type == .streamHeader else { throw ProtocolError.state("Expected an end-to-end stream header") }
            let decoded = try StreamHeader(decoding: content.payload)
            let mask = StreamProtocol.capabilityMask(codecId: decoded.codecId)
            if grant == nil {
                guard (endpoint?.peerCapabilities.encodeCodecMask ?? 0) & mask != 0 else { throw ProtocolError.incompatible("Sender did not authenticate support for stream codec \(decoded.codecId)") }
            }
            guard endpointCapabilities.decodeCodecMask & mask != 0 else { throw ProtocolError.incompatible("This phone cannot decode stream codec \(decoded.codecId)") }
            self.header = decoded
            onEvent?(.header(decoded))
            // Labels are verified once the stream ID is known (after the header).
            if let payload = pendingLabels, let source = mediaSourceNodeId {
                pendingLabels = nil
                let binding = LabelBinding.stream(grant?.streamId ?? meshStreamId)
                if !labelInbox.accept(payload, expectedSigner: source, expectedBinding: binding).isEmpty, let title = labelInbox.text(.streamTitle) {
                    onEvent?(.title(title))
                }
            }
            return
        }
        switch content.type {
        case .mediaPacket:
            let packet = try MediaPacket(decoding: content.payload, authenticatedFlags: content.flags)
            receivedMediaBytes += UInt64(packet.payload.count)
            if packet.isAudio {
                guard header.hasAudio else { throw ProtocolError.malformed("Undeclared stream audio") }
                if packet.isCodecConfig { return }
                for unit in try packet.splitAudio() { audioPackets += 1; onEvent?(.audio(unit)) }
            } else if packet.flags & StreamProtocol.flagDisplayRotation != 0 {
                let degrees = try packet.decodeDisplayRotation()
                self.header?.rotationDegrees = degrees
                onEvent?(.rotation(degrees))
            } else {
                videoPackets += 1
                onEvent?(.video(packet))
            }
        case .streamState:
            let state = try StreamLifecycleState(decoding: content.payload)
            onEvent?(.state(state))
            if state == .ended {
                enqueue(.content(.streamEndAck, 0, Data()), .control, closeAfter: true)
                finish("Stream ended by the broadcaster", error: false)
            }
        case .privateCallSignal:
            throw ProtocolError.malformed("Private-call signals are not broadcast stream content")
        default:
            throw ProtocolError.malformed("Unexpected end-to-end stream content \(content.type)")
        }
    }

    /// Asks the immediate parent for a recovery keyframe (decoder error or join).
    public func requestKeyFrame() { if endpoint != nil { enqueue(.content(.keyFrameRequest, 0, Data()), .control) } }

    /// Hop-local link report (version 2): measured arrival kbps and whether playout is pinned late.
    public func sendLinkReport(arrivalKbps: Int, linkLate: Bool, addedDelayMs: Int) {
        guard phase == .open else { return }
        enqueue(.record(.linkHeartbeat, LinkHeartbeat.encode(LinkCapacityReport(arrivalKbps: arrivalKbps, linkLate: linkLate, addedDelayMs: addedDelayMs))), .control)
    }

    public var silentTimeout: TimeInterval { transport == .gatt ? 6 : 8 }

    public override func tickOpen(now: TimeInterval) {
        if now - lastReceiveAt > silentTimeout { finish("The stream link went silent", error: true); return }
        if now - lastHeartbeatAt >= StreamViewerEngine.heartbeatInterval {
            lastHeartbeatAt = now
            enqueue(.record(.linkHeartbeat, LinkHeartbeat.version1), .control)
        }
    }

    public override func didClose(reason: String, error: Bool) { onEvent?(.ended(reason, error: error)) }
}

/// Broadcasting to one viewer: link and endpoint initiator (central). Direct BME1 records, or mesh
/// envelopes when the viewer signed relay capacity (`maxChildren` 1), exactly as Android's sender.
public final class StreamSourceEngine: MeshConnection {
    public enum Event: Equatable {
        case viewerAuthenticated(NodeId, IdentityFingerprint)
        case keyFrameRequested
        case endAcknowledged
        case routeWithdrawalAcknowledged
        case peerReport(LinkCapacityReport)
        case ended(String, error: Bool)
    }
    public var onEvent: ((Event) -> Void)?
    public let header: StreamHeader
    public let sourceNodeId: NodeId
    public let streamId: UUID
    public private(set) var useMeshEnvelope = false
    public private(set) var ready = false
    private var meshSequence: UInt64 = 0
    private var lastHeartbeatAt: TimeInterval = 0
    private var expectHeartbeat = true
    public private(set) var paused = false
    /// Experimental labels: false = off; when on, `labelsTitle` is the optional title to sign.
    public let labelsEnabled: Bool
    public let labelsTitle: String?
    public private(set) var labelsSent = false

    public init(transport: MeshTransport, identity: SigningIdentity, header: StreamHeader, expectedViewerPrefix: Data?, streamId: UUID = UUID(),
                labels: Bool = false, title: String? = nil) {
        let mask = StreamProtocol.capabilityMask(codecId: header.codecId)
        let caps = NodeCapabilities(transportMask: transport.capabilityBit, encodeCodecMask: mask, decodeCodecMask: 0,
                                    maxBitrateKbps: transport.maxVideoBitrateKbps, maxChildren: 0)
        self.header = header; sourceNodeId = identity.nodeId; self.streamId = streamId
        labelsEnabled = labels; labelsTitle = title
        super.init(role: .initiator, transport: transport, identity: identity, linkCapabilities: caps,
                   endpointCapabilities: PeerLabelFeature.advertise(caps, enabled: labels))
        expectedPeerPrefix = expectedViewerPrefix
    }

    public override func validateLinkPeer() throws {
        guard let caps = link.peerCapabilities else { return }
        if let expectedPeerPrefix, link.peerNodeId?.prefix != expectedPeerPrefix { throw ProtocolError.authentication }
        if caps.maxChildren > 1 { throw ProtocolError.incompatible("Group-relay (BGK1) viewers are not supported on iPhone") }
    }

    public override func endpointDidAuthenticate(_ session: EndToEndSession) throws {
        guard session.peerCapabilities.decodeCodecMask & StreamProtocol.capabilityMask(codecId: header.codecId) != 0 else {
            throw ProtocolError.incompatible("Final receiver cannot decode the stream codec")
        }
        useMeshEnvelope = link.peerCapabilities!.maxChildren > 0
        lastHeartbeatAt = now
        if labelsEnabled, let linkPeer = link.peerNodeId,
           PeerLabelFeature.streamHopNegotiated(localEnabled: true, linkPeer: linkPeer, endpointPeer: session.peerNodeId, peer: session.peerCapabilities) {
            // One LABELS record before the header (count 0 if no title); title bound to the mesh stream ID or the zero ID.
            let binding = LabelBinding.stream(useMeshEnvelope ? streamId : nil)
            var labels: [Data] = []
            if let title = labelsTitle, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let signed = try? SignedLabelCodec.sign(identity: identity, kind: .streamTitle, binding: binding, text: title) { labels.append(signed) }
            enqueue(.content(.labels, 0, try SignedLabelCodec.encodeContainer(labels)), .control)
            labelsSent = true
        }
        enqueueStream(.streamHeader, flags: 0, payload: try header.encoded(), priority: .control)
        ready = true
        onEvent?(.viewerAuthenticated(session.peerNodeId, session.peerFingerprint))
    }

    private func enqueueStream(_ type: EndToEndContentType, flags: UInt8, payload: Data, priority: OutboundPriority, keyFrame: Bool = false, keep: Bool = false, extra: UInt8 = 0, closeAfter: Bool = false) {
        let kind: OutboundItem.Kind = useMeshEnvelope ? .mesh(type, flags, payload, extraMeshFlags: extra) : .content(type, flags, payload)
        if priority == .control { enqueue(kind, .control, closeAfter: closeAfter) }
        else { enqueueMedia(kind, audio: priority == .audio, keyFrame: keyFrame, keep: keep) }
    }

    public override func sealMesh(type: EndToEndContentType, flags: UInt8, payload: Data, extraMeshFlags: UInt8) throws -> Data {
        guard let endpoint else { throw ProtocolError.state("No endpoint") }
        let sealed = try endpoint.sealer.seal(type, flags: flags, payload)
        var meshFlags = MeshEnvelope.meshFlags(mediaFlags: flags) | extraMeshFlags
        if type == .streamState { meshFlags |= MeshEnvelope.flagControl }
        let envelope = MeshEnvelope(streamId: streamId, sourceNodeId: sourceNodeId, sequence: meshSequence, ttl: MeshEnvelope.defaultTtl, flags: meshFlags, payload: sealed)
        meshSequence += 1
        return try link.seal(.meshEnvelope, envelope.encoded)
    }

    public func sendAudio(presentationTimeUs: Int64, opus: Data) {
        guard ready, !paused else { return }
        let p = MediaPacket(flags: StreamProtocol.flagAudio, presentationTimeUs: presentationTimeUs, payload: opus)
        enqueueStream(.mediaPacket, flags: p.flags, payload: p.encoded, priority: .audio)
    }
    public func sendAudioConfig() {
        guard ready else { return }
        let p = MediaPacket(flags: StreamProtocol.flagAudio | StreamProtocol.flagCodecConfig, presentationTimeUs: 0, payload: OpusHead.make())
        enqueueStream(.mediaPacket, flags: p.flags, payload: p.encoded, priority: .control)
    }
    public func sendVideo(flags: UInt8, presentationTimeUs: Int64, payload: Data) {
        guard ready, !paused else { return }
        let p = MediaPacket(flags: flags, presentationTimeUs: presentationTimeUs, payload: payload)
        enqueueStream(.mediaPacket, flags: flags, payload: p.encoded, priority: .video,
                      keyFrame: flags & (StreamProtocol.flagKeyFrame | StreamProtocol.flagCodecConfig) != 0, keep: flags & StreamProtocol.flagCodecConfig != 0)
    }

    /// Pause clears queued media and repeats PAUSED every 2 s; resume queues LIVE before media.
    public func setPaused(_ value: Bool) {
        guard ready, paused != value else { return }
        paused = value
        if value { queues.clearMedia() }
        enqueueStream(.streamState, flags: 0, payload: (value ? StreamLifecycleState.paused : .live).encoded, priority: .control)
        lastPausedAt = now
    }
    private var lastPausedAt: TimeInterval = 0
    private var endingSince: TimeInterval?

    /// End clears queued media, sends ENDED and waits (at most 2 s) for the viewer's acknowledgement.
    public func endStream() {
        guard ready, endingSince == nil else { finish("Stream ended", error: false); return }
        queues.clearMedia()
        enqueueStream(.streamState, flags: 0, payload: StreamLifecycleState.ended.encoded, priority: .control, extra: MeshEnvelope.flagTerminal)
        endingSince = now
    }

    public override func handleOpenRecord(_ record: SecureRecord) throws {
        switch record.type {
        case .endToEndContent:
            guard let endpoint else { throw ProtocolError.state("No endpoint") }
            let content = try endpoint.opener.open(record.payload)
            guard content.payload.isEmpty else { throw ProtocolError.malformed("Invalid receiver control") }
            switch content.type {
            case .keyFrameRequest: onEvent?(.keyFrameRequested)
            case .streamEndAck:
                onEvent?(.endAcknowledged)
                if endingSince != nil { finish("Stream ended; viewer acknowledged", error: false) }
            default: throw ProtocolError.malformed("Expected an end-to-end receiver control")
            }
        case .linkHeartbeat:
            lastHeartbeatAt = now
            if let report = try LinkHeartbeat.decode(record.payload) { onEvent?(.peerReport(report)) }
        case .routeControlAck:
            _ = try RouteWithdrawal(decoding: record.payload)
            onEvent?(.routeWithdrawalAcknowledged)
            finish("Viewer route withdrawn", error: false)
        default:
            throw ProtocolError.malformed("Unexpected source control record \(record.type)")
        }
    }

    /// Hop-local overload: ask the viewer to look elsewhere; close after its ack (or 4 s).
    public func withdrawRoute() { enqueue(.record(.routeControl, RouteWithdrawal.localCapacity.encoded), .control); withdrawingSince = now }
    private var withdrawingSince: TimeInterval?

    public override func tickOpen(now: TimeInterval) {
        let timeout: TimeInterval = transport == .gatt ? 6 : 8
        if expectHeartbeat, now - lastHeartbeatAt > timeout, now - lastReceiveAt > timeout { finish("Immediate child heartbeat timed out", error: true); return }
        if let endingSince, now - endingSince > 2 { finish("Stream ended; viewer acknowledgement timed out", error: false); return }
        if let withdrawingSince, now - withdrawingSince > 4 { finish("Viewer route withdrawn (no acknowledgement)", error: false); return }
        if paused, now - lastPausedAt >= 2 {
            lastPausedAt = now
            enqueueStream(.streamState, flags: 0, payload: StreamLifecycleState.paused.encoded, priority: .control)
        }
    }

    public override func didClose(reason: String, error: Bool) { onEvent?(.ended(reason, error: error)) }
}
