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
        /// Experimental audio-only live: the verified `BTL1` header (no video follows).
        case audioLiveHeader(AudioLiveHeader)
        /// The verified OpusHead of an audio-only stream.
        case audioConfig(Data)
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
    /// The key that opens the media (the source's endpoint key, or the granted key on a forwarded route):
    /// what a relaying viewer wraps in BFG1 for its child.
    public var mediaOpenKey: Data? { mediaOpener?.keyBytes }
    /// A relaying viewer waits (at most 2 s) for its child's end acknowledgement before acknowledging upstream.
    public var holdEndAck = false
    private var endAckHeldSince: TimeInterval?
    public private(set) var audioPackets = 0
    public private(set) var videoPackets = 0
    /// AB5: codecs 4 and 5 pass the receiver's access-unit gate, made from the stream header.
    private var videoGate: AccessUnitGate?
    private var lastGateKeyFrameRequest: TimeInterval = -1_000
    /// A dropped access unit (`au_reject`): codec, rule, NAL type, payload bytes.
    public var onAccessUnitRejected: ((AnnexBCodec, Int, Int, Int) -> Void)?
    /// AW2 (Experimental, off): the Wi-Fi Direct guest of this stream hop (Design WF "Stream and relay hops"); nil while
    /// the Wi-Fi switches are off or the parent did not sign a build tag of at least `WifiWire.firstRelease`.
    public private(set) var wifi: WifiCallAgent?
    private let wifiConfig: WifiCallAgent.Config?
    public var onWifiRequest: ((WifiCallAgent.Request) -> Void)?
    public var onWifiLog: ((String, [String: String]) -> Void)?
    /// iPhone: the app is in the foreground (Android: the screen is on); otherwise a HOST gets DECLINE 1.
    public var wifiForeground: () -> Bool = { true }

    /// - Parameters:
    ///   - expectedAdjacentPrefix: the advertiser's prefix from its offer (checked against the link and endpoint).
    ///   - decodeMask: codecs this phone can actually decode.
    ///   - maxChildren: 1 when this iPhone offers to forward the stream (viewer-forwarder), else 0.
    /// EXPERIMENTAL rotating IDs phase 1b: the selected offer carries a role-1 rotating ID (Android version 5), so the
    /// connector must open it in its link BDO1 instead of matching a fixed prefix.
    public let rotatingOffer: DiscoveryAnnouncement?
    private let wallEpoch: () -> Int64
    /// Experimental audio-only live: the selected offer carried the `0x40` marker. The header must agree
    /// (BTL1 for a marked offer, BTV3 otherwise), else the link fails closed.
    /// Non-nil only for a parsed header whose kind disagreed with the selected advert.
    public private(set) var audioMarkerMismatch: Bool?
    /// Checked only after the link authenticates; unauthenticated prefixes never identify a banned node.
    public var isParentBlocked: ((NodeId) -> Bool)?
    public let expectAudioOnly: Bool
    /// The audio-live switch (Android `allowAudioOnly`, `audio_live`): off, a `BTL1` header fails as an unsupported
    /// header exactly as on a build without audio-only streams.
    public let allowAudioOnly: Bool
    /// The verified `BTL1` header and the per-stream guard of an audio-only stream.
    public var onAudioLivePayload: ((Int) -> Void)?
    public private(set) var audioLiveHeader: AudioLiveHeader?
    public private(set) var audioLiveGuard: AudioLiveStreamGuard?

    public init(transport: MeshTransport, identity: SigningIdentity, decodeMask: UInt8, expectedAdjacentPrefix: Data?,
                expectedMediaSource: NodeId? = nil, maxChildren: UInt8 = 0, labels: Bool = false,
                rotatingOffer: DiscoveryAnnouncement? = nil, wallEpoch: @escaping () -> Int64 = RotatingDiscoveryIds.currentWallEpoch,
                openingEntries: [OpeningEntry] = [],
                expectAudioOnly: Bool = false, allowAudioOnly: Bool = false, wifi: WifiCallAgent.Config? = nil) {
        self.expectAudioOnly = expectAudioOnly
        self.allowAudioOnly = allowAudioOnly
        wifiConfig = wifi
        var caps = NodeCapabilities(transportMask: transport.capabilityBit, encodeCodecMask: 0, decodeCodecMask: decodeMask & NodeCapabilities.helloCodecMask,
                                    maxBitrateKbps: transport.maxVideoBitrateKbps, maxChildren: maxChildren)
        self.expectedMediaSource = expectedMediaSource
        self.rotatingOffer = rotatingOffer?.rotating == true ? rotatingOffer : nil
        self.wallEpoch = wallEpoch
        labelsEnabled = labels
        let endpointCaps = PeerLabelFeature.advertise(caps, enabled: labels)
        // Link hello bit 3 on an LE stream hop (never the end-to-end hello): BDO1 is the first hop record each way.
        if self.rotatingOffer != nil { caps.transportMask |= NodeCapabilities.transportDiscoveryOpening }
        super.init(role: .responder, transport: transport, identity: identity, linkCapabilities: caps, endpointCapabilities: endpointCaps)
        arrivalMeter = ArrivalTrainMeter()
        if wifi != nil {
            // AW2 (Design WF "BMH2 hops"): a debug build signs release 11 as its link-hello build tag while a Wi-Fi switch
            // is on, and keeps this hop's UW once; with the switches off nothing here runs and every byte is as before.
            link.ownBuildTag = BuildTag(releaseKey: false, release: WifiWire.firstRelease)
            link.deriveHopWifiKey = true
        }
        if expectAudioOnly { link.maxIncomingCiphertextBytes = 4 * 1024 }
        expectedPeerPrefix = self.rotatingOffer == nil ? expectedAdjacentPrefix : nil
        if self.rotatingOffer != nil {
            // Phase 1b item 4: the listener sends the role-2 entries pinned when the connection was accepted (its compact
            // v2 request, on air or off air for less than 60 s); the caller evaluates the pins at accept. A viewer that
            // advertised a fixed-prefix request (rotating IDs off) passes none and opens nothing: count 0.
            let pinned = openingEntries.filter { $0.role == RotatingDiscoveryIds.roleViewerRequest }
            discoveryOpeningEntries = { pinned }
            onDiscoveryOpening = { [weak self] entries in try self?.checkRotatingOpening(entries) }
        }
    }

    private func checkRotatingOpening(_ entries: [OpeningEntry]) throws {
        guard let selected = rotatingOffer, let peer = link.peerNodeId else { return }
        guard DiscoverySelectionCheck.check(selected: selected, expectedRole: RotatingDiscoveryIds.roleStreamOffer, peerNodeId: peer.bytes,
                                            openingEntries: entries, verifierWallEpoch: wallEpoch()) == .pass else {
            throw ProtocolError.authentication
        }
    }

    public override func validateLinkPeer() throws {
        guard let caps = link.peerCapabilities else { return }
        if let node = link.peerNodeId, isParentBlocked?(node) == true {
            throw ProtocolError.incompatible("This route to the stream is temporarily unavailable")
        }
        if caps.maxChildren > 1 { throw ProtocolError.incompatible("Group-relay (BGK1) sources are not supported on iPhone") }
        if rotatingOffer != nil {
            // The connector of a selected rotating offer must sign bit 3 and open the ID; else it fails like a prefix mismatch.
            guard caps.transportMask & NodeCapabilities.transportDiscoveryOpening != 0 else { throw ProtocolError.authentication }
            return
        }
        if let expectedPeerPrefix, link.peerNodeId?.prefix != expectedPeerPrefix { throw ProtocolError.authentication }
    }

    public override func linkDidAuthenticate() { if let id = link.peerNodeId { onEvent?(.linkAuthenticated(id)) } }

    public override func endpointDidAuthenticate(_ session: EndToEndSession) throws {
        // SEC-B2: on every hop (version 2 and 5) the end-to-end peer is the authenticated link peer, by node ID.
        try StreamHopPeerBinding.require(role: .viewer, rotating: rotatingOffer != nil, link: link.peerNodeId, endpoint: session.peerNodeId)
        // A rotating hop's link peer must also have opened the selected ID.
        if rotatingOffer != nil {
            guard peerOpening != nil else { throw ProtocolError.authentication }
        }
        lastHeartbeatAt = now
        enqueue(.record(.linkHeartbeat, LinkHeartbeat.version1), .control)
        session.opener.acceptLabels = labelsEnabled
        if let linkPeer = link.peerNodeId {
            expectLabels = PeerLabelFeature.streamHopNegotiated(localEnabled: labelsEnabled, linkPeer: linkPeer,
                                                                endpointPeer: session.peerNodeId, peer: session.peerCapabilities)
        }
        if let wifiConfig, link.wifiBuildTagGate {
            // AW2: both link hellos carried the build tag, so the parent reads BWF1. The child sends CAPS first once the
            // header arrived (tickOpen); a hop that cannot use Wi-Fi Direct sends it all clear.
            let agent = WifiCallAgent(linkInitiator: false, uw: link.takeHopWifiKey(), peerSentMarker: true, config: wifiConfig,
                                      streamChild: true)
            agent.onRequest = { [weak self] request in self?.onWifiRequest?(request) }
            agent.log = { [weak self] event, fields in self?.onWifiLog?(event, fields) }
            agent.foreground = { [weak self] in self?.wifiForeground() ?? true }
            wifi = agent
            link.acceptWifi = true
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
        // AW2: with a Wi-Fi agent, type 16 goes to it, the parent's carrier-0 heartbeats (written once its hop machine
        // runs) are dropped as Android's stream child drops them, and BME1 content passes the cutover before it is opened.
        if let wifi {
            switch record.type {
            case .wifi:
                wifi.receivedOnBluetooth(record.payload, now: now)
                try deliverWifiContent([], now: now)
                return
            case .linkHeartbeat:
                return
            case .endToEndContent:
                guard let endpoint else { throw ProtocolError.state("No endpoint") }
                let sequence = try endpoint.opener.peekSequence(record.payload)
                guard wifi.bluetoothVerdict(sequence: sequence) == .deliver else { return }
                try handleStreamRecord(record)
                wifi.delivered(sequence: sequence)
                return
            default:
                break
            }
        }
        try handleStreamRecord(record)
    }

    private func handleStreamRecord(_ record: SecureRecord) throws {
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
            // Verify ingress rules and source signatures before handing media to the forwarding core.
            try handleContent(content)
            onEvent?(.envelope(envelope))
            return
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
        if let audioGuard = audioLiveGuard {
            try handleAudioLive(content, guard: audioGuard)
            return
        }
        guard let header else {
            guard content.type == .streamHeader else { throw ProtocolError.state("Expected an end-to-end stream header") }
            if AudioLive.isAudioLiveHeader(content.payload) {
                guard allowAudioOnly else { throw ProtocolError.incompatible("Unsupported stream header") }
                try acceptAudioLiveHeader(content.payload)
                return
            }
            let decoded = try StreamHeader(decoding: content.payload)
            if expectAudioOnly {
                audioMarkerMismatch = true
                throw ProtocolError.incompatible("The offer was marked audio only but the stream is video")
            }
            let mask = StreamProtocol.capabilityMask(codecId: decoded.codecId)
            if grant == nil {
                guard (endpoint?.peerCapabilities.encodeCodecMask ?? 0) & mask != 0 else { throw ProtocolError.incompatible("Sender did not authenticate support for stream codec \(decoded.codecId)") }
            }
            guard endpointCapabilities.decodeCodecMask & mask != 0 else { throw ProtocolError.incompatible("This phone cannot decode stream codec \(decoded.codecId)") }
            self.header = decoded
            videoGate = AnnexBCodec(codecId: decoded.codecId).map {
                AccessUnitGate(codec: $0, headerMaxWidth: decoded.width, headerMaxHeight: decoded.height)
            }
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
                if let gate = videoGate {
                    switch gate.check(packet.payload, flags: packet.flags, nowMs: Int64((now * 1000).rounded())) {
                    case .accept(let unit, _, _):
                        onEvent?(.video(MediaPacket(flags: packet.flags, presentationTimeUs: packet.presentationTimeUs, payload: unit)))
                    case .reject(let rule, let nalType, let bytes, _, _):
                        onAccessUnitRejected?(gate.codec, rule, nalType, bytes)
                        if now - lastGateKeyFrameRequest >= 0.75 { lastGateKeyFrameRequest = now; requestKeyFrame() }
                    case .close(let reason):
                        throw ProtocolError.incompatible("Unsupported \(gate.codec.label) stream: \(reason)")
                    }
                } else {
                    onEvent?(.video(packet))
                }
            }
        case .streamState:
            let state = try StreamLifecycleState(decoding: content.payload)
            onEvent?(.state(state))
            if state == .ended {
                if holdEndAck { endAckHeldSince = now } else { releaseEndAck() }
            }
        case .privateCallSignal:
            throw ProtocolError.malformed("Private-call signals are not broadcast stream content")
        default:
            throw ProtocolError.malformed("Unexpected end-to-end stream content \(content.type)")
        }
    }

    /// `BTL1`: the marker must agree, the certifying identity key must hash to the authenticated source, and the
    /// certificate must verify over the mesh stream ID (zeros for a direct stream). Exactly one header per stream.
    private func acceptAudioLiveHeader(_ payload: Data) throws {
        let decoded = try AudioLiveHeader(decoding: payload)
        if !expectAudioOnly {
            audioMarkerMismatch = false
            throw ProtocolError.incompatible("The offer was not marked audio only but the stream is audio only")
        }
        guard let source = mediaSourceNodeId else { throw ProtocolError.state("No media source") }
        let streamId = grant?.streamId ?? meshStreamId ?? AudioLive.zeroStreamId
        let verifier = try AudioLiveVerifier(header: decoded, streamId: streamId, expectedSource: source)
        audioLiveHeader = decoded
        audioLiveGuard = AudioLiveStreamGuard(verifier: verifier)
        link.maxIncomingCiphertextBytes = 28 * 1024
        onEvent?(.audioLiveHeader(decoded))
        if let labels = pendingLabels {
            pendingLabels = nil
            let binding = LabelBinding.stream(grant?.streamId ?? meshStreamId)
            if !labelInbox.accept(labels, expectedSigner: source, expectedBinding: binding).isEmpty, let title = labelInbox.text(.streamTitle) {
                onEvent?(.title(title))
            }
        }
    }

    /// After a `BTL1` header: only signed audio records and lifecycle records; a second header fails closed.
    private func handleAudioLive(_ content: EndToEndContentRecord, guard audioGuard: AudioLiveStreamGuard) throws {
        switch content.type {
        case .mediaPacket:
            try audioGuard.checkSealedSize(content.payload.count)
            let packet = try MediaPacket(decoding: content.payload, authenticatedFlags: content.flags)
            receivedMediaBytes += UInt64(packet.payload.count)
            let opened = try audioGuard.open(packet)
            if opened.isCodecConfig {
                if let head = audioGuard.opusHead { onEvent?(.audioConfig(head)) }
                return
            }
            onAudioLivePayload?(opened.payload.count)
            for unit in try opened.splitAudio() { audioPackets += 1; onEvent?(.audio(unit)) }
        case .streamState:
            try audioGuard.onLifecycleRecord()
            let state = try StreamLifecycleState(decoding: content.payload)
            onEvent?(.state(state))
            if state == .ended {
                if holdEndAck { endAckHeldSince = now } else { releaseEndAck() }
            }
        case .streamHeader:
            throw ProtocolError.malformed("A second stream header")
        default:
            throw ProtocolError.malformed("Unexpected content on an audio-only stream \(content.type)")
        }
    }

    /// Acknowledges ENDED upstream and closes (immediately, or once the relay's child acknowledged).
    public func releaseEndAck() {
        guard phase == .open else { return }
        endAckHeldSince = nil
        enqueue(.content(.streamEndAck, 0, Data()), .control, closeAfter: true)
        finish("Stream ended by the broadcaster", error: false)
    }

    /// Asks the immediate parent for a recovery keyframe (decoder error or join).
    public func requestKeyFrame() { if !expectAudioOnly, endpoint != nil { enqueue(.content(.keyFrameRequest, 0, Data()), .control) } }

    /// Hop-local link report (version 2): measured arrival kbps and whether playout is pinned late.
    public func sendLinkReport(arrivalKbps: Int, linkLate: Bool, addedDelayMs: Int) {
        guard phase == .open else { return }
        if arrivalKbps > 0 { linkMeasured = true }
        reportedLate = linkLate
        lastReportAt = now; onTimeReportedBytes = receivedMediaBytes
        enqueue(.record(.linkHeartbeat, LinkHeartbeat.encode(LinkCapacityReport(arrivalKbps: arrivalKbps, linkLate: linkLate, addedDelayMs: addedDelayMs))), .control)
    }

    /// On-time reports (Android 2026-10-16, `test_on_time_reports`, on by default): while this viewer has not measured
    /// its parent link, it says every 2 s that media still arrives on time (a version 2 report: 0 kbps, not late), so the
    /// parent keeps its starting pace instead of halving it after 4 s of silence. The existing report format, which
    /// every parent accepts from a viewer; off restores the silent viewer.
    public var onTimeReports = true
    public static let onTimeReportInterval: TimeInterval = 2
    private var linkMeasured = false, reportedLate = false
    private var lastReportAt: TimeInterval = -.infinity
    private var onTimeReportedBytes: UInt64 = 0
    public private(set) var onTimeReportsSent = 0

    /// Android `onTimeReportDue`: enabled, no measured trains, not late, media arrived since the last report, 2 s passed.
    static func onTimeReportDue(enabled: Bool, measured: Bool, late: Bool, mediaArrived: Bool, sinceLastReport: TimeInterval) -> Bool {
        enabled && !measured && !late && mediaArrived && sinceLastReport >= onTimeReportInterval
    }

    public var silentTimeout: TimeInterval { transport == .gatt ? 6 : 8 }

    /// Measured link reports (Android viewers, always on there): the parent link's arrival rate from
    /// record trains (`ArrivalTrainMeter`) goes to the parent at most once a second when a new train was measured, so a
    /// source or relay paces to what this link delivers. This viewer has no adaptive playout clock, so the report never
    /// says late and adds no delay. Off (control arm), only the on-time reports remain.
    public var measuredReports: Bool {
        get { arrivalMeter != nil }
        set { arrivalMeter = newValue ? (arrivalMeter ?? ArrivalTrainMeter()) : nil }
    }
    /// Android `CAPACITY_REPORT_INTERVAL_MS`.
    public static let capacityReportInterval: TimeInterval = 1
    private var reportedTrains = 0
    public private(set) var measuredReportsSent = 0
    public private(set) var lastMeasuredKbps = 0

    public override func tickOpen(now: TimeInterval) {
        if let held = endAckHeldSince, now - held > 2 { releaseEndAck(); return }
        if now - lastReceiveAt > silentTimeout, endAckHeldSince == nil { finish("The stream link went silent", error: true); return }
        // Android's viewer loop: a full report when a new train was measured or an on-time report is due, 1 s apart.
        let trains = arrivalMeter?.trains ?? 0
        // AW2: while the parent's media arrives on Wi-Fi the Bluetooth meter sees only heartbeats: report on time instead.
        let readingWifi = wifi?.cutover.acceptWifi == true
        let onTimeDue = Self.onTimeReportDue(enabled: onTimeReports, measured: !readingWifi && (linkMeasured || trains > 0), late: reportedLate,
                                             mediaArrived: receivedMediaBytes > onTimeReportedBytes, sinceLastReport: now - lastReportAt)
        if (!readingWifi && trains > reportedTrains) || onTimeDue, now - lastReportAt >= Self.capacityReportInterval {
            let kbps = readingWifi ? 0 : arrivalMeter?.estimateKbps(now: now) ?? 0
            if kbps > 0 || onTimeDue {
                lastReportAt = now; onTimeReportedBytes = receivedMediaBytes; reportedTrains = trains
                if kbps > 0 { linkMeasured = true; measuredReportsSent += 1; lastMeasuredKbps = kbps } else { onTimeReportsSent += 1 }
                enqueue(.record(.linkHeartbeat, LinkHeartbeat.encode(LinkCapacityReport(arrivalKbps: kbps, linkLate: false, addedDelayMs: 0))), .control)
            }
        }
        if now - lastHeartbeatAt >= StreamViewerEngine.heartbeatInterval {
            lastHeartbeatAt = now
            enqueue(.record(.linkHeartbeat, LinkHeartbeat.version1), .control)
        }
        if let wifi {
            // AW2 (Android HopCapsPlan STREAM_CHILD): CAPS once the first stream header arrived; only a direct video stream
            // (BME1 records, not mesh envelopes, not audio only) offers Wi-Fi Direct.
            wifi.hopEligible = wireMesh == false && audioLiveGuard == nil
            wifi.tick(now: now, ready: header != nil || audioLiveHeader != nil, heartbeat: LinkHeartbeat.version1)
            for record in wifi.takeBluetoothRecords() { enqueue(.record(.wifi, record.encoded()), .control) }
            do { try deliverWifiContent([], now: now) } catch { fail(describe(error)); return }
        }
    }

    public override func didClose(reason: String, error: Bool) {
        wifi?.callEnded(now: now)
        onEvent?(.ended(reason, error: error))
    }

    // MARK: AW2 Wi-Fi carrier (receive only: this side's own records stay on Bluetooth)

    /// A RESUME (this side never moves its own direction) leaves on Bluetooth before any further output.
    public override func carrierMarker() throws -> Data? {
        guard let wifi, let endpoint, let marker = wifi.takeMarker(nextSequence: endpoint.sealer.nextSequence) else { return nil }
        onWifiLog?("wifi_cutover", ["event": "marker_sent", "kind": "\(marker.kind)"])
        return try link.seal(.wifi, marker.encoded())
    }

    /// Content the Wi-Fi carrier delivered, then held records the cutover releases; each is opened once, in order.
    private func deliverWifiContent(_ records: [Data], now: TimeInterval) throws {
        guard let wifi, let endpoint else { return }
        applyWifiResync()
        for bme1 in records {
            let sequence = try endpoint.opener.peekSequence(bme1)
            if wifi.wifiVerdict(sequence: sequence, record: bme1, now: now) == .deliver {
                try handleStreamRecord(SecureRecord(type: .endToEndContent, payload: bme1))
                wifi.delivered(sequence: sequence)
            }
        }
        let released = wifi.takeReleased(now: now)
        applyWifiResync()
        for (sequence, bme1) in released {
            try handleStreamRecord(SecureRecord(type: .endToEndContent, payload: bme1))
            wifi.delivered(sequence: sequence)
        }
    }

    /// After a fallback or a hold promotion while the parent's media was read from Wi-Fi a frame may be lost: ask the
    /// parent for a keyframe (stream media has no fragments).
    private func applyWifiResync() {
        guard let wifi else { return }
        if wifi.takeFragmentActions().suppressReceive { requestKeyFrame() }
    }

    public func wifiJoined(ticket: Data, local: IPv4Interface, all: [IPv4Interface], band: DirectGuestRules.Band, now: TimeInterval) {
        self.now = now; wifi?.joined(ticket: ticket, local: local, all: all, band: band, now: now)
    }
    public func wifiJoinFailed(ticket: Data, reason: DeclineReason, detail: String, now: TimeInterval) {
        self.now = now; wifi?.joinFailed(ticket: ticket, reason: reason, detail: detail, now: now)
    }
    public func wifiConnected(ticket: Data, now: TimeInterval) { self.now = now; wifi?.connected(ticket: ticket, now: now) }
    public func wifiConnectFailed(ticket: Data, detail: String, now: TimeInterval) {
        self.now = now; wifi?.connectFailed(ticket: ticket, detail: detail, now: now)
    }
    public func wifiSocketClosed(ticket: Data, detail: String, now: TimeInterval) {
        self.now = now; wifi?.socketClosed(ticket: ticket, detail: detail, now: now)
        applyWifiResync()
    }
    public func wifiSendState(oldestPendingSince: TimeInterval?, ticket: Data, now: TimeInterval) {
        self.now = now; wifi?.socketSendState(oldestPendingSince: oldestPendingSince, ticket: ticket)
    }
    public func wifiReceive(_ data: Data, ticket: Data, now: TimeInterval) {
        guard phase == .open, let wifi else { return }
        self.now = now
        do { try deliverWifiContent(wifi.receivedOnSocket(data, ticket: ticket, now: now), now: now) } catch { fail(describe(error)) }
    }
    /// The next bytes for the Wi-Fi socket: the binding frames and the carrier's own records (BIND, READY, heartbeats).
    public func nextWifiOutgoing(now: TimeInterval) -> Data? {
        guard let wifi else { return nil }
        self.now = now
        return wifi.takeSocketBytes()
    }
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
    /// Experimental audio-only live: the stream's signer. The header is `BTL1`, every record is pre-signed
    /// (`sendSignedAudio`), and the stream always uses mesh envelopes under the signer's stream ID (as Android).
    public let audioLive: AudioLiveSigner?
    /// Audio-only age shedding (Android test_audio_live_age_bound, on): oldest whole records beyond 3 s, keep 1.5 s.
    public var audioAgeBound = true
    public private(set) var shedAudioRecords = 0
    private var audioHealth: [(at: TimeInterval, queued: Int, shed: Int)] = []

    /// - Parameters:
    ///   - selectedRequest: AB4: the viewer request this source dials. A rotating one (version 5 / compact v2) is checked
    ///     by its role-2 opening (PROTOCOL phase 1b item 4) instead of `expectedViewerPrefix`; nil or a version 2 request
    ///     keeps the prefix check exactly as before.
    ///   - wallEpoch: this device's wall epoch, the reference of the opening's two-epoch window (RD4).
    public init(transport: MeshTransport, identity: SigningIdentity, header: StreamHeader, expectedViewerPrefix: Data?, streamId: UUID = UUID(),
                labels: Bool = false, title: String? = nil, rotatingEntries: (() -> [OpeningEntry])? = nil,
                linkPacing: Bool = false, seedProbeKbps: Int? = nil, audioLive: AudioLiveSigner? = nil,
                selectedRequest: DiscoveryAnnouncement? = nil, wallEpoch: @escaping () -> Int64 = RotatingDiscoveryIds.currentWallEpoch) {
        let rotatingRequest = selectedRequest?.rotating == true ? selectedRequest : nil
        self.rotatingRequest = rotatingRequest
        self.wallEpoch = wallEpoch
        self.seedProbeKbps = seedProbeKbps
        self.audioLive = audioLive
        let streamId = audioLive?.streamId ?? streamId
        let mask = audioLive == nil ? StreamProtocol.capabilityMask(codecId: header.codecId) : 0
        var caps = NodeCapabilities(transportMask: transport.capabilityBit, encodeCodecMask: mask, decodeCodecMask: 0,
                                    maxBitrateKbps: transport.maxVideoBitrateKbps, maxChildren: 0)
        self.header = header; sourceNodeId = identity.nodeId; self.streamId = streamId
        labelsEnabled = labels; labelsTitle = title
        let endpointCaps = PeerLabelFeature.advertise(caps, enabled: labels)
        // EXPERIMENTAL rotating stream offers (phase 1b): the connector sends its pinned role-1 entries in BDO1. A selected
        // rotating request needs the link opening too (with no entries of its own the connector sends count 0).
        if rotatingEntries != nil || rotatingRequest != nil { caps.transportMask |= NodeCapabilities.transportDiscoveryOpening }
        super.init(role: .initiator, transport: transport, identity: identity, linkCapabilities: caps, endpointCapabilities: endpointCaps)
        expectedPeerPrefix = rotatingRequest == nil ? expectedViewerPrefix : nil
        if let rotatingEntries { discoveryOpeningEntries = rotatingEntries } else if rotatingRequest != nil { discoveryOpeningEntries = { [] } }
        if rotatingRequest != nil { onDiscoveryOpening = { [weak self] entries in try self?.checkRotatingRequest(entries) } }
        if linkPacing { pacer = makePacer() }
    }
    /// This phone's own fresh measurement of the transport (nil: the conservative prior).
    public let seedProbeKbps: Int?
    /// AB4: the selected viewer request when it is rotating (its six bytes are the viewer's role-2 RDI), else nil.
    public let rotatingRequest: DiscoveryAnnouncement?
    private let wallEpoch: () -> Int64
    /// AB4: the result of the role-2 opening check of a rotating request (the app logs `rotid_open`).
    public var onOpeningChecked: ((DiscoverySelectionCheck.Result) -> Void)?

    /// AB4 (PROTOCOL phase 1b item 4, RV15, RD4): the viewer's BDO1 must hold a role-2 entry that recomputes to the six
    /// selected bytes from the authenticated link node, within two epochs of this device's wall epoch.
    private func checkRotatingRequest(_ entries: [OpeningEntry]) throws {
        guard let selected = rotatingRequest, let peer = link.peerNodeId else { throw ProtocolError.authentication }
        let result = DiscoverySelectionCheck.check(selected: selected, expectedRole: RotatingDiscoveryIds.roleViewerRequest, peerNodeId: peer.bytes,
                                                   openingEntries: entries, verifierWallEpoch: wallEpoch())
        onOpeningChecked?(result)
        guard result == .pass else { throw ProtocolError.authentication }
    }

    public override func validateLinkPeer() throws {
        guard let caps = link.peerCapabilities else { return }
        if rotatingRequest != nil {
            // A selected rotating request: the viewer must sign bit 3 and open its ID; it never falls back to a prefix.
            guard caps.transportMask & NodeCapabilities.transportDiscoveryOpening != 0 else { throw ProtocolError.authentication }
        } else if let expectedPeerPrefix, link.peerNodeId?.prefix != expectedPeerPrefix { throw ProtocolError.authentication }
        if caps.maxChildren > 1 { throw ProtocolError.incompatible("Group-relay (BGK1) viewers are not supported on iPhone") }
    }

    public override func endpointDidAuthenticate(_ session: EndToEndSession) throws {
        // SEC-B2: on every hop (version 2 and 5) the end-to-end peer is the authenticated link peer, by node ID.
        try StreamHopPeerBinding.require(role: .source, rotating: rotatingRequest != nil, link: link.peerNodeId, endpoint: session.peerNodeId)
        // AB4: a rotating request's link peer must also have opened it (hop-local rule).
        if rotatingRequest != nil {
            guard peerOpening != nil else { throw ProtocolError.authentication }
        }
        guard audioLive != nil || session.peerCapabilities.decodeCodecMask & StreamProtocol.capabilityMask(codecId: header.codecId) != 0 else {
            throw ProtocolError.incompatible("Final receiver cannot decode the stream codec")
        }
        // Paced from the first write at the learned capacity or the conservative prior (Android LinkPacerSeed).
        pacer?.seed(kbps: LinkPacer.seedKbps(transport, probeKbps: seedProbeKbps))
        useMeshEnvelope = audioLive != nil || link.peerCapabilities!.maxChildren > 0
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
        enqueueStream(.streamHeader, flags: 0, payload: try audioLive?.header.encoded ?? header.encoded(), priority: .control)
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
    /// Audio-only live: one record already signed by `audioLive` (the same bytes for every listener). The Opus
    /// configuration travels as control so it precedes the media; media records are dropped while paused.
    public func sendSignedAudio(_ record: MediaPacket) {
        guard ready, audioLive != nil else { return }
        let config = record.flags & StreamProtocol.flagCodecConfig != 0
        guard config || !paused else { return }
        enqueueStream(.mediaPacket, flags: record.flags, payload: record.encoded, priority: config ? .control : .audio)
        if !config { audioHealth.append((now, 1, 0)) }
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
            if let report = try LinkHeartbeat.decode(record.payload) { applyPacingReport(report); onEvent?(.peerReport(report)) }
        case .routeControlAck:
            _ = try RouteWithdrawal(decoding: record.payload)
            onEvent?(.routeWithdrawalAcknowledged)
            finish("Viewer route withdrawn", error: false)
        default:
            throw ProtocolError.malformed("Unexpected source control record \(record.type)")
        }
    }

    /// Hop-local listener withdrawal (Android protocol reference "Health and withdrawal"): more than 20% of the records queued for this
    /// listener shed over 10 s, or its oldest queued record older than 30 s, withdraws the route so it reroutes.
    private func checkAudioHealth(now: TimeInterval) -> Bool {
        if audioAgeBound {
            let dropped = queues.shedAudio(now: now, trigger: 3, keep: 1.5)
            if dropped > 0 { shedAudioRecords += dropped; audioHealth.append((now, 0, dropped)) }
        }
        audioHealth.removeAll { now - $0.at > 10 }
        let queued = audioHealth.reduce(0) { $0 + $1.queued }, shed = audioHealth.reduce(0) { $0 + $1.shed }
        if (queued >= 10 && Double(shed) > 0.2 * Double(queued)) || queues.audioAge(now: now) > 30 {
            withdrawRoute()
            return true
        }
        return false
    }

    /// Hop-local overload: ask the viewer to look elsewhere; close after its ack (or 4 s).
    public func withdrawRoute() { enqueue(.record(.routeControl, RouteWithdrawal.localCapacity.encoded), .control); withdrawingSince = now }
    private var withdrawingSince: TimeInterval?

    public override func tickOpen(now: TimeInterval) {
        let timeout: TimeInterval = transport == .gatt ? 6 : 8
        if expectHeartbeat, now - lastHeartbeatAt > timeout, now - lastReceiveAt > timeout { finish("Immediate child heartbeat timed out", error: true); return }
        if let endingSince, now - endingSince > 2 { finish("Stream ended; viewer acknowledgement timed out", error: false); return }
        if let withdrawingSince, now - withdrawingSince > 4 { finish("Viewer route withdrawn (no acknowledgement)", error: false); return }
        if audioLive != nil, withdrawingSince == nil, endingSince == nil, checkAudioHealth(now: now) { return }
        if paused, now - lastPausedAt >= 2 {
            lastPausedAt = now
            enqueueStream(.streamState, flags: 0, payload: StreamLifecycleState.paused.encoded, priority: .control)
        }
    }

    public override func didClose(reason: String, error: Bool) { onEvent?(.ended(reason, error: error)) }
}

// MARK: - Viewer admission bounds (Android PreAuthAdmissionGate, Design QV review 1 R3)

/// A key table whose entries expire, with a hard size cap (Android `BoundedExpiringMap`): a write at the cap first drops
/// expired entries, then the entry that would expire soonest; a read drops an expired entry. Not thread-safe.
public struct BoundedExpiringTable<Value> {
    private var entries: [String: (until: TimeInterval, value: Value)] = [:]
    public let maxEntries: Int

    public init(maxEntries: Int) { self.maxEntries = maxEntries }

    public var count: Int { entries.count }

    public mutating func put(_ key: String, _ value: Value, until: TimeInterval, now: TimeInterval) {
        entries[key] = nil
        if entries.count >= maxEntries { sweep(now: now) }
        while entries.count >= maxEntries, let soonest = entries.min(by: { $0.value.until < $1.value.until })?.key {
            entries[soonest] = nil
        }
        entries[key] = (until, value)
    }

    /// The value while it has not expired (an expired entry is removed on the way).
    public mutating func get(_ key: String, now: TimeInterval) -> Value? {
        guard let entry = entries[key] else { return nil }
        if now >= entry.until { entries[key] = nil; return nil }
        return entry.value
    }

    /// The value whether or not it expired (callers that judge expiry themselves).
    public func peek(_ key: String) -> Value? { entries[key]?.value }

    public mutating func sweep(now: TimeInterval) { entries = entries.filter { now < $0.value.until } }

    public mutating func clear() { entries = [:] }
}

/// Pre-authentication admission of viewer requests at a source (Android `PreAuthAdmissionGate`, on; DEBUG control arm
/// `-viewerAdmissionBounds NO`). A crowd, or a flood of requests with fresh keys (new changing IDs or addresses), must not
/// hold the source's fan-out slots:
/// - at most `attemptsPerWindow(fanOut:)` = max(4, fan-out) new pre-authentication attempts start per 10 s; the others
///   are deferred to the next discovery update, never refused;
/// - requests are tried oldest key first (when this source first saw the key); a real viewer keeps its key while fake
///   keys come and go, so it soon is the oldest;
/// - a key whose attempt failed before authentication sorts after untried keys for 10 s, but is never excluded;
/// - a route-recovery request (it names its previous parent) goes first and is not counted;
/// - both tables are capped at 512 keys and expire (seen 30 s, failure 10 s).
/// It decides only the order and the pace of connection attempts: every admitted viewer still authenticates. Times are
/// seconds on one monotonic clock; the owner calls it on one queue.
public final class ViewerAdmissionGate {
    public static let window: TimeInterval = 10
    public static let minAttemptsPerWindow = 4
    public static let seenTTL: TimeInterval = 30
    public static let failurePenalty: TimeInterval = 10
    public static let maxTracked = 512

    /// A source admitting a whole group at once still dials every free slot in one window.
    public static func attemptsPerWindow(fanOut: Int) -> Int { max(minAttemptsPerWindow, fanOut) }

    /// Android `recoveryPreviousSenderKey`: a request is a route recovery (tried first, not counted) only when the child
    /// it names is a viewer this source holds now and is not the requester itself. The request's own flag is an
    /// unauthenticated claim: alone it never skips the bound.
    public static func isRecovery(requester: Data, namedChild: Data?, children: Set<Data>) -> Bool {
        guard let namedChild else { return false }
        return namedChild != requester && children.contains(namedChild)
    }

    private var firstSeen = BoundedExpiringTable<TimeInterval>(maxEntries: maxTracked)
    private var failures = BoundedExpiringTable<Bool>(maxEntries: maxTracked)
    private var attempts: [TimeInterval] = []
    private let enabled: () -> Bool

    public init(enabled: @escaping () -> Bool = { true }) { self.enabled = enabled }

    public var trackedKeys: Int { firstSeen.count + failures.count }

    /// How many new pre-authentication attempts may start now.
    public func allowance(now: TimeInterval, fanOut: Int) -> Int {
        attempts.removeAll { now - $0 >= Self.window }
        return max(0, Self.attemptsPerWindow(fanOut: fanOut) - attempts.count)
    }

    /// Orders `candidates` (recovery requests first, then untried before recently failed, then oldest key first, then
    /// as listed) and keeps the recovery requests plus at most `allowance` others; the rest are deferred. Off: all are
    /// chosen, as listed.
    public func select<P>(_ candidates: [P], key: (P) -> String, isRecovery: (P) -> Bool, fanOut: Int,
                          now: TimeInterval) -> (chosen: [P], deferred: [P]) {
        guard enabled() else { return (candidates, []) }
        for candidate in candidates {
            let k = key(candidate)
            firstSeen.put(k, firstSeen.peek(k) ?? now, until: now + Self.seenTTL, now: now)
        }
        failures.sweep(now: now)
        let ranked = candidates.enumerated().map { index, candidate in
            (candidate: candidate, recovery: isRecovery(candidate) ? 0 : 1, failed: failures.peek(key(candidate)) == nil ? 0 : 1,
             since: firstSeen.peek(key(candidate)) ?? now, index: index)
        }.sorted { a, b in
            if a.recovery != b.recovery { return a.recovery < b.recovery }
            if a.failed != b.failed { return a.failed < b.failed }
            if a.since != b.since { return a.since < b.since }
            return a.index < b.index
        }
        var left = allowance(now: now, fanOut: fanOut)
        var chosen: [P] = [], deferred: [P] = []
        for entry in ranked {
            if entry.recovery == 0 {
                chosen.append(entry.candidate)
            } else if left > 0 {
                chosen.append(entry.candidate); left -= 1
            } else {
                deferred.append(entry.candidate)
            }
        }
        return (chosen, deferred)
    }

    /// A non-recovery connection attempt started.
    public func noteAttempt(now: TimeInterval) {
        guard enabled() else { return }
        attempts.append(now)
    }

    /// The attempt for `key` ended before the viewer authenticated.
    public func noteFailure(_ key: String, now: TimeInterval) {
        guard enabled() else { return }
        failures.put(key, true, until: now + Self.failurePenalty, now: now)
    }

    public func clear() { firstSeen.clear(); failures.clear(); attempts.removeAll() }
}
