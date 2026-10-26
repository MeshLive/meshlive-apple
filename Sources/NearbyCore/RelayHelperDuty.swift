import Foundation

// EXPERIMENTAL relayed calls (Design C), helper side (Android BluetoothPrivateCallRelay on-demand duty; PROTOCOL setup
// rules 2-7). Sans-I/O: the app admits the request, dials the next hop and pumps the links; this object checks the next
// hop, regenerates SETUP downstream, answers READY or FAIL upstream, enforces the one deadline, then copies the
// endpoints' records opaquely (the helper never opens BME1) under the chain guard.

/// After READY the chain tears down unless the end-to-end handshake crosses within 10 s and the callee's first
/// end-to-end content record (its Ringing answer) within 20 s; heartbeats and caller content prove nothing.
public struct RelayChainGuard {
    public static let handshakeSeconds: TimeInterval = 10
    public static let answerSeconds: TimeInterval = 20
    let readyAt: TimeInterval
    private(set) var handshakeSeen = false
    private(set) var answerSeen = false
    public init(readyAt: TimeInterval) { self.readyAt = readyAt }
    mutating func onRecord(fromCaller: Bool, type: SecureRecordType) {
        if type == .endToEndHandshake { handshakeSeen = true }
        if type == .endToEndContent && !fromCaller { answerSeen = true }
    }
    public func violation(now: TimeInterval) -> String? {
        if !handshakeSeen && now - readyAt > Self.handshakeSeconds { return "No end-to-end handshake within 10 s of the relay being ready" }
        if !answerSeen && now - readyAt > Self.answerSeconds { return "No answer from the callee within 20 s of the relay being ready" }
        return nil
    }
    public var satisfied: Bool { handshakeSeen && answerSeen }
}

public final class RelayHelperDuty {
    public enum State: Equatable { case connectingNext, waitingForNext, relaying, closed(String) }

    /// One SETUP (or a search turned into one) this helper accepted.
    public struct Request: Equatable {
        /// The target ID (a role-0 RDI on a rotating route). For a search, empty until the search found it.
        public var target: Data
        public let budget: Int, remainingMs: Int, setupId: Data, rotating: Bool
        /// Design OR: a search (`SEEK`): the target is matched by token; a next helper gets a regenerated SEEK.
        public let seek: Seek?
        public struct Seek: Equatable {
            public let nonce: Data, token: Data, skip: [Data]
            public init(nonce: Data, token: Data, skip: [Data]) { self.nonce = nonce; self.token = token; self.skip = skip }
        }
        public init(target: Data, budget: Int, remainingMs: Int, setupId: Data, rotating: Bool, seek: Seek? = nil) {
            self.target = target; self.budget = budget; self.remainingMs = remainingMs; self.setupId = setupId; self.rotating = rotating
            self.seek = seek
        }
        /// The request a listener read, as a duty request (a SEEK always concerns role-0 RDIs).
        public init?(_ message: RelaySetupMessage) {
            switch message {
            case let .setup(target, budget, remaining, id, rotating):
                self.init(target: target, budget: budget, remainingMs: remaining, setupId: id, rotating: rotating)
            case let .seek(budget, remaining, id, nonce, token, skip):
                self.init(target: Data(), budget: budget, remainingMs: remaining, setupId: id, rotating: true,
                          seek: Seek(nonce: nonce, token: token, skip: skip))
            default: return nil
            }
        }
    }

    /// Where the next hop goes: the target itself (`hopPrefix` nil), or the next helper whose offer has `hopPrefix`.
    public struct NextHop: Equatable {
        public let hopPrefix: Data?
        public let nextBudget: Int
        public init(hopPrefix: Data?, nextBudget: Int) { self.hopPrefix = hopPrefix; self.nextBudget = nextBudget }
    }

    public let identity: SigningIdentity
    public let transport: MeshTransport
    public let parent: CallRelayLink
    public private(set) var child: CallRelayLink?
    public private(set) var request: Request
    /// Design OR: a next-hop attempt failed before READY; return true when the app will try another candidate (the
    /// duty then waits for the next `makeChildLink` instead of answering FAIL).
    public var onChildAttemptFailed: ((RelaySetupFailure) -> Bool)?
    /// The last child failure of a search (FAIL reason when nothing is left).
    public private(set) var lastChildFailure: RelaySetupFailure?
    /// Design OR: the search matched this target RDI (budget-1 target link).
    public func setSearchTarget(_ rdi: Data) { request.target = rdi.rebased }
    public private(set) var next: NextHop?
    public private(set) var state: State = .connectingNext
    /// Relays from this helper to the target, as sent in READY.
    public private(set) var readyRelays: Int?
    public private(set) var failure: RelaySetupFailure?
    public var onStateChange: ((State) -> Void)?
    /// Backpressure: a hop drained; the app resumes the other hop asynchronously (as CallRelayHop).
    public var onIngressResumable: (() -> Void)?
    private let deadline: TimeInterval
    private var guardState: RelayChainGuard?
    private var childSetupId: Data?
    private let acceptedAt: TimeInterval

    /// - Parameters:
    ///   - parent: the authenticated parent link (adopted from the call listener) whose first record was the SETUP.
    ///   - now: when the SETUP was accepted; every later wait counts from it.
    public init(identity: SigningIdentity, transport: MeshTransport, parent: CallRelayLink, request: Request, now: TimeInterval) {
        self.identity = identity; self.transport = transport; self.parent = parent; self.request = request
        acceptedAt = now
        deadline = now + TimeInterval(request.remainingMs) / 1000
        parent.onClosed = { [unowned self] reason, _ in close("Parent: \(reason)") }
        parent.acceptRelaySetup = false   // a second type-12 record is a violation (the opener rejects it)
    }

    /// Answers FAIL upstream without any radio work (admission refused) and closes.
    public func refuse(_ reason: RelaySetupFailure) {
        failUpstream(reason, "Refused: \(reason.label)")
    }

    /// The app chose the next hop: returns the onward link to start on the new connection (BMH3 per Amendment CP when
    /// `bmh3` is set). A real-key target must be `request.target` (or open it on a rotating route); a real-key helper
    /// must be `next.hopPrefix`; a declared throwaway is not bound (the caller's end-to-end check authenticates).
    public func makeChildLink(next: NextHop, bmh3: Bmh3CallSettings?, wallEpoch: @escaping () -> Int64 = RotatingDiscoveryIds.currentWallEpoch) -> CallRelayLink {
        self.next = next
        child?.onClosed = nil; child?.onReady = nil; child?.onRelaySetup = nil   // a previous attempt is finished
        let expected = next.hopPrefix ?? request.target
        let opening = request.rotating ? RelayedCalls.helperOfferFor(expected, rotating: true) : nil
        let link = CallRelayLink(role: .initiator, transport: transport, identity: identity, bmh3: bmh3, relaySetup: true,
                                 openingCheck: opening, wallEpoch: wallEpoch)
        if !request.rotating { link.expectedPeerPrefix = expected }
        link.onAuthenticated = { [unowned self] id, caps in
            guard caps.supports(transport: transport.capabilityBit) else { throw ProtocolError.incompatible("Next hop did not authenticate the bearer") }
            if id == identity.nodeId { throw ProtocolError.state("The relay cannot be its own child") }
            if next.hopPrefix != nil, !RelayedCalls.linkAcceptsSetup(caps) { throw ProtocolError.state("Next relay did not authenticate as a relayed-call helper") }
        }
        link.onReady = { [unowned self] in try childReady() }
        link.onClosed = { [unowned self] reason, _ in childClosed(reason) }
        link.onRelaySetup = { [unowned self] message in try childReply(message) }
        child = link
        set(.waitingForNext)
        return link
    }

    /// The app could not open a link to the next hop.
    public func childConnectFailed(_ reason: String) {
        guard readyRelays == nil else { return }
        attemptFailed(next?.hopPrefix == nil ? .noRoute : .timeout, "Next hop: \(reason)")
    }

    /// A search found nothing to try (or ran out of candidates): FAIL with `reason`.
    public func searchFailed(_ reason: RelaySetupFailure) { failUpstream(reason, "Search: \(reason.label)") }

    /// Time left before the one deadline, in ms.
    public func remainingMs(now: TimeInterval) -> Int { max(0, Int(((deadline - now) * 1000).rounded())) }

    private func childReady() throws {
        guard let child, let next else { return }
        if next.hopPrefix == nil {
            ready(relays: 1)
            return
        }
        let elapsedMs = Int(((child.now - acceptedAt) * 1000).rounded())
        guard let remaining = RelayedCalls.nextHopRemainingMs(remainingMs: request.remainingMs, elapsedMs: elapsedMs) else {
            failUpstream(.timeout, "Too little time left for the next hop"); return
        }
        let id = RelaySetupCodec.newSetupId()
        childSetupId = id
        child.acceptRelaySetup = true
        if let seek = request.seek {
            // A search goes on as a search: the next helper must have signed RELAY_SEEK.
            guard child.linkPeerRelaySeek & RelaySeek.featureSeekV1 != 0 else { attemptFailed(.refused, "Next helper does not search"); return }
            try child.sendRelaySetup(.seek(budget: next.nextBudget, remainingMs: min(remaining, RelayedCalls.setupDeadlineMs), setupId: id,
                                           nonce: seek.nonce, token: seek.token, skip: seek.skip))
        } else {
            try child.sendRelaySetup(.setup(target: request.target, budget: next.nextBudget, remainingMs: remaining, setupId: id, rotating: request.rotating))
        }
    }

    /// One next-hop attempt failed before READY: another candidate if the app has one, else FAIL upstream.
    private func attemptFailed(_ reason: RelaySetupFailure, _ text: String) {
        lastChildFailure = reason
        let old = child
        old?.onClosed = nil
        old?.finish(text, error: false)
        if onChildAttemptFailed?(reason) == true { set(.connectingNext); return }
        failUpstream(reason, text)
    }

    private func childReply(_ message: RelaySetupMessage) throws {
        guard let id = childSetupId, message.setupId == id, readyRelays == nil else { throw ProtocolError.state("Unexpected setup reply") }
        switch message {
        case .ready(_, let relays):
            guard relays + 1 <= request.budget else { failUpstream(nil, "The next relay reported more relays than were asked for"); return }
            ready(relays: relays + 1)
        case .fail(_, let reason):
            attemptFailed(reason, "Next relay: \(reason.label)")
        case .setup, .seek:
            throw ProtocolError.state("A setup reply was expected")
        }
    }

    private func ready(relays: Int) {
        guard let child, readyRelays == nil else { return }
        do { try parent.sendRelaySetup(.ready(setupId: request.setupId, relays: relays)) } catch { close("READY could not be sent"); return }
        readyRelays = relays
        guardState = RelayChainGuard(readyAt: child.now)
        // Opaque copy mode, exactly as a call relay hop.
        parent.onRecord = { [unowned self] record in
            guardState?.onRecord(fromCaller: true, type: record.type)
            guard child.phase == .open else { return }
            if record.type == .linkHeartbeat { child.sendLiveness() } else { child.copy(record) }
        }
        child.onRecord = { [unowned self] record in
            guardState?.onRecord(fromCaller: false, type: record.type)
            guard parent.phase == .open else { return }
            if record.type == .linkHeartbeat { parent.sendLiveness() } else { parent.copy(record) }
        }
        parent.isDestinationBehind = { [unowned child] in child.isBehind }
        child.isDestinationBehind = { [unowned self] in parent.isBehind }
        parent.onDrained = { [unowned self] in onIngressResumable?() }
        child.onDrained = { [unowned self] in onIngressResumable?() }
        set(.relaying)
    }

    private func childClosed(_ reason: String) {
        guard readyRelays == nil else { close("Child: \(reason)"); return }
        // An identity or capability problem of the next hop is FAIL 3; a link that died while connecting is a timeout
        // (Android RelayIdentityPolicy.failureBeforeReady with pseudonymous edges: never "no route" for a working pair).
        let identityProblem = reason == ProtocolError.authentication.description || reason.contains("did not authenticate")
            || reason.contains("own child") || reason.contains("next relay")
        attemptFailed(identityProblem ? .childAuthentication : .timeout, "Next hop: \(reason)")
    }

    /// FAIL upstream (nil reason: an invalid next hop answer, sent as FAIL 3) and close both links.
    private func failUpstream(_ reason: RelaySetupFailure?, _ text: String) {
        if case .closed = state { return }
        let sent = reason ?? .childAuthentication
        failure = sent
        try? parent.sendRelaySetup(.fail(setupId: request.setupId, reason: sent))
        parent.requestCloseAfterFlush()
        child?.finish(text, error: false)
        set(.closed(text))
    }

    public func tick(now: TimeInterval) {
        if case .closed = state {} else if readyRelays == nil, now > deadline { failUpstream(.timeout, "The setup deadline ran out") }
        parent.tick(now: now); child?.tick(now: now)
        if case .closed = state { return }
        if let violation = guardState?.violation(now: now) { close(violation) }
    }

    public func resumeIngress(now: TimeInterval) { child?.resumeIngress(now: now); parent.resumeIngress(now: now) }

    public func close(_ reason: String) {
        if case .closed = state { return }
        set(.closed(reason))
        child?.finish(reason, error: false); parent.finish(reason, error: false)
    }

    private func set(_ s: State) { state = s; onStateChange?(s) }
}
