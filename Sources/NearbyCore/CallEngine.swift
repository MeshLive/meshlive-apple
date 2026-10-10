import Foundation

// Private call endpoint (Android AndroidPrivateVideoCall.kt): BMH2 link + endpoint handshakes, BMC2
// signalling, BTV3 header + Opus/video media, version 1/2/3 heartbeats, 8 s silent-link timeout.

public struct CallMediaSettings: Equatable {
    public var width: Int, height: Int, fps: Int, videoBitrate: Int, audioBitrate: Int, rotationDegrees: Int
    public init(width: Int = 426, height: Int = 240, fps: Int = 15, videoBitrate: Int = 300_000, audioBitrate: Int = 24_000, rotationDegrees: Int = 0) {
        self.width = width; self.height = height; self.fps = fps; self.videoBitrate = videoBitrate
        self.audioBitrate = audioBitrate; self.rotationDegrees = rotationDegrees
    }
}

/// Experimental peer labels for one call (naming phase 1). Nil = feature off: no hello bit, no type 10.
public struct CallLabelOptions {
    public var localName: String?
    public var subject: String?
    /// True when the peer's full fingerprint is a verified contact (R1: name at Ringing only then).
    public var isVerifiedPeer: (IdentityFingerprint) -> Bool
    public init(localName: String?, subject: String?, isVerifiedPeer: @escaping (IdentityFingerprint) -> Bool = { _ in false }) {
        self.localName = localName; self.subject = subject; self.isVerifiedPeer = isVerifiedPeer
    }
}

/// EXPERIMENTAL rotating discovery IDs for one call (nil = off: every byte unchanged).
public struct RotatingCallOptions {
    /// Caller: the advert the user selected (a rotating one requires the BDO1 opening, RV15).
    public var selected: DiscoveryAnnouncement?
    /// Callee: this phone's pinned role-0 opening entries (pin rule).
    public var entries: (() -> [OpeningEntry])?
    public init(selected: DiscoveryAnnouncement? = nil, entries: (() -> [OpeningEntry])? = nil) { self.selected = selected; self.entries = entries }
}

public final class CallEngine: MeshConnection {
    public enum Event: Equatable {
        case linkAuthenticated(NodeId)
        case peerAuthenticated(NodeId, IdentityFingerprint)
        case phase(PrivateCallPhase)
        case incomingCall(CallType)
        case offeredTypeChanged(CallType)
        /// Start microphone (and camera for video) with this header; send audio config then packets.
        case startLocalMedia(StreamHeader, CallType)
        case remoteHeader(StreamHeader)
        case remoteAudio(MediaPacket)
        case remoteVideo(MediaPacket)
        case remoteRotation(Int)
        case remoteCamera(Bool)
        case remoteMuted(Bool)
        case keyFrameRequested
        case peerReport(LinkCapacityReport)
        /// Verified self-chosen name and/or call subject of the peer (experimental labels).
        case peerLabels(name: String?, subject: String?)
        case ended(String, error: Bool)
    }

    public static let heartbeatInterval: TimeInterval = 1
    public static let silentLinkTimeout: TimeInterval = 8
    public static let ringTimeout: TimeInterval = 60

    public let callRole: PrivateCallRole
    public let negotiation: VoiceCallNegotiation
    public var onEvent: ((Event) -> Void)?
    public private(set) var state: PrivateCallState?
    public private(set) var relayHops: UInt8
    public private(set) var selectedCodec: UInt8?
    public private(set) var remoteHeader: StreamHeader?
    public private(set) var localHeader: StreamHeader?
    public private(set) var muted = false
    public private(set) var cameraEnabled: Bool
    public var settings: CallMediaSettings
    /// Android's experimental call video fragments (BME1 type 9); off by default, as on Android.
    public let fragmentsEnabled: Bool
    private(set) var peerAcceptsFragments = false
    private var reassembler = CallVideoReassembler()
    private var lastHeartbeatAt: TimeInterval = 0
    private var ringingSince: TimeInterval = 0
    private var mediaStarted = false
    /// The peer sent a version-1 heartbeat after its endpoint handshake: it accepts version-3 reports.
    public private(set) var peerAcceptsDeliveryReports = false
    private var receivedMediaBytes: UInt32 = 0
    private var receivedMediaClockMs: UInt32 = 0
    public private(set) var receivedAudioPackets = 0
    public private(set) var receivedVideoPackets = 0
    public private(set) var sentAudioPackets = 0
    public private(set) var sentVideoPackets = 0
    public let labelOptions: CallLabelOptions?
    public private(set) var peerAcceptsLabels = false
    private var bufferedLabels: Data?
    private var pendingAcceptLabels: Data?
    public let labelInbox = LabelInbox()

    /// - Parameters:
    ///   - encodeMask: codecs this phone can actually encode (BTV3 header codec must be one of them).
    ///   - decodeMask: codecs this phone can actually decode.
    public init(role: PrivateCallRole, transport: MeshTransport, identity: SigningIdentity, requestedType: CallType,
                encodeMask: UInt8, decodeMask: UInt8, settings: CallMediaSettings = CallMediaSettings(),
                expectedPeerPrefix: Data? = nil, relayHops: UInt8 = 0, videoFragments: Bool = false, labels: CallLabelOptions? = nil,
                rotating: RotatingCallOptions? = nil) {
        labelOptions = labels
        rotatingOptions = rotating
        callRole = role
        negotiation = VoiceCallNegotiation(role: role, requested: requestedType)
        self.relayHops = relayHops
        self.settings = settings
        cameraEnabled = requestedType == .video
        fragmentsEnabled = videoFragments
        var link = NodeCapabilities(transportMask: transport.capabilityBit, encodeCodecMask: encodeMask & NodeCapabilities.codecMask,
                                    decodeCodecMask: decodeMask & NodeCapabilities.codecMask, maxBitrateKbps: transport.maxVideoBitrateKbps, maxChildren: 0)
        var endpointCaps = link
        // Rotating IDs: bit 3 only in the call-endpoint link hello (never the endpoint hello).
        if rotating != nil { link.transportMask |= NodeCapabilities.transportDiscoveryOpening }
        if videoFragments { endpointCaps.transportMask |= NodeCapabilities.transportVideoFragments }
        endpointCaps = PeerLabelFeature.advertise(endpointCaps, enabled: labels != nil)
        super.init(role: role == .caller ? .initiator : .responder, transport: transport, identity: identity,
                   linkCapabilities: link, endpointCapabilities: endpointCaps)
        self.expectedPeerPrefix = rotating?.selected?.rotating == true ? nil : expectedPeerPrefix
        if let rotating {
            discoveryOpeningEntries = { [weak self] in self?.callRole == .callee ? (rotating.entries?() ?? []) : [] }
            onDiscoveryOpening = { [weak self] entries in try self?.checkOpening(entries) }
        }
    }

    // MARK: Experimental rotating discovery IDs (RV15)
    private let rotatingOptions: RotatingCallOptions?
    private var selectedRotating: DiscoveryAnnouncement? { rotatingOptions?.selected.flatMap { $0.rotating ? $0 : nil } }

    public override func validateLinkPeer() throws {
        // A selected rotating advert needs the opening; a peer without bit 3 fails like a prefix mismatch.
        if selectedRotating != nil, (link.peerCapabilities?.transportMask ?? 0) & NodeCapabilities.transportDiscoveryOpening == 0 {
            throw ProtocolError.authentication
        }
    }

    private func checkOpening(_ entries: [OpeningEntry]) throws {
        guard let selected = selectedRotating, let peer = link.peerNodeId else { return }
        guard DiscoverySelectionCheck.check(selected: selected, expectedRole: RotatingDiscoveryIds.roleCallOffer, peerNodeId: peer.bytes,
                                            openingEntries: entries) == .pass else { throw ProtocolError.authentication }
    }

    // A relayed caller's adjacent link is the relay; the endpoint must still match the callee prefix.
    public override var expectedPrefixAppliesToEndpoint: Bool { true }

    public override func linkDidAuthenticate() { if let id = link.peerNodeId { onEvent?(.linkAuthenticated(id)) } }

    public override func endpointDidAuthenticate(_ session: EndToEndSession) throws {
        // Phase 1 calls rotating offers only directly: the endpoint must be the link peer that opened the ID.
        if selectedRotating != nil {
            guard session.peerNodeId == link.peerNodeId, peerOpening != nil else { throw ProtocolError.authentication }
        }
        onEvent?(.peerAuthenticated(session.peerNodeId, session.peerFingerprint))
        peerAcceptsFragments = fragmentsEnabled && relayHops == 0 && session.peerCapabilities.transportMask & NodeCapabilities.transportVideoFragments != 0
        session.opener.acceptVideoFragments = fragmentsEnabled
        session.opener.acceptLabels = labelOptions != nil
        peerAcceptsLabels = PeerLabelFeature.negotiated(localEnabled: labelOptions != nil, peer: session.peerCapabilities)
        selectedCodec = CallEngine.codecForPeer(local: endpointCapabilities.encodeCodecMask, peerDecode: session.peerCapabilities.decodeCodecMask)
        guard selectedCodec != nil else { throw ProtocolError.incompatible("Peer cannot decode any locally available call codec") }
        let peerMax = Int(session.peerCapabilities.maxBitrateKbps)
        if peerMax > 0 { settings.videoBitrate = min(settings.videoBitrate, peerMax * 1000) }
        lastHeartbeatAt = now
        // Version-1 heartbeat: "this endpoint accepts version 3 reports" (Android CallDeliveryReports).
        enqueue(.record(.linkHeartbeat, LinkHeartbeat.version1), .control)
        if callRole == .caller {
            let initial = PrivateCallState.outgoing()
            state = initial
            ringingSince = now
            onEvent?(.phase(initial.phase))
            // Labels: one container (own name if set, and the subject) immediately before Invite.
            if peerAcceptsLabels, let options = labelOptions {
                let binding = LabelBinding.call(initial.callId)
                let labels = [signLabel(.personName, options.localName, binding), signLabel(.callSubject, options.subject, binding)].compactMap { $0 }
                if !labels.isEmpty, let container = try? SignedLabelCodec.encodeContainer(labels) { enqueue(.content(.labels, 0, container), .control) }
            }
            for signal in negotiation.inviteSignals() { try sendSignal(signal) }
        }
    }

    /// Android `privateCallCodecForPeer`: honour a VP9 preference bit, else any common codec.
    public static func codecForPeer(local: UInt8, peerDecode: UInt8) -> UInt8? {
        if peerDecode & NodeCapabilities.decodePrefersVP9 != 0, local & NodeCapabilities.codecVP9 != 0 { return StreamProtocol.codecVP9 }
        if peerDecode & NodeCapabilities.decodePrefersH264 != 0, local & NodeCapabilities.codecH264 != 0, StreamProtocol.h264Enabled { return StreamProtocol.codecH264 }
        for (bit, codec) in [(NodeCapabilities.codecVP9, StreamProtocol.codecVP9), (NodeCapabilities.codecAV1, StreamProtocol.codecAV1), (NodeCapabilities.codecH264, StreamProtocol.codecH264)]
        where local & bit != 0 && peerDecode & bit != 0 {
            if codec == StreamProtocol.codecH264 && !StreamProtocol.h264Enabled { continue }
            return codec
        }
        return nil
    }

    private func sendSignal(_ signal: PrivateCallSignal, reason: PrivateCallReason = .none, closeAfter: Bool = false) throws {
        guard let state else { throw ProtocolError.state("No call") }
        let message = try PrivateCallSignalMessage(callId: state.callId, signal: signal, reason: reason, relayHops: signal == .invite ? relayHops : 0)
        enqueue(.content(.privateCallSignal, 0, message.encoded), .control, closeAfter: closeAfter)
    }

    private func transition(_ event: PrivateCallEvent) throws {
        guard let current = state else { throw ProtocolError.state("No call") }
        let next = try current.transition(event)
        state = next
        onEvent?(.phase(next.phase))
    }

    public override func handleOpenRecord(_ record: SecureRecord) throws {
        switch record.type {
        case .linkHeartbeat:
            if let report = try LinkHeartbeat.decode(record.payload) { onEvent?(.peerReport(report)) }
            else { peerAcceptsDeliveryReports = true }
        case .endToEndContent:
            guard let endpoint else { throw ProtocolError.state("No endpoint") }
            try handleContent(try endpoint.opener.open(record.payload))
        default:
            throw ProtocolError.malformed("Unexpected private-call record \(record.type)")
        }
    }

    private func handleContent(_ content: EndToEndContentRecord) throws {
        switch content.type {
        case .privateCallSignal:
            try handleSignal(try PrivateCallSignalMessage(decoding: content.payload))
        case .streamHeader:
            try reassembler.requireIdle("A call stream header")
            let header = try StreamHeader(decoding: content.payload)
            guard endpointCapabilities.decodeCodecMask & StreamProtocol.capabilityMask(codecId: header.codecId) != 0 else {
                throw ProtocolError.incompatible("This phone cannot decode the peer's call codec")
            }
            guard (endpoint?.peerCapabilities.encodeCodecMask ?? 0) & StreamProtocol.capabilityMask(codecId: header.codecId) != 0 else {
                throw ProtocolError.authentication
            }
            remoteHeader = header
            onEvent?(.remoteHeader(header))
            if state?.phase == .negotiatingMedia { try transition(.mediaReady) }
        case .mediaPacket:
            guard remoteHeader != nil else { throw ProtocolError.state("Peer sent media before its call header") }
            let packet = try MediaPacket(decoding: content.payload, authenticatedFlags: content.flags)
            if packet.flags & StreamProtocol.flagDisplayRotation == 0 { countReceived(packet.payload.count) }
            if !packet.isAudio { try reassembler.requireIdle("A whole call video packet") }
            try deliver(packet)
        case .videoFragment:
            guard fragmentsEnabled, remoteHeader != nil else { throw ProtocolError.state("Unexpected call video fragment") }
            countReceived(content.payload.count - CallVideoFragments.headerBytes)
            if let whole = try reassembler.accept(flags: content.flags, fragment: content.payload) {
                try deliver(try MediaPacket(decoding: whole, authenticatedFlags: content.flags))
            }
        case .keyFrameRequest:
            guard content.payload.isEmpty else { throw ProtocolError.malformed("Invalid call keyframe request") }
            onEvent?(.keyFrameRequested)
        case .labels:
            // R3: at most one container before this session's Invite, verified when the Invite gives the call ID.
            if let state { applyLabels(content.payload, callId: state.callId) }
            else if bufferedLabels == nil { bufferedLabels = content.payload }
        default:
            throw ProtocolError.malformed("Unexpected private-call content \(content.type)")
        }
    }

    private func signLabel(_ kind: LabelKind, _ text: String?, _ binding: LabelBinding) -> Data? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try? SignedLabelCodec.sign(identity: identity, kind: kind, binding: binding, text: text)
    }

    private func applyLabels(_ payload: Data, callId: UUID) {
        guard let endpoint else { return }
        let changed = labelInbox.accept(payload, expectedSigner: endpoint.peerNodeId, expectedBinding: .call(callId))
        if !changed.isEmpty { onEvent?(.peerLabels(name: labelInbox.text(.personName), subject: labelInbox.text(.callSubject))) }
    }

    /// R1: the callee's name is sent at Ringing only to a verified contact (full fingerprint), else with Accept.
    private func prepareCalleeLabels(callId: UUID) {
        guard let options = labelOptions, let endpoint, let label = signLabel(.personName, options.localName, .call(callId)),
              let container = try? SignedLabelCodec.encodeContainer([label]) else { return }
        if options.isVerifiedPeer(endpoint.peerFingerprint) { enqueue(.content(.labels, 0, container), .control) }
        else { pendingAcceptLabels = container }
    }

    private func countReceived(_ bytes: Int) {
        receivedMediaBytes &+= UInt32(truncatingIfNeeded: bytes)
        receivedMediaClockMs = UInt32(truncatingIfNeeded: Int64(((now - startedAt) * 1000).rounded()))
    }

    private func deliver(_ packet: MediaPacket) throws {
        guard let header = remoteHeader else { return }
        if packet.isAudio {
            guard header.hasAudio else { throw ProtocolError.malformed("Peer sent undeclared call audio") }
            if packet.isCodecConfig { return } // OpusHead/AOPUSHDR: libopus needs no setup data for mono 48 kHz
            for unit in try packet.splitAudio() { receivedAudioPackets += 1; onEvent?(.remoteAudio(unit)) }
        } else if packet.flags & StreamProtocol.flagDisplayRotation != 0 {
            let degrees = try packet.decodeDisplayRotation()
            remoteHeader?.rotationDegrees = degrees
            onEvent?(.remoteRotation(degrees))
        } else {
            receivedVideoPackets += 1
            onEvent?(.remoteVideo(packet))
        }
    }

    private func handleSignal(_ message: PrivateCallSignalMessage) throws {
        guard let current = state else {
            guard callRole == .callee, message.signal == .invite else { throw ProtocolError.state("Expected a private-call invitation") }
            relayHops = message.relayHops
            let incoming = PrivateCallState.incoming(callId: message.callId)
            state = incoming
            ringingSince = now
            onEvent?(.phase(incoming.phase))
            try sendSignal(.ringing)
            if let buffered = bufferedLabels { bufferedLabels = nil; applyLabels(buffered, callId: message.callId) }
            if peerAcceptsLabels { prepareCalleeLabels(callId: message.callId) }
            onEvent?(.incomingCall(.video))
            return
        }
        guard message.callId == current.callId else { throw ProtocolError.state("Private-call ID changed during the call") }
        switch message.signal {
        case .ringing: try transition(.remoteRinging)
        case .accept:
            try transition(.remoteAccept)
            startLocalMedia()
        case .decline:
            try transition(.remoteDecline); finish("Call declined (\(message.reason))", error: false)
        case .cancel:
            try transition(.remoteCancel); finish("Caller cancelled", error: false)
        case .hangUp:
            try transition(.remoteHangUp)
            finish(message.reason == .error ? "Peer's phone ended the call after a local media failure" : "Peer ended the call", error: false)
        case .cameraOff, .cameraOn:
            let enabled = message.signal == .cameraOn
            if negotiation.onRemoteCameraSignal(phase: current.phase, enabled: enabled) {
                onEvent?(.offeredTypeChanged(negotiation.peerOfferedVoice ? .voice : .video))
            }
            onEvent?(.remoteCamera(enabled))
        case .microphoneMuted: onEvent?(.remoteMuted(true))
        case .microphoneUnmuted: onEvent?(.remoteMuted(false))
        case .invite: throw ProtocolError.state("Duplicate private-call invitation")
        }
    }

    private func startLocalMedia() {
        guard !mediaStarted, let codec = selectedCodec else { return }
        mediaStarted = true
        let header = StreamHeader(width: settings.width, height: settings.height, fps: settings.fps, codecId: codec,
                                  rotationDegrees: settings.rotationDegrees, includeAudio: true)
        localHeader = header
        guard let encoded = try? header.encoded() else { fail("Invalid local call header"); return }
        enqueue(.content(.streamHeader, 0, encoded), .control)
        let config = MediaPacket(flags: StreamProtocol.flagAudio | StreamProtocol.flagCodecConfig, presentationTimeUs: 0, payload: OpusHead.make())
        enqueue(.content(.mediaPacket, config.flags, config.encoded), .control)
        onEvent?(.startLocalMedia(header, cameraEnabled ? .video : .voice))
    }

    // MARK: User actions

    public func accept(as type: CallType? = nil) throws {
        guard callRole == .callee, state?.phase == .incomingRinging else { throw ProtocolError.state("No incoming call") }
        try transition(.localAccept)
        let answerVoice = (type ?? negotiation.localType) == .voice
        cameraEnabled = !answerVoice
        // R1: the callee's name travels immediately before Accept (never on decline, cancel or no answer).
        if let labels = pendingAcceptLabels { pendingAcceptLabels = nil; enqueue(.content(.labels, 0, labels), .control) }
        try sendSignal(.accept)
        if answerVoice { try sendSignal(.cameraOff) }
        startLocalMedia()
    }

    public func decline(_ reason: PrivateCallReason = .rejected) throws {
        guard state?.phase == .incomingRinging else { throw ProtocolError.state("No incoming call") }
        try transition(.localDecline)
        try sendSignal(.decline, reason: reason, closeAfter: true)
        finish("Call declined", error: false)
    }

    public func cancel() throws {
        guard let phase = state?.phase, phase == .outgoingInvite || phase == .outgoingRinging else { throw ProtocolError.state("No outgoing call") }
        try transition(.localCancel)
        try sendSignal(.cancel, closeAfter: true)
        finish("Call cancelled", error: false)
    }

    /// Ends the call from any phase (cancel/decline/hang up as appropriate).
    public func end() {
        do {
            switch state?.phase {
            case .outgoingInvite?, .outgoingRinging?: try cancel()
            case .incomingRinging?: try decline()
            case .negotiatingMedia?, .active?:
                try transition(.localHangUp)
                try sendSignal(.hangUp, reason: .normal, closeAfter: true)
                finish("Call ended", error: false)
            default: finish("Call ended", error: false)
            }
        } catch { fail(describe(error)) }
    }

    /// Hang up after a local media failure (the peer sees an error hang-up, not link loss).
    public func endForLocalMediaFailure(_ message: String) {
        if let phase = state?.phase, phase == .negotiatingMedia || phase == .active {
            try? transition(.localHangUp)
            try? sendSignal(.hangUp, reason: .error, closeAfter: true)
            finish(message, error: false)
        } else { fail(message) }
    }

    public func setMuted(_ value: Bool) {
        guard muted != value, state != nil else { muted = value; return }
        muted = value
        try? sendSignal(value ? .microphoneMuted : .microphoneUnmuted)
    }

    public func setCameraEnabled(_ enabled: Bool) {
        guard cameraEnabled != enabled else { return }
        cameraEnabled = enabled
        if state != nil { try? sendSignal(enabled ? .cameraOn : .cameraOff) }
    }

    public func requestKeyFrame() { if endpoint != nil { enqueue(.content(.keyFrameRequest, 0, Data()), .control) } }

    public func sendRotation(_ degrees: Int) {
        guard mediaStarted, let packet = try? MediaPacket.displayRotation(degrees) else { return }
        // Video queue: a rotation packet is a non-audio media packet and must not split a fragmented frame.
        enqueueMedia(.content(.mediaPacket, packet.flags, packet.encoded), audio: false, keyFrame: false, keep: true)
    }

    // MARK: Local media

    public var canSendMedia: Bool { mediaStarted && phase == .open }

    /// One Opus access unit (20 ms). Dropped while muted, like Android's push-to-talk.
    public func sendAudio(presentationTimeUs: Int64, opus: Data) {
        guard canSendMedia, !muted else { return }
        let packet = MediaPacket(flags: StreamProtocol.flagAudio, presentationTimeUs: presentationTimeUs, payload: opus)
        if enqueueMedia(.content(.mediaPacket, packet.flags, packet.encoded), audio: true, keyFrame: false) { sentAudioPackets += 1 }
    }

    /// One encoded video access unit (or codec configuration). Returns false when shed (request a keyframe).
    @discardableResult
    public func sendVideo(flags: UInt8, presentationTimeUs: Int64, payload: Data) -> Bool {
        guard canSendMedia, cameraEnabled else { return false }
        let packet = MediaPacket(flags: flags, presentationTimeUs: presentationTimeUs, payload: payload)
        let plaintext = packet.encoded
        let keyFrame = flags & StreamProtocol.flagKeyFrame != 0 || flags & StreamProtocol.flagCodecConfig != 0
        let keep = flags & StreamProtocol.flagCodecConfig != 0
        if peerAcceptsFragments && CallVideoFragments.shouldFragment(packetPlaintextBytes: plaintext.count, flags: flags),
           let fragments = try? CallVideoFragments.split(plaintext) {
            let ok = enqueueMedia(.fragments(flags, fragments), audio: false, keyFrame: keyFrame)
            if ok { sentVideoPackets += 1 }
            return ok
        }
        let ok = enqueueMedia(.content(.mediaPacket, flags, plaintext), audio: false, keyFrame: keyFrame, keep: keep)
        if ok { sentVideoPackets += 1 }
        return ok
    }

    // MARK: Timers

    public override func tickOpen(now: TimeInterval) {
        if now - lastReceiveAt > CallEngine.silentLinkTimeout { finishLost("Call peer stopped responding"); return }
        if let phase = state?.phase, now - ringingSince > CallEngine.ringTimeout {
            if phase == .outgoingInvite || phase == .outgoingRinging { try? cancel(); return }
            if phase == .incomingRinging { try? decline(.rejected); return }
        }
        if now - lastHeartbeatAt >= CallEngine.heartbeatInterval {
            lastHeartbeatAt = now
            // Version 3 only to a direct peer that announced it accepts it; older endpoints close on anything but v2.
            let direct = state != nil && relayHops == 0 && peerAcceptsDeliveryReports
            let report = LinkCapacityReport(arrivalKbps: 0, linkLate: false, addedDelayMs: 0,
                                            receivedBytes: direct ? receivedMediaBytes : nil, clockMs: direct ? receivedMediaClockMs : nil,
                                            deliveryOnly: false)
            enqueue(.record(.linkHeartbeat, LinkHeartbeat.encode(report)), .control)
        }
    }

    private func finishLost(_ reason: String) {
        if state != nil { try? transition(.linkLost) }
        finish(reason, error: true)
    }

    public override func didClose(reason: String, error: Bool) {
        if error, let phase = state?.phase, phase != .ended { if let next = try? state?.transition(.linkLost) { state = next; onEvent?(.phase(next.phase)) } }
        onEvent?(.ended(reason, error: error))
    }
}
