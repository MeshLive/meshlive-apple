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
    @Published var availableForCalls = AppSettings.availableForCalls { didSet { AppSettings.availableForCalls = availableForCalls; refreshAdvertising() } }
    @Published var wiped = false
    /// EXPERIMENTAL rotating discovery IDs (Settings > Advanced).
    @Published var rotatingIds = AppSettings.rotatingIds {
        didSet { AppSettings.rotatingIds = rotatingIds; radio.acceptRotating = rotatingIds; refreshAdvertising() }
    }
    let rotating = RotatingDiscoveryRuntime()
    private var rotationTimer: Timer?
    private var advertisedEpoch: Int64 = -1
    private var boundarySilenceUntil: Date?

    /// At each epoch boundary: stop, stay silent a uniform 1-8 s (RV12), then advertise the new ID.
    private func checkRotation() {
        guard rotatingIds, advertisedEpoch >= 0, boundarySilenceUntil == nil else { return }
        guard rotating.currentEpoch() != advertisedEpoch else { return }
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
        call?.enterForeground()
        start()
    }

    // MARK: Lists

    private func rebuildLists() {
        // Stable order: contacts first by name, then others by handle (rows no longer use advertised names).
        let peers = radio.peers.values.sorted { a, b in
            let ca = contactName(prefixHex: a.prefixHex), cb = contactName(prefixHex: b.prefixHex)
            if (ca != nil) != (cb != nil) { return ca != nil }
            return (ca ?? a.prefixHex, a.announcement.streamToken) < (cb ?? b.prefixHex, b.announcement.streamToken)
        }
        people = peers.filter { $0.announcement.isPrivateCallOffer && !$0.announcement.usesClassic }.map { p in
            // Pre-connect the prefix is an unauthenticated hint: a verified contact's local name may label the row,
            // but the row never claims "verified" (Android shows no badge here either).
            PersonRow(id: p.id, label: p.announcement.rotating ? PeerLabel.nearbyPhone(seed: p.announcement.nodeIdPrefix)
                        : PeerLabel(prefix: p.announcement.nodeIdPrefix, contactName: contactName(prefixHex: p.prefixHex)),
                      prefixHex: p.prefixHex, transport: p.announcement.transport ?? .gatt, relays: Int(p.announcement.routeCost), isIPhone: p.isIPhone)
        }
        streams = peers.filter { $0.announcement.isStreamOffer && !$0.announcement.usesClassic }.map {
            StreamRow(id: $0.id, label: PeerLabel(prefix: $0.announcement.nodeIdPrefix, contactName: contactName(prefixHex: $0.prefixHex)),
                      announcement: $0.announcement, advertisedTitle: peerLabelsEnabled ? radio.titleBoard.title(routeToken: $0.announcement.streamToken) : nil)
        }
        live?.viewerRequestsChanged(peers)
    }

    func contactName(prefixHex: String) -> String? { contacts.first { $0.nodePrefixHex == prefixHex }?.displayName }

    // MARK: Advertising (one kind at a time)

    func refreshAdvertising() {
        guard let identity else { return }
        let prefix = identity.nodeId.prefix
        let gattFlag = { (t: MeshTransport) in t == .gatt ? DiscoveryAnnouncement.flagGattTransport : 0 }
        var announcement: DiscoveryAnnouncement?
        if let watch, watch.awaitingSource {
            let offer = watch.offer
            announcement = DiscoveryAnnouncement(nodeIdPrefix: prefix, flags: DiscoveryAnnouncement.flagAcceptingConnections | gattFlag(watch.transport),
                                                 capabilitySummary: decodeMask, streamToken: offer.streamToken, routeCost: offer.routeCost,
                                                 streamBitrateKbps: offer.streamBitrateKbps)
        } else if let live, live.running {
            announcement = live.offerAnnouncement(prefix: prefix)
        } else if availableForCalls, call == nil, watch == nil {
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
        if let watch, watch.awaitingSource { watch.attach(link); refreshAdvertising(); return }
        guard call == nil, availableForCalls, let identity else { link.close(); return }
        let pins = rotating.pins
        let controller = CallController(model: self, role: .callee, peerName: "Incoming call", peerPrefixHex: nil,
                                        identity: identity, transport: link.transport, type: .video, relayHops: 0,
                                        rotating: rotatingIds ? RotatingCallOptions(entries: { pins.pinned(elapsedMs: RotatingDiscoveryRuntime.elapsedMs) }) : nil)
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
                                        rotating: rotatingIds ? RotatingCallOptions(selected: peer.announcement) : nil)
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

    func goLive() {
        guard live == nil, let identity else { return }
        live = LiveController(model: self, identity: identity, transport: transport,
                              labels: peerLabelsEnabled, title: liveTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : liveTitle)
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

    func forget(_ contact: VerifiedContact) { book.forget(contact.fingerprintHex); try? saveContacts() }

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
    /// Screenshot aid only (`-NearbyScreen call`): an unconnected outgoing call screen.
    func showDebugCall() {
        guard call == nil, let identity else { return }
        call = CallController(model: self, role: .caller, peerName: "Asha", peerPrefixHex: "a1b2c3d4e5f6", identity: identity,
                              transport: .gatt, type: .voice, relayHops: 0)
        call?.label = PeerLabel(prefix: Data(hex: "a1b2c3d4e5f6")!, selfName: "Asha")
        call?.phaseText = "Ringing…"
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
