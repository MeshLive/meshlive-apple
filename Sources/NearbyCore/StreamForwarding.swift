import Foundation

// EXPERIMENTAL (default off): an iPhone viewer passes a stream on to one child, as Android's
// ReceiverStreamForwarder (hop-local). Ports of MeshBandwidthEstimator/LinkCapacityPolicy (admission and
// the cold-start rule, e676ae5), ReceiverNodeForwardingCore (bootstrap, join keyframe, duplicates) and
// RelayChildHealthPolicy; the hop engine is StreamForwarderEngine.

// MARK: Capacity and admission

public enum MeshBandwidth {
    /// Planned-link margin over carried wire load (Android TRANSPORT_MARGIN).
    public static let transportMargin = 0.2
    /// LE prior aggregate when nothing is learned (Android safeAggregateKbps, BLE GATT/L2CAP).
    public static let leSafeAggregateKbps = 700.0

    /// One link's planned load: video + 32 kbps audio + 13-byte headers per packet ((fps + 25)/s), plus 20 %.
    public static func perLinkKbps(videoKbps: Int, fps: Int) -> Double {
        (Double(videoKbps) + 32 + 13.0 * 8 * Double(fps + 25) / 1000) * (1 + transportMargin)
    }
}

/// What this phone has learned about its own relaying (Android LearnedLinkCapacity, relay kind).
public struct LearnedLinkCapacity: Equatable, Codable {
    public var provenKbps: Int
    public var ceilingKbps: Int?
    public var ceilingMeasuredAtMs: Int64
    public var probeKbps: Int
    public var probeMeasuredAtMs: Int64
    public init(provenKbps: Int = 0, ceilingKbps: Int? = nil, ceilingMeasuredAtMs: Int64 = 0, probeKbps: Int = 0, probeMeasuredAtMs: Int64 = 0) {
        self.provenKbps = provenKbps; self.ceilingKbps = ceilingKbps; self.ceilingMeasuredAtMs = ceilingMeasuredAtMs
        self.probeKbps = probeKbps; self.probeMeasuredAtMs = probeMeasuredAtMs
    }
}

public enum LinkCapacityPolicy {
    public static let ceilingHeadroom = 0.9
    public static let ceilingTtlMs: Int64 = 6 * 60 * 60 * 1_000
    public static let probeTtlMs: Int64 = 7 * 24 * 60 * 60 * 1_000

    public static func freshCeiling(_ l: LearnedLinkCapacity, nowMs: Int64) -> Int? {
        guard let c = l.ceilingKbps, (0..<ceilingTtlMs).contains(nowMs - l.ceilingMeasuredAtMs) else { return nil }
        return c
    }
    public static func freshProbe(_ l: LearnedLinkCapacity, nowMs: Int64) -> Int? {
        guard l.probeKbps > 0, (0..<probeTtlMs).contains(nowMs - l.probeMeasuredAtMs) else { return nil }
        return l.probeKbps
    }
    /// With a fresh ceiling: max(proven, 0.9 x ceiling); otherwise max(prior, proven x scale + one link).
    public static func budgetKbps(_ l: LearnedLinkCapacity, priorKbps: Double, perLinkKbps: Double, nowMs: Int64, provenScale: Double = 1) -> Double {
        if let ceiling = freshCeiling(l, nowMs: nowMs) { return max(Double(l.provenKbps), Double(ceiling) * ceilingHeadroom) }
        return max(priorKbps, Double(l.provenKbps) * provenScale + perLinkKbps)
    }
    /// No relay evidence either way: never relayed cleanly and no fresh relay ceiling.
    public static func relayColdStart(_ l: LearnedLinkCapacity, nowMs: Int64) -> Bool { l.provenKbps <= 0 && freshCeiling(l, nowMs: nowMs) == nil }
    /// Cold start: the incoming link is already carried, so exactly one child may be added.
    public static func relayBudgetKbps(measured: Double, perLinkKbps: Double, coldStart: Bool) -> Double {
        coldStart ? max(measured, 2 * perLinkKbps) : measured
    }
    /// A relay carries its incoming link plus one child link.
    public static func relayFits(budgetKbps: Double, perLinkKbps: Double) -> Bool { budgetKbps >= 2 * perLinkKbps }
}

/// One relay admission decision (logged as BENCHMARK relay_admission, like Android).
public struct RelayAdmission: Equatable {
    public let needKbps: Double, budgetKbps: Double, measuredKbps: Double, coldStart: Bool, fits: Bool

    /// - Parameter advertisedKbps: the video offer's bitrate; an audio preset always supplies the load, even when the advert says 0.
    public static func evaluate(learned: LearnedLinkCapacity, advertisedKbps: Int, fps: Int, nowMs: Int64, coldStartRule: Bool = true, audioPreset: UInt8? = nil) -> RelayAdmission {
        guard advertisedKbps > 0 || audioPreset != nil else { return RelayAdmission(needKbps: 0, budgetKbps: 0, measuredKbps: 0, coldStart: false, fits: true) }
        let perLink = audioPreset.map { AudioLiveRelayAdmission.perLinkKbps(preset: $0) } ?? MeshBandwidth.perLinkKbps(videoKbps: advertisedKbps, fps: fps)
        let prior = LinkCapacityPolicy.freshProbe(learned, nowMs: nowMs).map(Double.init) ?? MeshBandwidth.leSafeAggregateKbps
        let measured = LinkCapacityPolicy.budgetKbps(learned, priorKbps: prior, perLinkKbps: perLink, nowMs: nowMs)
        let cold = coldStartRule && LinkCapacityPolicy.relayColdStart(learned, nowMs: nowMs)
        let budget = LinkCapacityPolicy.relayBudgetKbps(measured: measured, perLinkKbps: perLink, coldStart: cold)
        return RelayAdmission(needKbps: 2 * perLink, budgetKbps: budget, measuredKbps: measured, coldStart: cold,
                              fits: LinkCapacityPolicy.relayFits(budgetKbps: budget, perLinkKbps: perLink))
    }
}

// MARK: Child health (RelayChildHealthPolicy)

/// Nothing is dropped for a slow child, so the evidence is how far behind live its queue falls; a child that
/// stays behind is withdrawn so it can reroute (a relay only handles its own children).
public struct RelayChildHealthPolicy {
    public static let withdrawBacklog: TimeInterval = 2.5
    public static let sustained: TimeInterval = 3
    public static let hardBacklog: TimeInterval = 6
    public static let trendWindow: TimeInterval = 3
    public static let trendMinBacklog: TimeInterval = 1.5
    public static let trendGrowth: TimeInterval = 0.5
    public let sheddingActive: Bool
    private var behindSince: TimeInterval?
    private var samples: [(at: TimeInterval, backlog: TimeInterval)] = []

    public init(sheddingActive: Bool = false) { self.sheddingActive = sheddingActive }

    public mutating func shouldWithdraw(backlog: TimeInterval, now: TimeInterval) -> Bool {
        if backlog >= Self.hardBacklog { return true }
        samples.append((now, backlog))
        while samples.count >= 2 && now - samples[1].at >= Self.trendWindow { samples.removeFirst() }
        let then = samples[0]
        if !sheddingActive, now - then.at >= Self.trendWindow, backlog >= Self.trendMinBacklog,
           backlog - then.backlog >= Self.trendGrowth, backlog >= (samples.map(\.backlog).max() ?? 0) {
            return true
        }
        if backlog < Self.withdrawBacklog { behindSince = nil; return false }
        let since = behindSince ?? now
        behindSince = since
        return now - since >= Self.sustained
    }
}

// MARK: Forwarding core (ReceiverNodeForwardingCore)

public final class StreamForwardingCore {
    public enum Rejection: Equatable { case localLoop, duplicate, ttlExpired, noChild }
    public enum Outcome: Equatable {
        /// Send this copy (TTL - 1) to the child.
        case forward(MeshEnvelope, startedAtKeyFrame: Bool)
        /// The child joined mid-GOP: skipped until a keyframe (ask upstream for one).
        case waitingForJoinKeyFrame
        case rejected(Rejection)
    }
    public static let maxCodecConfigPackets = 8
    public let localNodeId: NodeId, upstreamPeerNodeId: NodeId, streamId: UUID, sourceNodeId: NodeId
    private var duplicates = DuplicateWindow()
    private var bootstrap: [MeshEnvelope] = []
    private var latestControl: MeshEnvelope?
    public private(set) var childNodeId: NodeId?
    private var childWaitsForKeyFrame = false
    private let audioOnly: Bool
    public private(set) var skippedBeforeJoin = 0

    public init(localNodeId: NodeId, upstreamPeerNodeId: NodeId, streamId: UUID, sourceNodeId: NodeId, audioOnly: Bool = false) {
        self.audioOnly = audioOnly
        self.localNodeId = localNodeId; self.upstreamPeerNodeId = upstreamPeerNodeId; self.streamId = streamId; self.sourceNodeId = sourceNodeId
    }

    public func receive(_ envelope: MeshEnvelope) throws -> Outcome {
        if envelope.sourceNodeId == localNodeId { return .rejected(.localLoop) }
        guard envelope.sourceNodeId == sourceNodeId else { throw ProtocolError.malformed("Forwarded stream source changed") }
        guard envelope.streamId == streamId else { throw ProtocolError.malformed("Forwarded stream ID changed") }
        guard duplicates.markIfNew(envelope) else { return .rejected(.duplicate) }
        try remember(envelope)
        guard let forwarded = envelope.forwarded() else { return .rejected(.ttlExpired) }
        guard let child = childNodeId, child != upstreamPeerNodeId else { return .rejected(.noChild) }
        let isControl = envelope.flags & MeshEnvelope.flagControl != 0, isAudio = envelope.flags & MeshEnvelope.flagAudio != 0
        if childWaitsForKeyFrame && !isControl && !isAudio {
            guard envelope.flags & MeshEnvelope.flagKeyFrame != 0 else { skippedBeforeJoin += 1; return .waitingForJoinKeyFrame }
            childWaitsForKeyFrame = false
            return .forward(forwarded, startedAtKeyFrame: true)
        }
        return .forward(forwarded, startedAtKeyFrame: false)
    }

    /// Admits the one child; returns its bootstrap (header, codec configs, latest state) in sequence order.
    public func addChild(_ child: NodeId) throws -> [MeshEnvelope] {
        guard child != localNodeId, child != upstreamPeerNodeId else { throw ProtocolError.state("Invalid downstream child") }
        guard childNodeId == nil else { throw ProtocolError.state("A downstream child is already connected") }
        childNodeId = child; childWaitsForKeyFrame = !audioOnly
        var seen = Set<UInt64>()
        return (bootstrap + [latestControl].compactMap { $0 })
            .filter { seen.insert($0.sequence).inserted }
            .sorted { $0.sequence < $1.sequence }
            .compactMap { $0.forwarded() }
    }

    public func removeChild(_ child: NodeId) { if childNodeId == child { childNodeId = nil; childWaitsForKeyFrame = false } }

    private func remember(_ envelope: MeshEnvelope) throws {
        guard let type = try? EndToEndContentProtocol.inspect(envelope.payload, acceptVideoFragments: true, acceptLabels: true).type else { return }
        func isConfig(_ e: MeshEnvelope) -> Bool {
            e.flags & MeshEnvelope.flagCodecConfig != 0 && (try? EndToEndContentProtocol.inspect(e.payload).type) == .mediaPacket
        }
        switch type {
        case .streamHeader:
            guard !bootstrap.contains(where: { (try? EndToEndContentProtocol.inspect($0.payload).type) == .streamHeader }) else {
                throw ProtocolError.malformed("Forwarded stream sent more than one header")
            }
            bootstrap.append(envelope)
        case .mediaPacket where envelope.flags & MeshEnvelope.flagCodecConfig != 0:
            bootstrap.append(envelope)
            while bootstrap.filter(isConfig).count > Self.maxCodecConfigPackets, let index = bootstrap.firstIndex(where: isConfig) { bootstrap.remove(at: index) }
        case .streamState:
            latestControl = envelope
        default: break
        }
    }
}

// MARK: Relay -> child hop engine

/// The forwarder's link to its one child: GATT/L2CAP central, BMH2 link and endpoint initiator, then the
/// BFG1 grant (the media-open key, sealed hop-locally) and unchanged upstream BMV1 envelopes in sequence
/// order. Child keyframe requests, end acks, heartbeats and route-withdrawal acks are handled hop-locally.
public final class StreamForwarderEngine: MeshConnection {
    /// Android LinkPacer on the relay's child link (the app turns it on, as Android's default).
    public var linkPacing = false
    public enum Event: Equatable {
        case childAuthenticated(NodeId, IdentityFingerprint)
        case keyFrameRequested
        case endAcknowledged
        case routeWithdrawalAcknowledged
        case report(LinkCapacityReport)
        case ended(String, error: Bool)
    }
    public var onEvent: ((Event) -> Void)?
    public let grant: ForwardedStreamGrant
    public let codecId: UInt8
    public let audioOnly: Bool
    public var audioAgeBound = true
    public private(set) var shedAudioRecords = 0
    private var audioHealth: [(at: TimeInterval, queued: Int, shed: Int)] = []
    public private(set) var ready = false
    /// Experimental labels: the verified upstream LABELS container to pass on (sent after the grant), or nil.
    public let labelsContainer: Data?
    private var envelopes: [(envelope: MeshEnvelope, at: TimeInterval)] = []
    private var lastSentSequence: Int64 = -1
    private var lastHeartbeatAt: TimeInterval = 0
    private var endingSince: TimeInterval?
    private var withdrawingSince: TimeInterval?
    public var isWithdrawing: Bool { withdrawingSince != nil }
    public private(set) var forwardedEnvelopes = 0
    public private(set) var forwardedBytes: UInt64 = 0

    public init(transport: MeshTransport, identity: SigningIdentity, grant: ForwardedStreamGrant, codecId: UInt8, expectedChildPrefix: Data?,
                labelsContainer: Data? = nil, audioOnly: Bool = false) {
        let mask = audioOnly ? 0 : StreamProtocol.capabilityMask(codecId: codecId)
        let caps = NodeCapabilities(transportMask: transport.capabilityBit, encodeCodecMask: mask, decodeCodecMask: 0,
                                    maxBitrateKbps: transport.maxVideoBitrateKbps, maxChildren: 1)
        self.audioOnly = audioOnly
        self.grant = grant; self.codecId = codecId; self.labelsContainer = labelsContainer
        super.init(role: .initiator, transport: transport, identity: identity, linkCapabilities: caps,
                   endpointCapabilities: PeerLabelFeature.advertise(caps, enabled: labelsContainer != nil))
        expectedPeerPrefix = expectedChildPrefix
    }

    public override func validateLinkPeer() throws {
        guard let caps = link.peerCapabilities else { return }
        if let expectedPeerPrefix, link.peerNodeId?.prefix != expectedPeerPrefix { throw ProtocolError.authentication }
        if caps.maxChildren > 1 { throw ProtocolError.incompatible("Group-relay (BGK1) children are not supported on iPhone") }
        if link.peerNodeId == grant.sourceNodeId { throw ProtocolError.state("The stream source cannot be this relay's child") }
    }

    public override func endpointDidAuthenticate(_ session: EndToEndSession) throws {
        guard audioOnly || session.peerCapabilities.decodeCodecMask & StreamProtocol.capabilityMask(codecId: codecId) != 0 else {
            throw ProtocolError.incompatible("The child cannot decode the stream codec")
        }
        // The relay's child link is paced like a source's (Android: the relay sender uses the same LinkPacer).
        if linkPacing && pacer == nil { pacer = makePacer() }
        pacer?.seed(kbps: LinkPacer.seedKbps(transport, probeKbps: nil))
        lastHeartbeatAt = now
        enqueue(.content(.groupKey, 0, grant.encoded), .control)
        if let labelsContainer, let linkPeer = link.peerNodeId,
           PeerLabelFeature.streamHopNegotiated(localEnabled: true, linkPeer: linkPeer, endpointPeer: session.peerNodeId, peer: session.peerCapabilities) {
            enqueue(.content(.labels, 0, labelsContainer), .control)
        }
        ready = true
        onEvent?(.childAuthenticated(session.peerNodeId, session.peerFingerprint))
    }

    // MARK: Relay-child media age (Android default ON: slow children skip to keyframes)
    public enum ForwardOutcome: Equatable {
        case queued
        /// Stale video was shed and this video is dropped until a keyframe: ask the parent for one (paced).
        case shedWaitingForKeyFrame
        /// Dropped while waiting for that keyframe; a request is outstanding (backoff).
        case shedDropped
        case refused
    }
    /// Skip-to-keyframe shedding of this child's stale video beyond its age budget (false: no-loss, withdrawal only).
    public var mediaAge = false
    public private(set) var shedder = MediaAgeShedder(cooldown: BoundedMediaAge.streamShedCooldown)
    public private(set) var recovery = RelayRecoveryBackoff()
    /// The child's reported added playout delay (hop-local), which shortens the budget.
    public private(set) var childAddedDelayMs = 0
    private var lastKeyFrameSentAt: TimeInterval?

    /// Queues one forwarded envelope (TTL already decremented); older or equal sequences are skipped.
    @discardableResult
    public func forward(_ envelope: MeshEnvelope, now: TimeInterval? = nil) -> ForwardOutcome {
        if let now { self.now = now }
        guard ready, endingSince == nil, withdrawingSince == nil else { return .refused }
        if !audioOnly, mediaAge {
            let shedClass = relayEnvelopeShedClass(envelope)
            if shedClass != .keep, let outcome = shedForMediaAge(keyFrame: shedClass == .keyFrame) { return outcome }
        }
        envelopes.append((envelope, self.now))
        if audioOnly {
            if Self.isAudioRecord(envelope) { audioHealth.append((self.now, 1, 0)) }
            checkAudioHealth(now: self.now)
        }
        return .queued
    }

    /// Exact mesh namespace predicate.
    private static func isAudioRecord(_ envelope: MeshEnvelope) -> Bool {
        envelope.flags == 8 || envelope.flags == 72
    }
    private func checkAudioHealth(now: TimeInterval) {
        guard audioOnly, withdrawingSince == nil, endingSince == nil else { return }
        if audioAgeBound, let oldest = envelopes.first(where: { Self.isAudioRecord($0.envelope) }), now - oldest.at > 3 {
            let before = envelopes.count
            envelopes.removeAll { Self.isAudioRecord($0.envelope) && now - $0.at > 1.5 }
            let dropped = before - envelopes.count
            shedAudioRecords += dropped; audioHealth.append((now, 0, dropped))
        }
        audioHealth.removeAll { now - $0.at > 10 }
        let queued = audioHealth.reduce(0) { $0 + $1.queued }, shed = audioHealth.reduce(0) { $0 + $1.shed }
        if (queued >= 10 && Double(shed) > 0.2 * Double(queued)) || backlog(now: now) > 30 {
            withdrawRoute()
        }
    }

    public var budgetMs: Int64 { BoundedMediaAge.streamQueueBudgetMs(viewerAddedDelayMs: childAddedDelayMs) }

    private func shedForMediaAge(keyFrame: Bool) -> ForwardOutcome? {
        if shedder.dropArrivingVideo(keyFrame: keyFrame) { return keyFrameWait() }
        let oldestVideo = envelopes.first { relayEnvelopeShedClass($0.envelope) != .keep }
        let ageMs = oldestVideo.map { Int64(max(0, now - $0.at) * 1000) } ?? 0
        let grace = lastKeyFrameSentAt.map { now - $0 < BoundedMediaAge.relayKeyFrameGrace } ?? false
        let budget = budgetMs
        guard shedder.shouldShed(queueAgeMs: ageMs, budgetMs: budget, keyFrameGrace: grace, now: now) else { return nil }
        let plan = planCodecSafeShed(envelopes.map { relayEnvelopeShedClass($0.envelope) },
                                     usable: envelopes.map { Int64((now - $0.at) * 1000) <= budget })
        for index in plan.drop.sorted(by: >) { envelopes.remove(at: index) }
        shedder.recordShed(plan, removed: plan.drop.count, now: now)
        guard plan.awaitKeyFrame else { return nil }
        return shedder.dropArrivingVideo(keyFrame: keyFrame) ? keyFrameWait() : nil
    }

    private func keyFrameWait() -> ForwardOutcome { recovery.tryRequest(now: now) ? .shedWaitingForKeyFrame : .shedDropped }

    /// How far behind live the child's queue is (oldest unsent envelope age).
    public func backlog(now: TimeInterval) -> TimeInterval { envelopes.first.map { now - $0.at } ?? 0 }
    public var queuedEnvelopes: Int { envelopes.count }
    public var queuedAudio: Bool { envelopes.contains { $0.envelope.flags & MeshEnvelope.flagAudio != 0 } }

    public override func nextOrderedOutgoing(now: TimeInterval) throws -> Data? {
        checkAudioHealth(now: now)
        while !envelopes.isEmpty {
            let (envelope, _) = envelopes.removeFirst()
            guard Int64(envelope.sequence) > lastSentSequence else { continue }
            lastSentSequence = Int64(envelope.sequence)
            if relayEnvelopeShedClass(envelope) == .keyFrame { lastKeyFrameSentAt = now }
            let bytes = try link.seal(.meshEnvelope, envelope.encoded)
            forwardedEnvelopes += 1; forwardedBytes += UInt64(bytes.count)
            if envelope.flags & MeshEnvelope.flagTerminal != 0 { endingSince = now; envelopes.removeAll() }
            return bytes
        }
        return nil
    }
    public override var hasOrderedOutput: Bool { !envelopes.isEmpty }

    public override func handleOpenRecord(_ record: SecureRecord) throws {
        switch record.type {
        case .endToEndContent:
            guard let endpoint else { throw ProtocolError.state("No endpoint") }
            let content = try endpoint.opener.open(record.payload)
            guard content.payload.isEmpty else { throw ProtocolError.malformed("Invalid child control") }
            switch content.type {
            case .keyFrameRequest: if !audioOnly { onEvent?(.keyFrameRequested) }
            case .streamEndAck:
                onEvent?(.endAcknowledged)
                finish("Stream ended; child acknowledged", error: false)
            default: throw ProtocolError.malformed("Expected a child keyframe request or end acknowledgement")
            }
        case .linkHeartbeat:
            lastHeartbeatAt = now
            if let report = try LinkHeartbeat.decode(record.payload), !report.deliveryOnly {
                childAddedDelayMs = report.addedDelayMs
                applyPacingReport(report); onEvent?(.report(report))
            }
        case .routeControlAck:
            _ = try RouteWithdrawal(decoding: record.payload)
            onEvent?(.routeWithdrawalAcknowledged)
            finish("Child route withdrawn", error: false)
        default:
            throw ProtocolError.malformed("Unexpected child record \(record.type)")
        }
    }

    /// Hop-local overload: ask the child to reroute; close after its ack (or 4 s).
    public func withdrawRoute() {
        guard withdrawingSince == nil else { return }
        envelopes.removeAll()
        enqueue(.record(.routeControl, RouteWithdrawal.localCapacity.encoded), .control)
        withdrawingSince = now
    }

    public override func tickOpen(now: TimeInterval) {
        checkAudioHealth(now: now)
        let timeout: TimeInterval = transport == .gatt ? 6 : 8
        if ready, now - lastHeartbeatAt > timeout, now - lastReceiveAt > timeout { finish("Child heartbeat timed out", error: true); return }
        if let endingSince, now - endingSince > 2 { finish("Stream ended; child acknowledgement timed out", error: false); return }
        if let withdrawingSince, now - withdrawingSince > 4 { finish("Child route withdrawn (no acknowledgement)", error: false) }
    }

    public override func didClose(reason: String, error: Bool) { if error { envelopes.removeAll() }; onEvent?(.ended(reason, error: error)) }
}
