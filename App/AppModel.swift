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
    /// First stored property, so it marks where this object's construction began (startup timing, `BENCHMARK startup`).
    private let constructionBegan = ProcessInfo.processInfo.systemUptime
    @Published var status = ""
    @Published var bluetoothProblem: String?
    @Published var people: [PersonRow] = []
    @Published var streams: [StreamRow] = []
    @Published var streamNotice: String?
    let streamRoutePenalties = StreamRoutePenalties()
    let audioRelayMemory = AudioLiveRelayMemory()
    @Published var call: CallController? {
        didSet {
            #if os(macOS)
            desktopCallScanning.selectCall(call?.id)
            #endif
        }
    }
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
    /// Set by three quick taps on a tab header (when the quick wipe is on): the root view asks to erase.
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
    func appActivityChanged() { CallNotifier.shared.update(for: call) }
    @Published var wiped = false
    /// Generated nearby names (Android names-v2) on iPhone and Mac, on by default as on Android.
    @Published var desktopGeneratedNames = AppSettings.desktopGeneratedNames {
        didSet { AppSettings.desktopGeneratedNames = desktopGeneratedNames; rebuildLists(); refreshAdvertising() }
    }
    /// The generated name of this device's own advertised rotating ID (what people nearby see), or nil.
    @Published private(set) var desktopAdvertisedName: String?
    /// BluetoothGuidance: Bluetooth is allowed and on but stuck; the status card says to turn it off and on.
    @Published var bluetoothRestartNeeded = false
    func checkBluetoothGuidance() {
        #if DEBUG
        if RootView.debugArgument("-NearbyBluetoothStuck") == "1" { return }   // UI fixture: keep the guidance shown
        #endif
        let needed = BluetoothGuidance.needsRestart(state: radio.guidanceState,
                                                    secondsInState: ProcessInfo.processInfo.systemUptime - radio.centralStateSince,
                                                    hostingFailed: radio.hostingFailed)
        guard needed != bluetoothRestartNeeded else { return }
        bluetoothRestartNeeded = needed
        AppLog.event("bluetooth_guidance", ["restart": "\(needed)", "state": "\(radio.guidanceState)", "hostingFailed": "\(radio.hostingFailed)"])
    }
    /// "You appear as ..." (OwnNearbyName): what people nearby who have not added you see for this device now, or nil.
    var ownNearbyLine: String? {
        OwnNearbyName.shown(reachableForCalls: availableForCalls, rotatingOn: rotatingIds,
                            generatedNamesOn: desktopGeneratedNames, generatedName: desktopAdvertisedName).map(OwnNearbyName.line)
    }
    /// EXPERIMENTAL rotating discovery IDs (Settings > Advanced).
    @Published var rotatingIds = AppSettings.rotatingIds {
        didSet {
            AppSettings.rotatingIds = rotatingIds; updateDiscoveryCompatibility()
            // A join or forwarder of a rotating stream started with the setting off advertises the fixed prefix:
            // stop it now that the setting hides that prefix (RotatingStreamPolicy).
            if let watch, let refusal = RotatingStreamPolicy.joinRefusal(offer: watch.offer, rotatingIds: rotatingIds) {
                AppLog.event("rotating_ids", ["event": "join_stopped", "role": "viewer"])
                watch.stop()
                streamNotice = refusal
            }
            refreshAdvertising()
        }
    }
    #if os(macOS)
    @Published var desktopPauseCallDiscovery = AppSettings.desktopPauseCallDiscovery {
        didSet {
            AppSettings.desktopPauseCallDiscovery = desktopPauseCallDiscovery
            desktopCallScanning.setEnabled(desktopPauseCallDiscovery)
        }
    }
    @Published var desktopCallDeliveryFeedback = AppSettings.desktopCallDeliveryFeedback {
        didSet { AppSettings.desktopCallDeliveryFeedback = desktopCallDeliveryFeedback }
    }
    @Published var desktopAndroidCompatibility = AppSettings.desktopAndroidCompatibility {
        didSet {
            AppSettings.desktopAndroidCompatibility = desktopAndroidCompatibility
            updateDiscoveryCompatibility()
        }
    }
    private var desktopCallCompatibility: DesktopCallCompatibility {
        DesktopCallCompatibility(enabled: desktopAndroidCompatibility, rotatingIds: rotatingIds,
                                 hiddenIdentities: hiddenIdentities, pseudonyms: bmh3Pseudonyms)
    }
    #endif

    private func updateDiscoveryCompatibility() {
        #if os(macOS)
        radio.acceptRotating = desktopCallCompatibility.acceptsRotating
        rebuildLists()
        #else
        radio.acceptRotating = rotatingIds
        #endif
    }

    private func outgoingRotatingOptions(selected: DiscoveryAnnouncement) -> RotatingCallOptions? {
        #if os(macOS)
        guard let options = desktopCallCompatibility.rotatingOptions(selected: selected) else { return nil }
        return rotatingIds ? withPresence(options) : options
        #else
        return rotatingIds ? withPresence(RotatingCallOptions(selected: selected)) : nil
        #endif
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
    func rotatingLabel(_ announcement: DiscoveryAnnouncement, generatedName: String? = nil) -> PeerLabel {
        let hits = rotating.vault.recognition.lookup(announcement.nodeIdPrefix)
        if hits.count == 1, let contact = contacts.first(where: { $0.fingerprintHex.hasPrefix(hits[0].contact.hex) }) {
            return PeerLabel.recognized(contactName: contact.displayName, seed: announcement.nodeIdPrefix)
        }
        if desktopGeneratedNames, let name = generatedName ?? DesktopNearbyNames.shared?.name(for: announcement)?.text {
            return PeerLabel.generated(name, seed: announcement.nodeIdPrefix)
        }
        return PeerLabel.nearbyPhone(seed: announcement.nodeIdPrefix)
    }

    /// EXPERIMENTAL BMH3 (Settings > Advanced "Hidden identities" and its child "Pseudonymous toward strangers").
    @Published var hiddenIdentities = AppSettings.hiddenIdentities { didSet { AppSettings.hiddenIdentities = hiddenIdentities } }
    @Published var bmh3Pseudonyms = AppSettings.bmh3Pseudonyms { didSet { AppSettings.bmh3Pseudonyms = bmh3Pseudonyms } }
    @Published var relayedCalls = AppSettings.relayedCalls { didSet { AppSettings.relayedCalls = relayedCalls } }
    /// Kept for 30 days across restarts, as Android (a stripped hint cannot downgrade a pinned peer to BMH2).
    let bmh3Pins = Bmh3Pins(storage: DesktopPreview.enabled ? nil : Bmh3PinFile())
    /// The BMH3 options of one call, or nil (BMH2 only). Mac compatibility can use a per-attempt
    /// pseudonym for a selected rotating offer independently of this Mac's own advertising setting.
    func bmh3Options(selected: DiscoveryAnnouncement?) -> Bmh3CallOptions? {
        #if os(macOS)
        guard var options = desktopCallCompatibility.bmh3Options(selected: selected, pins: bmh3Pins) else { return nil }
        #else
        guard hiddenIdentities else { return nil }
        var options = Bmh3CallOptions(pseudonyms: bmh3Pseudonyms && rotatingIds, selected: selected, pins: bmh3Pins)
        options.pseudonymousRelayEdges = AppSettings.relayedPseudonymousEdges
        #endif
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
                // Pseudonym mode: the responder's replay cache and signing budget follow the discovery epoch (PR3).
                let runtime = rotating
                options.epoch = { runtime.currentEpoch() }
            }
        }
        return options
    }
    let rotating = RotatingDiscoveryRuntime()
    private var rotationTimer: Timer?
    #if !os(macOS)
    private var advertisedEpoch: Int64 = -1
    private var boundarySilenceUntil: Date?
    #endif
    #if os(macOS)
    private var desktopStopping = false
    private lazy var desktopCallScanning = DesktopCallScanning(enabled: desktopPauseCallDiscovery) { [weak self] on in
        guard let self, !DesktopPreview.enabled else { return }
        self.radio.setScanning(on)
    }
    func desktopCallLinkAttached(_ controller: CallController) -> Bool {
        guard !desktopStopping, call === controller, controller.ended == nil else { return false }
        return desktopCallScanning.linkAttached(to: controller.id)
    }
    func desktopCallLinkFinished(_ controller: CallController) {
        desktopCallScanning.callEnded(controller.id)
    }
    var desktopRadioLogFields: [String: String] {
        var fields = radio.desktopLogFields
        fields["pauseCallDiscoveryEnabled"] = "\(desktopPauseCallDiscovery)"
        return fields
    }
    private lazy var desktopAdvertising: DesktopDiscoveryAdvertising = DesktopDiscoveryAdvertising(
        pins: rotating.pins,
        publish: { [weak self] announcement in
            guard let self else { return }
            self.desktopAdvertisedName = self.desktopGeneratedNames
                ? announcement.flatMap { DesktopNearbyNames.shared?.name(for: $0)?.text } : nil
            self.radio.advertise(announcement, name: self.displayName)
        }, refresh: { [weak self] in self?.refreshAdvertising() })
    #endif

    /// At each epoch boundary: stop, stay silent a uniform 1-8 s (RV12), then advertise the new ID.
    private func checkRotation() {
        #if os(macOS)
        guard rotatingIds, !desktopStopping else { return }
        // Reading the window on every check also expires a first-ever fixed-ID window. The
        // desktop scheduler decides whether the current role actually has anything to rotate.
        rotating.vault.rebuildRecognition(myEpoch: rotating.currentEpoch())
        refreshAdvertising()
        #else
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
        #endif
    }

    func startVisibleByHandle() {
        rotating.startVisibleWindow()
        #if os(macOS)
        desktopAdvertising.requestCallRestart()
        #endif
        refreshAdvertising()
    }
    /// Recent calls on this phone (newest first); Home shows the last 3.
    /// Loaded in init, after a resumed wipe and the one-time moves of plain copies.
    @Published var recentCalls: [CallRecord] = []
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
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
        let center = NotificationCenter.default
        #if os(iOS)
        let names = [ProcessInfo.thermalStateDidChangeNotification, UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification]
        #else
        let names = [ProcessInfo.thermalStateDidChangeNotification]
        #endif
        for name in names {
            healthObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshHealth() })
        }
        refreshHealth()
    }

    private func refreshHealth() {
        let thermal = ProcessInfo.processInfo.thermalState
        #if os(iOS)
        let level = UIDevice.current.batteryLevel, charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        #else
        let level: Float = -1
        let charging = true
        #endif
        var message: String?
        #if os(macOS)
        if thermal == .serious || thermal == .critical { message = "Your Mac is hot. Turning off video helps it cool down." }
        #else
        if thermal == .serious || thermal == .critical { message = "Your phone is hot. Turning off video helps it cool down." }
        else if level >= 0, level <= 0.2, !charging { message = "Battery \(Int((level * 100).rounded())) %. Plug in to keep going." }
        #endif
        if message != healthMessage {
            healthMessage = message
            AppLog.event("device_health", ["thermal": "\(thermal.rawValue)", "battery": String(format: "%.2f", level), "charging": "\(charging)", "message": message ?? "none"])
        }
    }
    @Published var peerLabelsEnabled = AppSettings.peerLabels { didSet { AppSettings.peerLabels = peerLabelsEnabled; radio.titlePages = peerLabelsEnabled } }
    /// Title of the next broadcast (experimental labels).
    @Published var liveTitle = ""
    private var automation: Automation?

    /// Label options for a new call, or nil when the experiment is off.
    func callLabelOptions() -> CallLabelOptions? {
        guard peerLabelsEnabled else { return nil }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return CallLabelOptions(localName: name.isEmpty ? nil : name, subject: nil,
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
        let initBegan = ProcessInfo.processInfo.systemUptime
        var steps: [String: String] = ["propertiesMs": AppLog.ms(since: constructionBegan, until: initBegan)]
        var mark = initBegan
        func step(_ name: String) { let now = ProcessInfo.processInfo.systemUptime; steps[name] = AppLog.ms(since: mark, until: now); mark = now }
        defer { steps["initMs"] = AppLog.ms(since: initBegan); AppLog.event("startup", steps) }
        // A wipe resumed at launch finishes first; it does not latch, so this run can store a new identity.
        if EmergencyWipe.pending && !DesktopPreview.enabled { EmergencyWipe.run(userInitiated: false) }
        SealedRecords.migrateLegacy()
        recentCalls = CallHistory.all
        step("wipeMs")
        CrashReports.shared.start()
        step("crashReportsMs")
        KeychainItem.migrateLegacyServices()
        step("keychainMoveMs")
        defer { step("contactsAndHooksMs") }
        do { identity = try IdentityStore.loadOrCreate() } catch {
            // Without Keychain access (for example an unsigned build) run with a session-only identity and say so.
            identity = SoftwareSigningIdentity()
            status = "This phone's identity could not be saved (\(error)); a temporary one is used until the app closes."
        }
        step("identityMs")
        loadContacts()
        book.policy = AppSettings.mismatchPolicyWarnOnly ? .warn : .refuse
        book.onMismatch = { [weak self] _, _, contact in
            DispatchQueue.main.async {
                self?.mismatchWarning = "This phone no longer matches the ID saved for \(contact.displayName). End the call and check with them in person before sharing anything private."
            }
        }
        radio.onPeersChanged = { [weak self] in self?.rebuildLists() }
        radio.onState = { [weak self] message in self?.bluetoothProblem = message }
        radio.onReady = { [weak self] in self?.bluetoothProblem = nil; self?.refreshAdvertising() }
        radio.onIncomingLink = { [weak self] link in self?.handleIncoming(link) }
        radio.allowIncomingGatt = { [weak self] in self?.call == nil || self?.watch?.awaitingSource == true }
    }

    func start() {
        guard !DesktopPreview.enabled, identity != nil else { return }
        #if os(macOS)
        guard !desktopStopping else { return }
        #endif
        let began = ProcessInfo.processInfo.systemUptime
        defer { AppLog.event("startup", ["startMs": AppLog.ms(since: began)]) }
        if rotatingIds { rotating.vault.rebuildRecognition(myEpoch: rotating.currentEpoch()) }
        if automation == nil, let auto = Automation(model: self) {
            automation = auto
            if auto.args["Labels"] == "1" { peerLabelsEnabled = true }
            if let name = auto.args["Name"] { displayName = name }
            auto.start()
        }
        radio.titlePages = peerLabelsEnabled
        updateDiscoveryCompatibility()
        if rotationTimer == nil {
            rotationTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.checkRotation() }
        }
        startHealthMonitoring()
        radio.start()
        #if os(macOS)
        desktopCallScanning.start()
        #else
        radio.setScanning(true)
        #endif
        pruneTimer?.invalidate()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.radio.prune(olderThan: 8); self?.checkBluetoothGuidance()
        }
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

    #if os(macOS)
    /// Quit stops local media and links; closing windows only does so when macOS terminates the app.
    func stopForDesktopExit() {
        desktopStopping = true
        desktopCallScanning.stop()
        desktopAdvertising.stop()
        call?.end()
        watch?.stop()
        live?.stop()
        radio.stopAll()
        pruneTimer?.invalidate(); pruneTimer = nil
        rotationTimer?.invalidate(); rotationTimer = nil
        healthObservers.forEach(NotificationCenter.default.removeObserver); healthObservers.removeAll()
        CallNotifier.shared.clear()
    }
    #endif

    // MARK: Lists

    private func rebuildLists() {
        defer { takeStreamRetry() }
        #if DEBUG
        if debugFixtureActive { return } // keep the simulator fixture rows
        #endif
        // Stable order: contacts first by name, then others by handle (rows no longer use advertised names).
        let peers = radio.peers.values.filter { peer in
            #if os(macOS)
            return !peer.announcement.rotating || radio.acceptRotating
            #else
            return true
            #endif
        }.sorted { a, b in
            let ca = contactName(prefixHex: a.prefixHex), cb = contactName(prefixHex: b.prefixHex)
            if (ca != nil) != (cb != nil) { return ca != nil }
            return (ca ?? a.prefixHex, a.announcement.streamToken) < (cb ?? b.prefixHex, b.announcement.streamToken)
        }
        let callPeers = peers.filter { $0.announcement.isPrivateCallOffer && !$0.announcement.usesClassic }
        let generatedCalls = desktopGeneratedNames ? DesktopNearbyNames.shared?.labels(for: callPeers.map(\.announcement)) ?? [:] : [:]
        let generatedStreams = desktopGeneratedNames ? DesktopNearbyNames.shared?.labels(for: peers.filter { $0.announcement.isStreamOffer }.map(\.announcement)) ?? [:] : [:]
        people = callPeers.map { p in
            // Pre-connect the prefix is an unauthenticated hint: a verified contact's local name may label the row,
            // but the row never claims "verified" (Android shows no badge here either).
            #if os(macOS)
            let generated = generatedCalls[p.announcement.nodeIdPrefix]
            #else
            let generated: String? = nil
            #endif
            return PersonRow(id: p.id, label: p.announcement.rotating ? rotatingLabel(p.announcement, generatedName: generated)
                        : PeerLabel(prefix: p.announcement.nodeIdPrefix, contactName: contactName(prefixHex: p.prefixHex)),
                      prefixHex: p.prefixHex, transport: p.announcement.transport ?? .gatt, relays: Int(p.announcement.routeCost), isIPhone: p.isIPhone)
        }
        // A malformed audio-only marker is never listed (Android StreamOfferKind.MALFORMED; Android lists it as video
        // with its switch off, this app refuses it either way). Audio-only offers are listed only with audio live on.
        let audioLive = AppSettings.audioLive
        streams = peers.filter {
            $0.announcement.isStreamOffer && !$0.announcement.usesClassic
                && ($0.announcement.streamOfferKind == .video || ($0.announcement.streamOfferKind == .audioOnly && audioLive))
                && !streamRoutePenalties.isPenalized(streamRouteKey($0.id, $0.announcement), now: ConnectionDriver.now)
        }.map { p in
            #if os(macOS)
            let label = p.announcement.rotating ? rotatingLabel(p.announcement, generatedName: generatedStreams[p.announcement.nodeIdPrefix])
                : PeerLabel(prefix: p.announcement.nodeIdPrefix, contactName: contactName(prefixHex: p.prefixHex))
            #else
            let label = p.announcement.rotating ? PeerLabel.nearbyPhone(seed: p.announcement.nodeIdPrefix)
                : PeerLabel(prefix: p.announcement.nodeIdPrefix, contactName: contactName(prefixHex: p.prefixHex))
            #endif
            return StreamRow(id: p.id, label: label, announcement: p.announcement,
                             advertisedTitle: peerLabelsEnabled ? radio.titleBoard.title(routeToken: p.announcement.streamToken) : nil)
        }
        live?.viewerRequestsChanged(peers)
        watch?.viewerRequestsChanged(peers)
    }

    func contactName(prefixHex: String) -> String? { contacts.first { $0.nodePrefixHex == prefixHex }?.displayName }

    // MARK: Advertising (one kind at a time)

    func refreshAdvertising() {
        guard !DesktopPreview.enabled, let identity else { return }
        #if os(macOS)
        guard !desktopStopping else { return }
        var desktopCallPresence: DesktopDiscoveryAdvertising.CallPresence?
        #endif
        let prefix = identity.nodeId.prefix
        let gattFlag = { (t: MeshTransport) in t == .gatt ? DiscoveryAnnouncement.flagGattTransport : 0 }
        var announcement: DiscoveryAnnouncement?
        if let relayOffer = callRelay?.parentOffer {
            // Experimental call relay: the callee's offer with route cost + 1 until one parent connects.
            announcement = relayOffer
        } else if let watch, !watch.awaitingSource, let forward = watch.forwardOffer,
                  RotatingStreamPolicy.mayForward(offer: watch.offer, rotatingIds: rotatingIds) {
            // Experimental forwarding: offer the stream onward until a child connects (one UUID at a time).
            announcement = forward
        } else if let watch, watch.awaitingSource, RotatingStreamPolicy.joinRefusal(offer: watch.offer, rotatingIds: rotatingIds) == nil {
            // (A rotating stream's fixed-prefix request is never advertised while rotating IDs are on.)
            let offer = watch.offer
            announcement = DiscoveryAnnouncement(nodeIdPrefix: prefix, flags: DiscoveryAnnouncement.flagAcceptingConnections | gattFlag(watch.transport),
                                                 capabilitySummary: decodeMask, streamToken: offer.streamToken, routeCost: offer.routeCost,
                                                 streamBitrateKbps: offer.streamBitrateKbps)
        } else if let live, live.running {
            announcement = live.offerAnnouncement(prefix: prefix)
        } else if availableForCalls, call == nil, watch == nil, callRelay == nil {
            #if os(macOS)
            desktopCallPresence = .fixed
            #endif
            announcement = DiscoveryAnnouncement(nodeIdPrefix: prefix, flags: DiscoveryAnnouncement.flagAcceptingConnections |
                                                 DiscoveryAnnouncement.flagPrivateCallAvailable | gattFlag(transport),
                                                 capabilitySummary: encodeMask & decodeMask, streamToken: 0, routeCost: 0)
            if rotatingIds && !rotating.visibleWindowActive {
                // Experimental: the role-0 rotating ID instead of the fixed prefix (compact v2).
                let entry = rotating.callEntry(nodeId: identity.nodeId)
                announcement?.nodeIdPrefix = entry.rdi; announcement?.rotating = true
                #if os(macOS)
                desktopCallPresence = .rotating(entry)
                #else
                rotating.pins.onAdvertised(entry, elapsedMs: RotatingDiscoveryRuntime.elapsedMs)
                advertisedEpoch = entry.epoch
                #endif
            }
        }
        #if os(macOS)
        desktopAdvertising.advertise(announcement, callPresence: desktopCallPresence)
        #else
        if boundarySilenceUntil != nil, announcement?.rotating == true || announcement?.isPrivateCallOffer == true { return }
        if rotatingIds && announcement?.rotating != true { rotating.pins.offAir(elapsedMs: RotatingDiscoveryRuntime.elapsedMs) }
        desktopAdvertisedName = desktopGeneratedNames ? announcement.flatMap { DesktopNearbyNames.shared?.name(for: $0)?.text } : nil
        radio.advertise(announcement, name: displayName)
        #endif
    }

    // MARK: Incoming links

    private func handleIncoming(_ link: MeshLink) {
        if let relay = callRelay, relay.awaitingParent { relay.attachParent(link); refreshAdvertising(); return }
        if let watch, watch.awaitingSource { watch.attach(link); refreshAdvertising(); return }
        if (call != nil || placingCall), availableForCalls, let identity,
           UserDefaults.standard.object(forKey: "callBusyDecline") as? Bool ?? true { declineBusy(link, identity: identity); return }
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

    /// Busy rule (Android F14): an incoming call while this phone is in a call or dialling finishes its handshake and
    /// is declined with BUSY before it rings; nothing is shown. (Android's glare exception, letting the person this
    /// phone is dialling ring, needs a second call controller and is not ported.)
    private var busyDrivers: [ObjectIdentifier: ConnectionDriver] = [:]
    private func declineBusy(_ link: MeshLink, identity: SigningIdentity) {
        let engine = CallEngine(role: .callee, transport: link.transport, identity: identity, requestedType: .voice,
                                encodeMask: VideoDecoderSupport.encodeMask, decodeMask: VideoDecoderSupport.decodeMask,
                                bmh3: bmh3Options(selected: nil))
        engine.declineAsBusy = true
        let driver = ConnectionDriver(engine: engine, link: link)
        let key = ObjectIdentifier(driver)
        driver.onFinished = { [weak self] reason in
            AppLog.event("call_collision", ["action": engine.declinedBusy ? "declined_busy" : "closed", "reason": reason])
            self?.busyDrivers[key] = nil
        }
        busyDrivers[key] = driver
        driver.start()
    }

    // MARK: Calls

    private var placingCall = false
    /// Last call problem, shown on the Call screen after the call screen closes ("Couldn't reach ...").
    @Published var callNotice: String? { didSet { if callNotice != oldValue { callRetry = nil } } }
    /// "Call again" on a "Couldn't reach" notice (Android 2026-10-21): the person and call type of the failed call.
    struct CallRetry: Equatable { let personId: UUID; let prefixHex: String?; let video: Bool; let name: String }
    @Published private(set) var callRetry: CallRetry?
    private var lastOutgoing: CallRetry?

    /// Calls the person from the last "Couldn't reach" notice again, through their current row when it still exists.
    func callAgain() {
        guard let retry = callRetry else { return }
        AppLog.event("call_again", ["video": "\(retry.video)"])
        callNotice = nil
        let person = people.first { $0.id == retry.personId } ?? retry.prefixHex.flatMap { prefix in people.first { $0.prefixHex == prefix } }
        if let person { startCall(to: person, type: retry.video ? .video : .voice) }
        else { callNotice = "\(retry.name) isn't nearby right now. Ask them to open MeshLive." }
    }

    /// Asks for the microphone (and camera for video) first, so the system prompt never interrupts media.
    /// A call is just a call with Mute; while muted, holding Mute talks (no separate push-to-talk mode).
    func startCall(to person: PersonRow, type: CallType) {
        guard call == nil, !placingCall, identity != nil else { return }
        placingCall = true; callNotice = nil
        let tappedAt = ProcessInfo.processInfo.systemUptime
        MediaPermissions.request(video: type == .video, context: "outgoing") { [weak self] _, _ in
            guard let self else { return }
            self.placingCall = false
            self.placeCall(to: person, type: type, tappedAt: tappedAt)
        }
    }

    private func placeCall(to person: PersonRow, type: CallType, tappedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard call == nil, let identity else { return }
        let retry = CallRetry(personId: person.id, prefixHex: person.prefixHex, video: type == .video, name: person.label.title)
        lastOutgoing = retry
        guard let peer = radio.peers[person.id], !(peer.announcement.rotating && peer.announcement.routeCost > 0) else {
            let text = "Couldn't reach \(person.label.title) \u{2013} they may have moved away."
            AppLog.event("call_end", ["reason": text, "error": "true", "stage": "not_nearby"])
            callNotice = text; callRetry = retry; return
        }
        #if os(macOS)
        guard !peer.announcement.rotating || desktopCallCompatibility.acceptsRotating else {
            callNotice = "This device uses changing nearby IDs. Enable Android compatibility in Settings > Experiments to call it."
            return
        }
        #endif
        let controller = CallController(model: self, role: .caller, peerName: person.label.title,
                                        peerPrefixHex: peer.announcement.rotating ? nil : person.prefixHex, identity: identity, transport: person.transport, type: type,
                                        relayHops: UInt8(min(Int(peer.announcement.routeCost), 15)),
                                        rotating: outgoingRotatingOptions(selected: peer.announcement),
                                        bmh3: bmh3Options(selected: peer.announcement))
        call = controller
        controller.startTimeline(origin: tappedAt)
        controller.markStage("permissions")
        refreshAdvertising()
        controller.phaseText = "Calling…"
        controller.markStage("connect")
        controller.connectHandle = radio.connect(to: person.id, transport: person.transport) { [weak self, weak controller] result in
            // The call ended while the link was connecting (the user cancelled, stage "stopped"): a late link is
            // closed at once and never handed on, and nothing is reported as "Couldn't reach".
            let stopped = { if case .failure(let error) = result { return (error as? RadioError)?.stage == "stopped" }; return false }()
            guard let controller, controller.ended == nil, !stopped else {
                if case .success(let link) = result { link.close(); AppLog.event("connect", ["stage": "late_link_closed"]) }
                self?.refreshAdvertising(); return
            }
            switch result {
            case .success(let link): controller.attach(link)
            case .failure(let error):
                let stage = (error as? RadioError)?.stage ?? "connect"
                controller.markStage("connect_failed")
                controller.failed("Couldn't reach \(person.label.title) \u{2013} they may have moved away.", stage: stage, detail: "\(error)")
            }
            self?.refreshAdvertising()
        }
        controller.connectHandle?.onStage = { [weak controller] stage in controller?.markStage(stage) }
    }

    /// Records the finished call in the local history (outgoing / incoming / missed).
    private func remember(_ controller: CallController) {
        guard !controller.closedBeforeRinging, let prefix = controller.peerPrefixHex else { return }
        let seconds = controller.activeSince.map { Int(Date().timeIntervalSince($0)) } ?? 0
        let direction: CallRecord.Direction = controller.role == .caller ? .outgoing : (controller.activeSince == nil ? .missed : .incoming)
        // Only a verified contact is kept by ID; anyone else by the generated name and the time (PROTOCOL "After the
        // reveal").
        let contact = contactName(prefixHex: prefix) != nil
        CallHistory.add(CallRecord(prefixHex: contact ? prefix : "", direction: direction, video: controller.callType == .video,
                                   at: Date(), seconds: seconds, name: contact ? nil : Self.generatedName(controller.label)))
        recentCalls = CallHistory.all
    }

    /// Same lookup as Android Contacts: a fixed ID, or one unambiguous call-offer recognition.
    /// Recognition only selects the route; startCall retains the authenticated selection and contact-tag checks.
    func nearbyPerson(for contact: VerifiedContact) -> PersonRow? {
        people.first { person in
            guard let offer = radio.peers[person.id]?.announcement, offer.rotating else {
                return person.prefixHex == contact.nodePrefixHex
            }
            let hits = rotating.vault.recognition.lookup(offer.nodeIdPrefix)
            return hits.count == 1 && hits[0].role == RotatingDiscoveryIds.roleCallOffer
                && contact.fingerprintHex.hasPrefix(hits[0].contact.hex)
        }
    }

    /// A generated nearby name (never a handle, a self-chosen name or "Nearby phone"), or nil.
    static func generatedName(_ label: PeerLabel?) -> String? {
        guard let label, label.handle.isEmpty, label.contactName == nil, label.selfName == nil, label.title != "Nearby phone" else { return nil }
        return label.title
    }

    /// Calls a recent contact back if their phone is nearby now.
    func callBack(_ record: CallRecord) {
        guard record.callable else { return }
        if let person = people.first(where: { $0.prefixHex == record.prefixHex }) {
            startCall(to: person, type: record.video ? .video : .voice)
        } else {
            let label = PeerLabel(prefix: Data(hex: record.prefixHex) ?? Data(count: 6), contactName: contactName(prefixHex: record.prefixHex))
            callNotice = "\(label.title) isn't nearby right now. Ask them to open MeshLive."
        }
    }

    func callFinished(_ controller: CallController) {
        // An older call's delayed dismissal must not clear a newer call's ringing alert.
        guard call === controller else { return }
        CallNotifier.shared.clear()
        if controller.activeSince != nil { CallNotifier.shared.requestIfAppropriate(.callEnded) }
        remember(controller)
        if controller.missedHere {
            // Call back and the caller's name only for a verified contact; anyone else is a generated name at most.
            let contact = controller.peerPrefixHex.flatMap { contactName(prefixHex: $0) } != nil
            CallNotifier.shared.postMissed(peerName: contact ? controller.label?.title : Self.generatedName(controller.label),
                                           stranger: controller.label == nil,
                                           prefixHex: contact ? controller.peerPrefixHex : nil, video: controller.offeredType == .video)
        }
        if controller.failedEarly, let ended = controller.ended {
            callNotice = ended
            if controller.role == .caller { callRetry = lastOutgoing }
        }
        call = nil
        refreshAdvertising()
    }

    // MARK: Watching

    /// Core Bluetooth's peripheral UUID is the advertising-address locator available to this app.
    func streamRouteKey(_ id: UUID, _ offer: DiscoveryAnnouncement) -> StreamRoutePenalties.Route {
        StreamRoutePenalties.Route(address: id.uuidString, prefixHex: offer.nodeIdPrefix.hex, routeToken: offer.streamToken)
    }
    func penalizeStreamRoute(_ route: StreamRoutePenalties.Route) {
        streamRoutePenalties.onMarkerMismatch(route, now: ConnectionDriver.now)
        rebuildLists()
    }

    func startWatching(_ row: StreamRow) {
        guard watch == nil, let identity else { return }
        let key = streamRouteKey(row.id, row.announcement)
        if let refusal = RotatingStreamPolicy.joinRefusal(offer: row.announcement, rotatingIds: rotatingIds) {
            AppLog.event("rotating_ids", ["event": "join_refused", "role": "viewer"])
            streamNotice = refusal
            return
        }
        guard !streamRoutePenalties.isPenalized(key, now: ConnectionDriver.now) else {
            streamNotice = "That route to the stream is temporarily unavailable. Try another one nearby."
            return
        }
        streamNotice = nil
        let controller = WatchController(model: self, identity: identity, offer: row.announcement, name: row.label.title, route: row.route, transport: row.announcement.transport ?? .gatt, routeKey: key)
        watch = controller
        refreshAdvertising()
    }

    func watchFinished(_ controller: WatchController) {
        guard watch === controller else { return }
        watch = nil
        let target = LogicalStreamTarget(controller.offer)
        if controller.joined {
            streamJoinRetry.onJoined(target)
        } else if !controller.stoppedByUser {
            // A join that never became active: say so, offer Try again, and retry once by itself (StreamJoinRetry).
            let auto = streamJoinRetry.onJoinFailed(target, now: ConnectionDriver.now)
            AppLog.event("stream_join", ["event": "failed", "autoRetry": "\(auto != nil)", "enabled": "\(AppSettings.streamJoinRetry)",
                                         "title": "\(controller.signedTitle != nil)"])
            if AppSettings.streamJoinRetry {
                streamNotice = StreamJoinRetry<LogicalStreamTarget>.failureMessage(title: controller.signedTitle)
                streamRetryTarget = target
            }
        }
        refreshAdvertising()
        takeStreamRetry()
    }

    /// Failed live joins (StreamJoinRetry; on, control arm `-streamJoinRetry NO`).
    let streamJoinRetry = StreamJoinRetry<LogicalStreamTarget>(enabled: { AppSettings.streamJoinRetry })
    /// Try again on "Couldn't join ...".
    @Published private(set) var streamRetryTarget: LogicalStreamTarget?
    /// The watch screen that is open (a retry joins only while it shows, never in the background).
    var watchScreenOpen = false { didSet { if !watchScreenOpen { streamJoinRetry.cancel(); streamRetryTarget = nil } } }

    func streamTryAgain() {
        guard let target = streamRetryTarget else { return }
        AppLog.event("stream_join", ["event": "try_again"])
        streamJoinRetry.onTryAgain(target, now: ConnectionDriver.now)
        streamNotice = nil; streamRetryTarget = nil
        takeStreamRetry()
    }

    /// Joins the pending retry's stream once it is listed (any route to the same logical stream).
    private func takeStreamRetry() {
        guard watchScreenOpen, watch == nil, call == nil, live == nil, streamJoinRetry.pending != nil else { return }
        guard let row = streamJoinRetry.take(now: ConnectionDriver.now, listed: streams, matches: { $0.matches($1.announcement) }) else { return }
        AppLog.event("stream_join", ["event": "retry", "route": row.route])
        streamNotice = nil; streamRetryTarget = nil
        startWatching(row)
    }

    // MARK: Going live

    func goLive(audioOnly: Bool = false, preset: UInt8 = AudioLive.presetVoice) {
        guard live == nil, let identity, !audioOnly || AppSettings.audioLive else { return }
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
        let before = rotating.vault.generation
        rotating.vault.setCanSeeMe(node, on, epoch: rotating.currentEpoch())
        objectWillChange.send()
        presenceRevoked(from: before)
    }
    /// After a revocation the advertised rotating ID must come from the new generation at once: until the next
    /// boundary the old one is still a valid ID for the revoked contacts to recognise.
    private func presenceRevoked(from before: UInt32) {
        // A revocation while the vault cannot be read changes no stored generation but drops the in-memory keys.
        guard rotating.vault.generation != before || !rotating.vault.persistent else { return }
        presenceGeneration = rotating.vault.generation
        refreshAdvertising()
    }
    /// "Reset presence key": a new generation; contacts recognise this phone again after the next mutual call.
    func resetPresenceKey() {
        rotating.vault.resetKey()
        presenceGeneration = rotating.vault.generation
        refreshAdvertising()
    }
    @Published var presenceGeneration: UInt32 = 0

    func forget(_ contact: VerifiedContact) {
        book.forget(contact.fingerprintHex); try? saveContacts()
        // A contact that holds this phone's lease: a new presence generation, so the old keys recognise nothing.
        if let node = Data(hex: String(contact.fingerprintHex.prefix(32))).flatMap({ try? NodeId(bytes: $0) }) {
            let before = rotating.vault.generation
            rotating.vault.forget(node, epoch: rotating.currentEpoch())
            presenceRevoked(from: before)
        }
    }

    func resetContacts() {
        VerifiedContactsStore.reset(); book.reset(); contacts = []; contactsUnreadable = nil
        // Former contacts must stop recognising this phone: their records go and any delivered lease is revoked
        // (a new presence generation), as Android's reset of the verified contacts.
        let before = rotating.vault.generation
        rotating.vault.resetContacts(epoch: RotatingDiscoveryIds.currentWallEpoch())
        presenceRevoked(from: before)
    }

    private func loadContacts() {
        switch VerifiedContactsStore.load() {
        case .loaded(let list): book.restore(list)
        case .empty: break
        case .unreadable(let reason): contactsUnreadable = reason
        }
        contacts = book.contacts
        // A contact forgotten or reset while the vault could not run is no longer a lease holder (Android
        // PresenceVault.reconcile). Only from a store that was read: an unreadable one says nothing about contacts.
        if contactsUnreadable == nil {
            rotating.vault.reconcile(verified: book.contacts.compactMap { nodeId(of: $0) }, epoch: RotatingDiscoveryIds.currentWallEpoch())
        }
    }

    private func saveContacts() throws {
        guard contactsUnreadable == nil else { throw ProtocolError.state("The verified-contact store is unreadable; reset it first") }
        try VerifiedContactsStore.save(book.contacts)
        contacts = book.contacts
        rebuildLists()
    }

    func myQrText() -> String? {
        guard let fingerprint else { return nil }
        let name = displayName.trimmingCharacters(in: .whitespaces).isEmpty ? (AppPlatform.isMac ? "Mac \(handle.prefix(5))" : "Phone \(handle.prefix(5))") : displayName
        return try? IdentityQrCodec.encode(IdentityQrPayload(fingerprint: fingerprint, displayName: name))
    }

    #if DEBUG
    /// Simulator fixture (`-NearbyFixture populated`): made-up people, streams and recent calls, in memory only
    /// (nothing is written to the call history), so every list state can be screenshot without radios.
    private(set) var debugFixtureActive = false
    func applyDebugFixture(_ name: String) {
        #if os(macOS)
        if name == "nearby-names" {
            debugFixtureActive = true
            desktopGeneratedNames = true
            people = ["44e69c0a7a7d", "67aba670e65a"].map { hex in
                let rdi = Data(hex: hex)!
                var offer = DiscoveryAnnouncement(nodeIdPrefix: rdi, flags: DiscoveryAnnouncement.flagPrivateCallAvailable,
                                                  capabilitySummary: 1, streamToken: 0, routeCost: 0)
                offer.rotating = true
                return PersonRow(id: UUID(), label: rotatingLabel(offer), prefixHex: hex, transport: .gatt, relays: 0, isIPhone: false)
            }
            people.append(PersonRow(id: UUID(), label: PeerLabel(prefix: Data(hex: "a1b2c3d4e5f6")!, contactName: "Asha"),
                                    prefixHex: "a1b2c3d4e5f6", transport: .gatt, relays: 0, isIPhone: false))
            rotatingIds = true
            desktopAdvertisedName = "mild bream"
            return
        }
        #endif
        guard name == "populated" else { return }
        debugFixtureActive = true
        if RootView.debugArgument("-NearbyBluetoothStuck") == "1" { bluetoothRestartNeeded = true }
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
            if let seconds = RootView.debugArgument("-NearbyFixtureMissAfter").flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak controller] in
                    if controller?.phase == .incomingRinging { controller?.debugCallerGaveUp() }
                }
            }
        case "call-active", "call-mismatch":
            controller.phase = .active; controller.activeSince = Date().addingTimeInterval(-83)
            controller.fingerprint = SoftwareSigningIdentity().fingerprint
            if variant == "call-mismatch" { controller.verification = .mismatch }
        case "call-ended":
            controller.phase = .ended; controller.ended = "Call ended"
        default:
            controller.phase = .outgoingRinging; controller.phaseText = "Ringing…"
        }
        controller.subject = RootView.debugArgument("-NearbyLegacySubject")
        call = controller
    }
    #endif

    // MARK: Emergency wipe

    func emergencyWipe() {
        #if os(macOS)
        desktopStopping = true
        desktopCallScanning.stop()
        desktopAdvertising.stop()
        #endif
        // The call is detached first, so its end never records, notifies or shows anything after the wipe.
        let ending = call; call = nil
        ending?.end(); watch?.stop(); live?.stop()
        radio.stopAll()
        streamRoutePenalties.reset(); streamNotice = nil
        audioRelayMemory.reset()
        bmh3Pins.clear()
        _ = EmergencyWipe.run()
        identity = nil; contacts = []; book.reset(); authenticated = [:]; people = []; streams = []; recentCalls = []
        wiped = true
    }
}
