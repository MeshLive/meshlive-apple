import Foundation

// Sans-I/O connection core shared by calls and streams: BMH2 link + endpoint handshakes, then
// prioritized, pull-based sealing. Transports push received bytes in and pull sealed bytes out when
// they can write, so BMS1/BME1 sequence numbers are assigned in exact transmission order.

public enum OutboundPriority { case control, audio, video }

public struct OutboundItem {
    enum Kind {
        case raw(Data)
        case record(SecureRecordType, Data)
        case content(EndToEndContentType, UInt8, Data)
        case mesh(EndToEndContentType, UInt8, Data, extraMeshFlags: UInt8)
        /// One video frame as experimental call fragments; sent in order, only audio/control may interleave.
        case fragments(UInt8, [Data])
    }
    let kind: Kind
    let enqueuedAt: TimeInterval
    let isKeyFrame: Bool
    let closeAfter: Bool
    /// Never shed (codec configuration, rotation).
    var keep = false
}

public struct OutboundQueues {
    public var audioCapacity = 150
    public var videoCapacity = 45
    var control: [OutboundItem] = []
    var audio: [OutboundItem] = []
    var video: [OutboundItem] = []
    var fragmentRemainder: [OutboundItem] = []
    public private(set) var droppedVideoFrames = 0
    public private(set) var droppedAudioPackets = 0
    var waitingForKeyFrame = false

    var isEmpty: Bool { control.isEmpty && audio.isEmpty && video.isEmpty && fragmentRemainder.isEmpty }
    var count: Int { control.count + audio.count + video.count + fragmentRemainder.count }
    public var videoBacklog: Int { video.count }

    mutating func push(_ item: OutboundItem, _ priority: OutboundPriority) -> Bool {
        switch priority {
        case .control: control.append(item); return true
        case .audio:
            if audio.count >= audioCapacity { audio.removeFirst(); droppedAudioPackets += 1 }
            audio.append(item); return true
        case .video:
            if item.keep { video.append(item); return true }
            if waitingForKeyFrame && !item.isKeyFrame { droppedVideoFrames += 1; return false }
            if video.count >= videoCapacity {
                // Whole-frame shedding: drop the queued dependent chain and wait for a fresh keyframe.
                let kept = video.filter(\.keep)
                droppedVideoFrames += video.count - kept.count + (item.isKeyFrame ? 0 : 1)
                video = kept
                if !item.isKeyFrame { waitingForKeyFrame = true; return false }
            }
            waitingForKeyFrame = false
            video.append(item); return true
        }
    }

    mutating func pop() -> OutboundItem? {
        if !control.isEmpty { return control.removeFirst() }
        if !audio.isEmpty { return audio.removeFirst() }
        if !fragmentRemainder.isEmpty { return fragmentRemainder.removeFirst() }
        guard !video.isEmpty else { return nil }
        let item = video.removeFirst()
        if case .fragments(let flags, let parts) = item.kind, parts.count > 1 {
            fragmentRemainder = parts.dropFirst().map {
                OutboundItem(kind: .content(.videoFragment, flags, $0), enqueuedAt: item.enqueuedAt, isKeyFrame: false, closeAfter: false)
            }
            return OutboundItem(kind: .content(.videoFragment, flags, parts[0]), enqueuedAt: item.enqueuedAt, isKeyFrame: item.isKeyFrame, closeAfter: false)
        }
        if case .fragments(let flags, let parts) = item.kind {
            return OutboundItem(kind: .content(.videoFragment, flags, parts.first ?? Data()), enqueuedAt: item.enqueuedAt, isKeyFrame: item.isKeyFrame, closeAfter: false)
        }
        return item
    }

    /// Clears queued media; an unfinished fragmented frame is completed so the receiver never sees a gap.
    mutating func clearMedia() { audio.removeAll(); video.removeAll() }
    func oldestAge(now: TimeInterval) -> TimeInterval {
        [control.first, audio.first, video.first].compactMap { $0?.enqueuedAt }.min().map { now - $0 } ?? 0
    }
    /// Audio-only live age bound (PROTOCOL "Age shedding"): when the oldest queued audio record is older than
    /// `trigger`, drops the oldest whole records until the oldest is at most `keep` old. Only the audio queue is
    /// touched (signed media records); control (header, OpusHead, lifecycle) never sheds. Returns the count dropped.
    mutating func shedAudio(now: TimeInterval, trigger: TimeInterval, keep: TimeInterval) -> Int {
        guard let first = audio.first, now - first.enqueuedAt > trigger else { return 0 }
        var dropped = 0
        while let oldest = audio.first, now - oldest.enqueuedAt > keep { audio.removeFirst(); dropped += 1 }
        droppedAudioPackets += dropped
        return dropped
    }
    func audioAge(now: TimeInterval) -> TimeInterval { audio.first.map { now - $0.enqueuedAt } ?? 0 }
    /// Age of the oldest queued video frame (0 when none): how far video sending lags capture.
    func videoAge(now: TimeInterval) -> TimeInterval { video.first.map { now - $0.enqueuedAt } ?? 0 }
}

open class MeshConnection {
    public enum Phase: Equatable { case linkHandshake, endpointHandshake, open, closed }
    public let role: HandshakeRole
    public let transport: MeshTransport
    public let identity: SigningIdentity
    public let linkCapabilities: NodeCapabilities
    public let endpointCapabilities: NodeCapabilities
    public private(set) var phase: Phase = .linkHandshake
    public private(set) var endpoint: EndToEndSession?
    public private(set) var closeReason: String?
    public var queues = OutboundQueues()
    public var expectedPeerPrefix: Data?
    public weak var identityGate: PeerIdentityGate?
    let link: SecureLink
    private var endpointHandshake: EndToEndHandshake?
    var startedAt: TimeInterval = 0
    public private(set) var lastReceiveAt: TimeInterval = 0
    public private(set) var lastSendAt: TimeInterval = 0
    public private(set) var receivedBytes: UInt64 = 0
    public private(set) var sentBytes: UInt64 = 0
    /// Sealed bytes of video media (whole packets and fragments) handed to the transport.
    public private(set) var sentVideoBytes: UInt64 = 0
    #if os(macOS)
    /// Native telemetry only: media payload bytes handed to the transport, in sealing order.
    /// Excludes rotation and record framing; fragments count their chunk bytes exactly once.
    public var onMediaSubmitted: ((_ payloadBytes: Int, _ audio: Bool, _ at: TimeInterval) -> Void)?
    #endif
    /// Age of the oldest video frame still waiting for the transport.
    public func videoQueueAge(now: TimeInterval) -> TimeInterval { queues.videoAge(now: now) }
    public private(set) var closeRequested = false
    /// Fatal closure discards queued output; transports must release even if their pipe is blocked.
    public private(set) var closedWithError = false
    /// EXPERIMENTAL rotating discovery IDs: this side's BDO1 entries (a callee's pinned role-0 IDs; a caller none).
    public var discoveryOpeningEntries: (() -> [OpeningEntry])?
    /// The peer's BDO1 entries arrived (the caller's RV15 check); throw to refuse the link.
    public var onDiscoveryOpening: (([OpeningEntry]) throws -> Void)?
    /// The peer's opening, or nil when none was negotiated or it has not arrived.
    public private(set) var peerOpening: [OpeningEntry]?
    public private(set) var openingExpected = false
    /// EXPERIMENTAL rotating IDs (RV8 tarpit): delay before the responder's link hello for this initiator.
    public var responderHelloDelay: ((NodeId) -> TimeInterval)?
    private var heldHello: (bytes: Data, releaseAt: TimeInterval)?
    private var responderHelloHandled = false
    public var setupTimeout: TimeInterval = 20
    /// Stream child links (source and relay sender): writes paced at the child-measured rate (Android LinkPacer).
    /// Control records are never held; audio, video and ordered envelopes wait their turn in the app queue.
    public var pacer: LinkPacer?
    /// A pacer on this connection's clock (the transport driver's monotonic `now`).
    public func makePacer() -> LinkPacer { LinkPacer(nanoTime: { [weak self] in Int64((self?.now ?? 0) * 1_000_000_000) }) }
    /// Android on-time seed raise (default ON since 2026-10-16): a held seed grows while this queue backs up.
    public var onTimeSeedRaise = true
    public private(set) var seedRaises = 0

    /// A hop-local report from the child: a measurement replaces the seed; an unmeasured on-time report holds it
    /// (and raises it while this sender's own queue is at least 0.5 s old); a late or delivery-only report changes nothing.
    func applyPacingReport(_ report: LinkCapacityReport) {
        guard let pacer, !report.deliveryOnly else { return }
        if report.arrivalKbps > 0 { pacer.setMeasuredLinkKbps(report.arrivalKbps); return }
        guard !report.linkLate else { return }
        let before = pacer.seedKbps
        let backlogMs = onTimeSeedRaise ? Int64(queues.oldestAge(now: now) * 1000) : -1
        if pacer.holdSeed(raiseBacklogMs: backlogMs), pacer.seedKbps > before { seedRaises += 1 }
    }
    var now: TimeInterval = 0

    /// Experimental BMH3 (calls only); nil = BMH2 exactly as before.
    public let bmh3: Bmh3CallSettings?

    public init(role: HandshakeRole, transport: MeshTransport, identity: SigningIdentity,
                linkCapabilities: NodeCapabilities, endpointCapabilities: NodeCapabilities, bmh3: Bmh3CallSettings? = nil) {
        self.role = role; self.transport = transport; self.identity = identity
        self.linkCapabilities = linkCapabilities; self.endpointCapabilities = endpointCapabilities
        self.bmh3 = bmh3
        link = SecureLink(role: role, identity: identity, capabilities: linkCapabilities, bmh3: bmh3)
    }

    public var peerLinkNodeId: NodeId? { link.peerNodeId }
    public var peerLinkCapabilities: NodeCapabilities? { link.peerCapabilities }
    /// BMH3: the link peer presented a throwaway key / this phone did.
    public var linkPeerPseudonymous: Bool { link.peerPseudonymous }
    public var linkUsedBmh3: Bool { link.usedBmh3 }

    /// Begins the connection once the byte stream is open. The initiator queues its link hello.
    public func start(now: TimeInterval) throws {
        // A connection that already ended (the user cancelled while its link was still being set up) sends nothing.
        guard phase != .closed else { return }
        self.now = now; startedAt = now; lastReceiveAt = now
        link.acceptDiscoveryOpening = linkCapabilities.transportMask & NodeCapabilities.transportDiscoveryOpening != 0
        if let hello = try link.start() { enqueue(.raw(hello), .control) }
    }

    /// Ingress backpressure: while true, no further record is parsed and received bytes are held (bounded by
    /// `maxHeldIngressBytes`) until `resumeIngress`. A call relay link pauses while the other hop is behind.
    open var ingressPaused: Bool { false }
    /// Received bytes not yet handed to the record parser. Exceeding it while paused ends the connection.
    public var maxHeldIngressBytes = Int.max
    private var heldIngress = Data()
    private var ingressStalled = false
    /// True while received input waits for `resumeIngress` (the transport can stop reading).
    public var ingressHeld: Bool { ingressStalled || !heldIngress.isEmpty }

    /// Bytes from the transport, in order. Errors are fatal for the connection.
    public func receive(_ data: Data, now: TimeInterval) {
        guard phase != .closed else { return }
        self.now = now
        receivedBytes += UInt64(data.count)
        lastReceiveAt = now
        heldIngress.append(data)
        guard heldIngress.count <= maxHeldIngressBytes else {
            fail("The next hop fell too far behind (\(heldIngress.count) bytes waiting)")
            return
        }
        processIngress()
    }

    /// Parses held input once `ingressPaused` is false again.
    public func resumeIngress(now: TimeInterval) {
        guard phase != .closed, ingressHeld, !ingressPaused else { return }
        self.now = now
        processIngress()
    }

    private func processIngress() {
        do {
            // Handle each record before parsing the next: a verified header can change the read cap even
            // when the transport coalesced the header and the first large audio batch into one read.
            while phase != .closed {
                if ingressPaused { ingressStalled = true; return }
                let pending = heldIngress
                heldIngress = Data()
                let outputs = try link.receive(pending, recordLimit: 1)
                guard !outputs.isEmpty else { break }
                for output in outputs {
                    switch output {
                    case .send(let bytes):
                        if role == .responder, !responderHelloHandled {
                            responderHelloHandled = true
                            if let peer = link.peerNodeId, let delay = responderHelloDelay?(peer), delay > 0 {
                                heldHello = (bytes, now + delay); continue
                            }
                        }
                        enqueue(.raw(bytes), .control)
                    case .established: try linkEstablished()
                    case .record(let record):
                        if phase == .closed { return }
                        try handleRecord(record)
                    }
                }
            }
            ingressStalled = false
        } catch {
            fail(describe(error))
        }
    }

    private func linkEstablished() throws {
        guard let caps = link.peerCapabilities, caps.supports(transport: transport.capabilityBit) else {
            throw ProtocolError.incompatible("Peer did not authenticate \(transport.label) support")
        }
        try validateLinkPeer()
        // A pseudonymous BMH3 responder presented its link capabilities without bit 3: then no BDO1 either way.
        if link.presentedCapabilities.transportMask & NodeCapabilities.transportDiscoveryOpening != 0,
           caps.transportMask & NodeCapabilities.transportDiscoveryOpening != 0 {
            // Both link hellos carry bit 3: exactly one BDO1 is the first hop record each way.
            openingExpected = true
            enqueue(.record(.discoveryOpening, try DiscoveryOpeningCodec.encode(discoveryOpeningEntries?() ?? [])), .control)
        }
        if linkOnly {
            // A call relay hop: link handshake only; endpoint records pass through opaquely
            // (a BDO1 opening, if negotiated, was queued above and is consumed by handleRecord first).
            phase = .open
            linkDidAuthenticate()
            return
        }
        phase = .endpointHandshake
        // BMH3: the caller speaks it end to end when it spoke it on the link; a responder dispatches on the magic.
        let handshake = EndToEndHandshake(role: role, identity: identity, capabilities: endpointCapabilities, gate: identityGate,
                                          bmh3: bmh3, speakBmh3: role == .initiator && link.usedBmh3)
        endpointHandshake = handshake
        if role == .initiator { enqueue(.record(.endToEndHandshake, try handshake.initiatorHello()), .control) }
        linkDidAuthenticate()
    }

    private func handleRecord(_ record: SecureRecord) throws {
        if openingExpected && peerOpening == nil {
            guard record.type == .discoveryOpening else { throw ProtocolError.state("Expected the BDO1 link opening first") }
            let entries = try DiscoveryOpeningCodec.decode(record.payload)
            peerOpening = entries
            try onDiscoveryOpening?(entries)
            return
        }
        if record.type == .discoveryOpening { throw ProtocolError.malformed("Unknown secure record type 13") }
        if phase == .endpointHandshake {
            guard record.type == .endToEndHandshake, let handshake = endpointHandshake else {
                throw ProtocolError.state("Expected an end-to-end handshake")
            }
            let (completed, reply) = try handshake.receive(record.payload)
            if let reply { enqueue(.record(.endToEndHandshake, reply), .control) }
            guard let session = completed else { return } // BMH3 responder: msg2 sent, msg3 follows
            // A pseudonymous peer cannot carry the announced prefix; its reveal is checked against the selection instead.
            if let expectedPeerPrefix, expectedPrefixAppliesToEndpoint, !session.peerPseudonymous {
                guard session.peerNodeId.prefix == expectedPeerPrefix else {
                    throw ProtocolError.authentication
                }
            }
            endpoint = session
            endpointHandshake = nil
            phase = .open
            try endpointDidAuthenticate(session)
            return
        }
        try handleOpenRecord(record)
    }

    // MARK: Subclass hooks
    /// True for a relay hop: no endpoint handshake of its own (the endpoints' records are copied).
    open var linkOnly: Bool { false }
    open var expectedPrefixAppliesToEndpoint: Bool { true }
    open func validateLinkPeer() throws {}
    open func linkDidAuthenticate() {}
    open func endpointDidAuthenticate(_ session: EndToEndSession) throws {}
    open func handleOpenRecord(_ record: SecureRecord) throws { throw ProtocolError.state("Unexpected record \(record.type)") }
    open func tickOpen(now: TimeInterval) {}
    open func didClose(reason: String, error: Bool) {}

    // MARK: Outbound
    func enqueue(_ kind: OutboundItem.Kind, _ priority: OutboundPriority, keyFrame: Bool = false, closeAfter: Bool = false, keep: Bool = false) {
        var item = OutboundItem(kind: kind, enqueuedAt: now, isKeyFrame: keyFrame, closeAfter: closeAfter)
        item.keep = keep
        _ = queues.push(item, priority)
    }
    @discardableResult
    func enqueueMedia(_ kind: OutboundItem.Kind, audio: Bool, keyFrame: Bool, keep: Bool = false) -> Bool {
        var item = OutboundItem(kind: kind, enqueuedAt: now, isKeyFrame: keyFrame, closeAfter: false)
        item.keep = keep
        return queues.push(item, audio ? .audio : .video)
    }

    /// Next sealed bytes for the transport, in priority order (control, audio, video).
    /// After a graceful finish the queue still drains (for example a final hang-up); a failure clears it.
    public func nextOutgoing(now: TimeInterval) -> Data? {
        self.now = now
        if let held = heldHello {
            guard now >= held.releaseAt else { return nil }
            heldHello = nil; sentBytes += UInt64(held.bytes.count); lastSendAt = now
            return held.bytes
        }
        // Pacing: nothing but control leaves before the pacer allows it (the burst allowance is 50 ms).
        if let pacer, queues.control.isEmpty, pacer.waitNs() > 0 { return nil }
        while let item = queues.pop() {
            do {
                let bytes: Data
                switch item.kind {
                case .raw(let data): bytes = data
                case .record(let type, let payload): bytes = try link.seal(type, payload)
                case .content(let type, let flags, let payload):
                    guard let endpoint else { continue }
                    bytes = try link.seal(.endToEndContent, try endpoint.sealer.seal(type, flags: flags, payload))
                case .mesh(let type, let flags, let payload, let extra):
                    bytes = try sealMesh(type: type, flags: flags, payload: payload, extraMeshFlags: extra)
                case .fragments:
                    continue // expanded by OutboundQueues.pop
                }
                sentBytes += UInt64(bytes.count); lastSendAt = now
                pacer?.onSent(bytes.count)
                if case .content(let type, let flags, _) = item.kind,
                   type == .videoFragment || (type == .mediaPacket && flags & StreamProtocol.flagAudio == 0) {
                    sentVideoBytes += UInt64(bytes.count)
                }
                if item.closeAfter { closeRequested = true }
                #if os(macOS)
                if let observe = onMediaSubmitted, case .content(let type, let flags, let payload) = item.kind {
                    if type == .mediaPacket, flags & StreamProtocol.flagDisplayRotation == 0 {
                        observe(max(0, payload.count - StreamProtocol.packetHeaderBytes), flags & StreamProtocol.flagAudio != 0, now)
                    } else if type == .videoFragment {
                        observe(max(0, payload.count - CallVideoFragments.headerBytes), false, now)
                    }
                }
                #endif
                return bytes
            } catch {
                fail(describe(error)); return nil
            }
        }
        // Ordered media after control/audio/video queues (a stream forwarder's envelopes, which must keep
        // their BMV1 sequence order; a call relay's copied endpoint records). It drains after a graceful finish.
        guard phase == .open || phase == .closed else { return nil }
        do {
            if let bytes = try nextOrderedOutgoing(now: now) { sentBytes += UInt64(bytes.count); lastSendAt = now; pacer?.onSent(bytes.count); return bytes }
        } catch { fail(describe(error)) }
        return nil
    }

    /// Subclass hook: the next sealed record of an ordered media stream, pulled when the queues are empty.
    open func nextOrderedOutgoing(now: TimeInterval) throws -> Data? { nil }
    open var hasOrderedOutput: Bool { false }

    open func sealMesh(type: EndToEndContentType, flags: UInt8, payload: Data, extraMeshFlags: UInt8) throws -> Data {
        throw ProtocolError.state("This connection does not write mesh envelopes")
    }

    /// True once a terminal record was handed to the transport; close after it drains.
    public var shouldCloseAfterFlush: Bool { closeRequested && queues.isEmpty && !hasOrderedOutput }
    public var hasPendingOutput: Bool { !queues.isEmpty || hasOrderedOutput }

    /// Timers: setup deadline and subclass liveness.
    public func tick(now: TimeInterval) {
        guard phase != .closed else { return }
        self.now = now
        if phase != .open, now - startedAt > setupTimeout { fail("Secure setup timed out"); return }
        if phase == .open { tickOpen(now: now) }
    }

    /// The transport closed or failed underneath.
    public func linkLost(_ reason: String) {
        guard phase != .closed else { return }
        finish(reason, error: true)
    }

    public func fail(_ reason: String) { finish(reason, error: true) }

    public func finish(_ reason: String, error: Bool) {
        guard phase != .closed else { return }
        phase = .closed; closeReason = reason
        closedWithError = error
        if error { queues = OutboundQueues() }
        didClose(reason: reason, error: error)
    }

    func describe(_ error: Error) -> String { (error as? ProtocolError)?.description ?? String(describing: error) }
}
