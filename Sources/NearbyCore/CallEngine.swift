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
    /// The verifier's wall-clock epoch for the RD4 window of an opening.
    public var wallEpoch: () -> Int64
    /// Phase 2: the presence-lease exchange with a mutual verified contact (nil = no OFFER/LEASE).
    public var presence: PresenceCallHooks?
    public init(selected: DiscoveryAnnouncement? = nil, entries: (() -> [OpeningEntry])? = nil,
                wallEpoch: @escaping () -> Int64 = RotatingDiscoveryIds.currentWallEpoch) {
        self.selected = selected; self.entries = entries; self.wallEpoch = wallEpoch
    }
}

/// Phase 2 presence leases for one call: what the app's vault answers. Every check runs again at send time.
public struct PresenceCallHooks {
    /// This side may offer: the peer's real identity is a verified contact, its "Can see when I'm nearby" switch is on
    /// and the vault is persistent.
    public var eligible: (NodeId, IdentityFingerprint) -> Bool
    /// The lease for the peer, recorded as delivered first; nil withholds it.
    public var lease: (NodeId, IdentityFingerprint) -> DiscoveryExchange.PresenceLease?
    /// A lease from the peer passed the session rules.
    public var store: (NodeId, DiscoveryExchange.PresenceLease) -> Void
    /// The peer's fingerprint is verified in the store right now.
    public var verified: (IdentityFingerprint) -> Bool
    public init(eligible: @escaping (NodeId, IdentityFingerprint) -> Bool, lease: @escaping (NodeId, IdentityFingerprint) -> DiscoveryExchange.PresenceLease?,
                store: @escaping (NodeId, DiscoveryExchange.PresenceLease) -> Void, verified: @escaping (IdentityFingerprint) -> Bool) {
        self.eligible = eligible; self.lease = lease; self.store = store; self.verified = verified
    }
}

/// EXPERIMENTAL BMH3 for one call (Android "Hidden identities" and "Pseudonymous toward strangers"; nil = BMH2 only).
/// EXPERIMENTAL relayed calls (Design C) for one call connection. With `featureOn` the link hello signs bit 4
/// ("understands RELAY_SETUP"); a caller with `route` connects to the route's first helper, sends SETUP after the link
/// handshake and starts the endpoint handshake only after READY.
public struct RelayedCallOptions {
    public var featureOn: Bool
    public var route: RelayRoute?
    /// Amendment CP: a first hop that declared a throwaway is not bound to the chosen helper (a real key still is).
    public var pseudonymousEdges: Bool
    /// When the dial started (uptime): the 20 s setup deadline counts from here, connect time included.
    public var setupStartedAt: TimeInterval?
    /// Benchmark rule: only a chain of exactly this many relays counts (0 = any).
    public var requireRelays: Int
    public var maxRelays: Int
    /// A listener that helps right now: its link hello signs bits 4 and 6 and capacity 1, and its first record may be
    /// a SETUP, which pauses this engine and raises `.relaySetupRequested` (the app hands the link to a duty).
    public var helperActive: Bool
    /// SETUP message 4 (role-0 RDI target) is understood: rotating IDs and relayed calls both on.
    public var acceptRdi: Bool
    public init(featureOn: Bool, route: RelayRoute? = nil, pseudonymousEdges: Bool = true, setupStartedAt: TimeInterval? = nil,
                requireRelays: Int = 0, maxRelays: Int = RelayedCalls.defaultMaxRelays, helperActive: Bool = false, acceptRdi: Bool = false) {
        self.featureOn = featureOn; self.route = route; self.pseudonymousEdges = pseudonymousEdges
        self.setupStartedAt = setupStartedAt; self.requireRelays = requireRelays; self.maxRelays = maxRelays
        self.helperActive = helperActive; self.acceptRdi = acceptRdi
    }
}

public struct Bmh3CallOptions {
    /// Pseudonym mode (rule P): strangers meet a throwaway key; needs rotating IDs, as on Android. It also means this
    /// phone never speaks BMH2 and refuses a BMH2 caller (PR1).
    public var pseudonyms: Bool
    /// Caller: the offer the user selected (any version; a version 5 one is always BMH3, a version 2 one with the hint).
    public var selected: DiscoveryAnnouncement?
    public var pins: Bmh3Pins?
    /// The responder's signing budget (process-wide by default).
    public var budget: Bmh3SigningBudget
    public var wallEpoch: () -> Int64
    /// Phase 2 (caller): the contact tag for a recognised contact's selected advert.
    public var contactTag: Bmh3ContactTag?
    /// Phase 2 (callee): this phone's tag checks for the adverts it has on air, and the lease recipients.
    public var tagChecks: (() -> [Bmh3ContactTag])?
    public var admitTagged: ((NodeId) -> Bool)?
    /// Callee in pseudonym mode: this phone's current discovery epoch, which scopes the replay cache and the signing
    /// budget (Android `epoch`, review PR3). Nil keeps the process-wide pair.
    public var epoch: (() -> Int64)?
    public var epochGuards: Bmh3EpochGuards = Bmh3CallSettings.epochGuards
    /// Amendment CP (Android `test_relayed_pseudonymous_edges`, on; false is the control arm): toward a relay the caller's
    /// fresh link throwaway declares PSEUDONYM instead of posing as a real key.
    public var pseudonymousRelayEdges = true
    /// Design C: the first helper's own offer when the call takes an on-demand relayed route.
    public var relayHop: DiscoveryAnnouncement?
    public init(pseudonyms: Bool, selected: DiscoveryAnnouncement? = nil, pins: Bmh3Pins? = nil,
                budget: Bmh3SigningBudget = Bmh3CallSettings.sharedBudget, wallEpoch: @escaping () -> Int64 = RotatingDiscoveryIds.currentWallEpoch) {
        self.pseudonyms = pseudonyms; self.selected = selected; self.pins = pins; self.budget = budget; self.wallEpoch = wallEpoch
    }

    /// The per-connection BMH3 settings, or nil when this connection speaks BMH2 (the caller's `Bmh3Choice`).
    func settings(role: PrivateCallRole, openingEntries: (() -> [OpeningEntry])?) -> Bmh3CallSettings? {
        switch role {
        case .caller:
            // A Design C route decides BMH3 on its first helper's own offer (Android relayHopUsesBmh3).
            let choiceOffer = relayHop ?? selected
            let pinned = choiceOffer.map { pins?.isPinned($0.nodeIdPrefix) ?? false } ?? false
            guard Bmh3Choice.decide(enabled: true, only: pseudonyms, offer: choiceOffer, pinned: pinned).bmh3 else { return nil }
            let towardRelay = (selected?.routeCost ?? 0) > 0
            let settings = Bmh3CallSettings(
                speak: true,
                stranger: pseudonyms && selected != nil ? SoftwareSigningIdentity() : nil,
                linkIdentityOverride: towardRelay ? SoftwareSigningIdentity() : nil,
                checkResponder: selected.map { Bmh3CallSettings.selectionCheck($0, wallEpoch: wallEpoch) } ?? { _, _ in })
            if let pins, !towardRelay { settings.onRealResponder = { peer in pins.pin(peer.nodeId.prefix) } }
            settings.contactTag = contactTag
            settings.linkTag = !towardRelay
            settings.declareLinkOverride = towardRelay && pseudonymousRelayEdges
            return settings
        case .callee:
            // Rule P fails closed: in pseudonym mode every untagged connection meets a fresh throwaway for this connection.
            // Its replay cache and budget belong to the current epoch, so nothing observable crosses a rotation (PR3).
            let scoped = pseudonyms ? epoch.map { epochGuards.forEpoch($0()) } : nil
            let settings = Bmh3CallSettings(speak: false, acceptBmh2: !pseudonyms, stranger: pseudonyms ? SoftwareSigningIdentity() : nil,
                                            opening: { Bmh3CallSettings.openingValue(openingEntries?() ?? []) },
                                            replayCache: scoped?.replayCache ?? Bmh3CallSettings.sharedReplayCache, budget: scoped?.budget ?? budget)
            if let tagChecks { settings.tagChecks = tagChecks }
            if let admitTagged { settings.admitTagged = admitTagged }
            return settings
        }
    }
}

public final class CallEngine: MeshConnection {
    public enum Event: Equatable {
        case linkAuthenticated(NodeId)
        case peerAuthenticated(NodeId, IdentityFingerprint)
        /// BMH3 pseudonyms: the peer is an unverified stranger behind a throwaway key (no node ID, no fingerprint) until
        /// its reveal, which then arrives as `peerAuthenticated` with the real identity.
        case peerStranger
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
        /// Experimental relayed calls: the first hop answered READY with this many relays to the callee.
        case relayReady(Int)
        /// Experimental relayed calls: this helper listener's first record was SETUP (adopt the link for a duty).
        case relaySetupRequested(RelaySetupMessage)
        case ended(String, error: Bool)
    }

    public static let heartbeatInterval: TimeInterval = 1
    public static let silentLinkTimeout: TimeInterval = 8
    public static let ringTimeout: TimeInterval = 60
    /// A link that finished both handshakes must carry the call's Invite within this time, or a peer could hold an
    /// authenticated link open with heartbeats and never ring. Apple-local for now (review 2026-10-27): the 10 s
    /// matches Android's HOP_AUTH_MS, which bounds the caller's handshake wait; PROTOCOL gains the rule once Android
    /// has the matching callee fix.
    public static let inviteTimeout: TimeInterval = 10
    public static let inviteTimeoutReason = "No call arrived after the secure setup"

    public let callRole: PrivateCallRole
    public let negotiation: VoiceCallNegotiation
    public var onEvent: ((Event) -> Void)?
    public private(set) var state: PrivateCallState?
    public private(set) var relayHops: UInt8
    /// Relayed calls cap video at 110 kbps (Android PrivateCallMedia: 15 fps / 110 kbps when hops > 0).
    public var effectiveVideoBitrate: Int { relayHops > 0 ? min(settings.videoBitrate, 110_000) : settings.videoBitrate }
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
                rotating: RotatingCallOptions? = nil, bmh3: Bmh3CallOptions? = nil, relayed: RelayedCallOptions? = nil) {
        labelOptions = labels
        relayedOptions = relayed
        rotatingOptions = rotating
        bmh3Options = bmh3
        callRole = role
        negotiation = VoiceCallNegotiation(role: role, requested: requestedType)
        self.relayHops = relayHops
        self.settings = settings
        cameraEnabled = requestedType == .video
        fragmentsEnabled = videoFragments
        var link = NodeCapabilities(transportMask: transport.capabilityBit, encodeCodecMask: encodeMask & NodeCapabilities.codecMask,
                                    decodeCodecMask: decodeMask & NodeCapabilities.codecMask, maxBitrateKbps: transport.maxVideoBitrateKbps, maxChildren: 0)
        var endpointCaps = link
        // Relayed calls: every endpoint with the experiment on signs link bit 4 (the end-to-end hello is unchanged).
        link = RelayedCalls.linkCapabilities(link, featureOn: relayed?.featureOn == true,
                                             helperActive: role == .callee && relayed?.featureOn == true && relayed?.helperActive == true)
        // Rotating IDs: bit 3 only in the call-endpoint link hello (never the endpoint hello).
        if rotating != nil { link.transportMask |= NodeCapabilities.transportDiscoveryOpening }
        if videoFragments { endpointCaps.transportMask |= NodeCapabilities.transportVideoFragments }
        endpointCaps = PeerLabelFeature.advertise(endpointCaps, enabled: labels != nil)
        // Rotating IDs phase 1b: call endpoints also sign end-to-end bit 3 (BDX1 OPENING / reveal exchange).
        if rotating != nil { endpointCaps.transportMask |= NodeCapabilities.endpointDiscoveryExchange }
        let bmh3Settings = bmh3?.settings(role: role, openingEntries: rotating?.entries)
        super.init(role: role == .caller ? .initiator : .responder, transport: transport, identity: identity,
                   linkCapabilities: link, endpointCapabilities: endpointCaps, bmh3: bmh3Settings)
        self.expectedPeerPrefix = rotating?.selected?.rotating == true ? nil : expectedPeerPrefix
        if let rotating {
            discoveryOpeningEntries = { [weak self] in self?.callRole == .callee ? (rotating.entries?() ?? []) : [] }
            onDiscoveryOpening = { [weak self] entries in try self?.checkOpening(entries) }
        }
        if role == .callee, relayed?.featureOn == true, relayed?.helperActive == true { acceptRelaySetup = true }
        if role == .caller, relayed?.route != nil {
            // The SETUP wait (up to 20 s plus 2 s grace) runs before the endpoint handshake.
            setupTimeout += TimeInterval(RelayedCalls.setupDeadlineMs + RelayedCalls.setupReplyGraceMs) / 1000
        }
    }

    // MARK: Experimental relayed calls (Design C), caller side

    private let relayedOptions: RelayedCallOptions?
    private var relayRoute: RelayRoute? { callRole == .caller ? relayedOptions?.route : nil }
    private var relaySetupId: Data?
    private var relaySetupDeadline: TimeInterval?
    /// Relays the first hop reported in READY (nil until READY).
    public private(set) var relayReadyRelays: Int?
    /// Why the relayed route failed before READY (a closure before READY counts as a timeout, PROTOCOL rule 5).
    public private(set) var relaySetupFailure: RelaySetupFailure?
    /// The hop answered something invalid (not a reason code): the route is skipped like a failure.
    public private(set) var relaySetupInvalid = false
    public var relayedRouteFailed: Bool {
        relayRoute != nil && relayReadyRelays == nil && (relaySetupFailure != nil || relaySetupInvalid || phase == .closed)
    }
    public override var defersEndpointHello: Bool { relayRoute != nil }

    /// Fails the relayed route: the call ends with the plain reason.
    private func failRelay(_ reason: RelaySetupFailure?, _ text: String) {
        if let reason { relaySetupFailure = reason } else { relaySetupInvalid = true }
        acceptRelaySetup = false
        fail("Relayed route failed: \(text)")
    }

    /// The first hop must be the chosen helper: a real key equals (fixed prefix) or opens (rotating) the helper's
    /// offer; a declared throwaway is accepted only under Amendment CP. Its hello must show bits 4 and 6 and capacity.
    private func relayHopProblem() -> (RelaySetupFailure, String)? {
        guard let route = relayRoute, let peer = link.peerNodeId, let caps = link.peerCapabilities else { return (.childAuthentication, "No first hop") }
        let throwaway = link.peerPseudonymous
        if throwaway && relayedOptions?.pseudonymousEdges != true {
            return (.childAuthentication, "The phone that answered is not the helper that was chosen")
        }
        if !throwaway && !route.rotating && peer.prefix != route.helperPrefix {
            return (.childAuthentication, "The phone that answered is not the helper that was chosen")
        }
        if !RelayedCalls.linkAcceptsSetup(caps) { return (.refused, RelaySetupFailure.refused.userText) }
        return nil
    }

    private func sendRelaySetup() {
        guard let route = relayRoute, relaySetupId == nil else { return }
        if let (reason, text) = relayHopProblem() { failRelay(reason, text); return }
        let spentMs = Int(((now - (relayedOptions?.setupStartedAt ?? startedAt)) * 1000).rounded())
        let remaining = min(max(RelayedCalls.setupDeadlineMs - spentMs, 0), RelayedCalls.setupDeadlineMs)
        guard remaining >= RelayedCalls.minRemainingMs else { failRelay(.timeout, RelaySetupFailure.timeout.userText); return }
        let id = RelaySetupCodec.newSetupId()
        do {
            acceptRelaySetup = true
            try sendRelaySetup(.setup(target: route.target, budget: route.relays, remainingMs: remaining, setupId: id, rotating: route.rotating))
            relaySetupId = id
            relaySetupDeadline = now + TimeInterval(remaining + RelayedCalls.setupReplyGraceMs) / 1000
        } catch {
            failRelay(nil, "The relayed route could not be requested")
        }
    }

    /// A helper listener read SETUP as its first record: this engine pauses (no call) until the app adopts its link.
    public private(set) var relaySetupRequest: RelaySetupMessage?
    public override var ingressPaused: Bool { relaySetupRequest != nil }

    public override func handleRelaySetupRecord(_ record: SecureRecord) throws {
        if callRole == .callee {
            guard relaySetupRequest == nil, state == nil, endpoint == nil else { throw ProtocolError.state("Unexpected relay setup record") }
            acceptRelaySetup = false
            let message = try RelaySetupCodec.decode(record.payload, acceptRdi: relayedOptions?.acceptRdi == true)
            guard case .setup = message else { throw ProtocolError.state("A listener reads only SETUP") }
            relaySetupRequest = message
            onEvent?(.relaySetupRequested(message))
            return
        }
        guard let route = relayRoute, let id = relaySetupId, relayReadyRelays == nil else { throw ProtocolError.state("Unexpected relay setup record") }
        acceptRelaySetup = false   // exactly one reply
        guard let reply = try? RelaySetupCodec.decode(record.payload), reply.setupId == id else {
            failRelay(nil, "The helping phone sent an invalid answer"); return
        }
        switch reply {
        case .ready(_, let relays):
            let required = relayedOptions?.requireRelays ?? 0
            guard relays <= route.relays, relays <= (relayedOptions?.maxRelays ?? CallRelayChain.maxRelays) else {
                failRelay(nil, "The helping phone reported more relays than were asked for"); return
            }
            if required > 0 && relays != required {
                failRelay(nil, "The route used \(relays) relays, but exactly \(required) were required"); return
            }
            relayReadyRelays = relays
            relayHops = UInt8(relays)
            relaySetupDeadline = nil
            onEvent?(.relayReady(relays))
            try sendDeferredEndpointHello()
        case .fail(_, let reason):
            failRelay(reason, reason.userText)
        case .setup:
            failRelay(nil, "The helping phone sent an invalid answer")
        }
    }

    public override func tickSetup(now: TimeInterval) {
        if let deadline = relaySetupDeadline, relayReadyRelays == nil, now > deadline {
            relaySetupDeadline = nil
            failRelay(.timeout, RelaySetupFailure.timeout.userText)
        }
    }

    // MARK: Experimental rotating discovery IDs (RV15)
    private let rotatingOptions: RotatingCallOptions?
    private var selectedRotating: DiscoveryAnnouncement? { rotatingOptions?.selected.flatMap { $0.rotating ? $0 : nil } }

    public override func validateLinkPeer() throws {
        if let route = relayRoute {
            if route.rotating, !link.peerPseudonymous,
               (link.peerCapabilities?.transportMask ?? 0) & NodeCapabilities.transportDiscoveryOpening == 0 {
                throw ProtocolError.authentication
            }
            return
        }
        // A selected rotating advert needs the opening; a peer without bit 3 fails like a prefix mismatch. A pseudonymous
        // BMH3 answerer withholds its opening until its reveal; a relay (route cost above 0) cannot open the callee's ID.
        if selectedRotating != nil, !link.peerPseudonymous, (selectedRotating?.routeCost ?? 0) == 0,
           (link.peerCapabilities?.transportMask ?? 0) & NodeCapabilities.transportDiscoveryOpening == 0 {
            throw ProtocolError.authentication
        }
    }

    // MARK: Experimental BMH3 pseudonyms and the BDX1 exchange (phase 1b)
    private let bmh3Options: Bmh3CallOptions?
    /// Both endpoint hellos carried bit 3: BDX1 (content type 11) records are exchanged.
    public private(set) var discoveryNegotiated = false
    /// Caller: the callee's first end-to-end record must be its BDX1 OPENING for the selected rotating offer.
    private var awaitingOpening = false
    /// Caller: the callee answered with a throwaway; its reveal must arrive (before Accept) and open the selection.
    private var awaitingReveal = false
    /// Caller labels held until the callee proved itself (reveal or relayed OPENING).
    private var heldCallerLabels: Data?
    /// Callee: the role-0 entries pinned when the connection was set up (sent in the OPENING or the reveal).
    private var calleeEntries: [OpeningEntry] = []
    /// The peer's real identity after a verified reveal.
    public private(set) var revealedPeer: Bmh3Reveal.Verified?
    /// Callee that revealed itself to a pseudonymous caller: the caller's reveal is required (CallerRevealGate).
    private var callerRevealDeadlineArmed = false
    /// The callee's own camera and microphone wait for the caller's verified reveal (the risk stays with the caller).
    private var localMediaHeldForReveal = false
    private var callerRevealDeadlineStart: TimeInterval?
    /// Test seam: a caller that never reveals itself (a misbehaving peer).
    var testingWithholdOwnReveal = false
    /// Target-side rules for relayed calls (Android Design C target rule, Amendment CP): a relayed call is declined
    /// before it rings unless this phone's relayed calls are on, and a relayed stranger call also needs
    /// `acceptRelayedStrangerCalls`. The app sets both; they default to true only for the engine's own tests.
    public var acceptRelayedCalls = true
    public var acceptRelayedStrangerCalls = true
    /// Why an incoming call was declined before it rang, or nil.
    public private(set) var relayedDecline: RelayedCallPolicy.Incoming?
    /// Android F14 busy rule: this phone is already in a call or dialling, so an Invite is declined with BUSY (wire
    /// value 2) before it rings; the caller shows "Busy" instead of a dropped link.
    public var declineAsBusy = false
    public private(set) var declinedBusy = false
    /// True when this call passes through at least one relay: the Invite says so (the caller's claim, which can only
    /// make a call count as relayed), or the authenticated link peer is not the authenticated call peer (a direct call
    /// uses the same key at both layers).
    public var isRelayed: Bool {
        relayHops > 0 || (endpoint.map { session in peerLinkNodeId.map { $0 != session.peerNodeId } ?? false } ?? false)
    }
    /// Test seam: a caller that opens the link but never sends its Invite.
    var testingWithholdInvite = false
    /// Test seam: a peer that never sends its stream header or media.
    var testingWithholdLocalMedia = false
    /// Test seam: a peer that sends its stream header before the call was answered (a misbehaving peer).
    func testingSendHeaderEarly() {
        let header = StreamHeader(width: settings.width, height: settings.height, fps: settings.fps, codecId: StreamProtocol.codecVP9,
                                  includeAudio: true)
        if let encoded = try? header.encoded() { enqueue(.content(.streamHeader, 0, encoded), .control) }
    }
    /// Test seam: a caller that withheld its reveal sends it now (late).
    func testingSendHeldReveal() throws {
        guard let session = endpoint?.reveal, session.callerMayReveal else { return }
        enqueue(.content(.discoveryExchange, 0, try session.sendOwn(real: identity, entries: [])), .control)
    }
    /// When the secure setup finished (the first open tick), for the Invite deadline.
    private var openSince: TimeInterval?
    private var callerRevealPending: Bool { callRole == .callee && endpoint?.reveal?.peerRevealRequired == true }

    /// Header and media from the peer (review 2026-10-27, both roles; Android CallMediaGate): allowed once the call was
    /// answered and the peer's required reveal verified; late media after the end is dropped; anything else ends the
    /// call. The caller thus never decodes or shows a pseudonymous callee's video before its reveal, and nobody's
    /// media plays before the answer.
    private func admitMedia() throws -> Bool {
        switch state?.phase {
        case .negotiatingMedia?, .active?: break
        case .ended?: return false
        default: throw ProtocolError.state("Media before the call was answered")
        }
        if endpoint?.reveal?.peerRevealRequired == true { throw ProtocolError.authentication }
        return true
    }
    /// True while the peer is a stranger behind a throwaway key.
    public var peerIsStranger: Bool { endpoint?.peerPseudonymous == true && revealedPeer == nil }
    /// The key this phone signs labels with (a pseudonym in a stranger session).
    private var labelSigner: SigningIdentity { endpoint?.presentedIdentity ?? identity }

    private var selectedOffer: DiscoveryAnnouncement? { bmh3Options?.selected ?? rotatingOptions?.selected }

    private func handleDiscoveryExchange(_ payload: Data) throws {
        let record: DiscoveryExchange.Record
        do { record = try DiscoveryExchange.decode(payload) } catch {
            // A BDX1 record never fails a call, except a reveal (below) or a missing OPENING the caller waits for.
            if awaitingOpening { throw ProtocolError.authentication }
            return
        }
        switch record {
        case .opening(let entries):
            guard awaitingOpening, let selected = selectedOffer, let endpoint else { return } // not examined otherwise
            awaitingOpening = false
            guard DiscoverySelectionCheck.check(selected: selected, expectedRole: RotatingDiscoveryIds.roleCallOffer,
                                                peerNodeId: endpoint.peerNodeId.bytes, openingEntries: entries, verifierWallEpoch: rotatingOptions?.wallEpoch()) == .pass else {
                throw ProtocolError.authentication
            }
            releaseHeldCallerLabels()
        case .identityReveal(let reveal):
            guard let session = endpoint?.reveal else { throw ProtocolError.state("Unexpected identity reveal") }
            let verified = try session.onPeerReveal(reveal)
            // A verified contact's prefix with another key ends the call before this phone reveals anything.
            try identityGate?.admit(peer: verified.nodeId, fingerprint: verified.fingerprint)
            if callRole == .caller {
                guard awaitingReveal, let selected = selectedOffer else { throw ProtocolError.state("Unexpected callee reveal") }
                guard DiscoverySelectionCheck.check(selected: selected, expectedRole: RotatingDiscoveryIds.roleCallOffer,
                                                    peerNodeId: verified.nodeId.bytes, openingEntries: verified.entries, verifierWallEpoch: rotatingOptions?.wallEpoch()) == .pass else {
                    throw ProtocolError.authentication
                }
                awaitingReveal = false
                revealedPeer = verified
                onEvent?(.peerAuthenticated(verified.nodeId, verified.fingerprint))
                if session.callerMayReveal && !testingWithholdOwnReveal {
                    enqueue(.content(.discoveryExchange, 0, try session.sendOwn(real: identity, entries: [])), .control)
                }
                releaseHeldCallerLabels()
            } else {
                revealedPeer = verified
                onEvent?(.peerAuthenticated(verified.nodeId, verified.fingerprint))
                // The caller proved itself: the callee's own media may start now.
                callerRevealDeadlineArmed = false
                if localMediaHeldForReveal { localMediaHeldForReveal = false; startLocalMedia() }
                // The callee answered before it knew who called: the presence exchange starts with the real identity now.
                if state?.phase == .negotiatingMedia || state?.phase == .active { startPresence() }
            }
        case .recognitionOffer, .presenceLease:
            // Phase 2: never fails a call; anything the session rules refuse is dropped and logged by the app.
            guard let session = presenceSessionIfReady(), let peer = realPeer, let hooks = rotatingOptions?.presence else { return }
            perform(session.onRecord(record, peerVerifiedNow: hooks.verified(peer.fingerprint)))
        }
    }

    // MARK: Phase 2 presence leases (answered calls between mutual verified contacts)
    private var presenceSession: PresenceSession?
    public private(set) var presenceRejections: [String] = []
    public private(set) var presenceLeasesSent = 0, presenceLeasesStored = 0

    /// The peer's real identity: the endpoint, or after a pseudonym session its verified reveal; nil while a stranger.
    private var realPeer: (nodeId: NodeId, fingerprint: IdentityFingerprint)? {
        if let revealedPeer { return (revealedPeer.nodeId, revealedPeer.fingerprint) }
        guard let endpoint, !endpoint.peerPseudonymous else { return nil }
        return (endpoint.peerNodeId, endpoint.peerFingerprint)
    }

    private func presenceSessionIfReady() -> PresenceSession? {
        if let presenceSession { return presenceSession }
        guard discoveryNegotiated, let hooks = rotatingOptions?.presence, let peer = realPeer else { return nil }
        let session = PresenceSession(localEligible: hooks.eligible(peer.nodeId, peer.fingerprint))
        presenceSession = session
        return session
    }

    /// The call was answered: offer (the peer may have offered first).
    private func startPresence() { if let session = presenceSessionIfReady() { perform(session.start()) } }

    private func perform(_ actions: [PresenceSession.Action]) {
        guard let hooks = rotatingOptions?.presence, let peer = realPeer else { return }
        for action in actions {
            switch action {
            case .sendOffer:
                if hooks.eligible(peer.nodeId, peer.fingerprint), let bytes = try? DiscoveryExchange.encode(.recognitionOffer) {
                    enqueue(.content(.discoveryExchange, 0, bytes), .control)
                } else { presenceSession?.offerWithheld() }
            case .sendLease:
                if let lease = hooks.lease(peer.nodeId, peer.fingerprint), let bytes = try? DiscoveryExchange.encode(.presenceLease(lease)) {
                    enqueue(.content(.discoveryExchange, 0, bytes), .control); presenceLeasesSent += 1
                }
            case .storeLease(let lease): hooks.store(peer.nodeId, lease); presenceLeasesStored += 1
            case .reject(let reason): presenceRejections.append(reason)
            }
        }
    }

    private func releaseHeldCallerLabels() {
        if let held = heldCallerLabels { heldCallerLabels = nil; enqueue(.content(.labels, 0, held), .control) }
    }

    private func checkOpening(_ entries: [OpeningEntry]) throws {
        if let route = relayRoute {
            // Design C rotating route: the first hop's opening must open the helper offer that was chosen.
            if route.rotating, !link.peerPseudonymous, let peer = link.peerNodeId,
               DiscoverySelectionCheck.check(selected: RelayedCalls.helperOfferFor(route.helperPrefix, rotating: true),
                                             expectedRole: RotatingDiscoveryIds.roleCallOffer, peerNodeId: peer.bytes, openingEntries: entries,
                                             verifierWallEpoch: rotatingOptions?.wallEpoch()) != .pass {
                failRelay(.childAuthentication, "The phone that answered is not the helper that was chosen"); return
            }
            sendRelaySetup()
            return
        }
        guard let selected = selectedRotating, let peer = link.peerNodeId else { return }
        guard DiscoverySelectionCheck.check(selected: selected, expectedRole: RotatingDiscoveryIds.roleCallOffer, peerNodeId: peer.bytes,
                                            openingEntries: entries, verifierWallEpoch: rotatingOptions?.wallEpoch()) == .pass else { throw ProtocolError.authentication }
    }

    // A relayed caller's adjacent link is the relay; the endpoint must still match the callee prefix.
    public override var expectedPrefixAppliesToEndpoint: Bool { true }

    public override func linkDidAuthenticate() {
        if let id = link.peerNodeId { onEvent?(.linkAuthenticated(id)) }
        // A relayed route sends SETUP now, or after the helper's BDO1 opening when one was negotiated.
        if relayRoute != nil, !(openingExpected && peerOpening == nil) { sendRelaySetup() }
    }

    public override func endpointDidAuthenticate(_ session: EndToEndSession) throws {
        discoveryNegotiated = rotatingOptions != nil &&
            session.peerCapabilities.transportMask & NodeCapabilities.endpointDiscoveryExchange != 0
        session.opener.acceptDiscoveryExchange = discoveryNegotiated
        if callRole == .callee { calleeEntries = rotatingOptions?.entries?() ?? [] }
        if callRole == .caller, let selected = selectedOffer {
            if session.peerPseudonymous {
                // The callee answered with a throwaway (any offer version): the binding arrives in its reveal, after
                // Accept. A direct call must still reach the same throwaway at both layers.
                guard discoveryNegotiated, session.reveal != nil else { throw ProtocolError.authentication }
                guard selected.routeCost > 0 || session.peerNodeId == link.peerNodeId else { throw ProtocolError.authentication }
                awaitingReveal = true
            } else if selected.rotating {
                // RV15: the check follows the selected version 5 offer. A direct call keeps the link opening and requires
                // the endpoint to be the link peer; with bit 3 on both sides the callee's first record is its OPENING.
                if selected.routeCost == 0 {
                    guard session.peerNodeId == link.peerNodeId, peerOpening != nil || link.usedBmh3 else { throw ProtocolError.authentication }
                }
                if discoveryNegotiated { awaitingOpening = true }
                else if selected.routeCost > 0 { throw ProtocolError.authentication }
            }
        }
        if session.peerPseudonymous { onEvent?(.peerStranger) }
        else { onEvent?(.peerAuthenticated(session.peerNodeId, session.peerFingerprint)) }
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
                if !labels.isEmpty, let container = try? SignedLabelCodec.encodeContainer(labels) {
                    // A stranger session holds the caller's name and subject until the callee proved itself (PR6), as does
                    // a relayed rotating offer until its OPENING passed.
                    if awaitingReveal || (awaitingOpening && (selectedOffer?.routeCost ?? 0) > 0) { heldCallerLabels = container }
                    else { enqueue(.content(.labels, 0, container), .control) }
                }
            }
            if !testingWithholdInvite { for signal in negotiation.inviteSignals() { try sendSignal(signal) } }
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
        // Rotating IDs phase 1b: the callee's first end-to-end record is its OPENING; anything else ends the call.
        if awaitingOpening && content.type != .discoveryExchange { throw ProtocolError.authentication }
        switch content.type {
        case .discoveryExchange:
            try handleDiscoveryExchange(content.payload)
        case .privateCallSignal:
            try handleSignal(try PrivateCallSignalMessage(decoding: content.payload))
        case .streamHeader:
            // CallerRevealGate: a pseudonymous peer reveals itself before its header; media before that ends the call.
            guard try admitMedia() else { return }
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
            guard try admitMedia() else { return }
            guard remoteHeader != nil else { throw ProtocolError.state("Peer sent media before its call header") }
            let packet = try MediaPacket(decoding: content.payload, authenticatedFlags: content.flags)
            if packet.flags & StreamProtocol.flagDisplayRotation == 0 { countReceived(packet.payload.count) }
            if !packet.isAudio { try reassembler.requireIdle("A whole call video packet") }
            try deliver(packet)
        case .videoFragment:
            guard try admitMedia() else { return }
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
        return try? SignedLabelCodec.sign(identity: labelSigner, kind: kind, binding: binding, text: text)
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
            let decision = RelayedCallPolicy.incoming(viaRelay: isRelayed, relayedCallsOn: acceptRelayedCalls,
                                                      callerPseudonymous: endpoint?.peerPseudonymous == true,
                                                      strangerCallsOn: acceptRelayedStrangerCalls)
            if decision != .ring {
                // Declined before it rings and before any opening or label leaves this phone.
                relayedDecline = decision
                try transition(.localDecline)
                try sendSignal(.decline, reason: .rejected, closeAfter: true)
                finish("Relayed call declined (\(decision.rawValue))", error: false)
                return
            }
            if declineAsBusy {
                declinedBusy = true
                try transition(.localDecline)
                try sendSignal(.decline, reason: .busy, closeAfter: true)
                finish("Declined as busy (already in a call)", error: false)
                return
            }
            ringingSince = now
            onEvent?(.phase(incoming.phase))
            // Rotating IDs phase 1b: the OPENING goes first, ahead of any label or answer (RD6). A pseudonymous callee
            // keeps its salt until its reveal at Accept.
            if discoveryNegotiated, endpoint?.reveal?.ownPseudonymous != true {
                enqueue(.content(.discoveryExchange, 0, try DiscoveryExchange.encode(.opening(calleeEntries))), .control)
            }
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
            // A pseudonymous callee's reveal precedes its Accept; an Accept without one could not prove the offer.
            if awaitingReveal { throw ProtocolError.authentication }
            try transition(.remoteAccept)
            startPresence()
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
        if testingWithholdLocalMedia { return }
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
        // BMH3 pseudonyms: accepting tells a stranger caller who this phone is. The reveal (with the pinned opening
        // entries) goes before the name and the Accept in the same ordered queue.
        if let reveal = endpoint?.reveal, reveal.ownPseudonymous, reveal.peerPseudonymous {
            enqueue(.content(.discoveryExchange, 0, try reveal.sendOwn(real: identity, entries: calleeEntries)), .control)
            callerRevealDeadlineArmed = reveal.peerRevealRequired
        }
        localMediaHeldForReveal = callerRevealPending
        // R1: the callee's name travels immediately before Accept (never on decline, cancel or no answer).
        if let labels = pendingAcceptLabels { pendingAcceptLabels = nil; enqueue(.content(.labels, 0, labels), .control) }
        try sendSignal(.accept)
        if answerVoice { try sendSignal(.cameraOff) }
        startPresence()
        if !localMediaHeldForReveal { startLocalMedia() }
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

    /// CallerRevealGate: the caller never proved who it is. Hang up with an error and the gate's own reason.
    private func endForCallerReveal() {
        if let phase = state?.phase, phase == .negotiatingMedia || phase == .active {
            try? transition(.localHangUp)
            try? sendSignal(.hangUp, reason: .error, closeAfter: true)
        }
        finish(CallerRevealGate.message, error: false)
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
        if state == nil {
            let since = openSince ?? now
            openSince = since
            if now - since >= CallEngine.inviteTimeout { fail(CallEngine.inviteTimeoutReason); return }
        }
        if callerRevealDeadlineArmed {
            // Counted from the first tick after Accept (ticks run several times a second).
            let start = callerRevealDeadlineStart ?? now
            callerRevealDeadlineStart = start
            if !callerRevealPending {
                callerRevealDeadlineArmed = false
            } else if CallerRevealGate.expired(revealPending: true, acceptedAt: start, now: now) {
                callerRevealDeadlineArmed = false
                endForCallerReveal()
                return
            }
        }
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
