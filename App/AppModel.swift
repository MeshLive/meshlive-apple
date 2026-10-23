import Foundation
import SwiftUI
import NearbyCore
#if canImport(NearbyMedia)
import NearbyMedia
#endif

struct PersonRow: Identifiable, Equatable {
    let id: UUID
    let label: PeerLabel
    let prefixHex: String
    let transport: MeshTransport
    let relays: Int
    let isIPhone: Bool
    /// One plain sentence: where the person is, never technical words.
    var routeText: String {
        let place = relays == 0 ? "Nearby" : relays == 1 ? "Through 1 other phone" : "Through \(relays) other phones"
        return label.handle.isEmpty ? place : "\(place), ID \(label.shortHandle)"
    }
}

struct StreamRow: Identifiable, Equatable {
    let id: UUID
    let label: PeerLabel
    let announcement: DiscoveryAnnouncement
    /// Public title page (unconfirmed until the signed title arrives after joining).
    var advertisedTitle: String? = nil
    var title: String { advertisedTitle.map { "\($0) (unconfirmed)" } ?? "Live from \(label.title)" }
    /// "direct" / "via 2 phones", plus Paused/Full when they apply.
    var detail: String {
        var text = announcement.routeCost == 0 ? "Direct" : "Via \(announcement.routeCost) phone\(announcement.routeCost == 1 ? "" : "s")"
        if paused { text += ", paused" } else if full { text += ", full right now" }
        return text
    }
    var route: String { announcement.routeCost == 0 ? "direct" : "via \(announcement.routeCost) phone\(announcement.routeCost == 1 ? "" : "s")" }
    var paused: Bool { announcement.flags & DiscoveryAnnouncement.flagStreamPaused != 0 }
    var full: Bool { announcement.isFullStreamOffer }
    /// Experimental audio-only live ("radio"): the offer carries the 0x40 marker (unauthenticated hint; the
    /// signed BTL1 header must agree when joining).
    var audioOnly: Bool { announcement.isAudioOnlyOffer }
}

/// App state and orchestration on the main queue. One radio; one advertised role at a time
/// (review R5: a pending viewer request beats call availability).
final class AppModel: ObservableObject {
    @Published var status = ""
    @Published var bluetoothProblem: String?
    @Published var people: [PersonRow] = []
    @Published var streams: [StreamRow] = []
    @Published var call: CallController?
    @Published var watch: WatchController?
    @Published var live: LiveController?
    @Published var contacts: [VerifiedContact] = []
    @Published var contactsUnreadable: String?
    @Published var mismatchWarning: String?
    @Published var displayName = AppSettings.displayName { didSet { AppSettings.displayName = displayName; refreshAdvertising() } }
    @Published var transport = AppSettings.transport { didSet { AppSettings.transport = transport; refreshAdvertising() } }
    @Published var availableForCalls = AppSettings.availableForCalls {
        didSet {
            AppSettings.availableForCalls = availableForCalls; refreshAdvertising()
            if availableForCalls && !oldValue { CallNotifier.shared.requestIfAppropriate(.reachableTurnedOn) }
        }
    }
    /// Settings > Safety "Quick wipe: triple-tap the status line" (off by default, as Android).
    @Published var quickWipeGesture = AppSettings.quickWipeGesture { didSet { AppSettings.quickWipeGesture = quickWipeGesture } }
    /// Set by three quick taps on a tab header (when the quick wipe is on): the root asks to erase.
    @Published var askQuickWipe = false
    /// Local incoming-call alerts (notification permission), shown in Settings.
    @Published var callAlerts: CallAlertPolicy.Authorization = .notDetermined
    private var notifierConfigured = false
    func configureCallAlerts() {
        guard !notifierConfigured else { CallNotifier.shared.refreshAuthorization(); return }
        notifierConfigured = true
        CallNotifier.shared.onAuthorizationChange = { [weak self] in self?.callAlerts = $0 }
        CallNotifier.shared.configure(model: self)
    }
    /// The app left or regained the front while a call may ring (inactive or background).
    func appActivityChanged() {
        if let call { call.updateCallAlert() } else { CallNotifier.shared.update(for: nil) }
    }
    @Published var wiped = false
    /// EXPERIMENTAL rotating discovery IDs (Settings > Advanced).
    @Published var rotatingIds = AppSettings.rotatingIds {
        didSet { AppSettings.rotatingIds = rotatingIds; radio.acceptRotating = rotatingIds; refreshAdvertising() }
    }
    /// Phase 2 presence leases: the OFFER/LEASE exchange with a mutual verified contact in an answered call.
    func withPresence(_ options: RotatingCallOptions) -> RotatingCallOptions {
        var options = options
        let vault = rotating.vault, runtime = rotating, book = book
        options.presence = PresenceCallHooks(
            eligible: { id, fp in book.state(of: fp) == .verified && vault.persistent && vault.canSeeMe(id) },
            lease: { id, fp in vault.deliverLease(to: id, epoch: runtime.currentEpoch(), verified: book.state(of: fp) == .verified) },
            store: { id, lease in vault.store(lease, from: id, myEpoch: runtime.currentEpoch()) },
            verified: { fp in book.state(of: fp) == .verified })
        return options
    }

    /// A rotating advert: "Nearby phone", or a recognised contact's own label marked unconfirmed (never a check mark;
    /// a hit is a hint that anyone replaying the ID can fake, and never a reason to connect).
    func rotatingLabel(_ announcement: DiscoveryAnnouncement) -> PeerLabel {
        let hits = rotating.vault.recognition.lookup(announcement.nodeIdPrefix)
        if hits.count == 1, let contact = contacts.first(where: { $0.fingerprintHex.hasPrefix(hits[0].contact.hex) }) {
            return PeerLabel.recognized(contactName: contact.displayName, seed: announcement.nodeIdPrefix)
        }
        return PeerLabel.nearbyPhone(seed: announcement.nodeIdPrefix)
    }

    /// EXPERIMENTAL BMH3 (Settings > Advanced "Hidden identities" and its child "Pseudonymous toward strangers").
    @Published var hiddenIdentities = AppSettings.hiddenIdentities { didSet { AppSettings.hiddenIdentities = hiddenIdentities } }
    @Published var bmh3Pseudonyms = AppSettings.bmh3Pseudonyms { didSet { AppSettings.bmh3Pseudonyms = bmh3Pseudonyms } }
    let bmh3Pins = Bmh3Pins()
    /// The BMH3 options of one call, or nil (BMH2 only). Pseudonyms need rotating IDs, as on Android.
    func bmh3Options(selected: DiscoveryAnnouncement?) -> Bmh3CallOptions? {
        guard hiddenIdentities else { return nil }
        var options = Bmh3CallOptions(pseudonyms: bmh3Pseudonyms && rotatingIds, selected: selected, pins: bmh3Pins)
        if rotatingIds {
            // Phase 2: real keys between contacts through the lease-derived contact tag (PROTOCOL "Real lease keys").
            let vault = rotating.vault, pins = rotating.pins
            if let selected {
                options.contactTag = PresenceContactTags.initiatorTag(selected: selected, recognition: vault.recognition) { vault.leaseKey(of: $0, day: $1) }
            } else {
                options.tagChecks = {
                    PresenceContactTags.responderChecks(entries: pins.pinned(elapsedMs: RotatingDiscoveryRuntime.elapsedMs)) { vault.ownDayKey(epoch: $0) }
                }
                options.admitTagged = { vault.deliveredTo($0) }
            }
        }
        return options
    }
    let rotating = RotatingDiscoveryRuntime()
    private var rotationTimer: Timer?
    private var advertisedEpoch: Int64 = -1
    private var boundarySilenceUntil: Date?

    /// At each epoch boundary: stop, stay silent a uniform 1-8 s (RV12), then advertise the new ID.
    private func checkRotation() {
        guard rotatingIds, advertisedEpoch >= 0, boundarySilenceUntil == nil else { return }
        guard rotating.currentEpoch() != advertisedEpoch else { return }
        // Phase 2: the recognition table follows the epoch (RV10).
        rotating.vault.rebuildRecognition(myEpoch: rotating.currentEpoch())
        let silence = Double.random(in: 1...8)
        boundarySilenceUntil = Date().addingTimeInterval(silence)
        rotating.pins.offAir(elapsedMs: RotatingDiscoveryRuntime.elapsedMs)
        radio.advertise(nil, name: "")
        AppLog.event("rotating_ids", ["event": "boundary", "silenceS": String(format: "%.1f", silence)])
        DispatchQueue.main.asyncAfter(deadline: .now() + silence) { [weak self] in
            self?.boundarySilenceUntil = nil; self?.refreshAdvertising()
        }
    }

    func startVisibleByHandle() { rotating.startVisibleWindow(); refreshAdvertising() }
    /// Recent calls on this phone (newest first); Home shows the last 3.
    @Published var recentCalls: [CallRecord] = CallHistory.all
    /// EXPERIMENTAL (Settings > Advanced): help pass streams and calls to others nearby.
    @Published var relayForOthers = AppSettings.relayForOthers { didSet { AppSettings.relayForOthers = relayForOthers } }
    /// EXPERIMENTAL call relay hop (DEBUG launch argument only, like Android's test_private_call_relay).
    @Published var callRelay: CallRelayController?

    /// Relays calls to `person` (the callee): connects to it first, then offers its call with route cost + 1.
    func startCallRelay(to person: PersonRow) {
        guard relayForOthers, callRelay == nil, call == nil, watch == nil, live == nil, let identity,
              let peer = radio.peers[person.id], CallRelayChain.admitsOffer(peer.announcement, ownPrefix: identity.nodeId.prefix) else {
            AppLog.event("relay_call", ["stage": "refused", "reason": "not admitted or busy"]); return
        }
        let relay = CallRelayController(model: self, identity: identity, row: person.id, childOffer: peer.announcement,
                                        transport: peer.announcement.transport ?? .gatt)
        callRelay = relay
        relay.start()
        refreshAdvertising()
    }

    func callRelayFinished(_ relay: CallRelayController) {
        guard callRelay === relay else { return }
        callRelay = nil
        refreshAdvertising()
    }
    /// Shown on call and live screens only when the phone is hot or the battery is at 20 % or less.
    @Published var healthMessage: String?
    private var healthObservers: [NSObjectProtocol] = []

    private func startHealthMonitoring() {
        guard healthObservers.isEmpty else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            healthObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshHealth() })
        }
        refreshHealth()
    }

    private func refreshHealth() {
        let thermal = ProcessInfo.processInfo.thermalState
        let level = UIDevice.current.batteryLevel, charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        var message: String?
        if thermal == .serious || thermal == .critical { message = "Your phone is hot. Turning off video helps it cool down." }
        else if level >= 0, level <= 0.2, !charging { message = "Battery \(Int((level * 100).rounded())) %. Plug in to keep going." }
        if message != healthMessage {
            healthMessage = message
            AppLog.event("device_health", ["thermal": "\(thermal.rawValue)", "battery": String(format: "%.2f", level), "charging": "\(charging)", "message": message ?? "none"])
        }
    }
    @Published var peerLabelsEnabled = AppSettings.peerLabels { didSet { AppSettings.peerLabels = peerLabelsEnabled; radio.titlePages = peerLabelsEnabled } }
    /// Subject typed for the next outgoing call (experimental labels); consumed when the call starts.
    @Published var pendingCallSubject = ""
    /// Title of the next broadcast (experimental labels).
    @Published var liveTitle = ""
    private var automation: Automation?

    /// Label options for a new call, or nil when the experiment is off.
    func callLabelOptions() -> CallLabelOptions? {
        guard peerLabelsEnabled else { return nil }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = pendingCallSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        return CallLabelOptions(localName: name.isEmpty ? nil : name, subject: subject.isEmpty ? nil : subject,
                                isVerifiedPeer: { [weak self] in self?.book.state(of: $0) == .verified })
    }
    @Published var identityError: String?

    private(set) var identity: SigningIdentity!
    let radio = MeshRadio()
    let book = VerifiedContactBook()
    /// Fingerprints authenticated in this process, by node ID hex (last 1024), for marking contacts verified.
    private(set) var authenticated: [String: IdentityFingerprint] = [:]
    private var authenticatedOrder: [String] = []
    private var pruneTimer: Timer?

    var fingerprint: IdentityFingerprint? { identity?.fingerprint }
    var nodePrefixHex: String { identity?.nodeId.prefix.hex ?? "" }
    var identityPrefix: Data? { identity?.nodeId.prefix }
    /// Your handle (Crockford Base32 of your prefix), never raw hex.
    var handle: String { identity.flatMap { IdentityHandle.handle(prefix: $0.nodeId.prefix) } ?? "" }
    var decodeMask: UInt8 { VideoDecoderSupport.decodeMask }
    var encodeMask: UInt8 { VideoDecoderSupport.encodeMask }

    init() {
        AppLog.start()
        if EmergencyWipe.pending { EmergencyWipe.run() }
        do { identity = try IdentityStore.loadOrCreate() } catch {
            // Without Keychain access (for example an unsigned build) run with a session-only identity and say so.
            identity = SoftwareSigningIdentity()
            status = "This phone's identity could not be saved (\(error)); a temporary one is used until the app closes."
        }
        loadContacts()
        book.policy = AppSettings.mismatchPolicyWarnOnly ? .warn : .refuse
        book.onMismatch = { [weak self] _, _, contact in
            DispatchQueue.main.async {
                self?.mismatchWarning = "This phone's identity is different from the one you verified for \(contact.displayName). Someone may be pretending to be them. Do not share anything sensitive. End the call and check in person."
            }
        }
        radio.onPeersChanged = { [weak self] in self?.rebuildLists() }
        radio.onState = { [weak self] message in self?.bluetoothProblem = message }
        radio.onReady = { [weak self] in self?.bluetoothProblem = nil; self?.refreshAdvertising() }
        radio.onIncomingLink = { [weak self] link in self?.handleIncoming(link) }
        radio.allowIncomingGatt = { [weak self] in self?.call == nil || self?.watch?.awaitingSource == true }
    }

    func start() {
        guard identity != nil else { return }
        if rotatingIds { rotating.vault.rebuildRecognition(myEpoch: rotating.currentEpoch()) }
        if automation == nil, let auto = Automation(model: self) {
            automation = auto
            if auto.args["Labels"] == "1" { peerLabelsEnabled = true }
            if let name = auto.args["Name"] { displayName = name }
            auto.start()
        }
        radio.titlePages = peerLabelsEnabled
        radio.acceptRotating = rotatingIds
        if rotationTimer == nil {
            rotationTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.checkRotation() }
        }
        startHealthMonitoring()
        radio.start()
        radio.setScanning(true)
        pruneTimer?.invalidate()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.radio.prune(olderThan: 8) }
        refreshAdvertising()
    }

    /// iOS cannot be discovered in the background (no local name, UUIDs in Apple's overflow area) and
    /// cannot use the camera there. An active call continues with audio (background modes audio and
    /// bluetooth-central/peripheral keep its link and audio session running), with this phone's video off.
    /// Everything else stops; foregrounding restarts discovery.
    func enterBackground() {
        // An audio-only stream keeps playing with the screen locked or the app in the background (audio and
        // bluetooth-central background modes); its link stays, discovery pauses.
        if let watch, watch.isRadio, watch.ended == nil, call == nil {
            AppLog.event("app_state", ["state": "background_radio"])
            live?.stop()
            radio.pauseDiscovery()
            return
        }
        // Broadcasting audio only also continues with the screen off (connected listeners keep listening).
        if let live, live.audioOnly, live.running, call == nil {
            AppLog.event("app_state", ["state": "background_radio_source"])
            watch?.stop()
            radio.pauseDiscovery()
            return
        }
        watch?.stop(); live?.stop()
        if let call, call.ended == nil {
            AppLog.event("app_state", ["state": "background_call", "video": "\(call.cameraOn)"])
            call.enterBackground()
            radio.pauseDiscovery()
        } else {
            radio.stopAll()
        }
    }

    func enterForeground() {
        CallNotifier.shared.clear()
        configureCallAlerts()
        call?.enterForeground()
        start()
    }

    // MARK: Lists

    private func rebuildLists() {
        #if DEBUG
        if debugFixtureActive { return } // keep the simulator fixture rows
        #endif
        // Stable order: contacts first by name, then others by handle (rows no longer use advertised names).
        let peers = radio.peers.values.sorted { a, b in
            let ca = contactName(prefixHex: a.prefixHex), cb = contactName(prefixHex: b.prefixHex)
            if (ca != nil) != (cb != nil) { return ca != nil }
            return (ca ?? a.prefixHex, a.announcement.streamToken) < (cb ?? b.prefixHex, b.announcement.streamToken)
        }
        people = peers.filter { $0.announcement.isPrivateCallOffer && !$0.announcement.usesClassic }.map { p in
            // Pre-connect the prefix is an unauthenticated hint: a verified contact's local name may label the row,
            // but the row never claims "verified" (Android shows no badge here either).
            PersonRow(id: p.id, label: p.announcement.rotating ? rotatingLabel(p.announcement)
                        : PeerLabel(prefix: p.announcement.nodeIdPrefix, contactName: contactName(prefixHex: p.prefixHex)),
                      prefixHex: p.prefixHex, transport: p.announcement.transport ?? .gatt, relays: Int(p.announcement.routeCost), isIPhone: p.isIPhone)
        }
        // A malformed audio-only marker is ignored (Android StreamOfferKind.MALFORMED).
        streams = peers.filter { $0.announcement.isStreamOffer && !$0.announcement.usesClassic && $0.announcement.streamOfferKind != .malformed }.map {
            StreamRow(id: $0.id, label: $0.announcement.rotating ? PeerLabel.nearbyPhone(seed: $0.announcement.nodeIdPrefix)
                        : PeerLabel(prefix: $0.announcement.nodeIdPrefix, contactName: contactName(prefixHex: $0.prefixHex)),
                      announcement: $0.announcement, advertisedTitle: peerLabelsEnabled ? radio.titleBoard.title(routeToken: $0.announcement.streamToken) : nil)
        }
        live?.viewerRequestsChanged(peers)
        watch?.viewerRequestsChanged(peers)
    }

    func contactName(prefixHex: String) -> String? { contacts.first { $0.nodePrefixHex == prefixHex }?.displayName }

    // MARK: Advertising (one kind at a time)

    func refreshAdvertising() {
        guard let identity else { return }
        let prefix = identity.nodeId.prefix
        let gattFlag = { (t: MeshTransport) in t == .gatt ? DiscoveryAnnouncement.flagGattTransport : 0 }
        var announcement: DiscoveryAnnouncement?
        if let relayOffer = callRelay?.parentOffer {
            // Experimental call relay: the callee's offer with route cost + 1 until one parent connects.
            announcement = relayOffer
        } else if let watch, !watch.awaitingSource, let forward = watch.forwardOffer {
            // Experimental forwarding: offer the stream onward until a child connects (one UUID at a time).
            announcement = forward
        } else if let watch, watch.awaitingSource {
            let offer = watch.offer
            announcement = DiscoveryAnnouncement(nodeIdPrefix: prefix, flags: DiscoveryAnnouncement.flagAcceptingConnections | gattFlag(watch.transport),
                                                 capabilitySummary: decodeMask, streamToken: offer.streamToken, routeCost: offer.routeCost,
                                                 streamBitrateKbps: offer.streamBitrateKbps)
        } else if let live, live.running {
            announcement = live.offerAnnouncement(prefix: prefix)
        } else if availableForCalls, call == nil, watch == nil, callRelay == nil {
            announcement = DiscoveryAnnouncement(nodeIdPrefix: prefix, flags: DiscoveryAnnouncement.flagAcceptingConnections |
                                                 DiscoveryAnnouncement.flagPrivateCallAvailable | gattFlag(transport),
                                                 capabilitySummary: encodeMask & decodeMask, streamToken: 0, routeCost: 0)
            if rotatingIds && !rotating.visibleWindowActive {
                // Experimental: the role-0 rotating ID instead of the fixed prefix (compact v2).
                let entry = rotating.callEntry(nodeId: identity.nodeId)
                announcement?.nodeIdPrefix = entry.rdi; announcement?.rotating = true
                rotating.pins.onAdvertised(entry, elapsedMs: RotatingDiscoveryRuntime.elapsedMs)
                advertisedEpoch = entry.epoch
            }
        }
        if boundarySilenceUntil != nil, announcement?.rotating == true || announcement?.isPrivateCallOffer == true { return }
        if rotatingIds && announcement?.rotating != true { rotating.pins.offAir(elapsedMs: RotatingDiscoveryRuntime.elapsedMs) }
        radio.advertise(announcement, name: displayName)
    }

    // MARK: Incoming links

    private func handleIncoming(_ link: MeshLink) {
        if let relay = callRelay, relay.awaitingParent { relay.attachParent(link); refreshAdvertising(); return }
        if let watch, watch.awaitingSource { watch.attach(link); refreshAdvertising(); return }
        guard call == nil, availableForCalls, let identity else { link.close(); return }
        let pins = rotating.pins
        let controller = CallController(model: self, role: .callee, peerName: "Incoming call", peerPrefixHex: nil,
                                        identity: identity, transport: link.transport, type: .video, relayHops: 0,
                                        rotating: rotatingIds ? withPresence(RotatingCallOptions(entries: { pins.pinned(elapsedMs: RotatingDiscoveryRuntime.elapsedMs) })) : nil,
                                        bmh3: bmh3Options(selected: nil))
        call = controller
        controller.attach(link)
        refreshAdvertising()
    }

    // MARK: Calls

    private var placingCall = false
    /// Last call problem, shown on the Call screen after the call screen closes ("Couldn't reach ...").
    @Published var callNotice: String?

    /// Asks for the microphone (and camera for video) first, so the system prompt never interrupts media.
    /// A call is just a call with Mute; while muted, holding Mute talks (no separate push-to-talk mode).
    func startCall(to person: PersonRow, type: CallType) {
        guard call == nil, !placingCall, identity != nil else { return }
        placingCall = true; callNotice = nil
        MediaPermissions.request(video: type == .video, context: "outgoing") { [weak self] _, _ in
            guard let self else { return }
            self.placingCall = false
            self.placeCall(to: person, type: type)
        }
    }

    private func placeCall(to person: PersonRow, type: CallType) {
        guard call == nil, let identity else { return }
        guard let peer = radio.peers[person.id], !(peer.announcement.rotating && peer.announcement.routeCost > 0) else {
            let text = "Couldn't reach \(person.label.title) \u{2013} they may have moved away."
            AppLog.event("call_end", ["reason": text, "error": "true", "stage": "not_nearby"])
            callNotice = text; return
        }
        let controller = CallController(model: self, role: .caller, peerName: person.label.title,
                                        peerPrefixHex: peer.announcement.rotating ? nil : person.prefixHex, identity: identity, transport: person.transport, type: type,
                                        relayHops: UInt8(min(Int(peer.announcement.routeCost), 15)),
                                        rotating: rotatingIds ? withPresence(RotatingCallOptions(selected: peer.announcement)) : nil,
                                        bmh3: bmh3Options(selected: peer.announcement))
        call = controller
        pendingCallSubject = ""
        refreshAdvertising()
        controller.phaseText = "Calling…"
        radio.connect(to: person.id, transport: person.transport) { [weak self, weak controller] result in
            guard let controller else { return }
            switch result {
            case .success(let link): controller.attach(link)
            case .failure(let error):
                let stage = (error as? RadioError)?.stage ?? "connect"
                controller.failed("Couldn't reach \(person.label.title) \u{2013} they may have moved away.", stage: stage, detail: "\(error)")
            }
            self?.refreshAdvertising()
        }
    }

    /// Records the finished call in the local history (outgoing / incoming / missed).
    private func remember(_ controller: CallController) {
        guard let prefix = controller.peerPrefixHex else { return }
        let seconds = controller.activeSince.map { Int(Date().timeIntervalSince($0)) } ?? 0
        let direction: CallRecord.Direction = controller.role == .caller ? .outgoing : (controller.activeSince == nil ? .missed : .incoming)
        CallHistory.add(CallRecord(prefixHex: prefix, direction: direction, video: controller.callType == .video, at: Date(), seconds: seconds))
        recentCalls = CallHistory.all
    }

    /// Calls a recent contact back if their phone is nearby now.
    func callBack(_ record: CallRecord) {
        if let person = people.first(where: { $0.prefixHex == record.prefixHex }) {
            startCall(to: person, type: record.video ? .video : .voice)
        } else {
            let label = PeerLabel(prefix: Data(hex: record.prefixHex) ?? Data(count: 6), contactName: contactName(prefixHex: record.prefixHex))
            callNotice = "\(label.title) isn't nearby right now. Ask them to open MeshLive."
        }
    }

    func callFinished(_ controller: CallController) {
        CallNotifier.shared.clear()
        if controller.activeSince != nil { CallNotifier.shared.requestIfAppropriate(.callEnded) }
        guard call === controller else { return }
        remember(controller)
        if controller.failedEarly, let ended = controller.ended { callNotice = ended }
        call = nil
        refreshAdvertising()
    }

    // MARK: Watching

    func startWatching(_ row: StreamRow) {
        guard watch == nil, let identity else { return }
        let controller = WatchController(model: self, identity: identity, offer: row.announcement, name: row.label.title, route: row.route, transport: row.announcement.transport ?? .gatt)
        watch = controller
        refreshAdvertising()
    }

    func watchFinished(_ controller: WatchController) {
        guard watch === controller else { return }
        watch = nil
        refreshAdvertising()
    }

    // MARK: Going live

    func goLive(audioOnly: Bool = false, preset: UInt8 = AudioLive.presetVoice) {
        guard live == nil, let identity else { return }
        live = LiveController(model: self, identity: identity, transport: transport,
                              labels: peerLabelsEnabled, title: liveTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : liveTitle,
                              audioOnly: audioOnly, preset: preset)
        live?.start()
        refreshAdvertising()
    }

    func liveFinished(_ controller: LiveController) {
        guard live === controller else { return }
        live = nil
        refreshAdvertising()
    }

    // MARK: Identity verification

    func noteAuthenticated(_ fingerprint: IdentityFingerprint) {
        let key = fingerprint.nodeId.hex
        if authenticated[key] == nil { authenticatedOrder.append(key) }
        authenticated[key] = fingerprint
        if authenticatedOrder.count > 1024 { authenticated[authenticatedOrder.removeFirst()] = nil }
    }

    func verificationState(of fingerprint: IdentityFingerprint) -> VerificationState { book.state(of: fingerprint) }

    /// QR scan: the scanned full fingerprint must equal one authenticated in this process.
    func markVerified(scanned payload: IdentityQrPayload) throws {
        let authenticatedFp = authenticated[payload.fingerprint.nodeId.hex]
        try book.markVerified(authenticated: authenticatedFp, confirmed: payload.fingerprint, name: payload.displayName, method: "qr")
        try saveContacts()
    }

    func markVerified(sessionPeer fingerprint: IdentityFingerprint, name: String) throws {
        try book.markVerified(authenticated: authenticated[fingerprint.nodeId.hex], confirmed: fingerprint, name: name, method: "safety-code")
        try saveContacts()
    }

    /// Phase 2: the node ID of a verified contact (the first 16 bytes of its fingerprint).
    private func nodeId(of contact: VerifiedContact) -> NodeId? {
        Data(hex: String(contact.fingerprintHex.prefix(32))).flatMap { try? NodeId(bytes: $0) }
    }
    /// "Can see when I'm nearby" (default on, as Android).
    func canSeeMe(_ contact: VerifiedContact) -> Bool { nodeId(of: contact).map { rotating.vault.canSeeMe($0) } ?? true }
    func setCanSeeMe(_ contact: VerifiedContact, _ on: Bool) {
        guard let node = nodeId(of: contact) else { return }
        rotating.vault.setCanSeeMe(node, on, epoch: rotating.currentEpoch())
        objectWillChange.send()
    }
    /// "Reset presence key": a new generation; contacts recognise this phone again after the next mutual call.
    func resetPresenceKey() {
        rotating.vault.newGeneration(epoch: rotating.currentEpoch(), reason: "reset")
        presenceGeneration = rotating.vault.generation
        refreshAdvertising()
    }
    @Published var presenceGeneration: UInt32 = 0

    func forget(_ contact: VerifiedContact) {
        book.forget(contact.fingerprintHex); try? saveContacts()
        // A contact that holds this phone's lease: a new presence generation, so the old keys recognise nothing.
        if let node = Data(hex: String(contact.fingerprintHex.prefix(32))).flatMap({ try? NodeId(bytes: $0) }) {
            rotating.vault.forget(node, epoch: rotating.currentEpoch())
        }
    }

    func resetContacts() { VerifiedContactsStore.reset(); book.reset(); contacts = []; contactsUnreadable = nil }

    private func loadContacts() {
        switch VerifiedContactsStore.load() {
        case .loaded(let list): book.restore(list)
        case .empty: break
        case .unreadable(let reason): contactsUnreadable = reason
        }
        contacts = book.contacts
    }

    private func saveContacts() throws {
        guard contactsUnreadable == nil else { throw ProtocolError.state("The verified-contact store is unreadable; reset it first") }
        try VerifiedContactsStore.save(book.contacts)
        contacts = book.contacts
        rebuildLists()
    }

    func myQrText() -> String? {
        guard let fingerprint else { return nil }
        let name = displayName.trimmingCharacters(in: .whitespaces).isEmpty ? "Phone \(handle.prefix(5))" : displayName
        return try? IdentityQrCodec.encode(IdentityQrPayload(fingerprint: fingerprint, displayName: name))
    }

    #if DEBUG
    /// Simulator fixture (`-NearbyFixture populated`): made-up people, streams and recent calls, in memory only
    /// (nothing is written to the call history), so every list state can be screenshot without radios.
    private(set) var debugFixtureActive = false
    func applyDebugFixture(_ name: String) {
        guard name == "populated" else { return }
        debugFixtureActive = true
        let asha = Data(hex: "a1b2c3d4e5f6")!, ravi = Data(hex: "0102030405a8")!, stranger = Data(hex: "112233445566")!
        people = [
            PersonRow(id: UUID(), label: PeerLabel(prefix: asha, contactName: "Asha"), prefixHex: asha.hex, transport: .gatt, relays: 0, isIPhone: false),
            PersonRow(id: UUID(), label: PeerLabel(prefix: ravi), prefixHex: ravi.hex, transport: .l2cap, relays: 2, isIPhone: false),
            PersonRow(id: UUID(), label: PeerLabel.nearbyPhone(seed: stranger), prefixHex: stranger.hex, transport: .gatt, relays: 0, isIPhone: true),
        ]
        let streamFlags = DiscoveryAnnouncement.flagStreamAvailable | DiscoveryAnnouncement.flagGattTransport
        streams = [
            StreamRow(id: UUID(), label: PeerLabel(prefix: asha, contactName: "Asha"),
                      announcement: DiscoveryAnnouncement(nodeIdPrefix: asha, flags: streamFlags, capabilitySummary: 1, streamToken: 0x8123_4567,
                                                          routeCost: 0, sequence: 1, streamWidth: 640, streamHeight: 360, streamFps: 15, streamBitrateKbps: 300)),
            StreamRow(id: UUID(), label: PeerLabel(prefix: ravi),
                      announcement: DiscoveryAnnouncement(nodeIdPrefix: ravi, flags: streamFlags | DiscoveryAnnouncement.flagStreamPaused, capabilitySummary: 1,
                                                          streamToken: 0x8765_4321, routeCost: 2, sequence: 1, streamWidth: 426, streamHeight: 240, streamFps: 15,
                                                          streamBitrateKbps: 200)),
            // Experimental audio-only live: a radio row (0x40 marker, no geometry).
            StreamRow(id: UUID(), label: PeerLabel(prefix: stranger),
                      announcement: DiscoveryAnnouncement(nodeIdPrefix: stranger, flags: streamFlags, capabilitySummary: AudioLive.summaryAudioOnly,
                                                          streamToken: 0x8555_1234, routeCost: 0, sequence: 1, streamBitrateKbps: 25),
                      advertisedTitle: "Neighbourhood radio, ward 12 updates"),
        ]
        // In memory only: a verified contact for the Verify screen (its presence switch is a real vault entry).
        contacts = [VerifiedContact(fingerprint: IdentityFingerprint(publicKey: try! SoftwareSigningIdentity(rawScalar: Data(repeating: 7, count: 32)).publicKeyEncoded),
                                    displayName: "Asha", method: "qr")]
        recentCalls = [
            CallRecord(prefixHex: asha.hex, direction: .outgoing, video: true, at: Date().addingTimeInterval(-300), seconds: 125),
            CallRecord(prefixHex: ravi.hex, direction: .missed, video: false, at: Date().addingTimeInterval(-3_600), seconds: 0),
            CallRecord(prefixHex: asha.hex, direction: .incoming, video: false, at: Date().addingTimeInterval(-86_400), seconds: 3_725),
        ]
    }

    /// Screenshot aid only: `-NearbyScreen call` (outgoing, ringing), `call-incoming`, `call-incoming-voice`,
    /// `call-active`, `call-ended`, `call-mismatch`. Unconnected: no engine runs, nothing is sent.
    func showDebugCall(_ variant: String = "call") {
        guard call == nil, let identity else { return }
        let incoming = variant.hasPrefix("call-incoming")
        let controller = CallController(model: self, role: incoming ? .callee : .caller, peerName: "Asha", peerPrefixHex: "a1b2c3d4e5f6",
                                        identity: identity, transport: .gatt, type: variant == "call-incoming" ? .video : .voice, relayHops: 0)
        controller.label = PeerLabel(prefix: Data(hex: "a1b2c3d4e5f6")!, selfName: "Asha")
        switch variant {
        case "call-incoming", "call-incoming-voice":
            controller.phase = .incomingRinging; controller.offeredType = variant == "call-incoming" ? .video : .voice
            controller.phaseText = "Incoming call"
        case "call-active", "call-mismatch":
            controller.phase = .active; controller.activeSince = Date().addingTimeInterval(-83)
            controller.fingerprint = SoftwareSigningIdentity().fingerprint
            if variant == "call-mismatch" { controller.verification = .mismatch }
        case "call-ended":
            controller.phase = .ended; controller.ended = "Call ended"
        default:
            controller.phase = .outgoingRinging; controller.phaseText = "Ringing…"
        }
        call = controller
    }
    #endif

    // MARK: Emergency wipe

    func emergencyWipe() {
        call?.end(); watch?.stop(); live?.stop()
        radio.stopAll()
        _ = EmergencyWipe.run()
        identity = nil; contacts = []; book.reset(); authenticated = [:]; people = []; streams = []; recentCalls = []
        wiped = true
    }
}
