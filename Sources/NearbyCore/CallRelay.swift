import Foundation

// EXPERIMENTAL (default off; Android's private-call relay is DEBUG-only): an iPhone relay hop for a private
// call, as Android BluetoothPrivateCallRelay / PrivateCallRelayChain. Downstream first: the relay connects to
// its child (the callee or the next relay) as BMH2 link initiator, then advertises the callee's call offer
// with route cost + 1 for one parent. Both link hellos sign maxChildren 1 and the call-relay bit (bit 6).
// END_TO_END_HANDSHAKE and END_TO_END_CONTENT records are copied unchanged in order (the relay never opens
// BME1); heartbeats are replaced with version-1 liveness; any other record ends the relay.

public enum CallRelayChain {
    /// Caller -> at most 4 relays -> callee (Android MAX_RELAYS).
    public static let maxRelays = 4
    /// The parent must connect within this time once the child is authenticated.
    public static let parentWait: TimeInterval = 180

    /// Whether this phone may relay the offer (a call offer, not its own, child cost 0...3). A rotating-ID offer
    /// (compact v2 / announcement version 5) is not relayed in phase 1: its prefix field holds an RDI, not the
    /// callee's node prefix, so the child and callee checks and the mirrored offer would be wrong.
    public static func admitsOffer(_ offer: DiscoveryAnnouncement, ownPrefix: Data) -> Bool {
        offer.isPrivateCallOffer && !offer.rotating && offer.nodeIdPrefix != ownPrefix && Int(offer.routeCost) <= maxRelays - 1
    }

    /// Why the authenticated child cannot be used, or nil.
    public static func childProblem(childRouteCost: UInt8, calleePrefix: Data, ownNodeId: NodeId, child: NodeId, caps: NodeCapabilities) -> String? {
        if child == ownNodeId { return "The relay cannot be its own child" }
        if childRouteCost == 0 {
            return child.prefix == calleePrefix ? nil : "The child is not the advertised callee"
        }
        if child.prefix == calleePrefix { return "A relayed offer's child must be the next relay, not the callee" }
        guard caps.maxChildren >= 1, caps.transportMask & NodeCapabilities.transportCallRelay != 0 else {
            return "The next relay did not sign relay-chain capacity"
        }
        return nil
    }

    /// Why the authenticated parent cannot be used, or nil.
    public static func parentProblem(parent: NodeId, ownNodeId: NodeId, child: NodeId?, calleePrefix: Data) -> String? {
        if parent == ownNodeId { return "The relay cannot be its own parent" }
        if parent == child { return "The parent is this relay's child" }
        if parent.prefix == calleePrefix { return "The callee cannot call itself through this relay" }
        return nil
    }

    /// The call-offer capabilitySummary bits a relayed offer keeps: the codec bits (0-2) and the relay-consent bit 4
    /// (0x10). Bit 3 (0x08, Android's dual-listening CoC hint, d58b604) is cleared: a relay is single-bearer, a
    /// caller ignores the hint at route cost above 0, and the compact encoder would throw on it and stop the relay
    /// advertising (PROTOCOL "Experimental dual listening", Announcement hint). Bits 5-7 stay zero.
    public static let relayedSummaryMask: UInt8 = NodeCapabilities.codecMask | CompactAnnouncement.relayConsent

    /// The relayed offer: the callee's prefix, call + relay flags, the child's cost + 1.
    public static func parentOffer(childOffer: DiscoveryAnnouncement, transport: MeshTransport) -> DiscoveryAnnouncement {
        var flags = DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable | DiscoveryAnnouncement.flagRelayCapable
        if transport == .gatt { flags |= DiscoveryAnnouncement.flagGattTransport }
        return DiscoveryAnnouncement(nodeIdPrefix: childOffer.nodeIdPrefix, flags: flags, capabilitySummary: childOffer.capabilitySummary & relayedSummaryMask,
                                     streamToken: 0, routeCost: min(childOffer.routeCost + 1, 15))
    }

    /// Hop count a caller puts in Invite for an offer (nil: too many relays, refuse).
    public static func inviteHops(routeCost: UInt8) -> UInt8? { Int(routeCost) <= maxRelays ? routeCost : nil }
}

/// One link of a relay hop: BMH2 link handshake only, then opaque endpoint records in strict order.
public final class CallRelayLink: MeshConnection {
    public var onAuthenticated: ((NodeId, NodeCapabilities) throws -> Void)?
    public var onRecord: ((SecureRecord) -> Void)?
    public var onClosed: ((String, Bool) -> Void)?
    /// Called after a record was queued on this link (the app pumps its driver).
    public var onRecordCopied: (() -> Void)?
    private var ordered: [(type: SecureRecordType, payload: Data)] = []
    public private(set) var copiedRecords = 0

    // Backpressure, as Android's blocking copy loop (one record in flight per direction): the other hop stops parsing
    // records while this link has `highWaterBytes` of copied records queued, and resumes below `lowWaterBytes`.
    public static let highWaterBytes = 64 * 1024
    public static let lowWaterBytes = 16 * 1024
    /// Input held while paused before the relay gives up on a hop that never drains (a GATT peer cannot be slowed).
    public static let maxHeldBytes = 512 * 1024
    public private(set) var orderedBytes = 0
    public var isBehind: Bool { orderedBytes >= Self.highWaterBytes }
    /// True while the hop this link's records are copied to is behind (set by `CallRelayHop`).
    public var isDestinationBehind: (() -> Bool)?
    /// Called once the queue drained below `lowWaterBytes` after being behind. It runs inside the sealing path: resume
    /// the other hop asynchronously (`CallRelayHop.resumeIngress`), never from this callback directly.
    public var onDrained: (() -> Void)?
    private var wasBehind = false
    public override var ingressPaused: Bool { isDestinationBehind?() ?? false }

    /// - Parameter bmh3: EXPERIMENTAL BMH3 on this hop (Android: a relay is an R_FIRST responder toward its parent and an
    ///   initiator toward its child, always with its real key; nil = BMH2 only).
    public init(role: HandshakeRole, transport: MeshTransport, identity: SigningIdentity, bmh3: Bmh3CallSettings? = nil) {
        let caps = NodeCapabilities(transportMask: transport.capabilityBit | NodeCapabilities.transportCallRelay, encodeCodecMask: 0, decodeCodecMask: 0,
                                    maxBitrateKbps: transport.maxVideoBitrateKbps, maxChildren: 1)
        super.init(role: role, transport: transport, identity: identity, linkCapabilities: caps, endpointCapabilities: caps, bmh3: bmh3)
        maxHeldIngressBytes = Self.maxHeldBytes
    }

    public override var linkOnly: Bool { true }

    public override func validateLinkPeer() throws {
        guard let id = link.peerNodeId, let caps = link.peerCapabilities else { throw ProtocolError.authentication }
        if let expectedPeerPrefix, id.prefix != expectedPeerPrefix { throw ProtocolError.authentication }
        try onAuthenticated?(id, caps)
    }

    public override func handleOpenRecord(_ record: SecureRecord) throws {
        switch record.type {
        case .endToEndHandshake, .endToEndContent, .linkHeartbeat: onRecord?(record)
        default: throw ProtocolError.malformed("A call relay carries only end-to-end records and heartbeats, not \(record.type)")
        }
    }

    /// Copies one endpoint record unchanged (ordered with every other copied record).
    public func copy(_ record: SecureRecord) {
        ordered.append((record.type, record.payload)); orderedBytes += record.payload.count; copiedRecords += 1
        if isBehind { wasBehind = true }
        onRecordCopied?()
    }
    /// Fresh version-1 liveness for this hop (replaces the endpoint's heartbeat). It keeps its place among the
    /// copied records: an endpoint still in its handshake accepts only the handshake reply first (a heartbeat
    /// overtaking the callee's reply ended the caller's handshake in the first loopback).
    public func sendLiveness() {
        ordered.append((.linkHeartbeat, LinkHeartbeat.version1)); orderedBytes += LinkHeartbeat.version1.count
        if isBehind { wasBehind = true }   // a heartbeat can be what crosses the high-water mark
        onRecordCopied?()
    }

    public override func nextOrderedOutgoing(now: TimeInterval) throws -> Data? {
        guard !ordered.isEmpty else { return nil }
        let (type, payload) = ordered.removeFirst()
        orderedBytes -= payload.count
        let sealed = try link.seal(type, payload)
        if wasBehind, orderedBytes < Self.lowWaterBytes { wasBehind = false; onDrained?() }
        return sealed
    }
    public override var hasOrderedOutput: Bool { !ordered.isEmpty }
    public override func didClose(reason: String, error: Bool) {
        if error { ordered.removeAll(); orderedBytes = 0 }
        onClosed?(reason, error)
    }
}

/// A relay hop: one child (downstream, connected first) and one parent. Single use.
public final class CallRelayHop {
    public enum State: Equatable { case connectingChild, waitingForParent, relaying, closed(String) }
    public let identity: SigningIdentity
    public let transport: MeshTransport
    public let childOffer: DiscoveryAnnouncement
    public var calleePrefix: Data { childOffer.nodeIdPrefix }
    public let child: CallRelayLink
    public private(set) var parent: CallRelayLink?
    public private(set) var state: State = .connectingChild
    public private(set) var childNodeId: NodeId?
    public var onStateChange: ((State) -> Void)?
    private var childAuthenticatedAt: TimeInterval?
    private let budget: Bmh3SigningBudget

    /// EXPERIMENTAL "Hidden identities": BMH3 on both hops (the parent hop answers BMH3 or BMH2; the child hop speaks
    /// BMH3 when the child's offer carries the hint or its prefix is pinned, else BMH2, exactly as a caller decides).
    public let hiddenIdentities: Bool
    private let pins: Bmh3Pins?

    /// Amendment CP (pseudonym mode with `test_relayed_pseudonymous_edges` on): the child hop always speaks BMH3 with a
    /// declared throwaway, fresh for this connection, no tag and nothing pinned. A child that answers with a real key
    /// must be the callee at route cost 0; a child that declared a throwaway is not bound (the caller's end-to-end check
    /// authenticates the callee).
    public let pseudonymousEdges: Bool

    public init(identity: SigningIdentity, transport: MeshTransport, childOffer: DiscoveryAnnouncement,
                hiddenIdentities: Bool = false, pins: Bmh3Pins? = nil, budget: Bmh3SigningBudget = Bmh3CallSettings.sharedBudget,
                pseudonymousEdges: Bool = false) {
        self.identity = identity; self.transport = transport; self.childOffer = childOffer
        self.hiddenIdentities = hiddenIdentities; self.pins = pins; self.budget = budget
        self.pseudonymousEdges = hiddenIdentities && pseudonymousEdges
        var childSettings: Bmh3CallSettings?
        if self.pseudonymousEdges {
            let settings = Bmh3CallSettings(speak: true, stranger: SoftwareSigningIdentity(), checkResponder: { peer, _ in
                if !peer.pseudonymous, childOffer.routeCost == 0, peer.nodeId.prefix != childOffer.nodeIdPrefix { throw ProtocolError.authentication }
            })
            settings.linkTag = false
            childSettings = settings
        } else if hiddenIdentities, Bmh3Choice.decide(enabled: true, only: false, offer: childOffer, pinned: pins?.isPinned(childOffer.nodeIdPrefix) ?? false).bmh3 {
            // A relay presents its real key. At route cost 0 the child must be the callee (the prefix, checked before this
            // relay reveals itself); a pseudonymous answerer is refused by the engine (a real key never answers a throwaway).
            let settings = Bmh3CallSettings(speak: true, checkResponder: { peer, _ in
                if childOffer.routeCost == 0, peer.nodeId.prefix != childOffer.nodeIdPrefix { throw ProtocolError.authentication }
            })
            if let pins, childOffer.routeCost == 0 { settings.onRealResponder = { pins.pin($0.nodeId.prefix) } }
            childSettings = settings
        }
        child = CallRelayLink(role: .initiator, transport: transport, identity: identity, bmh3: childSettings)
        child.onAuthenticated = { [unowned self] id, caps in
            if self.pseudonymousEdges, child.linkPeerPseudonymous {
                // A declared throwaway is only acceptable as the callee itself (route cost 0); a next relay answers real.
                guard childOffer.routeCost == 0, id != identity.nodeId else { throw ProtocolError.state("A next relay must answer with its real key") }
                childNodeId = id
                childAuthenticatedAt = child.lastReceiveAt
                set(.waitingForParent)
                return
            }
            if let problem = CallRelayChain.childProblem(childRouteCost: childOffer.routeCost, calleePrefix: childOffer.nodeIdPrefix,
                                                          ownNodeId: identity.nodeId, child: id, caps: caps) {
                throw ProtocolError.state(problem)
            }
            childNodeId = id
            childAuthenticatedAt = child.lastReceiveAt
            set(.waitingForParent)
        }
        child.onRecord = { [unowned self] record in
            guard let parent, parent.phase == .open else { return }   // nothing to copy to yet
            if record.type == .linkHeartbeat { parent.sendLiveness() } else { parent.copy(record) }
        }
        child.isDestinationBehind = { [unowned self] in parent?.isBehind ?? false }
        child.onDrained = { [unowned self] in onIngressResumable?() }
        child.onClosed = { [unowned self] reason, _ in close("Child: \(reason)") }
    }

    /// The offer to advertise once the child is authenticated (nil before).
    public var parentOffer: DiscoveryAnnouncement? {
        state == .waitingForParent ? CallRelayChain.parentOffer(childOffer: childOffer, transport: transport) : nil
    }

    /// A caller or upstream relay connected as central: this hop is its link responder.
    public func attachParent() -> CallRelayLink? {
        guard state == .waitingForParent, parent == nil else { return nil }
        // Toward its parent the relay is an Everyone-mode responder: BMH3 (a pseudonym-mode caller speaks only that,
        // presenting a throwaway link key) or BMH2. It never presents a pseudonym itself.
        let settings = hiddenIdentities ? Bmh3CallSettings(speak: false, acceptBmh2: true, replayCache: Bmh3CallSettings.sharedReplayCache, budget: budget) : nil
        let link = CallRelayLink(role: .responder, transport: transport, identity: identity, bmh3: settings)
        link.onAuthenticated = { [unowned self] id, caps in
            guard caps.supports(transport: transport.capabilityBit) else { throw ProtocolError.incompatible("The parent did not sign this transport") }
            if let problem = CallRelayChain.parentProblem(parent: id, ownNodeId: identity.nodeId, child: childNodeId, calleePrefix: calleePrefix) {
                throw ProtocolError.state(problem)
            }
            set(.relaying)
        }
        link.onRecord = { [unowned self] record in
            guard child.phase == .open else { return }
            if record.type == .linkHeartbeat { child.sendLiveness() } else { child.copy(record) }
        }
        link.onClosed = { [unowned self] reason, _ in close("Parent: \(reason)") }
        link.isDestinationBehind = { [unowned self] in child.isBehind }
        link.onDrained = { [unowned self] in onIngressResumable?() }
        parent = link
        return link
    }

    /// A hop drained after falling behind: the app calls `resumeIngress` asynchronously (outside the sealing path).
    public var onIngressResumable: (() -> Void)?

    /// Parses input held on either hop while the other was behind.
    public func resumeIngress(now: TimeInterval) {
        child.resumeIngress(now: now); parent?.resumeIngress(now: now)
    }

    /// Parent wait bound (the endpoints' own 8 s liveness ends a stalled relayed call).
    public func tick(now: TimeInterval) {
        child.tick(now: now); parent?.tick(now: now)
        if state == .waitingForParent, parent == nil, let since = childAuthenticatedAt, now - since > CallRelayChain.parentWait {
            close("No caller connected within \(Int(CallRelayChain.parentWait)) s")
        }
    }

    public func close(_ reason: String) {
        if case .closed = state { return }
        set(.closed(reason))
        child.finish(reason, error: false); parent?.finish(reason, error: false)
    }

    private func set(_ s: State) { state = s; onStateChange?(s) }
}
