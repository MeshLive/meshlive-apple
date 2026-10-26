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

/// A helper listener's decision on its first-record SETUP or SEEK (PROTOCOL setup rule 2, Amendment CP, Design OR), in
/// order: the rotating-helper and control-arm refusals, the cheap switch, pause and busy checks, then the rate limiter
/// (SETUP only; a SEEK is bounded by the search budgets), then the route. Pure apart from the limiter and budgets.
public enum RelayHelperGate {
    public struct Facts {
        public var isSeek = false
        /// SETUP message 4 (a role-0 RDI target) or a SEEK.
        public var rotatingRequest = false
        public var featureOn = true, helpAllowed = true, onDemand = false
        public var paused: String?
        public var busy = false
        /// This helper uses rotating IDs (its own offer is version 5).
        public var rotatingHelper = false
        public var pseudonymousEdges = true
        public var pseudonymousParent = false
        public var parentPrefixHex = ""
        public var parentPeerIdentifier: UUID?
        public var parentIsSelf = false, parentIsTarget = false, targetIsSelf = false
        public var budget = 1, maxRelays = RelayedCalls.defaultMaxRelays
        public init() {}
    }

    public enum Decision: Equatable {
        case refuse(RelaySetupFailure, reason: String)
        /// Go on with the table route (SETUP); `limiterKey` and `admittedAtMs` let a good outcome refund the token.
        case setup(limiterKey: String?, admittedAtMs: Int64)
        /// A search: a SEEK, or (on-demand mode) a plain rotating SETUP whose target the table does not hold.
        case search(allowanceMs: Int)
    }

    public static func decide(_ f: Facts, remainingMs: Int, limiter: RelaySetupRateLimiter, budgets: RelaySeekBudgets, nowMs: Int64,
                              routeAvailable: () -> Bool) -> Decision {
        // Amendment CP: a rotating helper answers a fixed-prefix SETUP (message 1) with FAIL 5.
        if !f.isSeek && f.rotatingHelper && !f.rotatingRequest && f.pseudonymousEdges { return .refuse(.refused, reason: "rotating_helper") }
        // Control arm parity: without pseudonymous edges a throwaway parent is never served.
        if f.pseudonymousParent && !f.pseudonymousEdges { return .refuse(.refused, reason: "throwaway_parent") }
        if !f.featureOn || !f.helpAllowed { return .refuse(.refused, reason: "off") }
        if let pause = f.paused { return .refuse(.refused, reason: pause) }
        if f.isSeek && !f.onDemand { return .refuse(.refused, reason: "searches_off") }
        if f.busy { return .refuse(.busy, reason: "busy") }
        if !f.isSeek && f.targetIsSelf { return .refuse(.noRoute, reason: "no_route") }
        if f.parentIsSelf || f.parentIsTarget { return .refuse(.loop, reason: "loop") }
        let cap = f.isSeek ? min(RelaySeek.maxBudget, f.maxRelays) : f.maxRelays
        if f.budget < 1 || f.budget > cap { return .refuse(.refused, reason: "budget") }
        if f.isSeek {
            if let r = budgets.refusal(budget: f.budget, now: nowMs) { return .refuse(.refused, reason: "budget_" + r) }
            let allowance = min(Int64(remainingMs), budgets.remainingDutyMs(now: nowMs))
            return .search(allowanceMs: Int(allowance))
        }
        let key = RelaySetupRateLimiter.key(parentPrefixHex: f.parentPrefixHex, pseudonymous: f.pseudonymousParent, peerIdentifier: f.parentPeerIdentifier)
        if !limiter.tryAdmit(key, nowMs: nowMs) { return .refuse(.refused, reason: "rate") }
        if routeAvailable() { return .setup(limiterKey: key, admittedAtMs: nowMs) }
        // On-demand mode: a plain rotating SETUP with no table route is handled as a search for its single RDI.
        if f.onDemand && f.rotatingRequest && budgets.refusal(budget: min(f.budget, RelaySeek.maxBudget), now: nowMs) == nil {
            return .search(allowanceMs: Int(min(Int64(remainingMs), budgets.remainingDutyMs(now: nowMs))))
        }
        return .refuse(.noRoute, reason: "no_route")
    }
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
    /// Amendment CP edges: a failed target dial is FAIL 4 (the pair is skipped briefly), not "no route", which would drop a
    /// working table entry; the control arm keeps FAIL 1.
    public let pseudonymousEdges: Bool
    /// Design OR: one deadline from the allowance (the request's time, shortened to the duty time left).
    public init(identity: SigningIdentity, transport: MeshTransport, parent: CallRelayLink, request: Request, now: TimeInterval,
                allowanceMs: Int? = nil, pseudonymousEdges: Bool = true) {
        self.identity = identity; self.transport = transport; self.parent = parent; self.request = request
        self.pseudonymousEdges = pseudonymousEdges
        acceptedAt = now
        deadline = now + TimeInterval(min(request.remainingMs, allowanceMs ?? request.remainingMs)) / 1000
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
            childIdentityProblem = true   // cleared below when every check passed
            guard caps.supports(transport: transport.capabilityBit) else { throw ProtocolError.incompatible("Next hop did not authenticate the bearer") }
            if id == identity.nodeId { throw ProtocolError.state("The relay cannot be its own child") }
            if next.hopPrefix != nil, !RelayedCalls.linkAcceptsSetup(caps) { throw ProtocolError.state("Next relay did not authenticate as a relayed-call helper") }
            // Review 2026-10-27: on a search the target must prove the sought ID; an unbound throwaway could be a copy.
            if next.hopPrefix == nil, request.seek != nil, self.child?.linkPeerPseudonymous == true { throw ProtocolError.state("A searched target answered with a throwaway") }
            childIdentityProblem = false
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
        childIdentityProblem = false
        attemptFailed(next?.hopPrefix == nil && !pseudonymousEdges ? .noRoute : .timeout, "Next hop: \(reason)")
    }

    /// A search found nothing to try (or ran out of candidates): FAIL with `reason`.
    public func searchFailed(_ reason: RelaySetupFailure) { failUpstream(reason, "Search: \(reason.label)") }

    /// Time left before the one deadline, in ms.
    public func remainingMs(now: TimeInterval) -> Int { max(0, Int(((deadline - now) * 1000).rounded())) }

    /// The current next hop failed an identity or capability check (typed, review item 10).
    private var childIdentityProblem = false
    /// The address of the current next hop failed the sought ID (a search records it as a copied advert).
    public var lastChildIdentityFailure: Bool { childIdentityProblem }
    public var chainGuardSatisfied: Bool { guardState?.satisfied ?? false }

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
        let identityProblem = childIdentityProblem || child?.identityRejected == true
        childIdentityProblem = identityProblem
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
