import Foundation
import SwiftUI
import NearbyCore
#if canImport(NearbyMedia)
import NearbyMedia
#endif
#if os(macOS)
import CoreLocation
import CoreWLAN
#endif

#if os(macOS)
/// AW1: the one Location authorisation ask of the Mac "Join Wi-Fi Direct groups" switch.
private final class WifiLocationDelegate: NSObject, CLLocationManagerDelegate {
    var onAuthorization: ((CLAuthorizationStatus) -> Void)?
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { onAuthorization?(manager.authorizationStatus) }
}
#endif

struct PersonRow: Identifiable, Equatable {
    let id: UUID
    let label: PeerLabel
    let prefixHex: String
    let transport: MeshTransport
    let relays: Int
    let isIPhone: Bool
    /// Experimental relayed calls : an on-demand route through helpers, dialled at `hopRowId`.
    var relayRoute: RelayRoute? = nil
    var hopRowId: UUID? = nil
    /// Android copied-ID warning: this rotating ID is heard from more than one phone at once (local only, never sent).
    var copiedId = false
    /// One plain sentence: where the person is, never technical words.
    var routeText: String {
        if let relayRoute {
            // A reach page is a hint, not proof of identity (Android people_reach_relayed).
            return relayRoute.relays == 1 ? "Via 1 phone \u{00B7} not confirmed" : "Via \(relayRoute.relays) phones \u{00B7} not confirmed"
        }
        let place = relays == 0 ? "Nearby" : relays == 1 ? "Via 1 phone" : "Via \(relays) phones"
        return label.handle.isEmpty ? place : "\(place), ID \(label.shortHandle)"
    }
}

struct StreamRow: Identifiable, Equatable {
    let id: UUID
    let label: PeerLabel
    let announcement: DiscoveryAnnouncement
    /// Public title page (unconfirmed until the signed title arrives after joining).
    var advertisedTitle: String? = nil
    /// Android `supportsAdvertisedCodec` (`StreamPlayability`): false shows "This phone can't play it" and greys the row.
    var playable = true
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
    /// Android: a full or unplayable row cannot be opened (and recovery never picks it).
    var joinable: Bool { playable && !full }
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
    @Published var liveNotice: LiveNotice?
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
    /// AW1 (Experimental, off): "Use Wi-Fi for faster connections".
    @Published var wifiCarrier = AppSettings.wifiCarrier { didSet { AppSettings.wifiCarrier = wifiCarrier } }
    /// AW1 (Experimental, off): "Join Wi-Fi Direct groups" (Apple joins an Android host; it never hosts).
    @Published var wifiDirect = AppSettings.wifiDirect {
        didSet {
            AppSettings.wifiDirect = wifiDirect
            #if os(macOS)
            if wifiDirect && !oldValue { requestLocationForWifi() }
            #endif
        }
    }
    /// A Settings notice shown at the top of Connection (for example the Mac Location refusal).
    @Published var settingsNotice: String?
    #if os(macOS)
    private let wifiLocation = CLLocationManager()
    private let wifiLocationDelegate = WifiLocationDelegate()
    #endif
    /// AW1: both switches on and this platform can join a Wi-Fi Direct group now.
    var wifiDirectClientPossible: Bool {
        guard wifiCarrier, wifiDirect else { return false }
        #if os(iOS)
        #if HOTSPOT_ENTITLED
        return true
        #else
        return false
        #endif
        #else
        let status = wifiLocation.authorizationStatus
        let authorized = status == .authorizedAlways || status == .authorized
        return authorized && CWWiFiClient.shared().interface()?.powerOn() == true
        #endif
    }
    #if os(macOS)
    /// Asks for Location once when the Wi-Fi Direct switch goes on; a refusal leaves the switch off.
    private func requestLocationForWifi() {
        switch wifiLocation.authorizationStatus {
        case .notDetermined: wifiLocation.requestWhenInUseAuthorization()
        case .denied, .restricted:
            wifiDirect = false
            settingsNotice = "MeshLive needs Location to find Wi-Fi Direct networks on a Mac. It never reads your location."
        default: break
        }
    }
    #endif
    /// Set by three quick taps on a tab header (when the quick wipe is on): the root view asks to erase.
    @Published var askQuickWipe = false
    #if os(macOS)
    /// Mac Wi-Fi advice (Android withWifiCheck): the alert, the call or stream waiting for its answer, and the return from
    /// System Settings (`askWifiAdvice` and `answerWifiAdvice` in Desktop/MeshLiveApp.swift).
    @Published var wifiAdviceShown = false
    var wifiAdviceAction: (() -> Void)?
    var wifiResumeObserver: NSObjectProtocol?
    #endif
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
        MainStall.run("AppModel.appActivityChanged") {
            reloadBlockListIfNeeded()
            reconcileBlockedPresenceIfNeeded()
        }
        MainStall.run("CallNotifier.update") { CallNotifier.shared.update(for: call) }
    }
    @Published var wiped = false
    /// Generated nearby names (Android names-v2) on iPhone and Mac: always on, no Settings switch since 2026-11-04.
    /// A DEBUG launch argument or fixture may change it for one run; nothing is stored.
    @Published var desktopGeneratedNames = AppSettings.desktopGeneratedNames {
        didSet { rebuildLists(); refreshAdvertising() }
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
    /// Android "Calls unavailable" (`CallsEndpointWatch`): Allow calls is on and Bluetooth is ready, but the call service
    /// has not been hosted for 5 s. Nil while calls can reach this device.
    @Published private(set) var callsEndpointFault: CallsUnavailableReason?
    private var callsWatch = CallsEndpointWatch()
    /// What the chip, the status sheet, the Live card and the Mac menu show: nil with Allow calls off or the control arm
    /// `-callsUnavailableStatus NO`; DEBUG `-NearbyFixtureCallsUnavailable 1` forces it for UI tests and screenshots.
    var callsUnavailable: CallsUnavailableReason? {
        guard availableForCalls, AppSettings.callsUnavailableStatus else { return nil }
        #if DEBUG
        if RootView.debugArgument("-NearbyFixtureCallsUnavailable") == "1" { return .stalled }
        #endif
        return callsEndpointFault
    }
    /// Every 2 s after the restart guidance: a refused service is that guidance (Bluetooth problem), so it is not "wanted".
    func checkCallsAvailability() {
        let wanted = availableForCalls && radio.centralReady && !bluetoothRestartNeeded && bluetoothProblem == nil
        let fault = callsWatch.observe(enabled: AppSettings.callsUnavailableStatus, wanted: wanted,
                                       endpointReady: radio.peripheralReady, now: ProcessInfo.processInfo.systemUptime)
        guard fault != callsEndpointFault else { return }
        callsEndpointFault = fault
        AppLog.event("calls_status", ["kind": fault == nil ? "ready" : "callsUnavailable", "reason": fault?.rawValue ?? "-"])
    }
    /// "You appear as ..." (OwnNearbyName): what people nearby who have not added you see for this device now, or nil.
    var ownNearbyLine: String? {
        OwnNearbyName.shown(reachableForCalls: availableForCalls, rotatingOn: rotatingIds,
                            generatedNamesOn: desktopGeneratedNames, generatedName: desktopAdvertisedName.map(GeneratedNameText.display)).map(OwnNearbyName.line)
    }
    /// Rotating discovery IDs: always on, no Settings switch since 2026-11-04. DEBUG automation
    /// (`-NearbyRotatingIds 1|0`) or a fixture may change it for one run; nothing is stored.
    @Published var rotatingIds = AppSettings.rotatingIds {
        didSet {
            updateDiscoveryCompatibility()
            // A join or forwarder of a rotating stream started with the setting off advertises the fixed prefix:
            // stop it now that the setting hides that prefix (RotatingStreamPolicy).
            if let watch, let refusal = RotatingStreamPolicy.joinRefusal(offer: watch.offer, rotatingIds: rotatingIds, privateViewer: rotatingViewer) {
                AppLog.event("rotating_ids", ["event": "join_stopped", "role": "viewer"])
                watch.stop()
                streamNotice = refusal
            }
            if rotatingIds && !oldValue { reconcileBlockedPresenceIfNeeded() }
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
    /// Android compatibility: a DEBUG control arm only since 2026-11-04 (no Settings row).
    private let desktopAndroidCompatibility = AppSettings.desktopAndroidCompatibility
    private var desktopCallCompatibility: DesktopCallCompatibility {
        DesktopCallCompatibility(enabled: desktopAndroidCompatibility, rotatingIds: rotatingIds,
                                 hiddenIdentities: hiddenIdentities, pseudonyms: bmh3Pseudonyms)
    }
    #endif

    private func updateDiscoveryCompatibility() {
        configureRelayedCalls()
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
        let blocked: (IdentityFingerprint) -> Bool = { [weak self] in self?.isBlocked($0) ?? false }
        // Naming v2 (CodeOnlyLeaseRule): a contact only checked by code gets no new leases until scanned both ways.
        let codeOnly: (NodeId, IdentityFingerprint) -> Bool = { id, fp in
            let contact = book.contacts.first { $0.fingerprintHex == fp.hex }
            let holds = vault.deliveredTo(id) || vault.leaseKey(of: id.bytes, day: PresenceLeases.dayOf(runtime.currentEpoch())) != nil
            return CodeOnlyLeaseRule.blocked(method: contact?.method, scannedBothWays: contact?.scannedBothWaysAt != nil, holdsLease: holds)
        }
        options.presence = PresenceCallHooks(
            eligible: { id, fp in book.state(of: fp) == .verified && !blocked(fp) && vault.persistent && vault.canSeeMe(id) && !codeOnly(id, fp) },
            lease: { [weak self] id, fp in
                self?.reconcileBlockedPresenceIfNeeded()
                // A contact not yet asked ("Can see when I'm nearby") gets no lease, as no OFFER (decision 2026-11-06).
                return vault.deliverLease(to: id, epoch: runtime.currentEpoch(),
                                          verified: book.state(of: fp) == .verified && !blocked(fp) && vault.canSeeMe(id))
            },
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

    /// BMH3 "Hidden identities" and "Pseudonymous toward strangers": always on since 2026-11-04, as Android, with no
    /// Settings switch (DEBUG launch arguments `-experimentalBmh3 NO` and `-experimentalBmh3Pseudonyms NO` are the
    /// control arms).
    let hiddenIdentities = AppSettings.hiddenIdentities
    let bmh3Pseudonyms = AppSettings.bmh3Pseudonyms
    @Published var relayedCalls = AppSettings.relayedCalls {
        didSet { AppSettings.relayedCalls = relayedCalls; configureRelayedCalls(); refreshAdvertising(); rebuildLists() }
    }

    /// Relayed-call reach tables while "Relayed calls" is on; the rotating population only with rotating IDs on.
    func configureRelayedCalls() {
        guard let identity else { radio.configureRelayedCalls(on: false, rotating: false, ownPrefix: Data(), ownRdis: { [] }); return }
        let nodeId = identity.nodeId
        radio.configureRelayedCalls(on: relayedCalls, rotating: rotatingIds, ownPrefix: nodeId.prefix,
                                    // Poison reverse against the current and the previous RDI (a boundary may just have passed).
                                    ownRdis: { [weak self, identity] in self.map { Array($0.ownRelayIds(identity).dropFirst()) } ?? [] },
                                    directSightings: { !AppSettings.relayedNoDirect })
        if relayedCalls { observeRelayPowerChanges() }
        AppLog.event("relayed_calls", ["enabled": "\(relayedCalls)", "rotating": "\(relayedCalls && rotatingIds)", "consent": "\(relayedCalls)",
                                       "help": "false", "maxRelays": "\(RelayedCalls.defaultMaxRelays)"])
    }

    /// Relayed calls: routed rows for saved contacts with no direct offer, from the reach tables (only contacts are
    /// listed, as Android's default; a stranger several phones away is never shown).
    private func routedRows(direct: [PersonRow]) -> [PersonRow] {
        guard relayedCalls else { return [] }
        var rows: [PersonRow] = []
        let le: (DiscoveryAnnouncement) -> Bool = { $0.transport != nil && !$0.usesClassic }
        for (table, rotatingTable) in [(radio.reachFixed, false), (radio.reachRotating, true)] {
            guard let table else { continue }
            for target in table.relayedTargets(accept: le) {
                let contact: VerifiedContact?
                if rotatingTable {
                    let hits = rotating.vault.recognition.lookup(target)
                    contact = hits.count == 1 && hits[0].role == RotatingDiscoveryIds.roleCallOffer
                        ? contacts.first { $0.fingerprintHex.hasPrefix(hits[0].contact.hex) } : nil
                } else {
                    contact = contacts.first { $0.nodePrefixHex == target.hex }
                }
                guard let contact, !direct.contains(where: { $0.prefixHex == contact.nodePrefixHex }),
                      !rows.contains(where: { $0.prefixHex == contact.nodePrefixHex }),
                      let route = table.callerRoutes(target, accept: le).first(where: { $0.nextHop != nil }), let helper = route.nextHop,
                      let rowId = UUID(uuidString: "00000000-0000-000\(rotatingTable ? 1 : 0)-0000-\(target.hex)") else { continue }
                rows.append(PersonRow(id: rowId, label: PeerLabel(prefix: Data(hex: contact.nodePrefixHex) ?? target, contactName: contact.displayName),
                                      prefixHex: contact.nodePrefixHex, transport: route.hop.announcement.transport ?? .gatt, relays: route.relays,
                                      isIPhone: false, relayRoute: RelayRoute(target: target, helperPrefix: helper, relays: route.relays, rotating: rotatingTable),
                                      hopRowId: route.hop.peer))
            }
        }
        return rows
    }
    /// Kept for 30 days across restarts, as Android (a stripped hint cannot downgrade a pinned peer to BMH2).
    let bmh3Pins = Bmh3Pins(storage: DesktopPreview.enabled ? nil : Bmh3PinFile())
    /// The BMH3 options of one call, or nil (BMH2 only). Mac compatibility can use a per-attempt
    /// pseudonym for a selected rotating offer independently of this Mac's own advertising setting.
    /// The call listener's BMH3 options: RELAY_SEEK is signed while this device would admit a search (route search, Experimental).
    /// A busy listener still checks the code on screen, so a second phone using a consumed code raises the reuse alert.
    private func busyBmh3Options() -> Bmh3CallOptions? {
        var options = bmh3Options(selected: nil)
        options?.qrDisplay = meet.display
        return options
    }

    private func listenerBmh3Options() -> Bmh3CallOptions? {
        var options = bmh3Options(selected: nil)
        if relaySeekSigning { options?.relaySeek = RelaySeek.featureSeekV1 }
        // BVMID2: while a code is on screen its K_tag is one more tag check (one gate per connection).
        options?.qrDisplay = meet.display
        return options
    }

    func bmh3Options(selected: DiscoveryAnnouncement?) -> Bmh3CallOptions? {
        #if os(macOS)
        guard var options = desktopCallCompatibility.bmh3Options(selected: selected, pins: bmh3Pins) else { return nil }
        #else
        guard hiddenIdentities else { return nil }
        var options = Bmh3CallOptions(pseudonyms: bmh3Pseudonyms && rotatingIds, selected: selected, pins: bmh3Pins)
        options.pseudonymousRelayEdges = AppSettings.relayedPseudonymousEdges
        #endif
        if rotatingIds {
            // Phase 2: real keys between contacts through the lease-derived contact tag (Android protocol reference "Real lease keys").
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
    /// D1: this device's watch sessions with join keys (AppModel+Protocol.swift).
    let joinSessions = StreamJoinSessions(onClose: { keys, reason in AppModel.logJoinKeys(keys, .close, reason: reason.rawValue, role: .viewer) })
    /// Phase 1b viewer side (`AppSettings.rotatingViewer`, on): a rotating stream is joined with a role-2 request.
    let rotatingViewer = AppSettings.rotatingViewer
    /// The offer of the last finished join (the automatic retry keeps a rotating join on rotating routes).
    private var streamRetryOffer: DiscoveryAnnouncement?
    /// The end of a waiting viewer's boundary silence is already scheduled.
    private var viewerSilenceScheduled = false
    /// AB4: the end of this device's live offer's boundary silence is already scheduled.
    private var sourceSilenceScheduled = false
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
            self.radio.advertise(announcement, name: "")   // "Your name" never goes to the radio code (never broadcast)
        }, refresh: { [weak self] in self?.refreshAdvertising() })
    #endif

    private var reachTableEpoch: Int64?

    /// Phase 1b: the waiting viewer's compact v2 request for its selected rotating offer, or nil while the boundary
    /// silence runs (the end of the silence is scheduled once and recomputes the role and epoch).
    private func rotatingViewerAnnouncement(watch: WatchController, identity: SigningIdentity) -> DiscoveryAnnouncement? {
        let request = rotating.viewerRequest, vault = rotating.vault, node = identity.nodeId
        let now = RotatingDiscoveryRuntime.elapsedMs
        let epoch = rotating.currentEpoch()
        // D1: a join-key watch takes J's entries (AppModel+Protocol.swift).
        guard let entryFor = viewerRequestEntries(for: watch, epoch: epoch, presenceEntry: {
            vault.entry(nodeId: node, epoch: $0, role: RotatingDiscoveryIds.roleViewerRequest)
        }) else { return nil }
        let decision = request.decide(epoch: epoch, elapsedMs: now, entryFor: entryFor)
        switch decision {
        case .silent(let until):
            if !viewerSilenceScheduled {
                viewerSilenceScheduled = true
                let waitMs = max(0, until - now)
                AppLog.event("rotating_ids", ["event": "boundary", "role": "viewer", "silenceS": String(format: "%.1f", Double(waitMs) / 1000)])
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(waitMs) / 1000 + 0.05) { [weak self] in
                    self?.viewerSilenceScheduled = false
                    self?.refreshAdvertising()
                }
            }
            return nil
        case .advertise(let entry):
            do {
                return try RotatingViewerRequest.announcement(entry: entry, offer: watch.offer, transport: watch.transport)
            } catch {
                AppLog.event("rotating_ids", ["event": "request_refused", "role": "viewer"])
                return nil
            }
        }
    }

    /// AB4 (Experimental, `-rotatingSource`): this device's live offer. The fixed-prefix offer while the rotating arm is off
    /// or a Visible-by-handle window runs (version 2, as Android); otherwise this epoch's role-1 offer, or nil while its
    /// boundary silence runs (the end of the silence is scheduled once and recomputes the offer). Going back from the fixed
    /// form to the rotating one restarts it after a uniform 1-8 s silence, as at a boundary. `rotating` is true when the
    /// rotating form was asked for.
    private func liveOffer(_ live: LiveController, identity: SigningIdentity) -> (offer: DiscoveryAnnouncement?, rotating: Bool) {
        let rotatingForm = live.rotatingArm && !rotating.visibleWindowActive
        let now = RotatingDiscoveryRuntime.elapsedMs
        if rotatingForm, live.offerWasRotating == false {
            rotating.streamOffer.restart(elapsedMs: now)
        }
        live.offerWasRotating = rotatingForm
        guard rotatingForm else {
            return ((try? live.advertisedOffer(prefix: identity.nodeId.prefix, entry: nil)), false)
        }
        let vault = rotating.vault, node = identity.nodeId
        let epoch = rotating.currentEpoch()
        // AB4F: a revocation (also while the vault cannot be read) advances the revision, so the role-1 entry is rebuilt
        // at once instead of at the next epoch.
        let decision = rotating.streamOffer.decide(epoch: epoch, elapsedMs: now, generation: presenceKeyRevision) {
            vault.entry(nodeId: node, epoch: $0, role: RotatingDiscoveryIds.roleStreamOffer)
        }
        switch decision {
        case .silent(let until):
            if !sourceSilenceScheduled {
                sourceSilenceScheduled = true
                let waitMs = max(0, until - now)
                AppLog.event("rotating_ids", ["event": "boundary", "role": "stream", "silenceS": String(format: "%.1f", Double(waitMs) / 1000)])
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(waitMs) / 1000 + 0.05) { [weak self] in
                    self?.sourceSilenceScheduled = false
                    self?.refreshAdvertising()
                }
            }
            return (nil, true)
        case .advertise(let entry):
            do {
                return (try live.advertisedOffer(prefix: identity.nodeId.prefix, entry: entry), true)
            } catch {
                AppLog.event("rotating_ids", ["event": "offer_refused", "role": "stream"])
                return (nil, true)
            }
        }
    }

    /// At each epoch boundary: stop, stay silent a uniform 1-8 s, then advertise the new ID.
    private func checkRotation() {
        // Relayed calls: the rotating reach table flushes at this device's own boundary.
        if rotatingIds, radio.reachRotating != nil {
            let epoch = rotating.currentEpoch()
            if epoch != reachTableEpoch { if reachTableEpoch != nil { radio.reachRotating?.clear() }; reachTableEpoch = epoch }
        }
        // Phase 1b: a waiting viewer's rotating request follows its own boundary (stop, 1-8 s silence, new role-2
        // ID); `refreshAdvertising` asks `RotatingViewerRequest` and no call-presence silence is added on top.
        if rotatingIds, let watch, watch.awaitingSource,
           RotatingStreamPolicy.viewerRequest(offer: watch.offer, rotatingIds: rotatingIds, privateViewer: rotatingViewer) == .rotating {
            rotating.vault.rebuildRecognition(myEpoch: rotating.currentEpoch())
            refreshAdvertising()
            return
        }
        // AB4: a live source with the rotating arm follows its own boundary (stop, 1-8 s silence, new role-1 ID);
        // `refreshAdvertising` asks `RotatingStreamOffer` and no call-presence silence is added on top.
        if rotatingIds, let live, live.running, live.rotatingArm {
            rotating.vault.rebuildRecognition(myEpoch: rotating.currentEpoch())
            refreshAdvertising()
            return
        }
        #if os(macOS)
        guard rotatingIds, !desktopStopping else { return }
        // Reading the window on every check also expires a first-ever fixed-ID window. The
        // desktop scheduler decides whether the current role actually has anything to rotate.
        rotating.vault.rebuildRecognition(myEpoch: rotating.currentEpoch())
        refreshAdvertising()
        #else
        guard rotatingIds, advertisedEpoch >= 0, boundarySilenceUntil == nil else { return }
        guard rotating.currentEpoch() != advertisedEpoch else { return }
        // Phase 2: the recognition table follows the epoch.
        rotating.vault.rebuildRecognition(myEpoch: rotating.currentEpoch())
        let silence = Double.random(in: 1...8)
        // This boundary is handled now. A joined viewer advertises nothing, so refreshAdvertising never
        // moves the advertised epoch for it; without this the check repeats every tick for the whole watch.
        advertisedEpoch = rotating.currentEpoch()
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
    @Published var relayForOthers = StreamSourceGate(sourceRoles: ReleaseGates.sourceRoles).effectiveRelayForOthers(requested: AppSettings.relayForOthers) {
        didSet {
            if sourceGate.allowsForwarding { AppSettings.relayForOthers = relayForOthers }
            else if relayForOthers { relayForOthers = false }
        }
    }
    /// Settings › Manual video: read by each new call and broadcast (a running one keeps what it started with).
    @Published var videoRequest = AppSettings.videoRequest { didSet { AppSettings.videoRequest = videoRequest } }
    @Published var manualVideo = AppSettings.manualVideo {
        didSet {
            AppSettings.manualVideo = manualVideo
        }
    }
    /// Settings › Video quality (Android defaults: fill on, temperature off, heat limit on, freeze warning off).
    @Published var videoFill = AppSettings.videoFill { didSet { AppSettings.videoFill = videoFill } }
    @Published var showTemperature = AppSettings.showTemperature { didSet { AppSettings.showTemperature = showTemperature } }
    @Published var lowerQualityWhenHot = AppSettings.lowerQualityWhenHot { didSet { AppSettings.lowerQualityWhenHot = lowerQualityWhenHot; refreshHealth() } }
    @Published var viewerFreezeWarning = AppSettings.viewerFreezeWarning { didSet { AppSettings.viewerFreezeWarning = viewerFreezeWarning } }
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
    /// Android videoHealthNotice on call and live screens: too hot (critical), hot with the quality lowered, or a low battery.
    @Published var healthMessage: String?
    private var healthObservers: [NSObjectProtocol] = []
    /// This device's thermal state (`ProcessInfo.ThermalState` raw value 0-3). DEBUG
    /// `-NearbyThermalOverride nominal|fair|serious|critical` fixes it for one run (critical cannot be induced on purpose).
    var thermalState: Int {
        #if DEBUG
        switch RootView.debugArgument("-NearbyThermalOverride") {
        case "nominal": return 0
        case "fair": return 1
        case "serious": return 2
        case "critical": return 3
        default: break
        }
        #endif
        return ProcessInfo.processInfo.thermalState.rawValue
    }
    /// Android critical heat (`ThermalGuardPolicy.shouldBlockStreaming`): no video may run or start; calls are still
    /// placed and answered, as voice (decision 2026-11-06). Lifts as soon as the state is below critical.
    @Published private(set) var videoBlockedByHeat = false
    private var thermalVideo = ThermalVideoState()
    /// Lower quality when hot for call and broadcast encoders (read once a second while video runs): a hotter state at
    /// once, a cooler one after 30 s (Android `THERMAL_RECOVERY_DELAY_MS`).
    func videoHeatPercent() -> Int {
        thermalVideo.update(thermalState: thermalState, reduction: lowerQualityWhenHot, nowMs: Int(ProcessInfo.processInfo.systemUptime * 1000))
    }
    /// Android `status_too_hot` and the automatic stop text (the Mac says Mac).
    static var tooHotText: String {
        AppPlatform.isMac ? "Your Mac is too hot. Let it cool down before starting video." : "Your phone is too hot. Let it cool down before starting video."
    }
    static var stoppedHotText: String {
        AppPlatform.isMac ? "Stopped automatically: the Mac reached critical thermal stress." : "Stopped automatically: the phone reached critical thermal stress."
    }

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
        let thermal = thermalState
        #if os(iOS)
        let level = UIDevice.current.batteryLevel, charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        #else
        let level: Float = -1
        let charging = true
        #endif
        let blocked = ThermalVideoState.blocksVideo(thermalState: thermal, enabled: AppSettings.thermalCriticalStop)
        if blocked != videoBlockedByHeat {
            videoBlockedByHeat = blocked
            AppLog.event("device_thermal", ["blocked": "\(blocked)", "thermal": "\(thermal)"])
        }
        // Android videoHealthNotice: too hot at critical; "video quality lowered" while Lower quality when hot acts
        // (serious or hotter); then a battery at 20 % or less that is not charging.
        var message: String?
        if blocked {
            message = AppModel.tooHotText
        } else if lowerQualityWhenHot, ThermalVideoPolicy.percent(thermalState: thermal, reduction: true) < 100 {
            message = AppPlatform.isMac ? "Mac is hot, video quality lowered" : "Phone is hot, video quality lowered"
        } else if level >= 0, level <= 0.2, !charging {
            message = "Battery low, streaming uses extra power"
        }
        if message != healthMessage {
            healthMessage = message
            AppLog.event("device_health", ["thermal": "\(thermal)", "battery": String(format: "%.2f", level), "charging": "\(charging)", "message": message ?? "none"])
        }
    }
    /// Names and titles: always on since P5 (Android one name). DEBUG automation (`-NearbyLabels 0`) or the control arm
    /// `-experimentalPeerLabels NO` may turn them off for one run; nothing is stored.
    @Published var peerLabelsEnabled = AppSettings.peerLabels { didSet { radio.titlePages = peerLabelsEnabled } }
    /// "Who sees my name" (Settings, shown while a name is set). Read when a call starts.
    @Published var namesAudience = AppSettings.namesAudience { didSet { AppSettings.namesAudience = namesAudience } }
    /// Call blocking (Android CallBlocking): the sealed block list in memory; nil while it cannot be read (blocks nobody).
    @Published private(set) var blockList: BlockList? = nil
    /// True only when the stored list exists but is damaged; a locked Keychain is `.unavailable`, not damaged.
    @Published private(set) var blockListDamaged = false
    /// "Block list can't be read" with Reset, after a Block that could not be saved because the list is damaged (Android
    /// `showBlockListUnreadable`; decision 2026-11-06). A locked Keychain keeps the plain notice: nothing to reset.
    @Published var blockListUnreadableAlert = false
    /// "Block unknown callers" (Settings › Privacy), off by default.
    @Published var blockUnknownCallers = AppSettings.blockUnknownCallers { didSet { AppSettings.blockUnknownCallers = blockUnknownCallers } }
    /// "Declined. Block all unknown callers?" after a plain decline of a caller with a one-time ID.
    @Published var askBlockUnknown = false
    /// "Blocked and hidden on this phone." with Tell MeshLive, after a report.
    @Published var reportDone = false
    /// A stored call history this device cannot open now (Android `RecentCalls.isUnreadable`): Recent says so and offers
    /// Clear history; nothing writes over it by itself.
    @Published private(set) var recentUnreadable = false
    /// Android StrangerCallFollowup: "Add <name> as a contact?" after a call with someone who is not saved (their
    /// generated name or handle, in memory only; cleared when the next call is placed).
    @Published var strangerFollowUp: String?
    /// Routes (logical token + advertised ID) whose source authenticated as a blocked person: hidden for this run only.
    private var hiddenStreamRoutes: [String] = []
    /// Radio addresses of routes hidden by "Hide this livestream" whose advertised ID was not proven (AB3): this run only.
    private var hiddenStreamAddresses: Set<String> = []
    private var blockedReconciled = false
    private var blockListHolder = BlockListHolder(save: { BlockedPeopleFile.save($0) })
    /// The unreadable reason already logged, so every gate check on a locked list does not repeat it.
    private var loggedBlockListReason: String?
    private var blockListObservers: [NSObjectProtocol] = []
    /// The radio callbacks are wired: init's first block-list read must not rebuild the Live list before then.
    private var radioConfigured = false
    /// Title of the next broadcast (experimental labels).
    @Published var liveTitle = ""
    /// "Audio broadcast stopped" (Android audio_live_stopped_title) after a stop the user did not ask for.
    @Published var liveStoppedNotice: String?
    /// The title of that alert: "Audio broadcast stopped" (Android audio_live_stopped_title) unless heat stopped or
    /// refused a video live.
    @Published var liveStoppedTitle = "Audio broadcast stopped"
    /// Switch to video: the radio ended and a video live with the same title starts when it is gone.
    private var videoAfterRadio = false
    private var automation: Automation?

    /// Label options for a new call (nil only in a DEBUG run that turned names and titles off). The audience and the
    /// name-before-answer rule are read when the call starts.
    func callLabelOptions() -> CallLabelOptions? {
        guard peerLabelsEnabled else { return nil }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return CallLabelOptions(localName: name.isEmpty ? nil : name, audience: namesAudience,
                                nameBeforeAnswer: AppSettings.namesBeforeAnswer,
                                calleeNameAfterReveal: AppSettings.labSwitch("calleeNameAfterReveal", shipped: true),
                                isVerifiedPeer: { [weak self] in self?.book.state(of: $0) == .verified },
                                currentAudience: { AppSettings.namesAudience },
                                currentName: { [weak self] in
                                    guard let text = self?.displayName.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                                    return text
                                })
    }
    @Published var identityError: String?

    private(set) var identity: SigningIdentity!
    let radio = MeshRadio()
    let book = VerifiedContactBook()
    /// BVMID2 on the Add contact screen: the expiring one-use code, the scanner and the Design QL visit.
    lazy var meet: MeetController = { let meet = MeetController(); meet.model = self; return meet }()
    /// The role-0 rotating ID this device advertises right now (the ID a BVMID2 code names), or nil while none is on air.
    private(set) var meetRdi: Data?
    /// Fingerprints authenticated in this process, by node ID hex (last 1024), for marking contacts verified.
    private(set) var authenticated: [String: IdentityFingerprint] = [:]
    private var authenticatedOrder: [String] = []
    private var pruneTimer: Timer?

    var fingerprint: IdentityFingerprint? { identity?.fingerprint }
    var nodePrefixHex: String { identity?.nodeId.prefix.hex ?? "" }
    var identityPrefix: Data? { identity?.nodeId.prefix }
    /// Your handle (Crockford Base32 of your prefix), never raw hex.
    var handle: String {
        #if DEBUG
        if debugReadme { return "K7Q2M-X4PLA" }   // README fixture: an invented ID, never this device's
        #endif
        return identity.flatMap { IdentityHandle.handle(prefix: $0.nodeId.prefix) } ?? ""
    }
    var decodeMask: UInt8 { VideoDecoderSupport.decodeMask }
    var encodeMask: UInt8 { VideoDecoderSupport.encodeMask }

    init() {
        AppLog.start()
        // AB5: the HEVC/H.264 masters (Experimental, off) are fixed before any hello, header or decoder mask exists.
        HardwareCodecSwitches.apply()
        #if os(macOS)
        wifiLocation.delegate = wifiLocationDelegate
        wifiLocationDelegate.onAuthorization = { [weak self] status in
            guard let self, status == .denied || status == .restricted, self.wifiDirect else { return }
            self.wifiDirect = false
            self.settingsNotice = "MeshLive needs Location to find Wi-Fi Direct networks on a Mac. It never reads your location."
        }
        #endif
        let initBegan = ProcessInfo.processInfo.systemUptime
        var steps: [String: String] = ["propertiesMs": AppLog.ms(since: constructionBegan, until: initBegan)]
        var mark = initBegan
        func step(_ name: String) { let now = ProcessInfo.processInfo.systemUptime; steps[name] = AppLog.ms(since: mark, until: now); mark = now }
        defer { steps["initMs"] = AppLog.ms(since: initBegan); AppLog.event("startup", steps) }
        // A wipe resumed at launch finishes first; it does not latch, so this run can store a new identity.
        if EmergencyWipe.pending && !DesktopPreview.enabled { EmergencyWipe.run(userInitiated: false) }
        SealedRecords.migrateLegacy()
        recentCalls = CallHistory.all
        recentUnreadable = CallHistory.unreadable
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
        _ = DesktopNearbyNames.shared   // loads and installs the generated-name words for the reserved-name rule
        loadBlockList()
        #if os(iOS)
        blockListObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                                                                         object: nil, queue: .main) { [weak self] _ in
            MainStall.run("AppModel.protectedData") { self?.reloadBlockListIfNeeded() }
        })
        #endif
        // An identity mismatch is always refused (owner, 2026-11-04; Android has no warn-only choice).
        book.policy = .refuse
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
        radioConfigured = true
    }

    func start() {
        guard !DesktopPreview.enabled, identity != nil else { return }
        MainStall.start()
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
        // Android copied-ID warning (on) and its DEBUG control arms (test_copied_id_overlap, test_copied_id_pc_pair).
        radio.copiedIdWarning = AppSettings.labSwitch("copiedIdWarning", shipped: true)
        // SEC-B2: a stream hop whose end-to-end peer is not its link peer fails; DEBUG builds say so.
        StreamHopPeerBinding.debugLog = LabSwitch.isDebugBuild ? { AppLog.event("stream_peer_binding", $0) } : nil
        radio.copiedIds.requireOverlap = AppSettings.labSwitch("copiedIdOverlap", shipped: true)
        radio.copiedIds.pcPairExempt = AppSettings.labSwitch("copiedIdPcPair", shipped: true)
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
            self?.radio.prune(olderThan: 8); self?.checkBluetoothGuidance(); self?.checkCallsAvailability()
        }
        refreshAdvertising()
    }

    /// iOS cannot be discovered in the background (no local name, UUIDs in Apple's overflow area) and
    /// cannot use the camera there. An active call continues with audio (background modes audio and
    /// bluetooth-central/peripheral keep its link and audio session running), with this phone's video off.
    /// Everything else stops; foregrounding restarts discovery.
    func enterBackground() {
        MainStall.run("AppModel.enterBackground") {
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
    }

    func enterForeground() {
        MainStall.run("AppModel.enterForeground") {
            CallNotifier.shared.clear()
            configureCallAlerts()
            call?.enterForeground()
            start()
        }
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
        defer { takeStreamRetry(); takeViewerRecovery() }
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
            let generated = generatedCalls[p.announcement.nodeIdPrefix]   // iPhone and Mac (names-v2, with collision suffixes)
            return PersonRow(id: p.id, label: p.announcement.rotating ? rotatingLabel(p.announcement, generatedName: generated)
                        : PeerLabel(prefix: p.announcement.nodeIdPrefix, contactName: contactName(prefixHex: p.prefixHex)),
                      prefixHex: p.prefixHex, transport: p.announcement.transport ?? .gatt, relays: Int(p.announcement.routeCost), isIPhone: p.isIPhone)
        }
        people += routedRows(direct: people)
        // Android copied-ID warning (Design G): the row says so and a call from it asks first.
        let advertised = radio.peers
        people = people.map { row in
            guard let offer = advertised[row.id]?.announcement, offer.rotating, radio.copiedIds.warned(offer.nodeIdPrefix) else { return row }
            var flagged = row
            flagged.copiedId = true
            return flagged
        }
        resumeContactDialWait()
        // A malformed audio-only marker is never listed (Android StreamOfferKind.MALFORMED; Android lists it as video
        // with its switch off, this app refuses it either way). Audio-only offers are listed only with audio live on.
        let audioLive = AppSettings.audioLive
        streams = peers.filter {
            $0.announcement.isStreamOffer && !$0.announcement.usesClassic
                && ($0.announcement.streamOfferKind == .video || ($0.announcement.streamOfferKind == .audioOnly && audioLive))
                && !streamRoutePenalties.isPenalized(streamRouteKey($0.id, $0.announcement), now: ConnectionDriver.now)
        }.map { p in
            // iPhone and Mac: a rotating stream source shows its generated name (Android G2), never "Nearby phone".
            let label = p.announcement.rotating ? rotatingLabel(p.announcement, generatedName: generatedStreams[p.announcement.nodeIdPrefix])
                : PeerLabel(prefix: p.announcement.nodeIdPrefix, contactName: contactName(prefixHex: p.prefixHex))
            return StreamRow(id: p.id, label: label, announcement: p.announcement,
                             advertisedTitle: peerLabelsEnabled ? radio.titleBoard.title(routeToken: p.announcement.streamToken) : nil,
                             playable: StreamPlayability.playable(offer: p.announcement, decodeMask: videoDecodeMask, audioLive: audioLive))
        }
        // Call blocking (Android hideBlockedStreams): a blocked or reported person's broadcasts are hidden.
        let hiddenRoutes = hiddenStreamRoutes
        streams = BlockedStreams.hide(streams, offer: { $0.announcement }, blockedPrefixes: blockList?.hiddenPrefixes ?? [],
                                      hiddenRoutes: blockList?.reportedRoutes ?? [],
                                      recognised: { [weak self] offer in self?.recognisedContactPrefix(offer) },
                                      hiddenRoute: { hiddenRoutes.contains(BlockedStreams.routeKey($0)) },
                                      hiddenAddresses: hiddenStreamAddresses, address: { $0.id.uuidString })
        live?.viewerRequestsChanged(peers)
        watch?.viewerRequestsChanged(peers)
    }

    func contactName(prefixHex: String) -> String? { contacts.first { $0.nodePrefixHex == prefixHex }?.displayName }

    // MARK: Advertising (one kind at a time)

    #if os(macOS)
    /// A MeshLive window is visible (set by the reachability monitor); see the window-only advertising switch.
    var desktopWindowOpen = true {
        didSet {
            guard desktopWindowOpen != oldValue else { return }
            AppLog.event("desktop_window", ["open": "\(desktopWindowOpen)"])
            refreshAdvertising()
        }
    }
    #endif

    func refreshAdvertising() {
        guard !DesktopPreview.enabled, let identity else { return }
        #if os(macOS)
        guard !desktopStopping else { return }
        var desktopCallPresence: DesktopDiscoveryAdvertising.CallPresence?
        #endif
        let prefix = identity.nodeId.prefix
        radio.redactAdvertisedId = watch?.joinKeys != nil   // D1 (S1): a join-key watch's IDs are never logged
        let gattFlag = { (t: MeshTransport) in t == .gatt ? DiscoveryAnnouncement.flagGattTransport : 0 }
        var announcement: DiscoveryAnnouncement?
        // BVMID2: the role-0 ID the code names, only while it is really on air.
        var advertisedRdi: Data?
        // Phase 1b: this device's own role-2 request is what goes on air now.
        var viewerRequestOnAir = false
        // AB4: this device's own role-1 stream offer is what goes on air now.
        var streamOfferOnAir = false
        defer { meetRdi = radio.peripheralReady ? advertisedRdi : nil }
        if let relayOffer = callRelay?.parentOffer {
            // Experimental call relay: the callee's offer with route cost + 1 until one parent connects.
            announcement = relayOffer
        } else if let watch, !watch.awaitingSource, let forward = watch.forwardOffer,
                  RotatingStreamPolicy.mayForward(offer: watch.offer, rotatingIds: rotatingIds) {
            // Experimental forwarding: offer the stream onward until a child connects (one UUID at a time).
            announcement = forward
        } else if let watch, watch.awaitingSource {
            let offer = watch.offer
            switch RotatingStreamPolicy.viewerRequest(offer: offer, rotatingIds: rotatingIds, privateViewer: rotatingViewer) {
            case .fixedPrefix:
                if watch.joinKeys != nil { announcement = joinKeyVersionTwoRequest(watch); break }   // D1: nodeId(J)'s prefix
                announcement = DiscoveryAnnouncement(nodeIdPrefix: prefix, flags: DiscoveryAnnouncement.flagAcceptingConnections | gattFlag(watch.transport),
                                                     capabilitySummary: VideoCodecMap.compactSummary(helloMask: decodeMask), streamToken: offer.streamToken, routeCost: offer.routeCost,
                                                     streamBitrateKbps: offer.streamBitrateKbps)
            case .rotating:
                // Phase 1b: the request mirrors the rotating offer with this device's role-2 RDI (compact v2). Any
                // failure advertises nothing: a rotating stream never gets the fixed-prefix request.
                announcement = rotatingViewerAnnouncement(watch: watch, identity: identity)
                viewerRequestOnAir = announcement != nil
            case .refused:
                break   // (A rotating stream's fixed-prefix request is never advertised while rotating IDs are on.)
            }
        } else if let live, live.running {
            let (offer, rotatingOffer) = liveOffer(live, identity: identity)
            announcement = offer
            streamOfferOnAir = rotatingOffer && offer != nil
        } else if availableForCalls || meet.wantsCallReady, call == nil, watch == nil, callRelay == nil, relayDuty == nil {
            #if os(macOS)
            desktopCallPresence = .fixed
            #endif
            announcement = DiscoveryAnnouncement(nodeIdPrefix: prefix, flags: DiscoveryAnnouncement.flagAcceptingConnections |
                                                 DiscoveryAnnouncement.flagPrivateCallAvailable | gattFlag(transport),
                                                 capabilitySummary: VideoCodecMap.compactSummary(helloMask: encodeMask & decodeMask), streamToken: 0, routeCost: 0)
            if rotatingIds && !rotating.visibleWindowActive {
                // Experimental: the role-0 rotating ID instead of the fixed prefix (compact v2).
                let entry = rotating.callEntry(nodeId: identity.nodeId)
                announcement?.nodeIdPrefix = entry.rdi; announcement?.rotating = true
                advertisedRdi = entry.rdi
                #if os(macOS)
                desktopCallPresence = .rotating(entry)
                #else
                rotating.pins.onAdvertised(entry, elapsedMs: RotatingDiscoveryRuntime.elapsedMs)
                advertisedEpoch = entry.epoch
                #endif
            }
            // Relayed calls: the consent bit (this phone may be found and called through other phones).
            if relayedCalls, let offer = announcement {
                announcement = RelayedCalls.offerFor(offer, consentOn: relayedCallsConsent, helperActive: relayHelperActive, rotatingCompat: true)
            }
        }
        if !viewerRequestOnAir { rotating.viewerRequest.offAir(elapsedMs: RotatingDiscoveryRuntime.elapsedMs) }
        if !streamOfferOnAir { rotating.streamOffer.offAir(elapsedMs: RotatingDiscoveryRuntime.elapsedMs) }
        #if os(macOS)
        if desktopCallPresence != nil, !desktopWindowOpen,
           DesktopPreview.preferences.bool(forKey: DesktopReachabilitySettings.advertiseOnlyWithWindowKey) {
            // Experimental window-only advertising: no idle call offer while every MeshLive window is closed.
            announcement = nil; desktopCallPresence = nil; advertisedRdi = nil
        }
        desktopAdvertising.advertise(announcement, callPresence: desktopCallPresence)
        #else
        // The call boundary silence holds call offers only (a waiting viewer's request has its own silence).
        if boundarySilenceUntil != nil, announcement?.isPrivateCallOffer == true { advertisedRdi = nil; return }
        if rotatingIds && (announcement?.rotating != true || viewerRequestOnAir || streamOfferOnAir) {
            rotating.pins.offAir(elapsedMs: RotatingDiscoveryRuntime.elapsedMs)
        }
        desktopAdvertisedName = desktopGeneratedNames ? announcement.flatMap { DesktopNearbyNames.shared?.name(for: $0)?.text } : nil
        radio.advertise(announcement, name: "")   // "Your name" never goes to the radio code (never broadcast)
        #endif
    }

    // MARK: Incoming links

    private func handleIncoming(_ link: MeshLink) {
        if let relay = callRelay, relay.awaitingParent { relay.attachParent(link); refreshAdvertising(); return }
        if let watch, watch.awaitingSource { watch.attach(link); refreshAdvertising(); return }
        if (call != nil || placingCall || relayDuty != nil || contactDialWait != nil), availableForCalls, let identity,
           AppSettings.labSwitch("callBusyDecline", shipped: true) { declineBusy(link, identity: identity); return }
        // BVMID2: a shown code makes the device call-ready for the screen's lifetime (then only the code is accepted).
        // A scan in progress holds the radio as a call would.
        guard call == nil, availableForCalls || meet.wantsCallReady, !meet.scanInProgress, let identity else { link.close(); return }
        let pins = rotating.pins
        let controller = CallController(model: self, role: .callee, peerName: "Incoming call", peerPrefixHex: nil,
                                        identity: identity, transport: link.transport, type: .video, relayHops: 0,
                                        rotating: rotatingIds ? withPresence(RotatingCallOptions(entries: { pins.pinned(elapsedMs: RotatingDiscoveryRuntime.elapsedMs) })) : nil,
                                        bmh3: listenerBmh3Options(),
                                        relayed: relayedCalls ? RelayedCallOptions(featureOn: true, helperActive: relayHelperActive,
                                                                                   acceptRdi: rotatingIds) : nil)
        call = controller
        controller.attach(link)
        refreshAdvertising()
    }

    /// Busy rule (as Android): an incoming call while this device is in a call, dialling or relaying finishes its
    /// handshake as an ordinary (hidden) callee and is declined with BUSY before it rings. Glare (DialCollision): when
    /// the caller is the very person being dialled, their call rings instead and the user's own dial stops; whichever
    /// Invite arrives first while the other is still looking becomes the call. `-dialCollisionRing NO` is the control arm.
    private var busyControllers: [CallController] = []
    var dialSuperseded = false
    private var pendingDialTarget: String?

    private func declineBusy(_ link: MeshLink, identity: SigningIdentity) {
        let pins = rotating.pins
        let controller = CallController(model: self, role: .callee, peerName: "Incoming call", peerPrefixHex: nil,
                                        identity: identity, transport: link.transport, type: .video, relayHops: 0,
                                        rotating: rotatingIds ? withPresence(RotatingCallOptions(entries: { pins.pinned(elapsedMs: RotatingDiscoveryRuntime.elapsedMs) })) : nil,
                                        bmh3: busyBmh3Options(),
                                        relayed: relayedCalls ? RelayedCallOptions(featureOn: true, acceptRdi: rotatingIds) : nil)
        controller.configureBusy { [weak self, weak controller] caller in
            guard let self, let controller else { return false }
            return self.glareRings(controller, caller: caller)
        }
        busyControllers.append(controller)
        controller.attach(link)
    }

    /// Android `call_busy_declined` / `call_busy_declined_while_dialling`: who was told this device is busy while it was
    /// still dialling (a busy decline during a call says nothing, as Android). Only a verified contact is named; anyone
    /// else is "Someone nearby".
    private func noteBusyDeclined(_ controller: CallController) {
        guard controller.declinedBusy, ownDial().dialling else { return }
        let caller = controller.verification == .verified ? (controller.label?.title ?? OwnNearbyName.someoneNearby) : OwnNearbyName.someoneNearby
        let dialling = contactDialWait?.contact.displayName ?? (call?.isConnecting == true ? call?.peerName : nil)
        if let dialling {
            callNotice = "\(caller) called while you were calling \(dialling). They were told you are busy; your call goes on."
        } else {
            callNotice = "\(caller) called while you were dialling. They were told you are busy."
        }
        AppLog.event("call_collision", ["action": "busy_notice"])
    }

    /// This device's own dial while it is still looking for its person, and that person's real prefix when known.
    private func ownDial() -> (dialling: Bool, target: String?) {
        if placingCall { return (true, pendingDialTarget) }
        if let c = call, c.isConnecting { return (true, c.dialTargetPrefixHex) }
        if let wait = contactDialWait { return (true, wait.contact.nodePrefixHex) }
        return (false, nil)
    }

    /// The real prefix of the person a row dials: a fixed prefix, or the contact a rotating or routed row stands for.
    func dialTarget(for person: PersonRow) -> String? {
        if person.relayRoute != nil { return person.prefixHex }
        guard let offer = radio.peers[person.id]?.announcement, offer.rotating else { return person.prefixHex }
        let hits = rotating.vault.recognition.lookup(offer.nodeIdPrefix)
        guard hits.count == 1 else { return nil }
        return contacts.first { $0.fingerprintHex.hasPrefix(hits[0].contact.hex) }?.nodePrefixHex
    }

    private func glareRings(_ controller: CallController, caller: NodeId?) -> Bool {
        let enabled = AppSettings.labSwitch("dialCollisionRing", shipped: true)
        let own = ownDial()
        let action = enabled ? DialCollision.decide(dialling: own.dialling, target: own.target, callerPrefix: caller?.prefix.hex) : .declineBusy
        AppLog.event("call_collision", ["action": action == .ring ? "their_call_rings" : "declined_busy", "dialling": "\(own.dialling)",
                                        "callerKnown": "\(caller != nil)"])
        guard action == .ring else { return false }
        // Their call is the conversation: the user's own dial stops, and this listener becomes the call.
        if let own = call, own !== controller { own.userCancelled = true; own.end() }
        if placingCall { dialSuperseded = true }
        contactDialWait = nil
        seekAttempt = nil
        busyControllers.removeAll { $0 === controller }
        controller.busyMode = false
        call = controller
        AppLog.event("call_invite", ["state": "cancelled", "reason": "target_called_first"])
        refreshAdvertising()
        return true
    }

    // MARK: Calls

    var placingCall = false
    /// Last call problem, shown on the Call screen after the call screen closes ("Couldn't reach ...").
    @Published var callNotice: String? { didSet { if callNotice != oldValue { callRetry = nil } } }
    /// B1.3: a placing refusal, shown above Nearby; "Open settings" only when Settings can change it.
    @Published var callAccessNotice: String?
    @Published var callAccessNoticeOpensSettings = false
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
        relayDuty?.preempt()   // the user's own activity ends a relay at once
        guard call == nil, !placingCall, identity != nil else { return }
        // Calls at critical heat (decision 2026-11-06): the call is placed; a video call goes on as voice.
        let callType = ThermalVideoState.callType(type, videoBlocked: videoBlockedByHeat)
        #if os(macOS)
        // Android withWifiCheck: a video call on 2.4 GHz Wi-Fi asks first (never a voice call, nor one that heat turned
        // into voice: the advice comes after the existing guards).
        if askWifiAdvice(voice: callType != .video, { [weak self] in self?.startCall(to: person, type: type) }) { return }
        #endif
        placingCall = true; callNotice = nil; callAccessNotice = nil; callAccessNoticeOpensSettings = false; strangerFollowUp = nil
        if callType != type { AppLog.event("call_thermal", ["event": "video_call_placed_as_voice_critical"]); callNotice = AppModel.tooHotText }
        pendingDialTarget = dialTarget(for: person); dialSuperseded = false
        let tappedAt = ProcessInfo.processInfo.systemUptime
        MediaPermissions.request(video: callType == .video, context: "outgoing") { [weak self] _, _ in
            self?.finishStartCall(to: person, type: callType, tappedAt: tappedAt)
        }
    }

    func placeCall(to person: PersonRow, type: CallType, tappedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard call == nil, let identity else { return }
        if person.relayRoute != nil { placeRelayedCall(to: person, type: type, tappedAt: tappedAt, identity: identity); return }
        let retry = CallRetry(personId: person.id, prefixHex: person.prefixHex, video: type == .video, name: person.label.title)
        lastOutgoing = retry
        guard let peer = radio.peers[person.id], !(peer.announcement.rotating && peer.announcement.routeCost > 0) else {
            let text = "Couldn't reach \(person.label.title) \u{2013} they may have moved away."
            AppLog.event("call_end", ["reason": text, "error": "true", "stage": "not_nearby"])
            callNotice = text; callRetry = retry; return
        }
        #if os(macOS)
        guard !peer.announcement.rotating || desktopCallCompatibility.acceptsRotating else {
            callNotice = "This device uses changing nearby IDs, which this test run has turned off."
            return
        }
        #endif
        let controller = CallController(model: self, role: .caller, peerName: person.label.title,
                                        peerPrefixHex: peer.announcement.rotating ? nil : person.prefixHex, identity: identity, transport: person.transport, type: type,
                                        relayHops: UInt8(min(Int(peer.announcement.routeCost), 15)),
                                        rotating: outgoingRotatingOptions(selected: peer.announcement),
                                        bmh3: bmh3Options(selected: peer.announcement),
                                        relayed: relayedCalls ? RelayedCallOptions(featureOn: true) : nil)
        controller.dialTargetPrefixHex = dialTarget(for: person)
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

    // MARK: Experimental relayed calls, caller

    /// One relayed dial's candidate routes (Android RelayCandidates): at most 3 helpers within 60 s of the tap.
    private struct RelayCandidates { var person: PersonRow; let type: CallType; let tappedAt: TimeInterval; var tried: [Data]; var firstDialAt: TimeInterval }
    /// Android RelayCandidatePolicy.mayTryNext: another route only while the first dial is at most 40 s old.
    static let relayCandidateWindow: TimeInterval = 40
    private var relayCandidates: RelayCandidates?

    private func placeRelayedCall(to person: PersonRow, type: CallType, tappedAt: TimeInterval, identity: SigningIdentity) {
        guard relayedCalls, let route = person.relayRoute, let hopRow = person.hopRowId, let hop = radio.peers[hopRow]?.announcement,
              RelayedCalls.isRelayHelperOffer(hop, rotating: route.rotating) else {
            callNotice = "Couldn't reach \(person.label.title) \u{2013} the phone that could pass the call on has moved away."
            AppLog.event("relayed_setup", ["role": "caller", "result": "failed", "reason": "no_helper_offer"]); return
        }
        if relayCandidates?.person.prefixHex != person.prefixHex || relayCandidates?.tappedAt != tappedAt {
            relayCandidates = RelayCandidates(person: person, type: type, tappedAt: tappedAt, tried: [], firstDialAt: ProcessInfo.processInfo.systemUptime)
        }
        relayCandidates?.tried.append(route.helperPrefix)
        let selected = RelayedCalls.routedAnnouncement(target: route.target, cost: route.relays, hop: hop)
        var bmh3 = bmh3Options(selected: selected)
        bmh3?.relayHop = hop
        let controller = CallController(model: self, role: .caller, peerName: person.label.title,
                                        peerPrefixHex: route.rotating ? nil : route.target.hex, identity: identity, transport: hop.transport ?? .gatt,
                                        type: type, relayHops: UInt8(route.relays),
                                        rotating: route.rotating ? outgoingRotatingOptions(selected: selected) : nil, bmh3: bmh3,
                                        // Each candidate gets its own 20 s SETUP clock, started now (after permissions), review item 4.
                                        relayed: RelayedCallOptions(featureOn: true, route: route, pseudonymousEdges: AppSettings.relayedPseudonymousEdges,
                                                                    setupStartedAt: ProcessInfo.processInfo.systemUptime))
        controller.relayRoute = route
        controller.dialTargetPrefixHex = person.prefixHex
        lastOutgoing = CallRetry(personId: person.id, prefixHex: person.prefixHex, video: type == .video, name: person.label.title)
        call = controller
        controller.startTimeline(origin: tappedAt)
        refreshAdvertising()
        controller.phaseText = "Calling…"
        AppLog.event("relayed_setup", ["role": "caller", "result": "dialing", "budget": "\(route.relays)", "rotating": "\(route.rotating)",
                                       "attempt": "\(relayCandidates?.tried.count ?? 1)"])
        controller.markStage("connect")
        controller.connectHandle = radio.connect(to: hopRow, transport: hop.transport ?? .gatt) { [weak self, weak controller] result in
            let stopped = { if case .failure(let error) = result { return (error as? RadioError)?.stage == "stopped" }; return false }()
            guard let controller, controller.ended == nil, !stopped else {
                if case .success(let link) = result { link.close() }
                self?.refreshAdvertising(); return
            }
            switch result {
            case .success(let link): controller.attach(link)
            case .failure(let error):
                controller.relayConnectFailed = true
                controller.failed("Couldn't reach \(person.label.title) \u{2013} the phone that could pass the call on did not answer.",
                                  stage: (error as? RadioError)?.stage ?? "connect", detail: "\(error)")
            }
            self?.refreshAdvertising()
        }
        controller.connectHandle?.onStage = { [weak controller] stage in controller?.markStage(stage) }
    }

    /// A relayed route's outcome feeds the reach table; a route that failed before READY hands over to the next
    /// candidate (at most 3 helpers within 60 s of the tap). Returns true when another route was dialled.
    private func relayedOutcome(_ controller: CallController) -> Bool {
        guard let route = controller.relayRoute else { return false }
        if route.seek != nil { return seekOutcome(controller, route: route) }
        let table = route.rotating ? radio.reachRotating : radio.reachFixed
        if controller.userCancelled { relayCandidates = nil; return false }   // the user's own end says nothing about the route
        if controller.relayReady {
            // Review item 3: READY is a relay's claim; the entry is proven only once the end-to-end peer was verified.
            if controller.endToEndVerified { table?.markUsed(relay: route.helperPrefix, target: route.target) }
            else { table?.markFailed(relay: route.helperPrefix, target: route.target, noRoute: false) }
            relayCandidates = nil
            return false
        }
        let failure = controller.relayFailure
        table?.markFailed(relay: route.helperPrefix, target: route.target, noRoute: failure == .noRoute)
        AppLog.event("relayed_setup", ["role": "caller", "result": "failed", "budget": "\(route.relays)", "reason": failure?.label ?? "invalid"])
        guard var candidates = relayCandidates, controller.userCancelled == false, candidates.tried.count < RelayedCalls.maxCandidates,
              ProcessInfo.processInfo.systemUptime - candidates.firstDialAt <= Self.relayCandidateWindow,
              let identity, let table else { relayCandidates = nil; return false }
        let le: (DiscoveryAnnouncement) -> Bool = { $0.transport != nil && !$0.usesClassic }
        guard let next = table.callerRoutes(route.target, accept: le).first(where: { r in r.nextHop.map { h in !candidates.tried.contains(h) } ?? false }),
              let helper = next.nextHop else { relayCandidates = nil; return false }
        var person = candidates.person
        person.relayRoute = RelayRoute(target: route.target, helperPrefix: helper, relays: next.relays, rotating: route.rotating)
        person.hopRowId = next.hop.peer
        candidates.person = person
        relayCandidates = candidates
        AppLog.event("relayed_setup", ["role": "caller", "result": "next_candidate", "attempt": "\(candidates.tried.count + 1)"])
        call = nil
        placeRelayedCall(to: person, type: candidates.type, tappedAt: candidates.tappedAt, identity: identity)
        return true
    }

    // MARK: Experimental relayed calls, helper

    @Published var relayedCallsConsent = AppSettings.relayedCallsConsent {
        didSet { AppSettings.relayedCallsConsent = relayedCallsConsent; refreshAdvertising() }
    }
    @Published var relayedCallsHelp = AppSettings.relayedCallsHelp {
        didSet { AppSettings.relayedCallsHelp = relayedCallsHelp; refreshAdvertising() }
    }
    /// The relayed call this device is passing on (at most one, protocol rule).
    @Published var relayDuty: RelayDutyController?
    private let relaySetupLimiter = RelaySetupRateLimiter()

    /// Android `relayAutoPaused`: Relay video for others does not forward a join started below 20 % battery while not
    /// charging, or in Low Power Mode (Android Battery Saver; the Mac reads no battery, so only Low Power Mode). Control
    /// arm `-relayBatteryPause NO`; DEBUG `-NearbyFixtureRelayPaused 1` forces the pause for screenshots.
    var relayBatteryPaused: Bool {
        #if DEBUG
        if RootView.debugArgument("-NearbyFixtureRelayPaused") == "1" { return true }
        #endif
        guard AppSettings.relayBatteryPause else { return false }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        return RelayBatteryPause.paused(batteryPercent: level < 0 ? -1 : Int((level * 100).rounded()), charging: charging, lowPowerMode: lowPower)
        #else
        return RelayBatteryPause.paused(batteryPercent: -1, charging: true, lowPowerMode: lowPower)
        #endif
    }

    /// Android `watch_status_relaying_battery` while this device passes a stream on (the Mac reads no battery).
    var relaySharingText: String {
        #if os(iOS)
        let level = UIDevice.current.batteryLevel
        if level >= 0 { return "Sharing with phones near you, battery \(Int((level * 100).rounded()))%" }
        #endif
        return "Sharing with phones near you"
    }

    /// Why helping is paused (battery, Low Power Mode or heat, as Android RelayHelperPolicy), or nil.
    var relayHelperPause: String? {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "low power mode" }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return "thermal"
        default: break
        }
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        if level >= 0 && level < 0.2 && UIDevice.current.batteryState == .unplugged { return "low battery" }
        #endif
        return nil
    }

    /// This device helps right now: relayed calls and Help on, idle (no call, stream, relay or dial), not paused; with
    /// searches on, not after 60 s of exhausted search budgets.
    var relayHelperActive: Bool {
        relayedCalls && relayedCallsHelp && relayHelperPause == nil && call == nil && watch == nil && live == nil
            && callRelay == nil && relayDuty == nil && !placingCall
            && !(AppSettings.relayedOnDemand && relaySeekBudgets.withdrawHelperFlag(now: MeshRadio.reachClockMs))
    }

    /// Power, heat and battery changes can pause or resume helping: the call offer's helper flag follows (review item 10).
    private var relayPowerObservers: [NSObjectProtocol] = []
    func observeRelayPowerChanges() {
        guard relayPowerObservers.isEmpty else { return }
        var names: [Notification.Name] = [.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification]
        #if os(iOS)
        names += [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification]
        #endif
        relayPowerObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.relayedCalls else { return }
                self.refreshAdvertising()
            }
        }
    }

    /// A helper listener read SETUP or SEEK as its first record: admit it in protocol order (RelayHelperGate), take over
    /// the link and dial the next hop from this device's own table, search for the target, or answer FAIL.
    func relaySetupRequested(by controller: CallController, message: RelaySetupMessage) {
        guard let request = RelayHelperDuty.Request(message), let identity,
              call === controller, let (link, engine) = controller.abandonForRelay() else { controller.end(); return }
        #if os(macOS)
        desktopCallLinkFinished(controller)
        #endif
        call = nil
        let now = ConnectionDriver.now
        let nowMs = MeshRadio.reachClockMs
        let parent = CallRelayLink(adopting: engine)
        // Call blocking (Android security review item 14): this device relays nothing for a blocked person (a real-key
        // parent; a throwaway parent cannot be matched).
        if !parent.linkPeerPseudonymous, let parentId = parent.peerLinkNodeId, isBlockedNode(parentId) {
            AppLog.event("call_blocking", ["event": "relay_refused", "reason": "blocked_person"])
            link.close()
            refreshAdvertising()
            return
        }
        let edges = AppSettings.relayedPseudonymousEdges
        // Facts first, then one decision (review items 1 and 10).
        var f = RelayHelperGate.Facts()
        f.isSeek = request.seek != nil
        f.rotatingRequest = request.rotating
        // SETUP and SEEK only from a parent whose link hello signed bit 4 ("understands RELAY_SETUP").
        f.featureOn = relayedCalls && parent.peerLinkCapabilities.map(RelayedCalls.linkUnderstandsSetup) == true
        f.helpAllowed = relayedCallsHelp
        f.onDemand = AppSettings.relayedOnDemand
        f.paused = relayHelperPause
        // Busy is recomputed now: another duty, a stream or this device's own dial.
        f.busy = relayDuty != nil || watch != nil || live != nil || callRelay != nil || placingCall
        f.rotatingHelper = rotatingIds
        f.pseudonymousEdges = edges
        f.pseudonymousParent = parent.linkPeerPseudonymous
        f.parentPrefixHex = parent.peerLinkNodeId?.prefix.hex ?? ""
        f.parentPeerIdentifier = link.peerIdentifier
        let ownIds = ownRelayIds(identity)
        f.targetIsSelf = ownIds.contains(request.target)
        f.parentIsSelf = parent.peerLinkNodeId == identity.nodeId
        f.parentIsTarget = !parent.linkPeerPseudonymous && parent.peerLinkNodeId?.prefix == request.target
        f.budget = request.budget
        f.maxRelays = RelayedCalls.defaultMaxRelays
        let table = request.rotating ? radio.reachRotating : radio.reachFixed
        let sameBearer: (DiscoveryAnnouncement) -> Bool = { $0.transport == link.transport }
        var route: ReachRoute<UUID>?
        let decision = RelayHelperGate.decide(f, remainingMs: request.remainingMs, limiter: relaySetupLimiter, budgets: relaySeekBudgets, nowMs: nowMs) {
            route = table?.setupRoute(request.target, budget: request.budget, accept: sameBearer)
            return route != nil
        }
        var allowance: Int?
        if case .search(let a) = decision { allowance = a }
        let duty = RelayHelperDuty(identity: identity, transport: link.transport, parent: parent, request: request, now: now,
                                   allowanceMs: allowance, pseudonymousEdges: edges)
        let relay = RelayDutyController(model: self, duty: duty, parentLink: link)
        relayDuty = relay
        refreshAdvertising()
        switch decision {
        case .refuse(let reason, let why):
            AppLog.event(f.isSeek ? "relayed_seek" : "relayed_setup", ["role": "helper", "result": "refused", "budget": "\(request.budget)",
                                                                       "reason": reason.label, "why": why])
            relay.refuse(reason)
        case .search:
            serveSearch(relay: relay, duty: duty, bearer: link.transport, identity: identity, plain: f.isSeek ? nil : request.target)
        case .setup(let key, let admittedAt):
            guard let route else { relay.refuse(.noRoute); return }
            // Only abusive traffic pays: a setup that reached READY and satisfied the chain guard gets its token back.
            let limiter = relaySetupLimiter
            relay.onClosed = { duty in if duty.readyRelays != nil && duty.chainGuardSatisfied { limiter.refund(key, admittedAtMs: admittedAt) } }
            let next = RelayHelperDuty.NextHop(hopPrefix: route.nextHop, nextBudget: route.nextHop == nil ? 0 : request.budget - 1)
            AppLog.event("relayed_setup", ["role": "helper", "result": "accepted", "budget": "\(request.budget)", "next_budget": "\(next.nextBudget)",
                                           "next": route.nextHop == nil ? "target" : "helper"])
            let onward = relayOnwardBmh3(hop: route.hop.announcement)
            _ = radio.connect(to: route.hop.peer, transport: link.transport) { [weak relay] result in
                guard let relay else { if case .success(let l) = result { l.close() }; return }
                switch result {
                case .success(let childLink): relay.attachChild(childLink, next: next, bmh3: onward)
                case .failure(let error): relay.childConnectFailed("\(error)")
                }
            }
        }
    }

    /// This device's own IDs: the fixed prefix and, with rotating IDs, the current and previous role-0 RDIs.
    func ownRelayIds(_ identity: SigningIdentity) -> [Data] {
        guard rotatingIds else { return [identity.nodeId.prefix] }
        let epoch = rotating.currentEpoch()
        return [identity.nodeId.prefix, rotating.callEntry(nodeId: identity.nodeId).rdi,
                rotating.vault.entry(nodeId: identity.nodeId, epoch: epoch - 1, role: RotatingDiscoveryIds.roleCallOffer).rdi]
    }

    // MARK: Route searches (helper)

    let relaySeekBudgets = RelaySeekBudgets()
    private let relaySeekFails = RelaySeekFailCache()
    private let relaySeekBadAddresses = RelaySeekBadAddresses()

    /// The listener signs RELAY_SEEK only within the helper scope (rotating IDs and hidden identities on, pseudonyms off)
    /// while a budget-1 search still fits its duty budget (review items 2 and 8).
    var relaySeekSigning: Bool {
        relayHelperActive && AppSettings.relayedOnDemand && hiddenIdentities && rotatingIds && !bmh3Pseudonyms
            && relaySeekBudgets.signing(now: MeshRadio.reachClockMs)
    }

    /// A search (the route-search helper rules): the FAIL cache, then what this device heard (offers of the
    /// last 5 s, else up to 3 s more of its scan, keeping the onward minimum), collecting addresses for 1 s after the
    /// first match; the target's addresses first, then (budget 2) up to two next helpers; at most 3 dials; the final
    /// reason by rule 10. `plain` is a plain SETUP's ID searched without a token.
    private func serveSearch(relay: RelayDutyController, duty: RelayHelperDuty, bearer: MeshTransport, identity: SigningIdentity, plain: Data?) {
        let request = duty.request
        let seek = request.seek
        let startedMs = MeshRadio.reachClockMs
        if let seek, let cached = relaySeekFails.lookup(budget: request.budget, nonce: seek.nonce, token: seek.token, skip: seek.skip, now: startedMs) {
            AppLog.event("relayed_seek", ["role": "helper", "result": "cached", "budget": "\(request.budget)", "reason": cached.label])
            relay.refuse(cached); return
        }
        if duty.remainingMs(now: ConnectionDriver.now) < RelaySeek.minSearchMs {
            relay.refuse(.timeout); return
        }
        AppLog.event("relayed_seek", ["role": "helper", "result": "accepted", "budget": "\(request.budget)", "plain": "\(plain != nil)"])
        let budgets = relaySeekBudgets, fails = relaySeekFails, bad = relaySeekBadAddresses
        let epoch = rotating.currentEpoch()
        var scanMs: Int64 = 0
        relay.onClosed = { duty in
            let now = MeshRadio.reachClockMs
            budgets.finish(startedAt: startedMs, scanMs: scanMs, ready: duty.readyRelays != nil, now: now)
            if duty.readyRelays == nil, let failure = duty.failure, let seek {
                fails.store(budget: request.budget, nonce: seek.nonce, token: seek.token, skip: seek.skip, reason: failure, now: now)
            }
        }
        let ownRdis = ownRelayIds(identity)
        let nonce = seek?.nonce ?? Data(repeating: 1, count: RelaySeek.nonceBytes), token = seek?.token ?? Data(count: RelaySeek.tokenBytes)
        let skip = seek?.skip ?? []
        let budget = min(request.budget, RelaySeek.maxBudget)
        var dials = 0
        var reachedAny = false, anyChildNoRoute = false
        var candidates: [(peer: UUID, next: RelayHelperDuty.NextHop, rdi: Data, hop: DiscoveryAnnouncement, address: String)] = []
        var current: (target: Bool, address: String)?
        func plan() -> Bool {
            guard let table = radio.reachRotating else { return false }
            let offers = table.recentOffers(withinMs: RelaySeek.opportunisticCacheMs)
            let p = RelaySeekPlan(offers: offers, nonce: nonce, token: token, skip: skip, budget: budget, bearer: bearer, ownRdis: ownRdis,
                                  badAddresses: bad.current(epoch: epoch), plainId: plain)
            func sighting(_ peer: UUID, _ rdi: Data) -> OfferSighting<UUID>? { offers.first { $0.peer == peer && $0.announcement.nodeIdPrefix == rdi } }
            // Rule 8 then 9: every target address first; budget 2 falls back to helpers when the target dials fail.
            candidates = p.targets.compactMap { t in sighting(t.peer, t.rdi).map { (t.peer, .init(hopPrefix: nil, nextBudget: 0), t.rdi, $0.announcement, $0.address) } }
            candidates += p.helpers.compactMap { h in sighting(h.peer, h.rdi).map { (h.peer, .init(hopPrefix: h.rdi, nextBudget: budget - 1), h.rdi, $0.announcement, $0.address) } }
            return !candidates.isEmpty
        }
        func finalReason() -> RelaySetupFailure {
            // Rule 10: no route when nothing was reached or any child had none; a timeout when the deadline ran out.
            if !reachedAny || anyChildNoRoute { return .noRoute }
            if duty.remainingMs(now: ConnectionDriver.now) <= 0 { return .timeout }
            return duty.lastChildFailure ?? .noRoute
        }
        func tryNext() -> Bool {
            if case .closed = duty.state { return false }
            while let c = candidates.first {
                candidates.removeFirst()
                // A child is dialled only while its minimum allowance still fits.
                let minimum = c.next.hopPrefix == nil ? RelaySeek.onwardTargetMs : RelaySeek.defaultConnectMs + RelaySeek.minAllowanceBudget1Ms
                guard dials < RelaySeek.dialsPerRequest, duty.remainingMs(now: ConnectionDriver.now) >= minimum else { continue }
                dials += 1
                budgets.chargeDial(now: MeshRadio.reachClockMs)
                if c.next.hopPrefix == nil { duty.setSearchTarget(c.rdi) }
                current = (c.next.hopPrefix == nil, c.address)
                AppLog.event("relayed_seek", ["role": "helper", "result": c.next.hopPrefix == nil ? "matched" : "forwarded", "budget": "\(budget)",
                                              "dials": "\(dials)"])
                let onward = relayOnwardBmh3(hop: c.hop)
                _ = radio.connect(to: c.peer, transport: bearer) { [weak relay] result in
                    guard let relay else { if case .success(let l) = result { l.close() }; return }
                    switch result {
                    case .success(let childLink):
                        reachedAny = true
                        budgets.chargeHandshake(now: MeshRadio.reachClockMs)   // only when a handshake happens
                        relay.attachChild(childLink, next: c.next, bmh3: onward)
                    case .failure(let error): relay.childConnectFailed("\(error)")
                    }
                }
                return true
            }
            return false
        }
        duty.onChildAttemptFailed = { reason in
            if let current, current.target, duty.lastChildIdentityFailure { bad.record(current.address, epoch: epoch) }
            if reason == .noRoute, current?.target == false { anyChildNoRoute = true }
            if tryNext() { return true }
            // Nothing left: the rule-10 reason replaces the last attempt's.
            DispatchQueue.main.async { duty.searchFailed(finalReason()) }
            return true
        }
        let scanStart = MeshRadio.reachClockMs
        var firstMatchAt: Int64?
        func search() {
            if case .closed = duty.state { return }
            let now = MeshRadio.reachClockMs
            let elapsed = now - scanStart
            let found = plan()
            if found, firstMatchAt == nil { firstMatchAt = now }
            let collecting = firstMatchAt.map { now - $0 < Int64(RelaySeek.collectAfterMatchMs) } ?? false
            let leftMs = duty.remainingMs(now: ConnectionDriver.now) - RelaySeek.onwardTargetMs
            if found && (!collecting || candidates.filter({ $0.next.hopPrefix == nil }).count >= RelaySeek.maxTargetAddresses || leftMs <= 0) {
                scanMs = elapsed
                if !tryNext() { duty.searchFailed(finalReason()) }
                return
            }
            if !found && (elapsed >= Int64(RelaySeek.defaultScanMs) || leftMs <= 0) {
                scanMs = elapsed
                AppLog.event("relayed_seek", ["role": "helper", "result": "failed", "budget": "\(budget)", "reason": "no match", "scan_ms": "\(elapsed)"])
                duty.searchFailed(.noRoute); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { search() }
        }
        search()
    }

    /// Pseudonymous relay edges: an onward relay edge in pseudonym mode speaks BMH3 with a declared throwaway, fresh per
    /// connection, no tag, nothing pinned; otherwise the direct-call choice with this device's real key.
    private func relayOnwardBmh3(hop: DiscoveryAnnouncement) -> Bmh3CallSettings? {
        guard hiddenIdentities else { return nil }
        if bmh3Pseudonyms && rotatingIds && AppSettings.relayedPseudonymousEdges {
            let settings = Bmh3CallSettings(speak: true, stranger: SoftwareSigningIdentity())
            settings.linkTag = false
            return settings
        }
        guard Bmh3Choice.decide(enabled: true, only: false, offer: hop, pinned: bmh3Pins.isPinned(hop.nodeIdPrefix)).bmh3 else { return nil }
        return Bmh3CallSettings(speak: true)
    }

    func relayDutyFinished(_ relay: RelayDutyController) {
        guard relayDuty === relay else { return }
        relayDuty = nil
        refreshAdvertising()
    }

    // MARK: Contact dial wait (relayed calls)

    /// A contact called from Contacts while not listed: with relayed calls on, wait up to 45 s for a direct or relayed
    /// row (Android RELAYED_CONTACT_WAIT_MS); the call starts from that row.
    struct ContactDialWait: Equatable { let contact: VerifiedContact; let type: CallType; let deadline: TimeInterval }
    @Published private(set) var contactDialWait: ContactDialWait?
    static let relayedContactWait: TimeInterval = 45

    func waitForContact(_ contact: VerifiedContact, type: CallType) {
        let wait = ContactDialWait(contact: contact, type: type, deadline: ProcessInfo.processInfo.systemUptime + Self.relayedContactWait)
        contactDialWait = wait
        startContactSeek(contact, type: type)
        AppLog.event("call_invite", ["state": "waiting", "reason": "contact_not_listed", "timeoutMs": "\(Int(Self.relayedContactWait * 1000))"])
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.relayedContactWait) { [weak self] in
            guard let self, self.contactDialWait == wait else { return }
            self.contactDialWait = nil
            AppLog.event("call_invite", ["state": "expired", "reason": "peer_not_seen"])
            self.callNotice = "\(contact.displayName) was not found nearby, directly or through other phones. Try again when they appear."
        }
    }

    func cancelContactDialWait() {
        contactDialWait = nil
        if seekAttempt != nil { seekAttempt = nil; AppLog.event("relayed_seek", ["role": "caller", "result": "cancelled"]) }
    }

    // MARK: Route searches (caller)

    let relaySeekMemory = RelaySeekCallerMemory()
    /// One search for a contact (route-search caller rule): ring requests through helpers this device hears, ending at
    /// READY, the contact's own offer, or 45 s.
    final class SeekAttempt {
        let contact: VerifiedContact, type: CallType, rings: RelaySeekRings, epoch: Int64, tappedAt: TimeInterval
        var current: RelaySeekRings.Request?
        init(contact: VerifiedContact, type: CallType, rings: RelaySeekRings, epoch: Int64, tappedAt: TimeInterval) {
            self.contact = contact; self.type = type; self.rings = rings; self.epoch = epoch; self.tappedAt = tappedAt
        }
    }
    private(set) var seekAttempt: SeekAttempt?

    /// Starts a search for `contact` when searches are on and it is possible: the contact's lease window, at least one
    /// version 5 helper heard in the last 10 s, rotating IDs and hidden identities on.
    private func startContactSeek(_ contact: VerifiedContact, type: CallType) {
        guard relayedCalls, AppSettings.relayedOnDemand, rotatingIds, hiddenIdentities, seekAttempt == nil, call == nil,
              let table = radio.reachRotating else { return }
        let reason: String?
        defer { if let reason { AppLog.event("relayed_seek", ["role": "caller", "result": "not_started", "reason": reason]) } }
        guard let window = rotating.vault.recognition.seekWindow(prefixHex: contact.nodePrefixHex) else { reason = "no_lease"; return }
        let recentOffers = table.recentOffers(withinMs: RelaySeekFirstHops.freshMs)
        let recognition = rotating.vault.recognition
        let isContact: (Data) -> Bool = { rdi in
            let hits = recognition.lookup(rdi)
            return hits.count == 1 && contact.fingerprintHex.hasPrefix(hits[0].contact.hex)
        }
        let directEpoch = recentOffers.filter { MeshRadio.reachClockMs - $0.seenMs <= RelaySeek.opportunisticCacheMs }
            .compactMap { o in recognition.lookup(o.announcement.nodeIdPrefix).first { contact.fingerprintHex.hasPrefix($0.contact.hex) }?.epoch }.first
        let epochMs = RotatingDiscoveryIds.epochSeconds * 1_000
        let sinceBoundary = Int64(Date().timeIntervalSince1970 * 1000) % epochMs
        let selectors = RelaySeekSelectors.selectors(window: window, directEpoch: directEpoch, msUntilBoundary: epochMs - sinceBoundary,
                                                     msSinceBoundary: sinceBoundary)
        guard !selectors.isEmpty else { reason = "no_selector"; return }
        let epoch = rotating.currentEpoch()
        let hops = RelaySeekFirstHops.choose(offers: recentOffers, bearer: transport, now: MeshRadio.reachClockMs, isContact: isContact,
                                             reachedBy: relaySeekMemory.reachedBy(contact: contact.nodePrefixHex, epoch: epoch))
        guard !hops.isEmpty else { reason = "no_helpers"; return }
        reason = nil
        let rings = RelaySeekRings(attemptEndMs: MeshRadio.reachClockMs + Int64(Self.relayedContactWait * 1000), selectors: selectors,
                                   firstHops: hops, maxRelays: RelayedCalls.defaultMaxRelays)
        let attempt = SeekAttempt(contact: contact, type: type, rings: rings, epoch: epoch, tappedAt: ProcessInfo.processInfo.systemUptime)
        seekAttempt = attempt
        AppLog.event("relayed_seek", ["role": "caller", "result": "started", "hops": "\(hops.count)", "selectors": "\(selectors.count)",
                                      "max_requests": "\(rings.maxRequests)"])
        // Past the give-up time plus a margin the attempt is over whatever happened.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.relayedContactWait + 5) { [weak self, weak attempt] in
            guard let self, let attempt, self.seekAttempt === attempt else { return }
            self.finishSeek(found: false)
        }
        dialNextSeek()
    }

    /// The next ring request, dialled through the relayed path; "Can't find" when the rings are done.
    private func dialNextSeek() {
        guard let attempt = seekAttempt, let identity, let table = radio.reachRotating else { return }
        while let request = attempt.rings.next(now: MeshRadio.reachClockMs) {
            guard let hop = table.recentOffers(withinMs: RelaySeekFirstHops.freshMs).filter({ $0.announcement.nodeIdPrefix == request.hop })
                    .max(by: { $0.seenMs < $1.seenMs }) else {
                attempt.rings.record(request, outcome: .stale, physicalDials: 0)
                AppLog.event("relayed_seek", ["role": "caller", "result": "stale", "ring": "\(request.ring)", "budget": "\(request.budget)"])
                continue
            }
            if relaySeekMemory.recentlyNoRoute(hop: request.hop, selector: request.selector.rdi, budget: request.budget, now: MeshRadio.reachClockMs) {
                attempt.rings.record(request, outcome: .noRoute, physicalDials: 0)
                continue
            }
            attempt.current = request
            let nonce = RelaySeek.newNonce()
            let route = RelayRoute(target: request.selector.rdi, helperPrefix: request.hop, relays: request.budget, rotating: true,
                                   seek: .init(nonce: nonce, token: RelaySeek.token(nonce: nonce, rdi: request.selector.rdi), skip: request.skip))
            let contact = attempt.contact
            let person = PersonRow(id: UUID(), label: PeerLabel(prefix: Data(hex: contact.nodePrefixHex) ?? request.selector.rdi, contactName: contact.displayName),
                                   prefixHex: contact.nodePrefixHex, transport: hop.announcement.transport ?? transport, relays: request.budget,
                                   isIPhone: false, relayRoute: route, hopRowId: hop.peer)
            AppLog.event("relayed_seek", ["role": "caller", "result": "sent", "ring": "\(request.ring)", "budget": "\(request.budget)",
                                          "selector": "\(request.selector.kind)"])
            call = nil
            placeRelayedCall(to: person, type: attempt.type, tappedAt: attempt.tappedAt, identity: identity)
            return
        }
        finishSeek(found: false)
    }

    private func seekOutcome(_ controller: CallController, route: RelayRoute) -> Bool {
        guard let attempt = seekAttempt, let request = attempt.current else { return false }
        let outcome: RelaySeekRings.Outcome
        if controller.relayReady && controller.endToEndVerified { outcome = .ready }
        else if controller.relayReady { outcome = .other }
        else if controller.relaySeekRefusedLocally { outcome = .noSeek }
        else if controller.relayFailure == .childAuthentication { outcome = .bindingFailed }
        else { outcome = RelaySeekRings.outcome(for: controller.relayFailure) }
        attempt.rings.record(request, outcome: outcome, physicalDials: 1)
        attempt.current = nil
        if controller.relayReady && outcome != .ready { finishSeek(found: false); return false }   // verified failure after READY
        if outcome == .ready {
            relaySeekMemory.rememberReached(contact: attempt.contact.nodePrefixHex, epoch: attempt.epoch, hop: request.hop)
            finishSeek(found: true)
            return false
        }
        if outcome == .noRoute {
            relaySeekMemory.rememberNoRoute(hop: request.hop, selector: request.selector.rdi, budget: request.budget, now: MeshRadio.reachClockMs)
        }
        AppLog.event("relayed_seek", ["role": "caller", "result": "failed", "ring": "\(request.ring)", "budget": "\(request.budget)",
                                      "reason": controller.relayFailure?.label ?? "\(outcome)"])
        guard !controller.userCancelled else { finishSeek(found: false); return false }
        dialNextSeek()
        return seekAttempt != nil && call != nil && call !== controller
    }

    private func finishSeek(found: Bool) {
        guard let attempt = seekAttempt else { return }
        seekAttempt = nil
        if found { relaySeekMemory.reset(contact: attempt.contact.nodePrefixHex) }
        AppLog.event("relayed_seek", ["role": "caller", "result": found ? "finished_found" : "cant_find", "requests": "\(attempt.rings.requests)",
                                      "dials": "\(attempt.rings.dials)"])
    }

    private func resumeContactDialWait() {
        // Route-search caller rule: the contact's own offer appearing before READY ends the search and calls directly.
        if let attempt = seekAttempt, let direct = people.first(where: { $0.relayRoute == nil && $0.prefixHex == attempt.contact.nodePrefixHex }),
           let current = call, current.relayRoute?.seek != nil, !current.relayReady {
            AppLog.event("relayed_seek", ["role": "caller", "result": "direct"])
            seekAttempt = nil
            current.userCancelled = true
            current.end()
            call = nil
            contactDialWait = nil
            startCall(to: direct, type: attempt.type)
            return
        }
        guard let wait = contactDialWait, call == nil, seekAttempt == nil, let person = nearbyPerson(for: wait.contact) else { return }
        contactDialWait = nil
        AppLog.event("call_invite", ["state": "resumed", "relayed": "\(person.relayRoute != nil)"])
        startCall(to: person, type: wait.type)
    }

    /// Records the finished call in the local history (outgoing / incoming / missed).
    private func remember(_ controller: CallController) {
        guard !controller.closedBeforeRinging else { return }
        // Call blocking: a stranger who turned out to be someone you blocked leaves a blocked call that names nobody.
        if controller.blockedAfterReveal && controller.role == .callee { recordBlockedCall(); return }
        guard let prefix = controller.peerPrefixHex else { return }
        let seconds = controller.activeSince.map { Int(Date().timeIntervalSince($0)) } ?? 0
        let direction: CallRecord.Direction = controller.role == .caller ? .outgoing : (controller.activeSince == nil ? .missed : .incoming)
        // Only a verified contact is kept by ID; anyone else by the generated name and the time (Android protocol reference "After the
        // reveal").
        let contact = contactName(prefixHex: prefix) != nil
        let outcome = RecentCallOutcome.of(answered: controller.activeSince != nil, missed: controller.missedHere,
                                           declinedHere: controller.declinedHere, cancelledHere: controller.cancelledWhileConnecting,
                                           reason: controller.endReason)
        CallHistory.add(CallRecord(prefixHex: contact ? prefix : "", direction: direction, video: controller.callType == .video,
                                   at: Date(), seconds: seconds, name: contact ? nil : controller.strangerName, outcome: outcome.rawValue))
        reloadRecentCalls()
        // Android StrangerCallFollowup: after a call with someone who is not saved, offer Add contact (in memory only).
        // Never for someone you blocked (a caller can meet a blocked person only after the reveal; Android RecentCall.blocked).
        let blocked = controller.blockedAfterReveal || controller.fingerprint.map { isBlocked($0) } == true
        strangerFollowUp = StrangerCallFollowUp.name(enabled: AppSettings.labSwitch("strangerFollowUp", shipped: true), blocked: blocked,
                                                     isContact: contact, generatedName: controller.strangerName,
                                                     handle: controller.label?.handle)
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

    /// A generated nearby name (never a handle, a contact, a claimed name or "Someone nearby"), or nil.
    static func generatedName(_ label: PeerLabel?) -> String? {
        guard let label, label.isGenerated else { return nil }
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
        if controller.busyMode { busyControllers.removeAll { $0 === controller }; noteBusyDeclined(controller); return }
        // An older call's delayed dismissal must not clear a newer call's ringing alert.
        guard call === controller else { return }
        if relayedOutcome(controller) { return }
        CallNotifier.shared.clear()
        if controller.activeSince != nil { CallNotifier.shared.requestIfAppropriate(.callEnded) }
        remember(controller)
        if controller.missedHere {
            // Call back and the caller's name only for a verified contact; anyone else is a generated name at most.
            let contact = controller.verification == .verified ? controller.peerPrefixHex.flatMap { contactName(prefixHex: $0) } : nil
            CallNotifier.shared.postMissed(peerName: contact != nil ? controller.label?.title : Self.generatedName(controller.label),
                                           stranger: contact == nil,
                                           prefixHex: contact != nil ? controller.peerPrefixHex : nil, video: controller.offeredType == .video)
        }
        if controller.failedEarly, let ended = controller.ended {
            callNotice = ended
            if controller.role == .caller { callRetry = lastOutgoing }
        }
        call = nil
        refreshAdvertising()
        if offerBlockUnknownAfterCall {
            offerBlockUnknownAfterCall = false
            // After the cover's closing animation; a call that rang meanwhile keeps its screen and skips the offer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.call == nil else { return }
                self.askBlockUnknown = true
            }
        }
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
        // Android ensureThermalReady: no video at critical heat (audio only is not video and still plays).
        if !row.audioOnly, videoBlockedByHeat {
            AppLog.event("watch_thermal", ["event": "refused_critical"]); streamNotice = AppModel.tooHotText; return
        }
        let key = streamRouteKey(row.id, row.announcement)
        if let refusal = RotatingStreamPolicy.joinRefusal(offer: row.announcement, rotatingIds: rotatingIds, privateViewer: rotatingViewer) {
            AppLog.event("rotating_ids", ["event": "join_refused", "role": "viewer"])
            streamNotice = refusal
            return
        }
        guard !streamRoutePenalties.isPenalized(key, now: ConnectionDriver.now) else {
            streamNotice = "That route to the stream is temporarily unavailable. Try another one nearby."
            return
        }
        #if os(macOS)
        // Android withWifiCheck before watching; an audio-only stream counts as voice.
        if askWifiAdvice(voice: row.audioOnly, { [weak self] in self?.startWatching(row) }) { return }
        #endif
        streamNotice = nil
        let joinKeys = beginJoinKeys()   // D1 (AppModel+Protocol.swift)
        if joinKeys == nil, RotatingStreamPolicy.showsFixedId(offer: row.announcement, rotatingIds: rotatingIds) {
            // Android rotid_downgrade: a version 2 source cannot decode a rotating request, so this one shows the fixed
            // prefix while it waits (stated residual, phase 1b item 2).
            AppLog.event("rotid_downgrade", ["role": "viewer", "reason": "selected_version_2"])
            streamNotice = RotatingStreamPolicy.fixedIdNotice
        }
        // A new stream: role-2 entries pinned for an earlier join are not opened to this stream's source.
        rotating.viewerRequest.startJoin(elapsedMs: RotatingDiscoveryRuntime.elapsedMs)
        let controller = WatchController(model: self, identity: joinKeys?.identity ?? identity, joinKeys: joinKeys, offer: row.announcement, name: row.label.title, route: row.route, transport: row.announcement.transport ?? .gatt, routeKey: key)
        watch = controller
        refreshAdvertising()
    }

    func watchFinished(_ controller: WatchController) {
        guard watch === controller else { return }
        watch = nil
        dropJoinKeyPins(after: controller)   // D1
        viewerRecovery.cancel(); viewerRecoveryRetry?.cancel(); viewerRecoveryRetry = nil
        let target = LogicalStreamTarget(controller.offer)
        streamRetryOffer = controller.offer
        if controller.searchGaveUp { noteStreamLost(controller); refreshAdvertising(); return }
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

    // MARK: Viewer recovery (Android: after an unexpected loss, the same stream on any route)

    /// The routes the recovering viewer may try, with Android's per-route back-off (0, 1, 2, 4, then 8 s).
    private let viewerRecovery = ViewerRecoveryRoutes<LogicalStreamTarget>()
    private var viewerRecoveryRetry: DispatchWorkItem?

    /// The watched stream was lost, or a rejoin through a route failed: that route backs off; look for any route of it.
    func viewerLost(_ controller: WatchController) {
        guard watch === controller else { return }
        if controller.noteSearchLoss() { return }
        let target = LogicalStreamTarget(controller.offer), now = ConnectionDriver.now
        viewerRecovery.onFailure(target: target, route: controller.recoveryRouteKey, now: now)
        if controller.routeWithdrawn {
            // Android onRouteWithdrawn: the parent has no room for this viewer; that route waits 30 s unless its offer
            // shows a new capacity generation.
            viewerRecovery.onWithdrawn(target: target, route: controller.recoveryRouteKey,
                                       generation: controller.offer.sequence & DiscoveryAnnouncement.sequenceGenerationMask, now: now)
        }
        refreshAdvertising()
        takeViewerRecovery()
    }

    func viewerRecovered(_ controller: WatchController) {
        guard watch === controller else { return }
        viewerRecovery.cancel(); viewerRecoveryRetry?.cancel(); viewerRecoveryRetry = nil
        refreshAdvertising()
    }

    /// Rejoins through the first listed, joinable route of the same stream whose back-off has passed; otherwise looks
    /// again when the next waiting route opens (a newly listed route comes through `rebuildLists`).
    private func takeViewerRecovery() {
        guard let watch, watch.recovering, !watch.awaitingSource, watch.ended == nil, call == nil, live == nil else { return }
        let now = ConnectionDriver.now
        // Recovery never moves a rotating join to a version 2 route (that request would show the fixed prefix untapped).
        let usable = streams.filter {
            $0.joinable && RotatingStreamPolicy.joinRefusal(offer: $0.announcement, rotatingIds: rotatingIds, privateViewer: rotatingViewer) == nil
                && RotatingStreamPolicy.mayRouteAutomatically(from: watch.offer, to: $0.announcement, rotatingIds: rotatingIds)
        }
        // Android's reconnection order: fewest relays, the lost route's transport, then the advertised ID. A route that
        // failed is tried again only after a fresh sighting of its offer (Android drops the failed route's cached offer).
        let sightings = radio.peers
        // RV-C: never a route this watch dropped because its forwarder named a blocked source.
        let allowed = watch.droppedRoutes.usable(usable) { ViewerRecovery.routeKey(self.streamRouteKey($0.id, $0.announcement)) }
        let ranked = ViewerRecovery.ordered(allowed, offer: { $0.announcement }, preferredTransport: watch.transport)
        if let row = viewerRecovery.candidate(now: now, listed: ranked, matches: { $0.matches($1.announcement) },
                                              route: { ViewerRecovery.routeKey(self.streamRouteKey($0.id, $0.announcement)) },
                                              seenAt: { sightings[$0.id]?.lastSeen },
                                              generation: { $0.announcement.sequence & DiscoveryAnnouncement.sequenceGenerationMask }) {
            viewerRecoveryRetry?.cancel(); viewerRecoveryRetry = nil
            watch.rejoin(offer: row.announcement, route: row.route, routeKey: streamRouteKey(row.id, row.announcement))
            refreshAdvertising()
        } else if viewerRecoveryRetry == nil {
            // An offer that is only seen again raises no list change: while recovering, look again at least every 0.5 s
            // (a route waiting for a fresh sighting, or whose wait ends sooner).
            let wait = min(viewerRecovery.nextOpening(now: now) ?? ViewerRecovery.recheckInterval, ViewerRecovery.recheckInterval)
            let work = DispatchWorkItem { [weak self] in self?.viewerRecoveryRetry = nil; self?.takeViewerRecovery() }
            viewerRecoveryRetry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.05, execute: work)
        }
    }

    /// Failed live joins (StreamJoinRetry; on, control arm `-streamJoinRetry NO`).
    let streamJoinRetry = StreamJoinRetry<LogicalStreamTarget>(enabled: { AppSettings.streamJoinRetry })
    /// The video codecs this device decodes (`VideoDecoderSupport.decodeMask` probes VideoToolbox; read once).
    private lazy var videoDecodeMask: UInt8 = VideoDecoderSupport.decodeMask
    /// Try again on "Couldn't join ...".
    @Published private(set) var streamRetryTarget: LogicalStreamTarget?
    /// The watch screen that is open (a retry joins only while it shows, never in the background).
    /// DEBUG `-NearbyAutoWatch`/`-NearbyAutoListen`: the stream the Live tab opens its player for, as a tap would (the
    /// hook used to start the watch with no player on screen: audio under the Live list, device test 2026-11-12).
    /// Release builds have no automation, so it stays nil there.
    @Published var debugOpenStream: StreamRow?
    var watchScreenOpen = false {
        didSet {
            if watchScreenOpen { liveNotice = nil }
            else { streamJoinRetry.cancel(); streamRetryTarget = nil }
        }
    }

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
        // The automatic retry of a rotating join never takes a version 2 route (a tap still can, with the notice).
        let listed = streamRetryOffer.map { failed in
            streams.filter { RotatingStreamPolicy.mayRouteAutomatically(from: failed, to: $0.announcement, rotatingIds: rotatingIds) }
        } ?? streams
        guard let row = streamJoinRetry.take(now: ConnectionDriver.now, listed: listed, matches: { $0.matches($1.announcement) }) else { return }
        AppLog.event("stream_join", ["event": "retry", "route": row.route])
        streamNotice = nil; streamRetryTarget = nil
        startWatching(row)
    }

    // MARK: Going live

    /// `setup`: audio only opens its own screen first (Android screen_audio_broadcast: title, quality, Start); nothing is
    /// advertised until Start. DEBUG automation starts at once (as Android test_audio_live_autostart).
    func goLive(audioOnly: Bool = false, preset: UInt8 = AudioLive.presetVoice, setup: Bool = false) {
        guard sourceGate.allowsGoLive else {
            AppLog.event("source_gate", ["event": "refused", "action": "go_live"]); return
        }
        guard live == nil, let identity, !audioOnly || AppSettings.audioLive else { return }
        // Android ensureThermalReady: no video live at critical heat.
        if !audioOnly, videoBlockedByHeat {
            AppLog.event("live_thermal", ["event": "refused_critical"])
            liveStoppedTitle = "Can't go live"; liveStoppedNotice = AppModel.tooHotText; return
        }
        #if os(macOS)
        // Android withWifiCheck before a video live (audio only never asks).
        if askWifiAdvice(voice: audioOnly, { [weak self] in self?.goLive(audioOnly: audioOnly, preset: preset, setup: setup) }) { return }
        #endif
        AppSettings.audioLiveLastChoice = audioOnly
        live = LiveController(model: self, identity: identity, transport: transport,
                              labels: peerLabelsEnabled, title: liveTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : liveTitle,
                              audioOnly: audioOnly, preset: preset)
        if audioOnly && setup {
            AppLog.event("radio_setup", ["event": "opened"])
        } else {
            if audioOnly { AppLog.event("radio_setup", ["event": "autostart"]) }
            live?.start()
        }
        refreshAdvertising()
    }

    /// Start on the audio-only screen (Android audio_live_start), with the title and quality chosen there.
    func startRadio(preset: UInt8) {
        guard let live, live.audioOnly, !live.running else { return }
        let title = liveTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        live.configure(title: title.isEmpty ? nil : title, preset: preset)
        live.start()
        refreshAdvertising()
    }

    /// Android switchAudioLiveToVideo: the radio ends, then a new video live with the same title starts.
    func switchRadioToVideo() {
        guard let live, live.audioOnly, live.running else { return }
        AppSettings.audioLiveLastChoice = false
        videoAfterRadio = true
        AppLog.event("radio_switch_to_video", [:])
        live.stop()
    }

    func liveFinished(_ controller: LiveController) {
        guard live === controller else { return }
        live = nil
        refreshAdvertising()
        if let notice = controller.stoppedNotice {
            // After the broadcast screen closed, so the alert is not hidden under it.
            let title = controller.stoppedTitle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.liveStoppedTitle = title; self?.liveStoppedNotice = notice }
        }
        if videoAfterRadio {
            videoAfterRadio = false
            // A new stream, never converted in place; the title is still `liveTitle`.
            if call == nil, watch == nil { goLive(audioOnly: false) }
        }
    }

    // MARK: Identity verification

    func noteAuthenticated(_ fingerprint: IdentityFingerprint) {
        let key = fingerprint.nodeId.hex
        if authenticated[key] == nil { authenticatedOrder.append(key) }
        authenticated[key] = fingerprint
        if authenticatedOrder.count > 1024 { authenticated[authenticatedOrder.removeFirst()] = nil }
    }

    func verificationState(of fingerprint: IdentityFingerprint) -> VerificationState { book.state(of: fingerprint) }

    /// BVMID1 scan: the scanned full fingerprint must equal one authenticated in this process. A static code has no
    /// freshness, so with BVMID2 it records only "Checked by code" unless the DEBUG compat arm `-bvmid1Compat YES` is on
    /// (Android `bvmid1_compat`, off, no Settings switch).
    func markVerified(scanned payload: IdentityQrPayload) throws {
        let authenticatedFp = authenticated[payload.fingerprint.nodeId.hex]
        // A contact already scanned (shield) keeps it: an older code never downgrades a stronger check.
        let existing = book.contacts.first { $0.fingerprintHex == payload.fingerprint.hex }?.method
        let method = existing == Bvmid1Policy.scanned ? Bvmid1Policy.scanned
            : Bvmid1Policy.methodForBvmid1Scan(compat: AppSettings.labSwitch("bvmid1Compat", shipped: false))
        try book.markVerified(authenticated: authenticatedFp, confirmed: payload.fingerprint, name: payload.displayName, method: method)
        try saveContacts()
    }

    /// BVMID2: the user confirmed "Is this <name>'s screen?" for a scan whose handshake key equals the code's. Always the
    /// scanned method (shield); a contact already saved keeps its name.
    func markScannedVerified(_ fingerprint: IdentityFingerprint, name: String) throws {
        let saved = book.contacts.first { $0.fingerprintHex == fingerprint.hex }?.displayName
        try book.markVerified(authenticated: authenticated[fingerprint.nodeId.hex], confirmed: fingerprint, name: saved ?? name,
                              method: Bvmid1Policy.scanned)
        try saveContacts()
    }

    /// Rename and "Save contact as" (Android `SecurityUi.renameContact`): the person-name rules, no name that reads like
    /// another contact's, then the sealed store. The name is only ever on this device.
    func renameContact(_ fingerprint: IdentityFingerprint, to input: String) -> ContactRenameOutcome {
        guard contactsUnreadable == nil else { return .unreadable }
        let decision = ContactNames.renameDecision(input, fingerprintHex: fingerprint.hex, contacts: book.contacts)
        guard case .renamed(let name) = decision else { return decision }
        do {
            try book.rename(fingerprintHex: fingerprint.hex, to: name)
            try saveContacts()
            return decision
        } catch {
            return .unreadable
        }
    }

    /// Naming v2 (Android `ContactClaims.recordClaim`): a verified contact's verified self-chosen name from a call, kept
    /// sealed with the contact for its sheet. Never the title, never sent; nothing is kept for anyone else.
    func recordContactClaim(_ fingerprint: IdentityFingerprint, name: String) {
        guard book.state(of: fingerprint) == .verified, book.recordClaim(fingerprintHex: fingerprint.hex, name: name) else { return }
        try? saveContacts()
    }

    /// The user saw or ignored the latest claim ("Use it as my label" or "Ignore").
    func acknowledgeClaim(_ contact: VerifiedContact) {
        guard book.acknowledgeClaim(fingerprintHex: contact.fingerprintHex) else { return }
        try? saveContacts()
    }

    /// Both phones scanned each other during one visit of Add contact (kept with the contact, as Android's claims file).
    func markScannedBothWays(_ fingerprint: IdentityFingerprint) {
        guard book.markScannedBothWays(fingerprintHex: fingerprint.hex) else { return }
        try? saveContacts()
    }

    func markVerified(sessionPeer fingerprint: IdentityFingerprint, name: String) throws {
        try book.markVerified(authenticated: authenticated[fingerprint.nodeId.hex], confirmed: fingerprint, name: name, method: "safety-code")
        try saveContacts()
    }

    /// Phase 2: the node ID of a verified contact (the first 16 bytes of its fingerprint).
    private func nodeId(of contact: VerifiedContact) -> NodeId? {
        Data(hex: String(contact.fingerprintHex.prefix(32))).flatMap { try? NodeId(bytes: $0) }
    }
    /// "Can see when I'm nearby": not yet asked counts as off until the user answers (decision 2026-11-06).
    func canSeeMe(_ contact: VerifiedContact) -> Bool { nodeId(of: contact).map { rotating.vault.canSeeMe($0) } ?? false }
    func setCanSeeMe(_ contact: VerifiedContact, _ on: Bool) {
        guard let node = nodeId(of: contact) else { return }
        let before = rotating.vault.generation
        rotating.vault.setCanSeeMe(node, on, epoch: rotating.currentEpoch())
        objectWillChange.send()
        presenceRevoked(from: before)
    }
    /// Design QL revision 2: the scan's "Let <name>'s phone recognise yours nearby" answer, written to that person's "Can
    /// see when I'm nearby" (a no for a contact holding a current lease revokes it, as the switch does). True only when
    /// the presence store is persistent and the switch now reads as written, so a failed write withholds the lease.
    func storeRecognitionChoice(_ fingerprint: IdentityFingerprint, recognise: Bool) -> Bool {
        let node = fingerprint.nodeId
        let before = rotating.vault.generation
        rotating.vault.setCanSeeMe(node, recognise, epoch: rotating.currentEpoch())
        objectWillChange.send()
        presenceRevoked(from: before)
        return rotating.vault.persistent && rotating.vault.canSeeMe(node) == recognise
    }
    /// A Contacts call to `contact` (the row's call buttons): the nearby person found by prefix or by an unambiguous
    /// recognition, else the wait for a recognisable contact. False when it cannot be found now.
    @discardableResult
    func callContact(_ contact: VerifiedContact, type: CallType) -> Bool {
        if let person = nearbyPerson(for: contact) { startCall(to: person, type: type); return true }
        if contactReach(contact) == .recognisable, relayedCalls { waitForContact(contact, type: type); return true }
        return false
    }
    /// Android `contactHint`: whether this device can recognise `contact` nearby and, if not, what the user can do.
    /// DEBUG fixture: `-NearbyFixtureReach recognisable|ask|again|nearby` forces one hint for the UI tests.
    func contactReach(_ contact: VerifiedContact) -> ContactReach.Hint {
        #if DEBUG
        if debugFixtureActive, let forced = RootView.debugArgument("-NearbyFixtureReach").flatMap(ContactReach.Hint.init(rawValue:)) {
            return forced
        }
        #endif
        guard let node = nodeId(of: contact) else { return .recognisable }
        let holds = rotating.vault.leaseKey(of: node.bytes, day: PresenceLeases.dayOf(rotating.currentEpoch())) != nil
        return ContactReach.hint(recognitionOn: rotatingIds && rotating.vault.persistent, holdsLease: holds,
                                 scannedBothWays: contact.scannedBothWaysAt != nil, meetAvailable: meet.available)
    }
    /// After a revocation the advertised rotating ID must come from the new generation at once: until the next
    /// boundary the old one is still a valid ID for the revoked contacts to recognise.
    private func presenceRevoked(from before: UInt32) {
        // A revocation while the vault cannot be read changes no stored generation but drops the in-memory keys.
        guard rotating.vault.generation != before || !rotating.vault.persistent else { return }
        presenceGeneration = rotating.vault.generation
        presenceKeyRevision &+= 1
        refreshAdvertising()
    }
    /// "Reset presence key": a new generation; contacts recognise this phone again after the next mutual call.
    func resetPresenceKey() {
        rotating.vault.resetKey()
        presenceGeneration = rotating.vault.generation
        presenceKeyRevision &+= 1
        refreshAdvertising()
    }
    @Published var presenceGeneration: UInt32 = 0
    /// AB4F: advances on every presence revocation (including while the vault cannot be read and its stored generation
    /// does not change) and on "Reset presence key"; the live role-1 offer is rebuilt when it changes.
    private var presenceKeyRevision: Int64 = 0

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

    // MARK: Call blocking (Android CallBlocking, PersonPolicy, LocalReporting)

    private func loadBlockList() {
        let firstLoad = blockList == nil
        blockListHolder.reloadIfNeeded { BlockedPeopleFile.load() }
        blockList = blockListHolder.list
        blockListDamaged = blockListHolder.damaged
        if blockList != nil {
            loggedBlockListReason = nil
            reconcileBlockedPresenceIfNeeded()
            // P6-A2: a list that became readable later must hide its people from the Live list now.
            if firstLoad, radioConfigured { rebuildLists() }
        } else {
            let reason = blockListDamaged ? "damaged" : "unavailable"
            if loggedBlockListReason != reason {
                loggedBlockListReason = reason
                AppLog.event("call_blocking", ["event": "list_unreadable", "reason": reason])
            }
        }
    }

    /// A locked Keychain blocks nobody until it can be read: retry on activation and at every gate, one file read only
    /// while the list is nil (P6-A2).
    func reloadBlockListIfNeeded() {
        if blockList == nil { loadBlockList() }
        reconcileBlockedPresenceIfNeeded()
    }

    /// Android `requestBlockedReconcile` after the first successful load: a blocked person holding this device's current
    /// presence lease loses it (a new generation). The start-up pass does not fail closed when the vault is unavailable.
    private func reconcileBlockedPresenceIfNeeded() {
        guard !blockedReconciled, rotatingIds, rotating.vault.persistent, let list = blockList else { return }
        blockedReconciled = true
        let before = rotating.vault.generation
        for person in list.people {
            guard let fingerprint = try? IdentityFingerprint(hex: person.fingerprintHex) else { continue }
            let node = fingerprint.nodeId
            if rotating.vault.deliveredTo(node) {
                rotating.vault.setCanSeeMe(node, false, epoch: rotating.currentEpoch())
            }
        }
        presenceRevoked(from: before)
    }

    /// Blocked right now (fails open: an unreadable list blocks nobody).
    func isBlocked(_ fingerprint: IdentityFingerprint) -> Bool {
        reloadBlockListIfNeeded()
        return blockList?.contains(fingerprint) ?? false
    }
    /// Blocked, known by the 128-bit node ID only (a forwarded stream's source, a link peer).
    func isBlockedNode(_ node: NodeId) -> Bool {
        reloadBlockListIfNeeded()
        return blockList?.containsNode(node) ?? false
    }
    /// Streams from this person are hidden and left: blocked, or reported (a report keeps hiding after an unblock).
    func hidesStreams(of node: NodeId) -> Bool {
        reloadBlockListIfNeeded()
        return blockList.map { $0.containsNode(node) || $0.reported(node: node) } ?? false
    }

    /// What block texts call a person: your contact label, else the handle (Android CallBlockingUi.nameFor).
    func blockName(for fingerprint: IdentityFingerprint) -> String {
        contactName(prefixHex: fingerprint.nodePrefixHex) ?? IdentityHandle.handle(prefix: fingerprint.nodeId.prefix) ?? "this person"
    }

    enum BlockOutcome { case blocked, alreadyBlocked, full, unavailable }

    /// Every block goes through here (Recent, a contact, Decline and block, the radio listener, a report), so the
    /// presence revocation always runs (Android BlockedPeople.block).
    @discardableResult
    func block(_ fingerprint: IdentityFingerprint) -> BlockOutcome {
        reloadBlockListIfNeeded()
        let result = blockListHolder.block(fingerprint, at: Date())
        blockList = blockListHolder.list
        switch result {
        case .unavailable: return .unavailable
        case .full: return .full
        case .blocked, .alreadyBlocked:
            revokePresence(of: fingerprint)
            rebuildLists()
            AppLog.event("call_blocking", ["event": "blocked"])
            return result == .blocked ? .blocked : .alreadyBlocked
        }
    }

    /// Blocks and says what happened on the Calls and Contacts notice (Android's toast).
    func blockAndSay(_ fingerprint: IdentityFingerprint) {
        let name = blockName(for: fingerprint)
        switch block(fingerprint) {
        case .blocked: callNotice = "\(name) blocked"
        case .alreadyBlocked: callNotice = "\(name) is already blocked"
        case .full: callNotice = "The block list is full. Unblock someone first."
        case .unavailable: sayBlockNotSaved()
        }
    }

    /// A Block that could not be saved because the list cannot be read: a damaged list offers Reset (Android); a locked
    /// one says so and is read again later (nothing to reset).
    private func sayBlockNotSaved() {
        if blockListDamaged { blockListUnreadableAlert = true }
        else { callNotice = "Could not save the block. The block list cannot be read right now." }
    }

    func unblock(_ person: BlockedPerson) {
        guard var list = blockList, let fingerprint = try? IdentityFingerprint(hex: person.fingerprintHex), list.remove(fingerprint),
              BlockedPeopleFile.save(list) else { return }
        blockList = list
        blockListHolder.replace(list)
        rebuildLists()
    }

    /// Unblock from a contact's sheet (Android `ContactActions.blockOrUnblock`): true when they are no longer blocked.
    @discardableResult
    func unblock(_ fingerprint: IdentityFingerprint) -> Bool {
        guard let person = blockList?.people.first(where: { $0.fingerprintHex == fingerprint.hex }) else { return false }
        unblock(person)
        return blockList?.contains(fingerprint) == false
    }

    /// Forgets every blocked person (the recovery for a damaged list). Logged, like the unreadable list itself (owner
    /// decision 2026-11-06); the line carries no identity.
    func resetBlockList() {
        guard blockListHolder.reset() else { return }
        BlockedPeopleFile.reset()
        blockList = blockListHolder.list
        blockListDamaged = blockListHolder.damaged
        loggedBlockListReason = nil
        rebuildLists()
        AppLog.event("call_blocking", ["event": "list_reset"])
    }

    /// Android LocalReporting: block and keep hiding the person locally, then offer Tell MeshLive. AB3: `streamRoute` is
    /// not kept (a route's token and advertised ID are chosen by its sender); the call sites still pass it.
    func report(_ fingerprint: IdentityFingerprint, streamRoute: String?) {
        reloadBlockListIfNeeded()
        guard var list = blockList else {
            sayBlockNotSaved()
            return
        }
        let result = list.report(fingerprint, at: Date())
        if result == .full {
            callNotice = "The block list is full. Unblock someone first."
            return
        }
        guard BlockedPeopleFile.save(list) else {
            callNotice = "Could not save the block. The block list cannot be read right now."
            return
        }
        blockList = list
        blockListHolder.replace(list)
        revokePresence(of: fingerprint)
        rebuildLists()
        AppLog.event("call_blocking", ["event": "reported"])
        reportDone = true
    }

    /// Blocking a contact who holds this device's current presence lease stops it (a new generation; Android
    /// PresenceStore.revokeForBlocked). Their "Can see when I'm nearby" switch goes off and stays off. If the vault is
    /// not persistent, fail closed: a new in-memory generation, so no lease can be delivered (P6-A4).
    private func revokePresence(of fingerprint: IdentityFingerprint) {
        guard rotatingIds else { return }
        let node = fingerprint.nodeId
        if !rotating.vault.persistent {
            let before = rotating.vault.generation
            rotating.vault.newGeneration(epoch: rotating.currentEpoch(), reason: "blocked_unreadable")
            presenceRevoked(from: before)
            AppLog.event("rotid_presence", ["event": "revoked", "reason": "blocked_unreadable"])
            return
        }
        guard rotating.vault.deliveredTo(node) else { return }
        let before = rotating.vault.generation
        rotating.vault.setCanSeeMe(node, false, epoch: rotating.currentEpoch())
        presenceRevoked(from: before)
        AppLog.event("rotid_presence", ["event": "revoked", "reason": "blocked"])
    }

    /// Android `CallBlocking.gate`: the block list, "Block unknown callers" and the verified contacts. Fails open.
    func callGateDecision(_ caller: CallGateCaller) -> CallGateDecision {
        reloadBlockListIfNeeded()
        let standing: ContactStanding
        if caller.pseudonymous || caller.fingerprint == nil { standing = .notVerified }
        else if contactsUnreadable != nil { standing = .unknown }
        else { standing = book.state(of: caller.fingerprint!) == .verified ? .verified : .notVerified }
        return blockListHolder.gateDecision(blockUnknown: blockUnknownCallers, caller: caller, standing: standing)
    }

    /// An incoming call the gate refused never shows here: its controller leaves the screen at once (kept like a busy
    /// listener until its engine has declined), and an unknown caller leaves a "Blocked call" in Recent.
    func hideSilentDecline(_ controller: CallController, unknown: Bool) {
        if unknown { recordBlockedCall() }
        guard call === controller else { return }
        call = nil
        controller.busyMode = true
        busyControllers.append(controller)
        refreshAdvertising()
    }

    private func recordBlockedCall() {
        CallHistory.add(CallRecord(prefixHex: "", direction: .incoming, video: false, at: Date(), seconds: 0, name: nil, blocked: true))
        reloadRecentCalls()
    }

    /// Android "Hide this livestream" (`LocalReporting.hideStream`) for a source that did not authenticate itself. AB3: a
    /// route whose fixed ID the viewer's hop proved (logical token and advertised ID, never the token alone) stays hidden
    /// with the block list, sealed on this device and deleted with it; if the list cannot be read or saved, that route is
    /// hidden for this run only. An unproven or rotating route could be a copy of someone else's, so only that
    /// advertiser's radio address is hidden, for this run. Nothing is sent and nobody is blocked.
    func hideLivestream(_ offer: DiscoveryAnnouncement, address: String, hopAuthenticated: Bool) {
        reloadBlockListIfNeeded()
        guard let route = BlockedStreams.keptRoute(offer, hopAuthenticated: hopAuthenticated) else {
            AppLog.event("call_blocking", ["event": "stream_hidden", "kept": "false", "proven": "false"])
            hiddenStreamAddresses.insert(address)
            rebuildLists()
            return
        }
        if var list = blockList, list.hideStream(route: route), BlockedPeopleFile.save(list) {
            blockList = list
            blockListHolder.replace(list)
            AppLog.event("call_blocking", ["event": "stream_hidden", "kept": "true", "proven": "true"])
            rebuildLists()
        } else {
            AppLog.event("call_blocking", ["event": "stream_hidden", "kept": "false", "proven": "true"])
            hideStreamRoute(offer)
        }
    }

    /// A stream whose source authenticated as a blocked person: this route stays hidden for this run (never the token
    /// alone, Android review 2026-10-27 finding 1).
    func hideStreamRoute(_ offer: DiscoveryAnnouncement) {
        let key = BlockedStreams.routeKey(offer)
        hiddenStreamRoutes.removeAll { $0 == key }
        hiddenStreamRoutes.append(key)
        if hiddenStreamRoutes.count > 256 { hiddenStreamRoutes.removeFirst(hiddenStreamRoutes.count - 256) }
        rebuildLists()
    }

    /// The one contact a rotating offer is recognised as (presence lease), as a 12-hex prefix, or nil.
    private func recognisedContactPrefix(_ offer: DiscoveryAnnouncement) -> String? {
        let hits = rotating.vault.recognition.lookup(offer.nodeIdPrefix)
        guard hits.count == 1 else { return nil }
        return contacts.first { $0.fingerprintHex.hasPrefix(hits[0].contact.hex) }?.nodePrefixHex
    }

    /// The full fingerprint behind a Recent row: only a verified contact's row has one (strangers are stored by
    /// generated name only).
    func fingerprint(ofRecent record: CallRecord) -> IdentityFingerprint? {
        guard record.callable, let contact = contacts.first(where: { $0.nodePrefixHex == record.prefixHex }) else { return nil }
        return try? IdentityFingerprint(hex: contact.fingerprintHex)
    }

    /// The full fingerprint behind a Nearby row: only a verified contact (a fixed prefix, or a rotating ID recognised
    /// through its presence lease) has one; anyone else uses a temporary ID that cannot be blocked one by one.
    func fingerprint(ofNearby person: PersonRow) -> IdentityFingerprint? {
        guard let contact = contacts.first(where: { nearbyPerson(for: $0)?.id == person.id }) else { return nil }
        return try? IdentityFingerprint(hex: contact.fingerprintHex)
    }

    /// Reloads Recent from the sealed history and notes whether a stored history cannot be opened now.
    private func reloadRecentCalls() {
        recentCalls = CallHistory.all
        recentUnreadable = recentCalls.isEmpty && CallHistory.unreadable
    }

    /// "Clear history" (Android `RecentCalls.clear`): deletes the whole history, also one that cannot be opened.
    func clearRecentHistory() {
        #if DEBUG
        if debugFixtureActive { recentCalls = []; recentUnreadable = false; return }
        #endif
        CallHistory.clear()
        reloadRecentCalls()
        AppLog.event("recent_calls", ["event": "cleared"])
    }

    /// Calls › Nearby "Search again" (Android `restartPrivateCallDiscovery`): restarts the scan; the list updates by itself.
    func searchAgain() {
        radio.restartScan()
        AppLog.event("people_search", ["event": "again"])
    }

    /// Incoming call screen: Decline and block (Android afterDeclineAndBlock; offered only for a real-key caller).
    func declineAndBlock(_ controller: CallController) {
        let fingerprint = controller.fingerprint
        controller.decline()
        guard let fingerprint else { return }
        let name = blockName(for: fingerprint)
        switch block(fingerprint) {
        case .blocked, .alreadyBlocked: callNotice = "Declined and blocked \(name)"
        case .full: callNotice = "The block list is full. Unblock someone first."
        case .unavailable: sayBlockNotSaved()
        }
    }

    /// Incoming call screen: Report (decline, then block and hide; offered only for a real-key caller).
    func declineAndReport(_ controller: CallController) {
        let fingerprint = controller.fingerprint
        controller.decline()
        if let fingerprint { report(fingerprint, streamRoute: nil) }
    }

    /// Incoming call screen: a plain Decline. A caller with a one-time ID cannot be blocked one by one, so once (until
    /// "Not now") this offers Block unknown callers (Android offerBlockUnknownAfterDecline).
    /// A ringing call's screen is a full-screen cover at the root; an alert still showing there would block it. Closes
    /// the decline offer, the report confirmation and the block list alert (each only informs or offers, and the
    /// decline offer comes back after the next decline). True when one was showing.
    func closeAlertsForRingingCall() -> Bool {
        let showing = askBlockUnknown || reportDone || blockListUnreadableAlert
        if showing { AppLog.event("call_alerts", ["event": "closed_for_ring"]) }
        askBlockUnknown = false; reportDone = false; blockListUnreadableAlert = false
        return showing
    }

    /// Set by a Decline of a temporary-ID caller; the offer is asked for after that call's screen has closed.
    private var offerBlockUnknownAfterCall = false

    func declineFromScreen(_ controller: CallController) {
        let oneTime = controller.fingerprint == nil
        controller.decline()
        // Offered once the call screen has gone (`callFinished`). Device test 2026-11-12: asked for while the
        // full-screen call cover still showed "Call declined", the alert was never shown, and its stuck state then kept
        // the next call from presenting its screen (testACallRingingOverTheDeclineOfferStillShowsItsScreen).
        if oneTime, !blockUnknownCallers, !AppSettings.blockUnknownOfferDismissed { offerBlockUnknownAfterCall = true }
    }

    private func saveContacts() throws {
        guard contactsUnreadable == nil else { throw ProtocolError.state("The verified-contact store is unreadable; reset it first") }
        #if DEBUG
        // The simulator fixture's contacts live in memory only.
        if debugFixtureActive { contacts = book.contacts; rebuildLists(); return }
        #endif
        try VerifiedContactsStore.save(book.contacts)
        contacts = book.contacts
        rebuildLists()
    }

    func myQrText() -> String? {
        guard let fingerprint else { return nil }
        // The code is shown face to face to add a contact: it carries "Your name" unless "Who sees my name" is Nobody
        // (Android 2026-11-04, one name); otherwise the neutral "Phone"/"Mac" and the first five ID symbols.
        let own = displayName.trimmingCharacters(in: .whitespaces)
        let neutral = AppPlatform.isMac ? "Mac \(handle.prefix(5))" : "Phone \(handle.prefix(5))"
        let name = own.isEmpty || namesAudience == .nobody ? neutral : displayName
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
        if name == "readme" { applyReadmeFixture(); return }
        // `empty`: nobody nearby. The fixture is active so a real iPhone's radio does not fill the list with the phones around it.
        if name == "empty" { debugFixtureActive = true; people = []; streams = []; return }
        guard name == "populated" else { return }
        debugFixtureActive = true
        if RootView.debugArgument("-NearbyBluetoothStuck") == "1" { bluetoothRestartNeeded = true }
        let asha = Data(hex: "a1b2c3d4e5f6")!, ravi = Data(hex: "0102030405a8")!, stranger = Data(hex: "112233445566")!
        people = [
            PersonRow(id: UUID(), label: PeerLabel(prefix: asha, contactName: "Asha"), prefixHex: asha.hex, transport: .gatt, relays: 0, isIPhone: false),
            PersonRow(id: UUID(), label: PeerLabel(prefix: ravi), prefixHex: ravi.hex, transport: .l2cap, relays: 2, isIPhone: false),
            PersonRow(id: UUID(), label: PeerLabel.nearbyPhone(seed: stranger), prefixHex: stranger.hex, transport: .gatt, relays: 0, isIPhone: true),
        ]
        // `-NearbyFixtureCrowd 1`: more than 8 people nearby, so Calls shows Android's search field.
        if RootView.debugArgument("-NearbyFixtureCrowd") == "1" {
            for index in 1...7 {
                let seed = Data([0x20, 0x21, 0x22, 0x23, 0x24, UInt8(index)])
                people.append(PersonRow(id: UUID(), label: PeerLabel.nearbyPhone(seed: seed), prefixHex: seed.hex, transport: .gatt,
                                        relays: 0, isIPhone: false))
            }
        }
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
        // In memory only (saveContacts writes nothing while the fixture runs): Asha, scanned, and Ravi, checked by code, who
        // now calls themselves "Ravi Kumar". Their presence switches are real vault entries.
        var raviContact = VerifiedContact(fingerprint: IdentityFingerprint(publicKey: try! SoftwareSigningIdentity(rawScalar: Data(repeating: 9, count: 32)).publicKeyEncoded),
                                          displayName: "Ravi", method: "safety-code")
        raviContact.claimedName = "Ravi Kumar"
        raviContact.acknowledgedClaim = "Ravi"
        contacts = [VerifiedContact(fingerprint: IdentityFingerprint(publicKey: try! SoftwareSigningIdentity(rawScalar: Data(repeating: 7, count: 32)).publicKeyEncoded),
                                    displayName: "Asha", method: "qr"), raviContact]
        book.restore(contacts)
        recentCalls = [
            CallRecord(prefixHex: asha.hex, direction: .outgoing, video: true, at: Date().addingTimeInterval(-300), seconds: 125),
            CallRecord(prefixHex: ravi.hex, direction: .missed, video: false, at: Date().addingTimeInterval(-3_600), seconds: 0),
            CallRecord(prefixHex: asha.hex, direction: .incoming, video: false, at: Date().addingTimeInterval(-86_400), seconds: 3_725),
        ]
        // DEBUG fixtures for Calls and Recent: Ravi's row heard from two phones, a stranger's recent call, the follow-up
        // offer, and a history that cannot be opened.
        if RootView.debugArgument("-NearbyFixtureCopiedId") == "1" {
            people = people.map { row in var flagged = row; flagged.copiedId = row.prefixHex == ravi.hex; return flagged }
        }
        if RootView.debugArgument("-NearbyFixtureStranger") == "1" {
            recentCalls.insert(CallRecord(prefixHex: "", direction: .incoming, video: true, at: Date().addingTimeInterval(-120), seconds: 40,
                                          name: "gold fox", outcome: RecentCallOutcome.answered.rawValue), at: 0)
        }
        if RootView.debugArgument("-NearbyFixtureStrangerFollowUp") == "1" { strangerFollowUp = "Gold Fox" }
        if RootView.debugArgument("-NearbyFixtureRecentUnreadable") == "1" { recentCalls = []; recentUnreadable = true }
    }

    /// README screenshots (`-NearbyFixture readme`): the same invented people and streams as Android's store
    /// screenshots, a ready radio and an invented ID. Nothing is written; nothing from this device is shown.
    private(set) var debugReadme = false
    private func applyReadmeFixture() {
        debugFixtureActive = true
        debugReadme = true
        func rdi(_ hex: String) -> Data { Data(hex: hex)! }
        people = [("44e69c0a7a7d", "artsy cascade"), ("67aba670e65a", "boxy rapids")].map { hex, name in
            PersonRow(id: UUID(), label: PeerLabel.generated(name, seed: rdi(hex)), prefixHex: hex, transport: .gatt, relays: 0, isIPhone: false)
        }
        let streamFlags = DiscoveryAnnouncement.flagStreamAvailable | DiscoveryAnnouncement.flagGattTransport
        streams = [
            StreamRow(id: UUID(), label: PeerLabel.generated("tidy harbour", seed: rdi("5a5a5a5a5a5a")),
                      announcement: DiscoveryAnnouncement(nodeIdPrefix: rdi("5a5a5a5a5a5a"), flags: streamFlags, capabilitySummary: AudioLive.summaryAudioOnly,
                                                          streamToken: 0x8555_1234, routeCost: 0, sequence: 1, streamBitrateKbps: 25),
                      advertisedTitle: "Ward 12 updates"),
            StreamRow(id: UUID(), label: PeerLabel.generated("calm meadow", seed: rdi("6b6b6b6b6b6b")),
                      announcement: DiscoveryAnnouncement(nodeIdPrefix: rdi("6b6b6b6b6b6b"), flags: streamFlags, capabilitySummary: 1, streamToken: 0x8123_4567,
                                                          routeCost: 0, sequence: 1, streamWidth: 640, streamHeight: 360, streamFps: 15, streamBitrateKbps: 300),
                      advertisedTitle: "Village meeting"),
        ]
        contacts = []
        recentCalls = []
    }

    /// Screenshot aid only: `-NearbyScreen call` (outgoing, ringing), `call-incoming`, `call-incoming-voice`,
    /// `call-active`, `call-active-video` (camera on, no capture), `call-ended`, `call-mismatch`. Unconnected: no engine runs, nothing is sent.
    func showDebugCall(_ variant: String = "call") {
        guard call == nil, let identity else { return }
        let connectingCallee = variant.hasPrefix("call-connecting-callee")
        let incoming = variant.hasPrefix("call-incoming") || connectingCallee
        let controller = CallController(model: self, role: incoming ? .callee : .caller, peerName: "Asha", peerPrefixHex: "a1b2c3d4e5f6",
                                        identity: identity, transport: .gatt, type: variant == "call-incoming" || variant == "call-active-video" ? .video : .voice, relayHops: 0)
        controller.label = PeerLabel(prefix: Data(hex: "a1b2c3d4e5f6")!, selfName: "Asha")
        if incoming { controller.debugSetClaimedName("asha") }
        switch variant {
        case "call-connecting-callee", "call-connecting-callee-rings":
            // A1 fixture: an authenticated callee link that has not carried a ringing Invite yet.
            controller.phaseText = "Connecting…"
            if variant == "call-connecting-callee-rings" {
                // `-NearbyFixtureDeclineOffer 1`: the "Block all unknown callers?" alert of an earlier Decline is up.
                if RootView.debugArgument("-NearbyFixtureDeclineOffer") == "1" { askBlockUnknown = true }
                // P6-A1: the Invite arrives after `call = controller`, as it does on a real link.
                let ringAfter = RootView.debugArgument("-NearbyFixtureRingAfter").flatMap(Double.init) ?? 1
                DispatchQueue.main.asyncAfter(deadline: .now() + ringAfter) { [weak controller] in
                    controller?.phase = .incomingRinging
                    controller?.phaseText = "Incoming call"
                }
            }
        case "call-incoming", "call-incoming-voice":
            controller.phase = .incomingRinging; controller.offeredType = variant == "call-incoming" ? .video : .voice
            controller.phaseText = "Incoming call"
            if variant == "call-incoming" { controller.fingerprint = SoftwareSigningIdentity().fingerprint }   // a real-key caller (Decline and block shows)
            if let seconds = RootView.debugArgument("-NearbyFixtureMissAfter").flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak controller] in
                    if controller?.phase == .incomingRinging { controller?.debugCallerGaveUp() }
                }
            }
            // `-NearbyFixtureRingAgainAfter N`: N s after launch a second call rings (device test 2026-11-12: Decline a
            // temporary-ID call, its "Block all unknown callers?" alert shows, and the next call must still show).
            if let seconds = RootView.debugArgument("-NearbyFixtureRingAgainAfter").flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    guard let self, self.call == nil || self.call?.ended != nil else { return }
                    self.call = nil
                    self.showDebugCall("call-connecting-callee-rings")
                }
            }
        case "call-active", "call-mismatch", "call-active-video":
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
        #if os(macOS)
        desktopStopping = true
        desktopCallScanning.stop()
        desktopAdvertising.stop()
        #endif
        // The call is detached first, so its end never records, notifies or shows anything after the wipe.
        let ending = call; call = nil
        ending?.end(); watch?.stop(); live?.stop()
        joinSessions.end(.wipe)   // D1
        radio.stopAll()
        streamRoutePenalties.reset(); streamNotice = nil
        audioRelayMemory.reset()
        bmh3Pins.clear()
        _ = EmergencyWipe.run()
        blockListHolder.clear()
        identity = nil; contacts = []; book.reset(); authenticated = [:]; people = []; streams = []; recentCalls = []; blockList = nil;
        strangerFollowUp = nil; recentUnreadable = false; hiddenStreamRoutes = []; hiddenStreamAddresses = []; blockListDamaged = false
        wiped = true
    }
}
