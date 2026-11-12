import Foundation

/// What the renewal agent needs from its call engine (implemented by `CallEngine`).
protocol CallRenewalHost: AnyObject {
    var renewalNow: TimeInterval { get }
    var renewalFacts: CallRenewalScope.Facts { get }
    var renewalCallActive: Bool { get }
    /// When the call became ACTIVE (nil before).
    var renewalActiveAt: TimeInterval? { get }
    /// The call ID once known (the Invite).
    var renewalCallId: UUID? { get }
    var renewalLastReceiveAt: TimeInterval { get }
    var renewalLastSendAt: TimeInterval { get }
    var renewalCurrentLink: SecureLink { get }
    func renewalSend(_ message: CallRenewalWire.Message)
    func renewalEndCall(_ reason: String)
    /// The call moves to `link` (`buffered` is its input already read): BMS1 from 0, end-to-end session unchanged.
    func renewalAdopt(_ link: SecureLink, buffered: Data)
    /// Opens a BME1 record with the call's end-to-end opener (the BIND check).
    func renewalOpen(_ encoded: Data) throws -> EndToEndContentRecord
    /// After BIND: key frames both ways, the current microphone and camera signals and this side's LABELS once more.
    func renewalReassert()
}

/// EXPERIMENTAL in-call link renewal (Design SR) for one call: the offerer and armed state machines, the attempt limits,
/// `K_renew` and the call's renewal connections. The app's radio acts on `Request`s and reports back through the
/// engine's `renewal...` entry points; nothing here touches a radio, a clock or a thread.
public final class CallRenewalAgent {
    public enum Request: Equatable {
        /// Offerer: scan for the armed phone's advert (only this 128-bit service UUID); the agent stops it.
        case startScan(UUID)
        case stopScan
        /// Offerer: the advert was found. Stop sending on the old link and close it now; the call continues and the app
        /// connects to the advertiser as central.
        case breakOldLink
        /// Armed: advertise only this service UUID (no announcement, no other data) and route new GATT subscriptions to
        /// `renewalAcceptConnection`. Report `renewalArmReady` within 3 s.
        case startAdvert(UUID)
        /// Armed: the 7 s advert window ended or the renewal bound (the listener stays until `endAttempt`).
        case stopAdvert
        /// Armed: the attempt is over: close every renewal connection of it (except a switched one) and stop listening.
        case endAttempt
    }

    /// The armed phone's verdict on a proved connection's input.
    public enum CandidateResult: Equatable {
        /// Waiting for the first BMS1 record.
        case pending
        /// BIND accepted: the call now runs on this connection. Move the call's transport to it and close the old link.
        case switched
        /// Not a valid BIND (or not the first record): close this connection.
        case refused
    }

    public let enabled: Bool
    /// 0: end-to-end initiator (caller), 1: responder.
    public let role: UInt8
    public private(set) var negotiated = false
    public let offerer = RenewalOfferer()
    public let armed = RenewalArmed()
    public private(set) var attempts = RenewalAttempts()
    public private(set) var bound = 0
    var onRequest: ((Request) -> Void)?
    var log: ((String, [String: String]) -> Void)?
    weak var host: CallRenewalHost?
    private var key: CallRenewalKey?
    private var callId: UUID? { host?.renewalCallId }
    private var softSince: TimeInterval?
    private var refusalLogged = false
    /// The current link's transport ended while a renewal owned the call's liveness.
    public private(set) var linkDead = false
    private var nextConnection = 0
    private var candidates: [Int: SecureLink] = [:]
    /// Offerer: the ticket of the BIND that is the first BMS1 record on the renewed link.
    private(set) var pendingBind: UInt64?
    /// When this side last heard the old link before a switch, for `call_renewal_silence`.
    private var silenceFrom: TimeInterval?
    private var silenceRole = "offerer"

    init(enabled: Bool, role: UInt8) { self.enabled = enabled; self.role = role }

    // MARK: Session

    /// The end-to-end session is up: negotiated when both hellos signed bit 4 and the session derived `K_renew`.
    func sessionReady(key: CallRenewalKey?, peerSigned: Bool) {
        negotiated = enabled && peerSigned && key != nil
        self.key = negotiated ? key : nil
        if !negotiated { key?.zero() }
        log?("call_renewal", ["role": role == 0 ? "caller" : "callee", "phase": "negotiated", "negotiated": "\(negotiated)"])
    }

    func callEnded() {
        if offerer.phase == .scanning { onRequest?(.stopScan) }
        if armed.suspendsLiveness || !candidates.isEmpty { onRequest?(.endAttempt) }
        candidates = [:]
        key?.zero(); key = nil
    }

    /// Negotiated and in scope right now (a relayed, CoC or verification call never renews).
    public var possible: Bool { negotiated && CallRenewalScope.direct(host?.renewalFacts ?? Self.noFacts) }
    private static let noFacts = CallRenewalScope.Facts(gattOnBothEnds: false, relayHops: 0, relayedRoute: false, linkPeerIsEndpointPeer: false, verificationSession: false)

    /// A running renewal decides when the call ends; the normal liveness close waits for it.
    public var ownsLiveness: Bool { offerer.ownsLiveness || armed.suspendsLiveness }

    // MARK: Liveness

    /// The current transport ended. True: the renewal owns it (the call continues without a link for now).
    func holdLinkLoss(_ reason: String) -> Bool {
        guard negotiated, ownsLiveness || pendingBind != nil else { return false }
        if !linkDead { log?("call_renewal", ["role": armed.suspendsLiveness ? "armed" : "offerer", "phase": "link_dead", "reason": reason]) }
        linkDead = true
        return true
    }

    /// The silence verdict: Android's stall tolerance while a renewal is possible, nothing while one owns the call.
    func silenceEnds(now: TimeInterval, lastReceiveAt: TimeInterval, lastSendAt: TimeInterval) -> Bool? {
        guard negotiated else { return nil }
        if ownsLiveness { return false }
        return RenewalStall.verdict(enabled: possible, now: now, lastReceived: lastReceiveAt, lastSendProgress: lastSendAt) == .end
    }

    // MARK: Ticks

    func tick() {
        guard negotiated, let host else { return }
        let now = host.renewalNow
        switch offerer.tick(now: now) {
        case .stopScan:
            onRequest?(.stopScan)
            log?("call_renewal", ["role": "offerer", "phase": "scan_ended", "found": "false", "ms": ms(now - offerer.offeredAt)])
        case .endCall:
            onRequest?(.stopScan)
            log?("call_renewal", ["role": "offerer", "phase": "failed", "reason": "bound", "ms": ms(now - offerer.offeredAt)])
            host.renewalEndCall("Call link lost: the link renewal did not complete")
            return
        case .none: break
        }
        switch armed.tick(oldLinkAlive: !linkDead, now: now) {
        case .refuseRegistration:
            host.renewalSend(.refused(ticket: armed.ticket, reason: .serverRegistration))
            onRequest?(.endAttempt)
            log?("call_renewal", ["role": "armed", "phase": "refused", "reason": CallRenewalWire.Reason.serverRegistration.label, "inTime": "false"])
            armed.reset()
        case .stopAdvert:
            onRequest?(.stopAdvert)
            log?("call_renewal", ["role": "armed", "phase": "advert_stopped", "ms": ms(now - armed.receivedAt)])
        case .disarm:
            closeCandidates()
            onRequest?(.endAttempt)
            log?("call_renewal", ["role": "armed", "phase": "disarmed", "reason": "bound_old_link_alive"])
            armed.reset()
        case .endCall:
            closeCandidates()
            onRequest?(.endAttempt)
            log?("call_renewal", ["role": "armed", "phase": "failed", "reason": "no_bind"])
            host.renewalEndCall("Call link lost: the link renewal did not complete")
            return
        case .none: break
        }
        // The link died while nothing owned it any more (a scan that found nothing, a disarm): the call ends now.
        if linkDead && !ownsLiveness && pendingBind == nil {
            log?("call_renewal", ["role": "supervisor", "phase": "failed", "reason": "link_dead"])
            host.renewalEndCall("Call link lost")
            return
        }
        maybeOffer(now: now, host: host)
    }

    /// Offerer trigger: the soft state (no record for 3 s while own writes complete) held for 1 s.
    private func maybeOffer(now: TimeInterval, host: CallRenewalHost) {
        guard !linkDead, RenewalStall.soft(now: now, lastReceived: host.renewalLastReceiveAt, lastSendProgress: host.renewalLastSendAt) else {
            softSince = nil; refusalLogged = false
            return
        }
        let since = softSince ?? now
        softSince = since
        guard offerer.shouldTrigger(softSince: since, now: now), !armed.suspendsLiveness else { return }
        if let reason = refusal(now: now, host: host) {
            if !refusalLogged { refusalLogged = true; log?("call_renewal", ["role": "offerer", "phase": "not_offered", "reason": reason.label]) }
            return
        }
        guard let key, let callId else { return }
        let ticket = CallRenewalCrypto.newTicket()
        offerer.offer(ticket: ticket, now: now)
        attempts.record(now: now)
        host.renewalSend(.offer(ticket: ticket, role: role))
        log?("call_renewal", ["role": "offerer", "phase": "offer", "attempt": "\(attempts.count)", "silentMs": ms(now - host.renewalLastReceiveAt)])
        onRequest?(.startScan(CallRenewalCrypto.advertUuid(key: key.data, callId: callId, ticket: ticket)))
        log?("call_renewal", ["role": "offerer", "phase": "scan"])
    }

    private func refusal(now: TimeInterval, host: CallRenewalHost) -> CallRenewalWire.Reason? {
        if key == nil || callId == nil { return .disabled }
        return CallRenewalScope.refusal(enabled: enabled, negotiated: negotiated, facts: host.renewalFacts, phaseActive: host.renewalCallActive,
                                        activeFor: host.renewalActiveAt.map { now - $0 } ?? 0, attempts: attempts.count,
                                        sinceLastAttempt: attempts.sinceLast(now: now))
    }

    // MARK: Records on the old link

    /// Every record opened on the call's current link: the post-switch silence log, and any record other than RENEW
    /// (the BME1 type byte follows the magic) means the peer is heard again.
    func observe(_ record: SecureRecord) {
        renewedLinkHeard()
        let p = record.payload
        if !(record.type == .endToEndContent && p.count > 4 && p[p.startIndex + 4] == EndToEndContentType.renew.rawValue) { peerHeard() }
    }

    /// Any record other than `RENEW` arrived on the current link.
    func peerHeard() {
        guard offerer.onPeerHeard() else { return }
        onRequest?(.stopScan)
        host?.renewalSend(.refused(ticket: offerer.ticket, reason: .abandoned))
        log?("call_renewal", ["role": "offerer", "phase": "abandoned", "reason": "peer_heard", "ms": ms((host?.renewalNow ?? 0) - offerer.offeredAt)])
        offerer.reset()
    }

    func onRecord(_ message: CallRenewalWire.Message) {
        guard let host else { return }
        let now = host.renewalNow
        switch message {
        case .offer(let ticket, _):
            onOffer(ticket: ticket, now: now, host: host)
        case .armed(let ticket):
            log?("call_renewal", ["role": "offerer", "phase": "armed_heard", "current": "\(ticket == offerer.ticket)"])
        case .refused(let ticket, let reason):
            if reason == .abandoned {
                if armed.onAbandoned(ticket: ticket) {
                    closeCandidates()
                    onRequest?(.endAttempt)
                    log?("call_renewal", ["role": "armed", "phase": "disarmed", "reason": "abandoned"])
                    armed.reset()
                }
            } else if ticket == offerer.ticket, offerer.onRefused() {
                onRequest?(.stopScan)
                log?("call_renewal", ["role": "offerer", "phase": "refused", "reason": reason.label])
            }
        case .bind:
            // BIND counts only as the first record of the proved new link; on the old link it is ignored.
            log?("call_renewal", ["role": "armed", "phase": "bind_ignored", "reason": "not_proved_link"])
        }
    }

    private func onOffer(ticket: UInt64, now: TimeInterval, host: CallRenewalHost) {
        var yielded = false
        if offerer.ownOfferPending {
            if RenewalCollision.keepOwn(ownRole: role) {
                host.renewalSend(.refused(ticket: ticket, reason: .collision))
                log?("call_renewal", ["role": "armed", "phase": "refused", "reason": "collision"])
                return
            }
            _ = offerer.yieldToPeer()
            onRequest?(.stopScan)
            offerer.reset()
            yielded = true
            log?("call_renewal", ["role": "offerer", "phase": "yielded", "reason": "collision"])
        }
        // A callee that yielded already counted this renewal when it offered: the caller's attempt is the same renewal.
        var reason = refusal(now: now, host: host)
        if yielded, reason == .limit { reason = nil }
        guard armed.onOffer(ticket: ticket, refusal: reason, now: now), let key, let callId else {
            let sent = reason ?? .limit
            host.renewalSend(.refused(ticket: ticket, reason: sent))
            log?("call_renewal", ["role": "armed", "phase": "refused", "reason": sent.label])
            return
        }
        if !yielded { attempts.record(now: now) }
        log?("call_renewal", ["role": "armed", "phase": "offer", "attempt": "\(attempts.count)", "yielded": "\(yielded)"])
        onRequest?(.startAdvert(CallRenewalCrypto.advertUuid(key: key.data, callId: callId, ticket: ticket)))
    }

    // MARK: Offerer entry points

    /// The advert was seen. True: the old link is broken now (`breakOldLink`), connect within `connectBudget`.
    func advertFound() -> Bool {
        guard let host, offerer.onAdvertFound(now: host.renewalNow) else { return false }
        onRequest?(.stopScan)
        log?("call_renewal", ["role": "offerer", "phase": "found", "ms": ms(host.renewalNow - offerer.offeredAt), "addressKind": "unknown"])
        silenceFrom = host.renewalLastReceiveAt; silenceRole = "offerer"
        linkDead = true
        onRequest?(.breakOldLink)
        return true
    }

    func connectBudget() -> TimeInterval { host.map { offerer.connectBudget(now: $0.renewalNow) } ?? 0 }

    /// A connected central link to the advertiser: its opening (nil when no connect may run now).
    func offererOpening() -> RenewalOpening? {
        guard let key, let callId, connectBudget() > 0 else { return nil }
        log?("call_renewal", ["role": "offerer", "phase": "connecting", "budgetMs": ms(connectBudget())])
        return RenewalOpening(offerer: key, callId: callId, ticket: offerer.ticket)
    }

    /// The opening proved the armed phone. True: the call moved to the new link and BIND is its first record.
    func offererProved(_ opening: RenewalOpening) -> Bool {
        guard let host, opening.role == .offerer, opening.state == .proved, let send = opening.sendKey, let receive = opening.receiveKey else { return false }
        log?("call_renewal", ["role": "offerer", "phase": "proved", "ms": ms(host.renewalNow - offerer.offeredAt)])
        // The bound is checked before BIND goes out, so a late BIND never binds the peer alone.
        guard offerer.onBound(now: host.renewalNow) else { return false }
        let renewed = SecureLink(renewing: host.renewalCurrentLink, sendKey: send, receiveKey: receive)
        opening.wipe()
        pendingBind = offerer.ticket
        switched(to: renewed, buffered: opening.takeLeftover(), host: host)
        log?("call_renewal", ["role": "offerer", "phase": "bound", "ms": ms(host.renewalNow - offerer.offeredAt), "attempt": "\(attempts.count)"])
        offerer.reset()
        return true
    }

    /// A connect or opening failed before CONFIRM: scan again for a new sighting while time remains.
    func offererConnectFailed(_ reason: String) {
        guard let host, let key, let callId else { return }
        log?("call_renewal", ["role": "offerer", "phase": "connect_failed", "reason": reason, "ms": ms(host.renewalNow - offerer.offeredAt)])
        guard offerer.mayRetry(now: host.renewalNow) else { return }
        onRequest?(.startScan(CallRenewalCrypto.advertUuid(key: key.data, callId: callId, ticket: offerer.ticket)))
    }

    /// A sighting of the advert: the first one breaks the old link; after a failed connect another one retries while
    /// time remains. True: connect now.
    func advertSeen() -> Bool {
        guard let host else { return false }
        if offerer.phase == .scanning { return advertFound() }
        if offerer.phase == .connecting, offerer.mayRetry(now: host.renewalNow) { onRequest?(.stopScan); return true }
        return false
    }

    // MARK: Armed entry points

    func armReady(_ ok: Bool, failure: CallRenewalWire.Reason) {
        guard let host else { return }
        let now = host.renewalNow
        if ok, armed.onServerReady(now: now) {
            host.renewalSend(.armed(ticket: armed.ticket))
            log?("call_renewal", ["role": "armed", "phase": "armed", "nonDiscoverable": "false", "ms": ms(now - armed.receivedAt)])
            return
        }
        guard armed.phase == .arming else {
            // A registration that finishes after the bound is closed, never adopted.
            if ok, !armed.suspendsLiveness { onRequest?(.endAttempt) }
            return
        }
        armed.onServerFailed()
        host.renewalSend(.refused(ticket: armed.ticket, reason: failure))
        onRequest?(.endAttempt)
        log?("call_renewal", ["role": "armed", "phase": "refused", "reason": failure.label, "inTime": "\(now - armed.receivedAt < RenewalArmed.registration)"])
        armed.reset()
    }

    /// A new GATT subscription while armed: its opening (send `start()` at once), or nil to close it.
    func acceptConnection() -> RenewalOpening? {
        guard let host, let key, let callId else { return nil }
        nextConnection += 1
        let id = nextConnection
        guard case .challenge = armed.onConnection(id, now: host.renewalNow) else {
            log?("call_renewal", ["role": "armed", "phase": "connection_dropped", "reason": "admission"])
            return nil
        }
        let machine = armed
        return RenewalOpening(armed: key, callId: callId, ticket: armed.ticket, connection: id) { [weak host] ticket, valid in
            machine.onProof(id, ticket: ticket, valid: valid, now: host?.renewalNow ?? .infinity) == .confirm
        }
    }

    func proofOverdue(_ connection: Int) -> Bool {
        guard let host, armed.proofOverdue(connection, now: host.renewalNow) else { return false }
        log?("call_renewal", ["role": "armed", "phase": "squatter_dropped", "connection": "\(connection)"])
        return true
    }

    func connectionClosed(_ connection: Int) {
        armed.onConnectionClosed(connection)
        candidates[connection] = nil
    }

    /// The armed opening proved the offerer: the connection waits for BIND as its first BMS1 record.
    func armedProved(_ opening: RenewalOpening) -> CandidateResult {
        guard let host, opening.role == .armed, opening.state == .proved, let send = opening.sendKey, let receive = opening.receiveKey,
              armed.provedConnection == opening.connection else { return .refused }
        log?("call_renewal", ["role": "armed", "phase": "proved", "connection": "\(opening.connection)", "ms": ms(host.renewalNow - armed.receivedAt)])
        candidates[opening.connection] = SecureLink(renewing: host.renewalCurrentLink, sendKey: send, receiveKey: receive)
        opening.wipe()
        return candidateReceive(opening.connection, opening.takeLeftover())
    }

    /// Input of a proved connection before its BIND.
    func candidateReceive(_ connection: Int, _ data: Data) -> CandidateResult {
        guard let host, let candidate = candidates[connection] else { return .refused }
        // Only the proved connection of the attempt in progress may bind: checked before its record is opened.
        guard armed.phase == .armed, armed.provedConnection == connection else { return refuseCandidate(connection) }
        let record: SecureRecord
        do {
            guard let first = try candidate.receive(data, recordLimit: 1).first else { return .pending }
            guard case .record(let r) = first else { throw ProtocolError.state("Unexpected renewal link output") }
            record = r
        } catch {
            return refuseCandidate(connection)
        }
        // BIND must be the first record of this proved link, with this ticket, once.
        guard record.type == .endToEndContent, let content = try? host.renewalOpen(record.payload), content.type == .renew,
              case .bind(let ticket, let next)? = try? CallRenewalWire.decode(content.payload), next == content.sequence + 1,
              armed.onBind(connection: connection, ticket: ticket, firstRecord: true) == .accept else {
            return refuseCandidate(connection)
        }
        candidates[connection] = nil
        closeCandidates()
        silenceFrom = host.renewalLastReceiveAt; silenceRole = "armed"
        switched(to: candidate, buffered: Data(), host: host)
        log?("call_renewal", ["role": "armed", "phase": "bound", "connection": "\(connection)", "ms": ms(host.renewalNow - armed.receivedAt)])
        renewedLinkHeard()   // BIND was the first record heard on the renewed link
        armed.reset()
        // The bound connection is the call's link now; the radio ends the attempt's other connections and its advert.
        onRequest?(.stopAdvert)
        onRequest?(.endAttempt)
        return .switched
    }

    private func refuseCandidate(_ connection: Int) -> CandidateResult {
        candidates[connection] = nil
        armed.onConnectionClosed(connection)
        log?("call_renewal", ["role": "armed", "phase": "bind_refused", "connection": "\(connection)"])
        return .refused
    }

    private func closeCandidates() { candidates = [:] }

    // MARK: Switch

    private func switched(to renewed: SecureLink, buffered: Data, host: CallRenewalHost) {
        host.renewalAdopt(renewed, buffered: buffered)
        linkDead = false
        softSince = nil
        bound += 1
        host.renewalReassert()
    }

    /// The first record on a renewed link: the silence the renewal cost (last record on the old link to this one).
    func renewedLinkHeard() {
        guard let from = silenceFrom, let host else { return }
        silenceFrom = nil
        log?("call_renewal_silence", ["role": silenceRole, "ms": ms(host.renewalNow - from)])
    }

    /// Offerer: the BIND record, sealed now as the first BMS1 record of the renewed link.
    func takePendingBind() -> UInt64? { defer { pendingBind = nil }; return pendingBind }

    private func ms(_ seconds: TimeInterval) -> String { "\(Int((seconds * 1000).rounded()))" }
}

/// The app's radio reports to the call through these (main queue, the transport driver's clock).
public extension CallEngine {
    /// Both end-to-end hellos signed bit 4 and this call holds `K_renew`.
    var renewalNegotiated: Bool { renewal?.negotiated == true }

    /// Offerer: the armed advert was seen. True: connect to it now as central (on the first sighting the old link was
    /// broken through `breakOldLink`).
    func renewalAdvertSeen(now: TimeInterval) -> Bool { self.now = now; return renewal?.advertSeen() ?? false }

    /// Offerer: how long a connect plus opening may still take.
    func renewalConnectBudget(now: TimeInterval) -> TimeInterval { self.now = now; return renewal?.connectBudget() ?? 0 }

    /// Offerer: the opening for a connected central link to the advertiser (nil: close it).
    func renewalOffererOpening(now: TimeInterval) -> RenewalOpening? { self.now = now; return renewal?.offererOpening() }

    /// Offerer: the opening proved the armed phone. True: the call moved to that link (attach it); false: close it.
    func renewalOffererProved(_ opening: RenewalOpening, now: TimeInterval) -> Bool { self.now = now; return renewal?.offererProved(opening) ?? false }

    /// Offerer: a connect or opening failed before CONFIRM (a squatter, a copied advert, a failed connect).
    func renewalConnectFailed(_ reason: String, now: TimeInterval) { self.now = now; renewal?.offererConnectFailed(reason) }

    /// Armed: the advert and listener are up (`ok`) or could not start (`failure`).
    func renewalArmReady(_ ok: Bool, failure: CallRenewalWire.Reason = .advertising, now: TimeInterval) {
        self.now = now; renewal?.armReady(ok, failure: failure)
    }

    /// Armed: a new GATT subscription. Its opening (send `start()` at once and check `renewalProofOverdue` 1 s later),
    /// or nil to close the connection.
    func renewalAcceptConnection(now: TimeInterval) -> RenewalOpening? { self.now = now; return renewal?.acceptConnection() }

    func renewalProofOverdue(_ connection: Int, now: TimeInterval) -> Bool { self.now = now; return renewal?.proofOverdue(connection) ?? true }

    /// Armed: the opening of `opening.connection` proved the offerer; feed its later input to `renewalCandidateReceive`.
    func renewalArmedProved(_ opening: RenewalOpening, now: TimeInterval) -> CallRenewalAgent.CandidateResult {
        self.now = now; return renewal?.armedProved(opening) ?? .refused
    }

    func renewalCandidateReceive(_ connection: Int, _ data: Data, now: TimeInterval) -> CallRenewalAgent.CandidateResult {
        self.now = now; return renewal?.candidateReceive(connection, data) ?? .refused
    }

    func renewalConnectionClosed(_ connection: Int) { renewal?.connectionClosed(connection) }

    /// Input of a renewal opening (either role), on the engine's clock: the armed phone's proof window is judged at `now`.
    func renewalOpeningReceive(_ opening: RenewalOpening, _ data: Data, now: TimeInterval) throws -> Data? {
        self.now = now
        return try opening.receive(data)
    }
}
