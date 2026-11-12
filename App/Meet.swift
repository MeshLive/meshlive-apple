import Foundation
import Combine
import NearbyCore

/// BVMID2 on the Add contact screen (Android VerifyContactActivity's Meet flow and MeetBridge): an expiring one-use code
/// shown on this device's role-0 rotating ID, scanning the other device's code over a verify-only session, "Is this
/// <name>'s screen?" before the shield, and Design QL's presence leases. The screen never touches Bluetooth itself: it asks
/// the model to keep this device call-ready while a code shows, reads the ID on air to draw the code, and asks this
/// controller to scan.
///
/// Reachability (review F10): when "Reachable for calls" is off, a shown code makes the device call-ready only for the
/// screen's lifetime and the responder then accepts nothing but a connection whose tag matches the code
/// (`QrCodeDisplay.screenOnlyReachable`); leaving the screen restores it (it is recomputed from the setting).
final class MeetController: ObservableObject, QrDisplayEvents {
    weak var model: AppModel?
    let display = QrCodeDisplay()
    let visit = MeetVisit()
    private(set) var session = MeetSession()

    /// The text of the live code (nil while none can be shown).
    @Published private(set) var codeText: String?
    /// "Getting your code ready…", the scan's progress and the outcome lines.
    @Published var status: String?
    /// "Two phones used your code" (shown once as an alert).
    @Published var reuseAlert = false
    /// "Is this <name>'s screen?" while a scan waits for the user's answer.
    @Published var confirmation: Confirmation?
    /// "Save contact as" after a confirmed scan stored the shield.
    @Published var saveContact: SaveContact?
    /// The page is open and shows "Show my code".
    @Published private(set) var showingCode = false
    /// iPhone: the screen is being recorded or mirrored, so the live code is hidden (and ended).
    @Published private(set) var captureHidden = false
    @Published private(set) var scanning = false
    /// A scan's connection is open (from the search until its verification session ended).
    var scanInProgress: Bool { scanner != nil }
    /// Design QL revision 2: Call now, for the person whose lease this visit stored in the last 60 s (nil: hidden).
    @Published private(set) var callNowPeer: IdentityFingerprint?
    /// The scan's verification connection is still open (Call now waits for it: the other phone serves one connection).
    @Published private(set) var scanSessionOpen = false

    /// Design QL revision 2 (Android `ql_consent_ui`, on): the recognition choice at the scan, the plain result and Call
    /// now. DEBUG control arm `-qlConsentUi NO`: today's confirmation and texts (the yes then lets them recognise you).
    let consentUi = AppSettings.labSwitch("qlConsentUi", shipped: true)
    /// The confirmation asks "Let <name>'s phone recognise yours nearby" only where the answer can be stored: with
    /// rotating IDs and a persistent presence store (Android `presenceVaultUsable`).
    var asksRecognition: Bool { consentUi && (model.map { $0.rotatingIds && $0.rotating.vault.persistent } ?? false) }

    struct Confirmation: Identifiable, Equatable {
        let id = UUID()
        let peer: IdentityFingerprint
        let name: String
        let handle: String
    }
    struct SaveContact: Identifiable, Equatable {
        let id = UUID()
        let fingerprint: IdentityFingerprint
        let suggestion: String
    }

    private var visitOpen = false
    private var timer: Timer?
    private var scanner: CodeScan?

    /// BVMID2 runs with rotating IDs and hidden identities (the code's tag and the reservation exist only in BMH3);
    /// otherwise the screen keeps the static BVMID1 code.
    var available: Bool { model.map { $0.rotatingIds && $0.hiddenIdentities } ?? false }

    /// The device is call-ready because this screen shows a code.
    var wantsCallReady: Bool { visitOpen && showingCode && available && !captureHidden }

    // MARK: The visit

    /// The Add contact page appeared (or the app came back to it): a new visit (Design QL review).
    func beginVisit() {
        guard !visitOpen else { return }
        visitOpen = true
        visit.begin()
        session = MeetSession()
        callNowPeer = nil
        reuseAlert = false
        display.events = self
        display.onReuse = { [weak self] in self?.visit.onReuseAlert() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        applyReachability()
        tick()
    }

    /// The page left (or the app went to the background): the code dies and reachability is restored.
    func endVisit() {
        guard visitOpen else { return }
        visitOpen = false
        visit.end()
        timer?.invalidate(); timer = nil
        display.leave()
        codeText = nil
        confirmation = nil
        callNowPeer = nil
        if let scanner { scanner.cancel(); self.scanner = nil; scanning = false; scanSessionOpen = false }
        applyReachability()
    }

    func setShowingCode(_ on: Bool) {
        guard showingCode != on else { return }
        showingCode = on
        if !on { display.leave(); codeText = nil }
        applyReachability()
        tick()
    }

    /// iPhone screen recording or mirroring (`UIScreen.isCaptured`): the code is hidden and ended while it lasts.
    func setCaptured(_ captured: Bool) {
        guard captureHidden != captured else { return }
        captureHidden = captured
        if captured { display.leave(); codeText = nil }
        applyReachability()
        tick()
    }

    /// iPhone screenshot: the picture holds the live code, so that code ends and a new one is drawn.
    func screenshotTaken() {
        guard codeText != nil else { return }
        display.leave(); codeText = nil
        tick()
    }

    private func applyReachability() {
        display.screenOnlyReachable = wantsCallReady && model?.availableForCalls != true
        model?.refreshAdvertising()
    }

    /// Draws a fresh code whenever none is live (first time, after a scan, an ID change, expiry).
    private func tick() {
        refreshCallNow()
        guard visitOpen, showingCode, available, let model else { return }
        if captureHidden { codeText = nil; return }
        guard let rdi = model.meetRdi, let fingerprint = model.fingerprint else {
            // No call offer on air right now (Bluetooth off, or the advert paused while a session with this device runs):
            // a live code is kept (its ID has not changed), and no new one is drawn until the ID is back on air.
            if display.livePayload() != nil, codeText != nil { return }
            codeText = nil
            if !session.reuseAlert, status == nil || Self.readyTexts.contains(status ?? "") {
                status = model.call != nil ? Self.inCallText : Self.gettingReadyText
            }
            return
        }
        display.onRdiChanged(rdi)
        if let live = display.livePayload() {
            // The live code stays: drawn again only if the picture was cleared (never a new secret for it).
            if codeText == nil { codeText = Bvmid2.encode(live) }
            return
        }
        guard let payload = try? display.show(fingerprint: fingerprint, rdi: rdi) else {
            codeText = nil; status = Self.unavailableText; return
        }
        codeText = Bvmid2.encode(payload)
        if Self.readyTexts.contains(status ?? "") { status = nil }
    }

    static let gettingReadyText = "Getting your code ready…"
    static let unavailableText = "A code cannot be shown right now. Turn Bluetooth on and try again."
    static let inCallText = "Your code shows again after the call."
    private static let readyTexts: Set<String> = [gettingReadyText, unavailableText, inCallText]

    // MARK: Display events (the engine's thread)

    func onScanCompleted(_ peer: IdentityFingerprint) {
        onMain { [weak self] in
            guard let self else { return }
            self.session.scannedByPeer(peer)
            self.showOutcome(peer)
            self.codeText = nil   // the code was consumed: draw a new one
            self.tick()
        }
    }

    func onReuseAlert() {
        onMain { [weak self] in
            guard let self else { return }
            self.session.onReuseAlert()
            self.reuseAlert = true
            if let pending = self.confirmation {
                self.confirmation = nil
                self.scanner?.engine?.confirmVerification(pending.peer, yes: false)
            }
        }
    }

    func onCodeEnded(_ reason: String) {
        // The ended code may already be replaced by a newer one (`show` ends the old code first): only redraw if needed.
        onMain { [weak self] in self?.tick() }
    }

    /// Design QL: a verification session stored `peer`'s presence lease.
    func leaseStored(_ peer: IdentityFingerprint) {
        onMain { [weak self] in
            guard let self, self.visitOpen else { return }
            self.session.leaseStored(peer, at: ProcessInfo.processInfo.systemUptime)
            self.showOutcome(peer)
        }
    }

    /// Call now shows only with result (a) and only for 60 s after that lease was stored (re-read every tick).
    private func refreshCallNow() {
        let next = visitOpen && consentUi ? session.callNowPeer(now: ProcessInfo.processInfo.systemUptime) : nil
        if callNowPeer != next { callNowPeer = next }
    }

    /// Design QL revision 2, Call now: an ordinary Contacts call to the person just added (a new connection with the
    /// normal contact handshake), never on the verification link, whose scope forbids an Invite.
    func callNow() {
        refreshCallNow()
        guard let peer = callNowPeer, let model else { return }
        guard !scanSessionOpen, model.call == nil else { return }
        guard model.verificationState(of: peer) == .verified, !model.isBlocked(peer),
              let contact = model.contacts.first(where: { $0.fingerprintHex == peer.hex }) else { callNowPeer = nil; return }
        // Android calls with video unless its voice-only intercom calls are on (they are off by default).
        let started = model.callContact(contact, type: .video)
        AppLog.event("meet_call_now", ["state": started ? "started" : "not_found"])
        if !started {
            status = "\(contact.displayName) is not found nearby yet. Make sure \(contact.displayName) is close by with MeshLive open."
        }
    }

    /// Display events can arrive inside the display's lock (a commit, a new code ending the old one): the screen reacts on
    /// the next main-loop turn, never re-entering the display from its own callback.
    private func onMain(_ work: @escaping () -> Void) { DispatchQueue.main.async(execute: work) }

    private func name(_ peer: IdentityFingerprint) -> String {
        model?.contacts.first { $0.fingerprintHex == peer.hex }?.displayName ?? handle(peer)
    }

    private func handle(_ peer: IdentityFingerprint) -> String {
        IdentityHandle.handle(prefix: peer.nodeId.prefix) ?? peer.nodePrefixHex
    }

    private func showOutcome(_ peer: IdentityFingerprint) {
        let shown = name(peer)
        guard let line = consentUi ? session.qlMessage(peer, name: shown) : session.message(peer, name: shown) else { return }
        status = line
        refreshCallNow()
        if session.outcome(peer) == .scannedEachOther { model?.markScannedBothWays(peer) }
    }

    // MARK: Scanning

    /// A code from the camera: BVMID2 runs the verification session; an older BVMID1 code is still read and recorded as
    /// "Checked by code" (it needs a connection with that person first).
    func scanned(_ text: String) {
        if available, Bvmid2.looksLikeBvmid2(text) {
            guard let payload = Bvmid2.tryParse(text) else { status = "That is not a code from this app."; return }
            startScan(payload)
            return
        }
        guard let model else { return }
        guard let payload = try? IdentityQrCodec.parse(text) else { status = "That is not a code from this app."; return }
        do {
            try model.markVerified(scanned: payload)
            status = "Code matches. \(payload.displayName) is now verified."
        } catch let error as ProtocolError where error == .state("No authenticated session with this peer") {
            status = "Not connected to this person right now. Verify during a call with them."
        } catch {
            status = Self.failureText(error)
        }
    }

    static func failureText(_ error: Error) -> String {
        let text = String(describing: error)
        if text.contains("prefix") { return "Another contact's ID starts the same way, so this phone can't tell them apart. Forget them first, then verify again." }
        if text.contains("unreadable") { return "Could not save: your list of verified people cannot be read right now." }
        if (error as? ProtocolError) == .authentication { return "This code does not match the person you are connected to." }
        return "Could not save: your list of verified people cannot be read right now."
    }

    private func startScan(_ payload: Bvmid2Payload) {
        guard let model, scanner == nil, model.identity != nil, model.call == nil else {
            status = "This phone is not ready to scan yet. Check Bluetooth and try again."
            return
        }
        guard payload.fingerprint != model.fingerprint else { status = "That is your own code."; return }
        status = "Looking for their phone…"
        scanning = true
        let scanner = CodeScan(meet: self, model: model, payload: payload)
        self.scanner = scanner
        scanSessionOpen = true
        scanner.start()
    }

    fileprivate func scanReached(_ scanner: CodeScan, peer: IdentityFingerprint) {
        guard self.scanner === scanner else { return }
        scanning = false
        model?.noteAuthenticated(peer)
        let shown = name(peer)
        session.scanReached(peer, name: shown)
        confirmation = Confirmation(peer: peer, name: shown, handle: handle(peer))
    }

    fileprivate func scanFailed(_ scanner: CodeScan, _ text: String) {
        guard self.scanner === scanner else { return }
        self.scanner = nil
        scanning = false
        scanSessionOpen = false
        if confirmation == nil { status = text }
    }

    fileprivate func scanEnded(_ scanner: CodeScan) {
        guard self.scanner === scanner else { return }
        self.scanner = nil
        scanning = false
        scanSessionOpen = false
    }

    /// The user answered "Is this <name>'s screen?". Yes stores the shield (the scanned method), then the recognition
    /// choice (`recognise`, Design QL revision 2: written to "Can see when I'm nearby" before anything may leave), and only
    /// a yes that was stored lets the session start the presence exchange. No, a cancel or a failed shield write ends the
    /// session at once and marks nothing; a declined or unstored recognition choice ends it without an OFFER.
    ///
    /// `recognise` is the checkbox the confirmation showed (nil: it showed none). With the consent UI on, an answer without
    /// the checkbox never lets a lease leave (fails closed): the checkbox shows wherever a lease could be stored.
    func answer(_ confirmation: Confirmation, yes: Bool, recognise: Bool? = nil) {
        // A late answer for an older confirmation never clears a newer one.
        if self.confirmation?.id == confirmation.id { self.confirmation = nil }
        let peer = confirmation.peer
        let engine = scanner?.engine
        guard session.confirmScreen(peer, yes: yes) else {
            engine?.confirmVerification(peer, yes: false)
            if !yes { status = "Scan cancelled." }
            return
        }
        guard let model else { engine?.confirmVerification(peer, yes: false); return }
        do {
            try model.markScannedVerified(peer, name: confirmation.name)
            // The control arm's yes lets them recognise you (P7). With the consent UI, only the checkbox the user saw
            // decides, and its answer is stored first; a confirmation without one (no persistent presence store, so no
            // lease could leave anyway) lets nothing leave.
            let mayOffer: Bool
            if !consentUi {
                mayOffer = true
            } else if let recognise {
                let usable = model.rotatingIds && model.rotating.vault.persistent
                if !recognise {
                    session.declinedRecognition(peer)
                    // A no is recorded even while the store cannot be read: the vault's guard keeps the switch-off until
                    // it can be stored, so a later call does not lease under the default either.
                    if !usable { _ = model.storeRecognitionChoice(peer, recognise: false) }
                }
                mayOffer = QlConsent.applyAnswer(recognise: recognise, vaultUsable: usable) {
                    model.storeRecognitionChoice(peer, recognise: $0)
                }
            } else {
                mayOffer = false
            }
            AppLog.event("meet_consent", ["asked": "\(recognise != nil)", "recognise": "\(recognise ?? false)", "mayOffer": "\(mayOffer)"])
            // The visit holds the answer BEFORE the session may start: it is the lease gate of both roles in this visit.
            visit.confirm(peer, recognise: mayOffer)
            engine?.confirmVerification(peer, yes: mayOffer)
            showOutcome(peer)
            saveContact = SaveContact(fingerprint: peer, suggestion: ContactNames.suggestion(saved: model.contacts.first { $0.fingerprintHex == peer.hex },
                                                                                             shared: scanner?.sharedName))
        } catch {
            engine?.confirmVerification(peer, yes: false)
            status = Self.failureText(error)
        }
    }

    /// "Save contact as": a name only you see; empty keeps their ID. The rename rules say why a name is refused.
    func save(_ request: SaveContact, name: String) {
        saveContact = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let model else { return }
        status = model.renameContact(request.fingerprint, to: trimmed).message
    }

    // MARK: The scanner's connection

    /// One scan: up to 10 s looking for call offers with the code's RDI, every address that carries it tried in turn,
    /// all within 30 s; the first connection whose handshake reached the code's key becomes the verification session.
    fileprivate final class CodeScan {
        weak var meet: MeetController?
        weak var model: AppModel?
        let payload: Bvmid2Payload
        private(set) var engine: CallEngine?
        private var driver: ConnectionDriver?
        private var connectHandle: ConnectHandle?
        private var tried = Set<String>()
        private var startedAt: TimeInterval = 0
        private var poll: Timer?
        private var reached = false
        private var done = false
        /// The name the other device shared in this verification session (a suggestion for "Save contact as" only).
        private(set) var sharedName: String?
        static let searchLimit = QrScanPolicy.search
        static let overallLimit: TimeInterval = 30

        init(meet: MeetController, model: AppModel, payload: Bvmid2Payload) {
            self.meet = meet; self.model = model; self.payload = payload
        }

        func start() {
            startedAt = ProcessInfo.processInfo.systemUptime
            AppLog.event("meet_scan", ["state": "searching"])
            tryNext()
        }

        func cancel() {
            done = true
            poll?.invalidate(); poll = nil
            connectHandle?.cancel(); connectHandle = nil
            driver?.cancel()
            driver = nil
        }

        private var elapsed: TimeInterval { ProcessInfo.processInfo.systemUptime - startedAt }

        /// The next address that carries the code's RDI (a copy of the advert can answer first and fail).
        private func tryNext() {
            guard !done, let model else { return }
            poll?.invalidate(); poll = nil
            let seen = model.radio.peers.values.sorted { $0.lastSeen > $1.lastSeen }
                .map { ("\($0.id.uuidString)/\($0.peripheralId.uuidString)", $0) }
            let candidates = seen.filter { QrScanPolicy.matches(payload, $0.1.announcement) && !tried.contains($0.0) }
            guard let candidate = candidates.first else {
                if elapsed < Self.searchLimit {
                    poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in self?.tryNext() }
                } else {
                    fail(tried.isEmpty ? "Could not find that phone. Ask them to show the code again, and stay close."
                                       : "Could not reach that phone. Ask them to show the code again.")
                }
                return
            }
            guard elapsed < Self.overallLimit else { fail("Could not reach that phone. Ask them to show the code again."); return }
            let (key, peer) = candidate
            tried.insert(key)
            let transport = peer.announcement.transport ?? .gatt
            AppLog.event("meet_scan", ["state": "connecting", "attempt": "\(tried.count)"])
            connectHandle = model.radio.connect(to: peer.id, transport: transport) { [weak self] result in
                guard let self, !self.done else { if case .success(let link) = result { link.close() }; return }
                switch result {
                case .success(let link): self.attach(link, offer: peer.announcement, transport: transport)
                case .failure: self.tryNext()
                }
            }
        }

        private func attach(_ link: MeshLink, offer: DiscoveryAnnouncement, transport: MeshTransport) {
            guard let model, let identity = model.identity else { link.close(); return }
            var bmh3 = model.bmh3Options(selected: offer) ?? Bmh3CallOptions(pseudonyms: false, selected: offer)
            bmh3.qrScan = payload
            let engine = CallEngine(role: .caller, transport: transport, identity: identity, requestedType: .voice,
                                    encodeMask: VideoDecoderSupport.encodeMask, decodeMask: VideoDecoderSupport.decodeMask,
                                    rotating: model.withPresence(RotatingCallOptions(selected: offer)), bmh3: bmh3)
            engine.identityGate = model.book
            engine.meetVisit = meet?.visit
            engine.onEvent = { [weak self] event in self?.handle(event) }
            self.engine = engine
            let driver = ConnectionDriver(engine: engine, link: link)
            driver.onFinished = { [weak self] reason in self?.finished(reason) }
            self.driver = driver
            driver.start()
        }

        private func handle(_ event: CallEngine.Event) {
            switch event {
            case .verificationReached(_, let peer):
                reached = true
                AppLog.event("meet_scan", ["state": "reached"])
                meet?.scanReached(self, peer: peer)
            case .verificationLeaseStored(let peer):
                AppLog.event("meet_scan", ["state": "lease_stored"])
                meet?.leaseStored(peer)
            case .peerLabels(let name):
                sharedName = name
            case .ended(let reason, _):
                finished(reason)
            default:
                break
            }
        }

        /// The session ended. After the code's key was reached nothing more is tried (a confirmation that comes later still
        /// stores the shield; the leases then follow at the next answered call); before it, the next address is tried.
        private func finished(_ reason: String) {
            guard !done, engine != nil else { return }
            if reached {
                done = true
                AppLog.event("meet_scan", ["state": "ended"])
                meet?.scanEnded(self)
                return
            }
            engine = nil; driver = nil
            AppLog.event("meet_scan", ["state": "attempt_failed"])
            tryNext()
        }

        private func fail(_ text: String) {
            done = true
            AppLog.event("meet_scan", ["state": "failed"])
            meet?.scanFailed(self, text)
        }
    }
}
