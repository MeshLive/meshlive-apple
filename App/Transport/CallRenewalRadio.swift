import Foundation
import CoreBluetooth
import NearbyCore

/// EXPERIMENTAL in-call link renewal (Design SR; gate `ReleaseGates.linkRenewal`, DEBUG `-appleLinkRenewal YES`, off)
/// for one call: performs the engine's renewal requests with the app's radio and carries the renewal opening on the new
/// GATT link. The offerer scans for the armed phone's derived UUID, breaks its old link only after the sighting,
/// connects as central and runs the opening; the armed phone advertises only that UUID, challenges every new
/// subscription and hands the proved one to the call's driver once its BIND is accepted. The wire rules and every bound
/// live in NearbyCore (`CallRenewalAgent`); nothing here decides a limit. Main queue only. Logs carry no UUID, ticket,
/// key or address.
final class CallRenewalRadio {
    private let engine: CallEngine
    private weak var radio: CallRenewalRadioPort?
    private let driver: () -> ConnectionDriver?
    private let clock: () -> TimeInterval
    /// The offerer's connect attempt in progress (from the sighting to proved or failed), independent of which step
    /// it is in, so every failure reaches the engine once and its retry rule.
    private var attemptActive = false
    /// Offerer: the old link it broke (its LE connection may carry the renewed link) and the connect attempts made.
    private var brokenLink: MeshLink?
    private var connectAttempts = 0
    private var connecting: ConnectHandle?
    private var connectDeadline: Timer?
    private var offererLink: MeshLink?
    /// Armed: the renewal connections of the attempt in progress, by the state machine's connection ID. An entry is
    /// taken out while the engine decides on its input, so an `endAttempt` raised by that decision (the bind) never
    /// closes the connection that just became the call's link.
    private var armedLinks: [Int: (link: MeshLink, opening: RenewalOpening, proved: Bool)] = [:]
    private var proofTimers: [Int: Timer] = [:]
    private var stopped = false

    private var now: TimeInterval { clock() }

    init(engine: CallEngine, radio: CallRenewalRadioPort, driver: @escaping () -> ConnectionDriver?,
         clock: @escaping () -> TimeInterval = { ConnectionDriver.now }) {
        self.engine = engine; self.radio = radio; self.driver = driver; self.clock = clock
        engine.onRenewalRequest = { [weak self] in self?.handle($0) }
        engine.onRenewalLog = { event, fields in AppLog.event(event, fields) }
    }

    /// The call ended: nothing of a renewal is left on air or open.
    func stop() {
        guard !stopped else { return }
        stopped = true
        radio?.renewalScan(nil, found: nil)
        radio?.renewalSubscriber = nil
        radio?.endRenewalAdvert()
        cancelOfferer()
        // An old link's LE connection kept for a renewal over it (none bound) goes with the call.
        if let old = brokenLink { radio?.releaseRenewalExisting(old) }
        brokenLink = nil
        for id in Array(armedLinks.keys) { dropArmed(id, reason: nil) }
    }

    /// Requests arrive inside engine calls; the driver pumps after them (deferred, never re-entering the engine).
    private func handle(_ request: CallRenewalAgent.Request) {
        guard !stopped, let radio else { return }
        switch request {
        case .startScan(let uuid):
            radio.renewalScan(uuid) { [weak self] peer in self?.found(peer) }
        case .stopScan:
            radio.renewalScan(nil, found: nil)
        case .breakOldLink:
            brokenLink = driver()?.link
            connectAttempts = 0
            // Over the existing connection: the old link is unsubscribed but its LE connection stays for the new one.
            if Self.overExistingConnection, let client = brokenLink as? GattClientLink { client.keepConnectionOnClose = true }
            driver()?.dropLink()
        case .startAdvert(let uuid):
            // The call's link now (a link a previous renewal bound included) is the established call link: a GR1 HELLO
            // on it starts this renewal's stream on the same connection. Marked here, at the arming, not at the bind, so
            // a late repeat of the bound stream's own HELLO cannot end the link it just became.
            radio.renewalEstablished(driver()?.link)
            radio.renewalSubscriber = { [weak self] link in self?.accept(link) }
            radio.setRenewalAdvert(uuid) { [weak self] started in
                guard let self, !self.stopped else { return }
                self.engine.renewalArmReady(started, failure: .advertising, now: self.now)
                self.driver()?.pump()
            }
        case .stopAdvert:
            // The renewal advert goes off air; the discovery advert stays off until the attempt ends.
            radio.pauseRenewalAdvert()
        case .endAttempt:
            radio.renewalSubscriber = nil
            radio.endRenewalAdvert()
            for id in Array(armedLinks.keys) { dropArmed(id, reason: nil) }
        }
        DispatchQueue.main.async { [weak self] in self?.driver()?.pump() }
    }

    // MARK: Offerer

    private func found(_ peer: AnyObject) {
        guard !stopped, !attemptActive, engine.renewalAdvertSeen(now: self.now), let radio else { return }
        let budget = engine.renewalConnectBudget(now: self.now)
        guard budget > 0 else { return }
        attemptActive = true
        connectDeadline = Self.deadline(after: budget) { [weak self] in
            // The opening never waits past the last connect moment: a silent peer is closed, not waited for.
            self?.offererFailed("connect_timeout")
        }
        // Apple keeps one address: the first attempt (and every other one) runs over the LE connection that already
        // exists to the armed device; the others connect to the sighting, after letting that connection go.
        let existing = Self.overExistingConnection && connectAttempts % 2 == 0 ? brokenLink : nil
        connectAttempts += 1
        let done: (Result<MeshLink, Error>) -> Void = { [weak self] result in self?.connected(result) }
        if let existing, let handle = radio.renewalConnectExisting(existing, completion: done) {
            connecting = handle
        } else {
            if let brokenLink { radio.releaseRenewalExisting(brokenLink) }
            connecting = radio.renewalConnect(peer, until: self.now + budget, completion: done)
        }
    }

    private func connected(_ result: Result<MeshLink, Error>) {
        self.connecting = nil
        switch result {
        case .failure(let error):
            self.offererFailed("connect_\((error as? RadioError)?.stage ?? "failed")")
        case .success(let link):
            guard !self.stopped, let opening = self.engine.renewalOffererOpening(now: self.now) else { link.close(); self.offererFailed("late"); return }
            self.offererLink = link
            link.onBytes = { [weak self, weak link] data in
                guard let self, let link else { return }
                self.offererReceived(data, link: link, opening: opening)
            }
            link.onClosed = { [weak self] _ in self?.offererFailed("link_closed") }
        }
    }

    private func offererReceived(_ data: Data, link: MeshLink, opening: RenewalOpening) {
        do {
            if let reply = try engine.renewalOpeningReceive(opening, data, now: self.now) { link.send(reply) }
        } catch { offererFailed("opening"); return }
        switch opening.state {
        case .waiting: return
        case .refused: offererFailed("confirm_refused")
        case .proved:
            connectDeadline?.invalidate(); connectDeadline = nil
            offererLink = nil; attemptActive = false; brokenLink = nil
            if engine.renewalOffererProved(opening, now: self.now), let driver = driver() {
                driver.replaceLink(link)
            } else {
                opening.wipe()
                link.onBytes = nil; link.onClosed = nil; link.close()
            }
        }
    }

    /// A connect or opening failed before CONFIRM: the engine scans again while time remains.
    private func offererFailed(_ reason: String) {
        guard !stopped, attemptActive else { return }
        cancelOfferer()
        engine.renewalConnectFailed(reason, now: self.now)
    }

    private func cancelOfferer() {
        // Cleared first: a cancel that completes the connect synchronously reports nothing a second time.
        attemptActive = false
        connectDeadline?.invalidate(); connectDeadline = nil
        connecting?.cancel(); connecting = nil
        if let link = offererLink { link.onBytes = nil; link.onClosed = nil; link.close() }
        offererLink = nil
    }

    // MARK: Armed

    private func accept(_ link: MeshLink) {
        guard !stopped, let opening = engine.renewalAcceptConnection(now: self.now) else { link.close(); return }
        let id = opening.connection
        armedLinks[id] = (link, opening, false)
        link.onBytes = { [weak self] data in self?.armedReceived(id, data) }
        link.onClosed = { [weak self] _ in self?.dropArmed(id, reason: nil, closeLink: false) }
        if let challenge = opening.start() { link.send(challenge) }
        // Squatters: no valid PROOF 1 s after the challenge drops the connection; the advert stays.
        proofTimers[id] = Self.deadline(after: RenewalArmed.proofWindow + 0.01) { [weak self] in
            guard let self else { return }
            self.proofTimers[id] = nil
            if self.engine.renewalProofOverdue(id, now: self.now) { self.dropArmed(id, reason: "squatter") }
        }
    }

    private func armedReceived(_ id: Int, _ data: Data) {
        // Out of the map while the engine decides: its bind raises `endAttempt`, which must not close this link.
        guard var entry = armedLinks.removeValue(forKey: id) else { return }
        let result: CallRenewalAgent.CandidateResult
        if !entry.proved {
            do {
                if let confirm = try engine.renewalOpeningReceive(entry.opening, data, now: self.now) { entry.link.send(confirm) }
            } catch { close(entry, id: id, reason: "not_opening"); return }
            switch entry.opening.state {
            case .waiting: armedLinks[id] = entry; return
            case .refused: close(entry, id: id, reason: "proof_refused"); return
            case .proved:
                entry.proved = true
                proofTimers[id]?.invalidate(); proofTimers[id] = nil
                result = engine.renewalArmedProved(entry.opening, now: self.now)
            }
        } else {
            result = engine.renewalCandidateReceive(id, data, now: self.now)
        }
        switch result {
        case .pending:
            // The attempt may have ended meanwhile (a disarm): then this connection goes too.
            if stopped || radio?.renewalSubscriber == nil { close(entry, id: id, reason: nil) } else { armedLinks[id] = entry }
        case .refused: close(entry, id: id, reason: "bind_refused")
        case .switched:
            if let driver = driver() { driver.replaceLink(entry.link) } else { entry.link.close() }
        }
    }

    private func dropArmed(_ id: Int, reason: String?, closeLink: Bool = true) {
        guard let entry = armedLinks.removeValue(forKey: id) else { proofTimers[id]?.invalidate(); proofTimers[id] = nil; return }
        if closeLink { close(entry, id: id, reason: reason) } else {
            proofTimers[id]?.invalidate(); proofTimers[id] = nil
            entry.opening.wipe()
            engine.renewalConnectionClosed(id)
        }
    }

    private func close(_ entry: (link: MeshLink, opening: RenewalOpening, proved: Bool), id: Int, reason: String?) {
        proofTimers[id]?.invalidate(); proofTimers[id] = nil
        entry.link.onBytes = nil; entry.link.onClosed = nil; entry.link.close()
        entry.opening.wipe()
        engine.renewalConnectionClosed(id)
        if let reason { AppLog.event("call_renewal", ["role": "armed", "phase": "connection_dropped", "reason": reason, "connection": "\(id)"]) }
    }
}

extension CallRenewalRadio {
    /// A renewal deadline on the main run loop in its common modes, so it fires while a scroll or a held control tracks
    /// touches (as the connection tick, `ConnectionDriver`).
    static func deadline(after seconds: TimeInterval, _ fire: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in fire() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// The switch: `ReleaseGates.linkRenewal` (DEBUG `-appleLinkRenewal YES`; off in release).
    static var enabled: Bool { ReleaseGates.linkRenewal }

    /// The offerer's renewed link over the LE connection that already exists to the armed device (alternating with
    /// the sighting). DEBUG control arm `-renewalOverExistingConnection NO`: every attempt connects the sighting.
    static var overExistingConnection: Bool { LabSwitch.read("renewalOverExistingConnection", shipped: true) }

    /// DEBUG `-callTxStallAfterS N` (Android `test_call_tx_stall_after_s`): this phone's call writer stops sending on
    /// its first link N s after the call became ACTIVE, once per call (an induced one-way stall on any pair).
    static func configure(_ engine: CallEngine) {
        let after = LabSwitch.integer("callTxStallAfterS", shipped: 0)
        guard after > 0 else { return }
        engine.debugTxStallAfter = TimeInterval(after)
        engine.onDebugTxStall = { AppLog.event("call_debug_tx_stall", ["afterS": "\(after)", "link": "first"]) }
    }
}

/// What the renewal needs from the radio (the app's `MeshRadio`; tests use an in-memory one). A peer is the radio's
/// opaque handle of a sighting.
protocol CallRenewalRadioPort: AnyObject {
    /// Armed: every new GATT subscription is handed here while set.
    var renewalSubscriber: ((MeshLink) -> Void)? { get set }
    /// Scans for an advert carrying `uuid` (nil stops).
    func renewalScan(_ uuid: UUID?, found: ((AnyObject) -> Void)?)
    func setRenewalAdvert(_ uuid: UUID, started: @escaping (Bool) -> Void)
    func pauseRenewalAdvert()
    func endRenewalAdvert()
    func renewalConnect(_ peer: AnyObject, until: TimeInterval, completion: @escaping (Result<MeshLink, Error>) -> Void) -> ConnectHandle
    /// The renewed link over the LE connection of `oldLink` (to the armed device's own data service instance); nil when
    /// that connection cannot carry it.
    func renewalConnectExisting(_ oldLink: MeshLink, completion: @escaping (Result<MeshLink, Error>) -> Void) -> ConnectHandle?
    /// Lets the old link's LE connection go (before a connect to the sighting).
    func releaseRenewalExisting(_ oldLink: MeshLink)
    /// Armed: `link` (the call's link when a renewal arms) is an established call link, no longer a renewal candidate.
    func renewalEstablished(_ link: MeshLink?)
}

extension MeshRadio: CallRenewalRadioPort {
    func renewalScan(_ uuid: UUID?, found: ((AnyObject) -> Void)?) {
        setRenewalScan(uuid, onFound: found.map { report in { peripheral in report(peripheral) } })
    }

    func renewalConnect(_ peer: AnyObject, until: TimeInterval, completion: @escaping (Result<MeshLink, Error>) -> Void) -> ConnectHandle {
        guard let peripheral = peer as? CBPeripheral else {
            completion(.failure(RadioError.connect(stage: "not_nearby", reason: "Not a peripheral"))); return ConnectHandle()
        }
        return connectRenewal(peripheral, until: until, completion: completion)
    }

    func renewalConnectExisting(_ oldLink: MeshLink, completion: @escaping (Result<MeshLink, Error>) -> Void) -> ConnectHandle? {
        connectRenewalOverExisting(oldLink, completion: completion)
    }

    func renewalEstablished(_ link: MeshLink?) { (link as? GattServerLink)?.isRenewal = false }
}
