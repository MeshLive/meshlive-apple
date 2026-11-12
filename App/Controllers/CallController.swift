import Foundation
import SwiftUI
import NearbyCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif
#if canImport(NearbyMedia)
import NearbyMedia
#endif

// MARK: - Calls

final class CallController: ObservableObject, Identifiable {
    let id = UUID()
    weak var model: AppModel?
    let role: PrivateCallRole
    let transport: MeshTransport
    @Published var phase: PrivateCallPhase? {
        didSet {
            if phase == .incomingRinging && !rang {
                rang = true
                if !busyMode {
                    // Device test 2026-11-12: after a plain Decline the "Block all unknown callers?" alert was still up
                    // when the next call rang; the call screen cannot be presented over it, so the phone vibrated for a
                    // minute with nothing to answer or decline. A ringing call closes those root alerts first.
                    if model?.closeAlertsForRingingCall() == true {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.model?.objectWillChange.send() }
                    }
                    model?.objectWillChange.send()   // P6-A1: root views read presentable through the model
                }
            }
        }
    }
    /// This incoming call rang here (a link that failed before ringing is not a missed call).
    private(set) var rang = false
    /// Nothing of a callee is presented before its call rings (P6-A1); a caller's own screen shows from the tap.
    var presentable: Bool { role == .caller || rang }
    @Published var phaseText = ""
    #if DEBUG
    @Published var peerName: String {
        didSet { debugLogPeerNameChange(from: oldValue) }
    }
    #else
    @Published var peerName: String
    #endif
    @Published var peerPrefixHex: String?
    @Published var fingerprint: IdentityFingerprint?
    @Published var verification: VerificationState = .unverified
    @Published var callType: CallType
    @Published var offeredType: CallType = .video
    @Published var muted = false
    @Published var cameraOn: Bool
    @Published var speaker: Bool
    @Published var remoteCameraOn = true
    @Published var remoteMuted = false
    @Published var ended: String?
    @Published var relayed = false
    /// The caller's hop count (G37); nil when this side does not know it, as a callee of a relayed call never does.
    @Published var relayCount: Int?
    /// Relayed calls: the on-demand route this caller dialled, and how it went.
    var relayRoute: RelayRoute?
    var relayConnectFailed = false
    var relayReady: Bool { engine.relayReadyRelays != nil }
    /// The end-to-end peer was authenticated (for a stranger: after its reveal), review item 3.
    private(set) var endToEndVerified = false
    /// Why the route failed before READY (a first hop that could not be connected or closed early counts as a timeout).
    var relayFailure: RelaySetupFailure? { engine.relaySetupFailure ?? (relayConnectFailed || engine.relayedRouteFailed ? .timeout : nil) }
    var userCancelled = false
    /// Glare: the real prefix of the person this caller dials, when known.
    var dialTargetPrefixHex: String?
    /// A busy listener (DialCollision): never shown, never rings unless promoted to the device's call.
    var busyMode = false
    /// A caller still looking for its person (no link yet).
    var isConnecting: Bool { role == .caller && driver == nil && ended == nil }
    /// Busy listener: the Invite is declined with BUSY unless `ring` says the caller is the person being dialled.
    func configureBusy(ring: @escaping (NodeId?) -> Bool) {
        busyMode = true
        engine.declineAsBusy = true
        engine.ringInsteadOfBusy = ring
    }
    /// The busy listener really answered the Invite with BUSY (the caller was told this device is busy).
    var declinedBusy: Bool { engine.declinedBusy }
    /// A search was not sent because the first hop did not sign RELAY_SEEK.
    var relaySeekRefusedLocally: Bool { engine.closeReason?.contains("does not search") == true }

    /// Relayed calls: this listener's link is taken over by a relay duty. The engine already stopped silently; the driver
    /// stops without closing the link, timers stop, and nothing is shown or remembered. Returns the link.
    func abandonForRelay() -> (link: MeshLink, engine: CallEngine)? {
        guard let driver else { return nil }
        driver.detach()
        self.driver = nil
        statsTimer?.invalidate(); statsTimer = nil
        ringer.stop()
        ended = ""
        return (driver.link, engine)
    }
    /// The stranger notice under a ring (nil for a contact): a relayed stranger call names the possible relay in the middle.
    @Published var ringNotice: String?

    private func ringText(_ type: CallType) -> String {
        if engine.isRelayed { relayed = true }
        ringNotice = engine.peerIsStranger ? RelayedCallPolicy.strangerRingStatus(viaRelay: engine.isRelayed) : nil
        let base = type == .voice ? "Incoming voice call" : "Incoming video call"
        return engine.isRelayed ? "\(base) \(RelayedCallPolicy.viaRelayStatus)" : base
    }
    @Published var stats = ""
    /// Settings › Manual video when this call started: what the user asked to send (kept as chosen) and whether nothing
    /// may adapt to the link (Android's CBR arm).
    let requestedVideo: VideoRequest
    let exactVideo: Bool
    /// Call info › Video: what the encoder sends now, and why it is lower than the request (one line per reason).
    @Published private(set) var videoSending: String?
    @Published private(set) var videoNotes: [String] = []
    private var heatPercent = 100
    /// The camera the heat frame-rate limit was last applied to.
    private var heatCamera: ObjectIdentifier?
    /// Android's per-transport call budget with Manual video on (`CallTransportCap`), nil when it does not apply. The
    /// request (`requestedVideo`) is kept as chosen; call info shows the cap.
    private(set) var transportCapKbps: Int?
    /// Call info: "Link currently allows about N kbps" (the encoder's current target while rate control runs).
    @Published private(set) var videoAllowsKbps: Int?
    /// Android RemoteVideoFit: this call's double-tap choice (true fill, false the whole picture); nil follows the rule.
    @Published var remoteFitOverride: Bool?
    @Published var label: PeerLabel?
    /// Naming v2: the peer's verified self-chosen name in this call, shown "~Name" unless your own contact name wins.
    /// Never put in a notification. For a verified contact it is also kept with the contact (sealed; Android
    /// ContactClaims) for the contact sheet's "They call themselves ..."; for anyone else it is not stored.
    @Published private(set) var claimedName: String?
    /// The generated name of a stranger's throwaway key (both phones derive the same one), kept for Recent (Android F20).
    private(set) var strangerName: String?
    /// Call blocking: the identity this call revealed is blocked here; the call ends shortly.
    private(set) var blockedAfterReveal = false
    static let blockedEndText = "Call ended: this is someone you blocked."
    /// A claimed name that reads the same as one of your contacts (minimal-table sameness, P5-A1).
    var imitates: String? { guard label?.contactName == nil, let c = claimedName else { return nil }; return model?.contacts.first { NameReading.same(c, $0.displayName) }?.displayName }
    /// Android's second line under a self-claimed name ("Gold Fox - not verified"), nil otherwise.
    var claimedNote: String? {
        guard claimedName != nil, label?.contactName == nil else { return nil }
        if let x = imitates { return fingerprint == nil ? "Says they are \(x)" : "Not your contact \(x)" }
        let base = strangerName.map(GeneratedNameText.display) ?? label.flatMap { $0.handle.isEmpty ? nil : $0.handle } ?? OwnNearbyName.someoneNearby
        return "\(base) - not verified"
    }
    @Published var activeSince: Date?
    /// True while Mute is held down during a muted call (talking until release).
    @Published var talking = false
    /// Another app or the system has the audio (a phone call, Siri): the microphone is off and the peer sees
    /// "muted" (signal 9, as Android sends on audio-focus loss) until it ends.
    @Published var onHold = false
    private var mutedBeforeHold = false
    private let ringer = Ringer()
    /// Android ringback (`CallRinger.startRingback`, on): the caller hears ringing while the other phone rings.
    /// DEBUG control arm `-ringback NO`.
    private let ringback = Ringback()
    private let ringbackOn = AppSettings.labSwitch("ringback", shipped: true)
    /// Android camera pause at the ear: the outgoing camera is paused by the proximity sensor (not by the user).
    @Published private(set) var earPaused = false
    private var proximityObserver: NSObjectProtocol?
    /// The engine's own end reason, for Recent's outcome (Answered, Missed, Declined, No answer, Failed).
    private(set) var endReason: String?
    /// Visible media problem (microphone/camera/audio), shown on the call screen.
    @Published var mediaProblem: String?
    /// Android CallMediaAccess: what a refused camera or microphone means, shown as a caption; it does not answer the call.
    @Published var accessNotice: String?
    @Published var accessNoticeOpensSettings = false
    /// B1.5: the decoder recovery caption (recovering, then stopped); nil while the picture is healthy.
    @Published var videoNotice: String?
    let remote = RemoteVideo()
    private var rateController: VideoRateController?
    /// Call resolution ladder (on for user calls, like Android; DEBUG -NearbyResolutionLadder 0 turns it off).
    private var ladder: CallResolutionLadder?
    private var lastRateWindow: (at: TimeInterval, encoded: Int, sent: UInt64)?
    private var audioFromEncoder = 0, videoFromEncoder = 0, videoShed = 0, remoteAudioWithoutPlayer = 0, remoteAudioEvents = 0, remoteVideoEvents = 0
    private var engine: CallEngine
    private var driver: ConnectionDriver?
    private var wifiGuest: WifiDirectGuest?
    private var renewalRadio: CallRenewalRadio?
    private var audio: CallAudio?
    /// The call's Opus bitrate (fixed on Apple); call info shows it as Android's "Sound: N kbps".
    static let audioBitrate = 24_000
    private(set) var camera: CameraVideo?
    private var statsTimer: Timer?
    private var linkPeer: NodeId?
    #if os(macOS)
    private let desktopDelivery = DesktopCallDelivery()
    #endif

    init(model: AppModel, role: PrivateCallRole, peerName: String, peerPrefixHex: String?, identity: SigningIdentity,
         transport: MeshTransport, type: CallType, relayHops: UInt8, rotating: RotatingCallOptions? = nil, bmh3: Bmh3CallOptions? = nil,
         relayed relayedOptions: RelayedCallOptions? = nil) {
        self.model = model; self.role = role; self.transport = transport; self.peerName = peerName; self.peerPrefixHex = peerPrefixHex
        requestedVideo = model.videoRequest; exactVideo = model.manualVideo
        callType = type; cameraOn = type == .video
        #if os(macOS)
        speaker = true
        #else
        speaker = type == .video
        #endif
        let expected = peerPrefixHex.flatMap { Data(hex: $0) }
        // Portrait capture; 240x426 keeps software VP9 light and fits the Android call profiles on Bluetooth.
        // Settings › Manual video (standard: 426x240, portrait 240x426, at 15 FPS, 200 kbps; design decision 2026-10-10).
        // Android privateCallVideoSettings: with Manual video settings on the call starts at most at the transport's
        // budget (GATT 180, L2CAP 200 kbps); the request stays as chosen and call info shows the cap.
        let cap = CallTransportCap.cap(transport: transport, manual: model.manualVideo, enabled: AppSettings.callTransportCap)
        transportCapKbps = cap
        let settings = CallMediaSettings(width: requestedVideo.width, height: requestedVideo.height, fps: requestedVideo.fps,
                                         videoBitrate: CallTransportCap.startKbps(requested: requestedVideo.kbps, cap: cap) * 1000,
                                         audioBitrate: 24_000)
        // Android CallHeadOfLine (promoted 2026-10-11): video fragments on direct GATT calls; Android's speech-led playout
        // follows on the Android side. Control arm `-callVideoFragments NO`.
        engine = CallEngine(role: role, transport: transport, identity: identity, requestedType: type, encodeMask: VideoDecoderSupport.encodeMask,
                            decodeMask: VideoDecoderSupport.decodeMask, settings: settings, expectedPeerPrefix: expected, relayHops: relayHops,
                            videoFragments: CallHeadOfLine.videoFragments(enabled: AppSettings.labSwitch("callVideoFragments", shipped: true), transport: transport, relayHops: relayHops),
                            wifi: AppSettings.wifiWire ? WifiCallAgent.Config(directClient: model.wifiDirectClientPossible) : nil,
                            labels: model.callLabelOptions(), rotating: rotating, bmh3: bmh3, relayed: relayedOptions,
                            linkRenewal: CallRenewalRadio.enabled)
        CallRenewalRadio.configure(engine)
        if rotating != nil, role == .callee {
            // Stranger tarpit: strangers' link hellos wait 2^(n-6) s per epoch; verified contacts never wait.
            let runtime = model.rotating
            engine.responderHelloDelay = { [weak model] peer in
                if model?.contacts.contains(where: { $0.nodePrefixHex == peer.prefix.hex }) == true { return 0 }
                let ms = runtime.tarpit.nextDelayMs(epoch: runtime.currentEpoch())
                AppLog.event("rotating_ids", ["event": "tarpit", "delayMs": "\(ms)"])
                return TimeInterval(ms) / 1000
            }
        }
        engine.identityGate = model.book
        // BVMID2 (Design QL): the Add contact screen's visit decides whether a displayer answers a scanner's OFFER.
        engine.meetVisit = model.meet.visit
        // Call blocking (Android CallGate): asked at the Invite, before anything rings; and a block follows the real
        // identity a stranger's reveal shows (both roles). Both fail open.
        if role == .callee { engine.callGate = { [weak model] caller in model?.callGateDecision(caller) ?? .ring } }
        engine.personBlocked = { [weak model] fingerprint in model?.isBlocked(fingerprint) ?? false }
        engine.onEvent = { [weak self] in self?.handle($0) }
        // AB5 (Design HC, Experimental): the call codec choice reads this device's encoders and the power state now.
        engine.codecChoiceInputs = HardwareCodecSwitches.callInputs()
        engine.onAccessUnitRejected = { codec, rule, nalType, bytes in
            AppLog.event("au_reject", ["codec": codec.label, "rule": "\(rule)", "type": "\(nalType)", "bytes": "\(bytes)"])
        }
        #if os(macOS)
        engine.onMediaSubmitted = { [weak self] bytes, audio, at in self?.desktopDelivery.submitted(payloadBytes: bytes, audio: audio, at: at) }
        #endif
        remote.onNeedKeyFrame = { [weak self] in self?.engine.requestKeyFrame(); self?.pump() }
        remote.onFirstPicture = { [weak self] in self?.markStage("first_frame") }
        // B1.5 (Android decoder stall recovery, promoted): on by default; `-callVideoRecovery NO` is BASE. The watch path
        // never sets the object, so its RemoteVideo is unchanged.
        if AppSettings.labSwitch("callVideoRecovery", shipped: true) { remote.recovery = VideoDecoderRecovery() }
        remote.onRecoveryNotice = { [weak self] text in self?.videoNotice = text }
        remote.onVideoStopped = { [weak self] in self?.videoNotice = VideoRecoveryNotice.stopped }
        relayed = relayHops > 0
        relayCount = role == .caller && relayHops > 0 ? Int(relayHops) : nil
        engine.acceptRelayedCalls = model.relayedCalls && model.relayedCallsConsent
        // As Android: 15 s (relayed 30 s) from hop authentication to Ringing; `-callerAnswerDeadline NO`.
        engine.callerAnswerDeadline = AppSettings.labSwitch("callerAnswerDeadline", shipped: true)
        // Call audio coalescing (Android callAudioCoalesce, on since 2026-10-27; no wire change). Control arm
        // `-callAudioCoalesce NO`.
        engine.queues.coalesceAudio = AppSettings.labSwitch("callAudioCoalesce", shipped: true)
        engine.onWifiRequest = { [weak self] in self?.handleWifi($0) }
        engine.onWifiLog = { event, fields in AppLog.event(event, fields) }
        #if os(iOS)
        engine.wifiForeground = { UIApplication.shared.applicationState == .active }
        #endif
        engine.acceptRelayedStrangerCalls = AppSettings.relayedStrangerCalls
        phaseText = role == .caller ? "Calling…" : "Connecting…"
        #if DEBUG
        debugLogPeerNameChange()
        #endif
    }

    func attach(_ link: MeshLink) {
        #if os(macOS)
        guard driver == nil, busyMode || model?.desktopCallLinkAttached(self) == true else { link.close(); return }
        #else
        guard driver == nil, ended == nil else { link.close(); return }
        #endif
        let driver = ConnectionDriver(engine: engine, link: link)
        driver.onFinished = { [weak self] reason in self?.finished(reason) }
        self.driver = driver
        if engine.renewal != nil, let radio = model?.radio { renewalRadio = CallRenewalRadio(engine: engine, radio: radio, driver: { [weak self] in self?.driver }) }
        linkAttachedAt = ProcessInfo.processInfo.systemUptime
        if timeline == nil { startTimeline(origin: linkAttachedAt ?? 0) }   // callee: from the incoming link
        markStage("link_attached")
        driver.start()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshStats() }
    }

    /// True when the call ended with an error before it was ever active (shown again on the Call screen).
    private(set) var failedEarly = false

    func failed(_ reason: String, stage: String = "connect", detail: String = "") {
        #if os(macOS)
        model?.desktopCallLinkFinished(self)
        #endif
        AppLog.event("call_end", ["reason": reason, "error": "true", "stage": stage, "detail": detail])
        failedEarly = true
        ended = reason; phaseText = reason; cleanupMedia(); scheduleDismiss(after: 6)
    }

    private func pump() { driver?.pump() }

    private func handleWifi(_ request: WifiCallAgent.Request) {
        switch request {
        case .join(let ssid, let passphrase, _, let ticket):
            let guest = WifiDirectGuest(engine: engine, pumpBluetooth: { [weak self] in self?.driver?.pump() })
            wifiGuest = guest
            guest.join(ssid: ssid, passphrase: passphrase, ticket: ticket)
        case .connect(let host, let port, let local, _):
            wifiGuest?.connect(host: host, port: port, local: local)
        case .closeSocket:
            wifiGuest?.closeSocket()
        case .leave:
            wifiGuest?.leave(); wifiGuest = nil
        case .keyFrame:
            camera?.requestKeyFrame()
        }
        driver?.pump()
    }

    private func handle(_ event: CallEngine.Event) {
        log(event)
        switch event {
        case .linkAuthenticated(let id): linkPeer = id
        case .peerAuthenticated(let id, let fp):
            fingerprint = fp
            peerPrefixHex = id.prefix.hex
            model?.noteAuthenticated(fp)
            verification = model?.verificationState(of: fp) ?? .unverified
            if let name = claimedName, verification == .verified { model?.recordContactClaim(fp, name: name) }
            let contact = model?.contactName(prefixHex: id.prefix.hex)
            // After a stranger's reveal its claimed name stays with the call for display ("re-keyed"); a contact's own
            // label always wins.
            let newLabel = PeerLabel(prefix: id.prefix, contactName: contact, selfName: contact == nil ? claimedName : nil,
                                     verified: verification == .verified)
            label = newLabel; peerName = newLabel.title
            if let linkPeer, linkPeer != id, !engine.linkPeerPseudonymous { relayed = true }
        case .peerStranger:
            // BMH3 pseudonyms: a throwaway key; the real identity (and the call history entry) only after its reveal.
            fingerprint = nil; verification = .unverified
            label = nil
            strangerName = model?.desktopGeneratedNames == true ? DesktopNearbyNames.shared?.name(forStranger: engine)?.text : nil
            peerName = claimedName.map { "~" + $0 } ?? strangerName.map(GeneratedNameText.display) ?? OwnNearbyName.someoneNearby
        case .phase(let p):
            phase = p
            if p == .incomingRinging { ringer.start() } else { ringer.stop() }
            // AB3: no ringback while a call with someone you blocked waits for its ordinary end.
            if CallTones.ringbackPlays(enabled: ringbackOn && !busyMode && !blockedAfterReveal, phase: p) { ringback.start(speaker: speaker) } else { ringback.stop() }
            if !busyMode { CallNotifier.shared.update(for: self) }
            switch p {
            case .outgoingInvite: phaseText = "Calling…"
            case .outgoingRinging: phaseText = "Ringing…"
            case .incomingRinging: phaseText = ringText(offeredType)
            case .negotiatingMedia: phaseText = callType == .voice ? "Starting the voice call…" : "Starting video and sound…"
            case .active: phaseText = ""; if activeSince == nil { activeSince = Date() }; updateEarPause()
            case .ended: phaseText = "Call ended"
            }
            if blockedAfterReveal { phaseText = Self.blockedEndText }
        case .incomingCall(let type):
            offeredType = type; callType = type
            if let runtime = model?.rotating, model?.rotatingIds == true { runtime.tarpit.forgive(epoch: runtime.currentEpoch()) }
        case .offeredTypeChanged(let type):
            offeredType = type; callType = type
            if phase == .incomingRinging { phaseText = ringText(type) }
        case .startLocalMedia(let header, let type):
            callType = type; cameraOn = type == .video
            startMedia(header: header, video: type == .video)
        case .remoteHeader(let header):
            remote.onDecoderUnavailable = { [weak self] detail in self?.endForLocalMediaFailure(.videoDecoderSetup, detail: detail) }
            remote.configure(header: header)
        case .remoteAudio(let packet):
            remoteAudioEvents += 1
            if remoteAudioEvents == 1 { markStage("first_audio_rx") }
            if let audio { audio.receive(presentationTimeUs: packet.presentationTimeUs, opus: packet.payload) } else { remoteAudioWithoutPlayer += 1 }
        case .remoteVideo(let packet): remoteVideoEvents += 1; remote.decode(packet)
        case .remoteRotation(let degrees): remote.sink.rotation = degrees
        case .remoteCamera(let on): remoteCameraOn = on; if on { remote.requestKeyFrame() }
        case .remoteMuted(let m): remoteMuted = m
        case .keyFrameRequested: camera?.requestKeyFrame()
        case .peerReport(let report):
            #if os(macOS)
            if !relayed { desktopDelivery.accept(report) }
            #endif
            break
        case .peerLabels(let name):
            // Naming v2: a verified signed name for this call only, shown "~Name"; your contact's own label always wins
            // and nothing is cached. A stranger's name (signed by its pseudonym) shows before the reveal too.
            claimedName = name
            if let name, let fp = fingerprint, verification == .verified { model?.recordContactClaim(fp, name: name) }
            if let current = label, let prefix = peerPrefixHex.flatMap({ Data(hex: $0) }), prefix.count == 6 {
                let updated = PeerLabel(prefix: prefix, contactName: current.contactName,
                                        selfName: current.contactName == nil ? name : nil, verified: current.verified)
                label = updated; peerName = updated.title
            } else if label == nil {
                peerName = name.map { "~" + $0 } ?? strangerName.map(GeneratedNameText.display) ?? peerName
            }
        case .relaySetupRequested(let message):
            model?.relaySetupRequested(by: self, message: message)
        case .relayReady(let relays):
            relayed = true; markStage("relay_ready")
            AppLog.event("relayed_setup", ["role": "caller", "result": "ready", "relays": "\(relays)"])
        case .declinedSilently(let decision):
            model?.hideSilentDecline(self, unknown: decision == .declineUnknown)
            if let runtime = model?.rotating, model?.rotatingIds == true { runtime.tarpit.forgive(epoch: runtime.currentEpoch()) }
        case .blockedAfterReveal:
            blockedAfterReveal = true
            ringback.stop()
            phaseText = Self.blockedEndText
        case .verificationCommitted(let fp, let committed):
            // BVMID2 displayer: never a call (it never rings, so nothing is shown or remembered). The Add contact screen
            // hears of the scan from the code itself; the key of a scan that consumed the code is noted for this process.
            if committed { model?.noteAuthenticated(fp) }
        case .verificationLeaseStored(let fp):
            model?.meet.leaseStored(fp)
        case .verificationReached:
            break
        case .ended(let reason, let error):
            endReason = reason
            // An error before the call was ever active stays readable longer and is repeated on the Call screen.
            #if os(macOS)
            model?.desktopCallLinkFinished(self)
            #endif
            if closedBeforeRinging {
                AppLog.event("call_end", ["reason": reason, "error": "\(error)", "stage": "closed_before_ringing", "shown": "false"])
                ended = ""; phaseText = ""; cleanupMedia(); scheduleDismiss(after: 0); return
            }
            let missed = missedHere
            if error && activeSince == nil && !missed && !answeredHere { failedEarly = true }
            let plain = CallController.plainReason(reason)
            // A callee whose caller gave up sees "Missed call" (Android CallRingTimeout), not a connection failure.
            let shown = blockedAfterReveal ? Self.blockedEndText : missed ? "Missed call"
                : error && activeSince == nil ? couldNotConnectText : plain
            ended = shown; phaseText = shown; cleanupMedia(); scheduleDismiss(after: error ? 6 : 2)
        }
    }

    private let mediaClock = ProcessInfo.processInfo.systemUptime
    /// When the Bluetooth link was attached: `linkMs` on call_auth and call_phase times the handshake and setup.
    private var linkAttachedAt: TimeInterval?
    /// Setup stages from the tap (caller) or the incoming link (callee) to the first media; `call_stage` per stage and
    /// one `call_setup_timeline` summary at the first remote picture (video) or audio (voice), or at the end.
    private(set) var timeline: CallSetupTimeline?
    private var timelineLogged = false
    #if DEBUG
    /// A6: the last stage `markStage` actually logged, and the number of `peerName` changes.
    private var lastMarkedStage = "none"
    private var peerNameChanges = 0
    #endif

    func startTimeline(origin: TimeInterval) {
        guard timeline == nil else { return }
        timeline = CallSetupTimeline(origin: origin)
        markStage(role == .caller ? "tap" : "incoming_link", at: origin)
    }

    func markStage(_ name: String, at: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard timeline != nil, !timelineLogged, let step = timeline?.mark(name, at: at) else { return }
        AppLog.event("call_stage", ["role": role == .caller ? "caller" : "callee", "stage": name, "ms": "\(step.ms)", "stepMs": "\(step.stepMs)"])
        #if DEBUG
        lastMarkedStage = name
        #endif
        let done = callType == .video ? "first_frame" : "first_audio_rx"
        if name == done { logTimeline(complete: true) }
    }

    private func logTimeline(complete: Bool) {
        guard let timeline, !timelineLogged else { return }
        timelineLogged = true
        let largest = timeline.largestStep
        AppLog.event("call_setup_timeline", ["role": role == .caller ? "caller" : "callee", "type": callType.rawValue, "complete": "\(complete)",
                                             "totalMs": "\(timeline.totalMs)", "largestStep": largest?.name ?? "-",
                                             "largestStepMs": "\(largest?.ms ?? 0)", "transport": transport.rawValue,
                                             "relayed": "\(relayed)", "stages": timeline.summary])
    }

    #if DEBUG
    /// A6: log only the name's kind and timing, never the text itself.
    private func debugLogPeerNameChange(from oldValue: String? = nil) {
        if let oldValue {
            guard peerName != oldValue else { return }
            peerNameChanges += 1
        }
        let kind: String
        if peerName.hasPrefix("~") { kind = "claimed" }
        else if peerName == OwnNearbyName.someoneNearby { kind = "someone" }
        else { kind = "label" }
        let ms = timeline.map { AppLog.ms(since: $0.origin) } ?? "-1"
        AppLog.event("call_name", ["role": role == .caller ? "caller" : "callee", "kind": kind,
                                   "changes": "\(peerNameChanges)", "stage": lastMarkedStage, "ms": ms])
    }
    #endif

    private var linkMs: String { linkAttachedAt.map { "\(Int(((ProcessInfo.processInfo.systemUptime - $0) * 1000).rounded()))" } ?? "-" }

    private var lastStatsLog: TimeInterval = 0
    private func log(_ event: CallEngine.Event) {
        switch event {
        case .linkAuthenticated(let id): markStage("link_auth"); AppLog.event("call_auth", ["stage": "link", "peer": id.shortLabel, "transport": transport.rawValue, "linkMs": linkMs])
        case .peerAuthenticated(let id, let fp):
            markStage("endpoint_auth")
            endToEndVerified = true
            AppLog.event("call_auth", ["stage": "endpoint", "linkMs": linkMs, "peer": id.shortLabel, "handle": IdentityHandle.handle(prefix: id.prefix) ?? "?",
                                       "fingerprint": String(fp.hex.prefix(16)), "codec": engine.selectedCodec.map { VideoCodecMap.label(codecId: $0) } ?? "pending",
                                       "peerCaps": engine.endpoint.map { String(format: "t%02x/e%02x/d%02x/max%d", $0.peerCapabilities.transportMask, $0.peerCapabilities.encodeCodecMask, $0.peerCapabilities.decodeCodecMask, $0.peerCapabilities.maxBitrateKbps) } ?? "?"])
        case .peerStranger:
            markStage("endpoint_auth")
            AppLog.event("bmh3", ["event": "peer", "layer": "endpoint", "pseudonymous": "true", "linkBmh3": "\(engine.linkUsedBmh3)"])
        case .phase(let p):
            switch p {
            case .outgoingInvite: markStage("invite")
            case .outgoingRinging, .incomingRinging: markStage("ringing"); if p == .outgoingRinging { prewarmCallerAudio() }
            case .negotiatingMedia: markStage("accepted")
            case .active: markStage("active")
            default: break
            }
            AppLog.event("call_phase", ["role": role == .caller ? "caller" : "callee", "phase": "\(p)", "callId": engine.state?.callId.uuidString ?? "-", "linkMs": linkMs])
        case .incomingCall(let t), .offeredTypeChanged(let t): AppLog.event("call_offer", ["type": t.rawValue])
        case .startLocalMedia(let h, let t):
            AppLog.event("call_media_start", ["type": t.rawValue, "codec": "\(h.codecId)", "size": "\(h.width)x\(h.height)", "fps": "\(h.fps)"])
            if let choice = engine.codecChoice { AppLog.event("encoder_choice", choice.logFields(role: role == .caller ? "caller" : "callee")) }
        case .remoteHeader(let h): AppLog.event("call_remote_header", ["codec": "\(h.codecId)", "size": "\(h.width)x\(h.height)", "fps": "\(h.fps)", "rotation": "\(h.rotationDegrees)", "audio": "\(h.hasAudio)"])
        case .remoteCamera(let on): AppLog.event("call_signal", ["remoteCamera": "\(on)"])
        case .remoteMuted(let m): AppLog.event("call_signal", ["remoteMuted": "\(m)"])
        case .keyFrameRequested: AppLog.event("call_signal", ["keyFrameRequested": "true"])
        case .peerLabels(let n): AppLog.event("call_labels", ["name": n == nil ? "none" : "set"])
        case .declinedSilently(let decision):
            AppLog.event("call_blocking", ["event": "declined", "reason": decision == .declineUnknown ? "unknown_caller" : "blocked_person",
                                           "pseudonymous": "\(engine.peerIsStranger)"])
        case .blockedAfterReveal:
            AppLog.event("call_blocking", ["event": "ended", "reason": "blocked_person", "after": engine.blockedRealKey ? "handshake" : "reveal",
                                           "role": role == .caller ? "caller" : "callee"])
        case .ended(let reason, let error):
            AppLog.event("call_end", ["reason": reason, "error": "\(error)", "audioTx": "\(engine.sentAudioPackets)", "audioRx": "\(engine.receivedAudioPackets)",
                                      "videoTx": "\(engine.sentVideoPackets)", "videoRx": "\(engine.receivedVideoPackets)", "decoded": "\(remote.decodedFrames)",
                                      "rxBytes": "\(engine.receivedBytes)", "txBytes": "\(engine.sentBytes)"])
            // A held caller name that did not go (decision 2026-11-06): a reason word only, never an identity.
            if let withheld = engine.callerNameWithheld { AppLog.event("call_labels", ["callerName": "withheld", "reason": withheld.rawValue]) }
            AppLog.flush()
        case .verificationCommitted(_, let committed):
            AppLog.event("meet_session", ["role": "displayer", "committed": "\(committed)"])
        case .verificationLeaseStored:
            AppLog.event("meet_session", ["role": role == .caller ? "scanner" : "displayer", "event": "lease_stored"])
        case .remoteAudio, .remoteVideo, .remoteRotation, .peerReport, .relayReady, .relaySetupRequested, .verificationReached: break
        }
    }

    func logStats(final: Bool = false) {
        var fields: [String: String] = ["final": "\(final)", "phase": "\(String(describing: phase))",
            "audioFromEncoder": "\(audioFromEncoder)", "audioSent": "\(engine.sentAudioPackets)", "audioCoalesced": "\(engine.queues.coalescedAudioUnits)", "audioRx": "\(engine.receivedAudioPackets)",
            "remoteAudioEvents": "\(remoteAudioEvents)", "remoteAudioNoPlayer": "\(remoteAudioWithoutPlayer)",
            "videoFromEncoder": "\(videoFromEncoder)", "videoSent": "\(engine.sentVideoPackets)", "videoShed": "\(videoShed)",
            "videoRx": "\(engine.receivedVideoPackets)", "remoteVideoEvents": "\(remoteVideoEvents)", "decoded": "\(remote.decodedFrames)", "decoder": remote.decoderName,
            "muted": "\(muted)", "cameraOn": "\(cameraOn)", "canSendMedia": "\(engine.canSendMedia)",
            "rxBytes": "\(engine.receivedBytes)", "txBytes": "\(engine.sentBytes)", "mediaProblem": mediaProblem ?? "none",
            "audioStarted": "\(audio != nil)", "cameraStarted": "\(camera != nil)", "videoFragments": "\(engine.fragmentsEnabled)", "fragmentsNegotiated": "\(engine.peerAcceptsFragments)",
            "wifiCarrier": engine.wifi?.carrierUp == true ? "up" : (engine.wifi?.binding == true ? "binding" : "none"),
            "wifiSending": "\(engine.wifi?.sendingOnWifi ?? false)"]
        if let audio { audio.requestSnapshot(); fields.merge(audio.logFields) { a, _ in a } }
        if let camera { fields.merge(camera.logFields) { a, _ in a } }
        #if os(macOS)
        if let driver { fields.merge(driver.logFields) { a, _ in a } }
        if let model { fields.merge(model.desktopRadioLogFields) { a, _ in a } }
        fields.merge(desktopDelivery.logFields) { a, _ in a }
        fields["peerFeedbackEnabled"] = "\(model?.desktopCallDeliveryFeedback == true && !relayed)"
        fields["remoteVideoPayloadBytes"] = "\(remote.payloadBytes)"
        #endif
        AppLog.event("call_stats", fields)
    }

    /// EXPERIMENTAL (`-callerMicPrewarm YES`, off): the caller's audio engine, voice processing enabled at
    /// outgoingRinging but not started; used by `startMedia`, stopped if the call ends first.
    private var prewarmedAudio: CallAudio?

    private func prewarmCallerAudio() {
        guard role == .caller, prewarmedAudio == nil, audio == nil, AppSettings.labSwitch("callerMicPrewarm", shipped: false) else { return }
        let audio = CallAudio(bitrate: CallController.audioBitrate, route: speaker ? .speaker : .earpiece, fec: AppSettings.callAudioFec)
        audio.prewarm()
        prewarmedAudio = audio
    }

    private func startMedia(header: StreamHeader, video: Bool) {
        let audio = prewarmedAudio ?? CallAudio(bitrate: CallController.audioBitrate, route: speaker ? .speaker : .earpiece, fec: AppSettings.callAudioFec)
        prewarmedAudio = nil
        audio.clockStart = mediaClock
        audio.onPacket = { [weak self] pts, data in
            guard let self else { return }
            self.audioFromEncoder += 1
            if self.audioFromEncoder == 1 { self.markStage("first_audio_tx") }
            self.engine.sendAudio(presentationTimeUs: pts, opus: data); self.pump()
        }
        audio.onFailure = { [weak self] message in self?.stats = message; self?.mediaProblem = message; AppLog.event("call_error", ["stage": "audio", "message": message]) }
        audio.onPlaybackFailed = { [weak self] detail in self?.endForLocalMediaFailure(.audioPlayback, detail: detail) }
        audio.onInterruption = { [weak self] began in self?.audioInterrupted(began) }
        audio.captureEnabled = !muted
        audio.start(capture: true)
        self.audio = audio
        if video { startCamera(header: header) }
    }

    /// Android `endForLocalMediaFailure`: this device's own decoder or playback failed while the link is fine. The call
    /// hangs up with an error reason (the other phone sees that this phone had a problem) instead of going on silent or
    /// being retried as link loss. Control arm `-callEndOnMediaFailure NO`: the call stays up with the notice, as before.
    private func endForLocalMediaFailure(_ failure: LocalMediaFailure, detail: String) {
        let ends = AppSettings.labSwitch("callEndOnMediaFailure", shipped: true)
        AppLog.event("call_error", ["stage": failure.rawValue, "fatal": "\(ends)", "message": detail])
        guard ends, ended == nil else { return }
        engine.endForLocalMediaFailure(failure.message)
        pump()
    }

    private func startCamera(header: StreamHeader) {
        guard camera == nil, header.codecId != StreamProtocol.codecVP9 || VP9Encoder.isAvailable else { return }
        let camera = CameraVideo(width: header.width, height: header.height, fps: header.fps, bitrateKbps: engine.effectiveVideoBitrate / 1000,
                                 front: true, clockStart: mediaClock, codecId: header.codecId)
        camera.onFrame = { [weak self] flags, pts, data in
            guard let self else { return }
            self.videoFromEncoder += 1
            if !self.engine.sendVideo(flags: flags, presentationTimeUs: pts, payload: data) { self.videoShed += 1; self.camera?.requestKeyFrame() }
            self.pump()
        }
        camera.onFailure = { [weak self, weak camera] message in
            guard let self else { return }
            // A camera already stopped (the app went to the background, Camera off, the ear pause) can still fail the
            // frame it was encoding: iOS invalidates the hardware encoder session in the background (VideoToolbox
            // -12903). That is not a problem of this call, so it is logged and not shown.
            guard let camera, self.camera === camera else {
                AppLog.event("call_error", ["stage": "camera_stopped", "message": message])
                return
            }
            self.stats = message
            if self.mediaProblem == nil { self.mediaProblem = message }
            AppLog.event("call_error", ["stage": "camera", "message": message])
        }
        // Current before it starts, so a failure it reports straight away is not taken for a stopped camera.
        self.camera = camera
        camera.start()
        startLadder(header: header)
        observeOrientation()
        sendRotation(rotation.pending(sending: true))
    }

    // MARK: Display rotation (iPhone)

    /// The other phone turns this phone's picture upright while the iPhone is held sideways (`CallDisplayRotation`).
    /// Control arm `-callSendRotation NO`: no rotation is sent, as before. A Mac camera does not turn with the Mac.
    private var rotation = CallDisplayRotation()
    private var orientationObserver: NSObjectProtocol?

    private func observeOrientation() {
        #if os(iOS)
        guard orientationObserver == nil, AppSettings.labSwitch("callSendRotation", shipped: true) else { return }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationObserver = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil,
                                                                     queue: .main) { [weak self] _ in self?.deviceTurned() }
        deviceTurned()
        #endif
    }

    private func deviceTurned() {
        #if os(iOS)
        let orientation: CallDisplayRotation.Orientation
        switch UIDevice.current.orientation {
        case .portrait: orientation = .portrait
        case .portraitUpsideDown: orientation = .portraitUpsideDown
        case .landscapeLeft: orientation = .landscapeLeft
        case .landscapeRight: orientation = .landscapeRight
        default: orientation = .faceUpOrDownOrUnknown
        }
        sendRotation(rotation.deviceTurned(orientation, sending: camera != nil))
        #endif
    }

    private func sendRotation(_ degrees: Int?) {
        guard let degrees, orientationObserver != nil else { return }
        engine.sendRotation(degrees); pump()
        AppLog.event("call_rotation", ["degrees": "\(degrees)"])
    }

    private func stopObservingOrientation() {
        #if os(iOS)
        guard let observer = orientationObserver else { return }
        NotificationCenter.default.removeObserver(observer); orientationObserver = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        #endif
    }

    // MARK: User actions

    /// Asks for the microphone (and camera for video) before answering, so media starts without a prompt.
    /// The user answered this call here: it is never "missed", however it ends.
    private(set) var answeredHere = false
    /// An incoming call that rang here and ended unanswered and not declined here.
    var missedHere: Bool {
        MissedCallAlert.isMissed(incoming: role == .callee, rang: rang, wasActive: activeSince != nil || answeredHere, declinedHere: declinedHere)
    }
    /// An incoming link that closed before its call ever rang: nothing to tell the user (no notice, no history).
    var closedBeforeRinging: Bool { role == .callee && !rang }

    func accept(as requested: CallType) {
        // Calls at critical heat (decision 2026-11-06): the call is answered; a video answer goes on as voice, without
        // asking for or starting the camera.
        let type = ThermalVideoState.callType(requested, videoBlocked: model?.videoBlockedByHeat == true)
        if type != requested {
            AppLog.event("call_thermal", ["event": "answered_as_voice_critical"])
            phaseText = AppModel.tooHotText
        }
        MediaPermissions.request(video: type == .video, context: "incoming") { [weak self] _, _ in
            guard let self, self.phase == .incomingRinging else { return }
            let voiceSwitch = AppSettings.labSwitch("callVoiceWhenCameraRefused", shipped: true)
            let outcome = CallMediaAccess.decide(use: .answer, video: type == .video, camera: MediaPermissions.cameraAccess,
                                                 microphone: MediaPermissions.microphoneAccess,
                                                 voiceWhenCameraRefused: voiceSwitch)
            switch outcome.step {
            case .proceed:
                self.accessNotice = nil; self.accessNoticeOpensSettings = false
                self.completeAccept(as: type)
            case .voiceInstead:
                self.accessNotice = CallMediaAccess.voiceNotice(use: .answer)
                self.accessNoticeOpensSettings = false
                self.logMediaRefusal(use: .answer, video: type == .video, outcome: outcome, voiceWhenCameraRefused: voiceSwitch)
                self.completeAccept(as: .voice)
            case .tell:
                self.accessNotice = CallMediaAccess.text(use: .answer, missing: outcome.missing)
                self.accessNoticeOpensSettings = outcome.opensSettings
                self.logMediaRefusal(use: .answer, video: type == .video, outcome: outcome, voiceWhenCameraRefused: voiceSwitch)
            }
        }
    }

    private func completeAccept(as type: CallType) {
        answeredHere = true
        do { callType = type; try engine.accept(as: type); pump() } catch { stats = "\(error)" }
    }

    private func logMediaRefusal(use: CallMediaAccess.Use, video: Bool, outcome: CallMediaAccess.Outcome,
                                 voiceWhenCameraRefused: Bool) {
        guard !outcome.missing.isEmpty else { return }
        let missing = outcome.missing.map { $0 == .camera ? "camera" : "microphone" }.joined(separator: "+")
        let useWord: String
        switch use {
        case .answer: useWord = "answer"
        case .place: useWord = "place"
        case .cameraOn: useWord = "cameraOn"
        }
        let step: String
        switch outcome.step {
        case .proceed: step = "proceed"
        case .voiceInstead: step = "voiceInstead"
        case .tell: step = "tell"
        }
        AppLog.event("call_media_refused", ["use": useWord, "video": "\(video)", "missing": missing, "step": step,
                                            "openSettings": "\(outcome.opensSettings)",
                                            "voiceWhenCameraRefused": "\(voiceWhenCameraRefused)"])
    }
    /// The user declined this call here (a declined call is not a missed call).
    private(set) var declinedHere = false
    func decline() {
        declinedHere = true
        do { try engine.decline(.rejected); pump() } catch {
            // Nothing to decline on the wire (the link is not set up, or a DEBUG fixture): close the screen.
            CallNotifier.shared.clear()
            ended = "Call declined"; phaseText = "Call declined"; finished("Call declined")
        }
    }
    /// The user cancelled this call while it was still connecting (a cancel, not a failure).
    private(set) var cancelledWhileConnecting = false
    /// This call's outgoing connect, cancelled when the user ends the call before its link exists.
    var connectHandle: ConnectHandle?
    func end() {
        userCancelled = true
        // Still connecting (no link yet): this is the user's cancel. Mark it first, then stop the radio attempt, so
        // the attempt's "stopped" completion is not reported as "Couldn't reach" and nothing stays connecting.
        if driver == nil, role == .caller, ended == nil {
            cancelledWhileConnecting = true
            ended = "Call cancelled"; phaseText = "Call cancelled"
            AppLog.event("call_end", ["reason": "Call cancelled", "error": "false", "stage": "cancelled_while_connecting"])
            connectHandle?.cancel()
            engine.end(); cleanupMedia(); scheduleDismiss(after: 0.5)
            return
        }
        engine.end(); pump()
    }
    #if DEBUG
    /// Fixture only (`-NearbyFixtureMissAfter N`): the unconnected ringing call ends as if the caller gave up.
    func debugCallerGaveUp() { finished("Caller cancelled") }
    /// Fixture only: a claim shown without a live call, so the imitation warning can be reviewed.
    func debugSetClaimedName(_ name: String?) { claimedName = name }
    #endif

    func toggleMute() { setMuted(!muted) }
    /// `muted` stays true while talking by holding Mute, so the button and state line still read "muted".
    func setMuted(_ value: Bool, keepTalking: Bool = false) {
        #if os(macOS)
        AppLog.event("call_action", ["action": "mute", "enabled": "\(value)"])
        #endif
        if !keepTalking { muted = value; talking = false }
        audio?.captureEnabled = !value
        engine.setMuted(value); pump()
    }
    /// Audio interruption -> hold: mute (the peer is told) and restore the user's own mute state afterwards.
    private func audioInterrupted(_ began: Bool) {
        if began {
            guard !onHold else { return }
            onHold = true; mutedBeforeHold = muted
            if !muted { setMuted(true) }
        } else {
            guard onHold else { return }
            onHold = false
            if !mutedBeforeHold { setMuted(false) }
        }
        AppLog.event("call_hold", ["onHold": "\(onHold)", "userMuted": "\(mutedBeforeHold)"])
    }

    /// While muted, holding Mute talks: the microphone opens (Microphone unmuted signal) and closes again on
    /// release, so the call returns to muted. Same signals as Android.
    func holdToTalk(_ pressed: Bool) {
        if pressed {
            guard muted, !talking else { return }
            talking = true; setMuted(false, keepTalking: true)
        } else {
            guard talking else { return }
            talking = false; setMuted(true, keepTalking: true)
        }
        AppLog.event("call_hold_to_talk", ["pressed": "\(pressed)"])
    }

    private var cameraPermissionRequestInFlight = false

    func toggleCamera() {
        MainStall.run("CallController.toggleCamera") {
            // Critical heat: the camera cannot start (turning it off always works).
            if !cameraOn, model?.videoBlockedByHeat == true { AppLog.event("call_thermal", ["event": "camera_refused_critical"]); return }
            if !cameraOn {
                switch CallMediaAccess.cameraOn(MediaPermissions.cameraAccess) {
                case .request:
                    requestCameraThenToggle()
                    return
                case .tell(let opensSettings):
                    showCameraRefused(opensSettings: opensSettings)
                    return
                case .start:
                    break
                }
            }
            cameraOn.toggle()
            engine.setCameraEnabled(cameraOn)
            if cameraOn {
                accessNotice = nil; accessNoticeOpensSettings = false
                if camera == nil, let header = engine.localHeader { startCamera(header: header) } else { camera?.requestKeyFrame() }
            } else if !AppSettings.labSwitch("NearbyKeepCameraWhenOff", shipped: false) {
                // Camera off releases the capture device, so the camera light goes out; turning it on
                // starts a fresh camera (and keyframe) through the path above. Control: -NearbyKeepCameraWhenOff 1.
                camera?.stop(); camera = nil
            }
            pump()
            updateEarPause()
        }
    }

    /// B1F step 1: a voice call's "Add video" reaches the system prompt first; the peer is told Camera on only after
    /// the grant. The prompt is asked once (the system decides the state); an interrupted prompt says so without Settings.
    private func requestCameraThenToggle() {
        guard !cameraPermissionRequestInFlight else { return }
        cameraPermissionRequestInFlight = true
        MediaPermissions.requestCamera { [weak self] _ in
            guard let self else { return }
            self.cameraPermissionRequestInFlight = false
            guard self.ended == nil else { return }
            let access = MediaPermissions.cameraAccess
            if access.granted || !access.canAskAgain {
                self.toggleCamera()
            } else {
                self.showCameraRefused(opensSettings: false)
            }
        }
    }

    private func showCameraRefused(opensSettings: Bool) {
        let voiceSwitch = AppSettings.labSwitch("callVoiceWhenCameraRefused", shipped: true)
        let outcome = CallMediaAccess.decide(use: .cameraOn, video: true, camera: MediaPermissions.cameraAccess,
                                             microphone: MediaPermissions.microphoneAccess,
                                             voiceWhenCameraRefused: voiceSwitch)
        accessNotice = CallMediaAccess.text(use: .cameraOn, missing: outcome.missing)
        accessNoticeOpensSettings = opensSettings
        logMediaRefusal(use: .cameraOn, video: true, outcome: outcome, voiceWhenCameraRefused: voiceSwitch)
    }
    /// iPhone: the other lens. Mac: the next camera (a Mac has no front and back lens); a running capture follows it.
    func flipCamera() {
        #if os(macOS)
        DesktopCameraDevices.selectNext()
        #else
        camera?.flip()
        #endif
    }

    // MARK: Camera pause at the ear (iPhone)

    /// Android "Pause video at the ear" (`CallProximityCameraPause`, on, no Settings row): in an active video call with
    /// your camera on and the sound on the earpiece, the proximity sensor near pauses the outgoing camera (the other
    /// phone gets the ordinary Camera off signal) and far restarts it with a fresh keyframe. Your own camera choice
    /// (`cameraOn`) never changes. iOS turns the screen off while near, as Android's proximity lock. DEBUG control arm
    /// `-earCameraPause NO`. A Mac has no proximity sensor: nothing happens there.
    ///
    /// Android `ProximityScreenOff` (device test 2026-11-12: a voice call's screen stayed on at the ear): any active
    /// call whose sound plays from the earpiece, voice or video, keeps proximity monitoring on, so the screen goes off
    /// at the ear and a cheek cannot press End. DEBUG control arm `-earScreenOff NO`.
    private func updateEarPause() {
        MainStall.run("CallController.updateEarPause") {
        #if os(iOS)
        let enabled = AppSettings.labSwitch("earCameraPause", shipped: true)
        let active = ended == nil && activeSince != nil
        let videoOn = active && callType == .video && cameraOn
        let screenOffAtEar = AppSettings.labSwitch("earScreenOff", shipped: true) && active && !speaker && CallAudio.playsOnEarpiece
        let watch = (enabled && videoOn && !speaker) || screenOffAtEar
        let device = UIDevice.current
        if watch, proximityObserver == nil {
            device.isProximityMonitoringEnabled = true
            proximityObserver = NotificationCenter.default.addObserver(forName: UIDevice.proximityStateDidChangeNotification, object: nil,
                                                                       queue: .main) { [weak self] _ in self?.updateEarPause() }
        } else if !watch, let observer = proximityObserver {
            NotificationCenter.default.removeObserver(observer); proximityObserver = nil
            device.isProximityMonitoringEnabled = false
        }
        let pause = EarCameraPause.shouldPause(enabled: enabled, userCameraOn: videoOn, earpiece: !speaker && CallAudio.playsOnEarpiece,
                                               near: watch && device.proximityState)
        guard pause != earPaused else { return }
        earPaused = pause
        AppLog.event("call_proximity_camera", ["paused": "\(pause)", "cameraOn": "\(cameraOn)", "earpiece": "\(!speaker)"])
        if pause {
            engine.setCameraEnabled(false)
            camera?.stop(); camera = nil
        } else {
            engine.setCameraEnabled(cameraOn)
            if cameraOn, camera == nil, let header = engine.localHeader { startCamera(header: header) }
        }
        pump()
        #endif
        }
    }

    /// The call's media ended: stop watching the sensor (the camera went with the media).
    private func stopEarPause() {
        #if os(iOS)
        if let observer = proximityObserver {
            NotificationCenter.default.removeObserver(observer); proximityObserver = nil
            UIDevice.current.isProximityMonitoringEnabled = false
        }
        earPaused = false
        #endif
    }

    private var backgroundCamera = BackgroundCameraRestore()
    private var appBackgrounded: Bool { backgroundCamera.backgrounded }
    /// iOS stops the camera in the background: tell the peer (Camera off) and resume on return. Unlocking and going
    /// straight to the home screen is a second background before the app was active: it keeps the first answer.
    func enterBackground() {
        MainStall.run("CallController.enterBackground") {
            backgroundCamera.enterBackground(cameraOn: cameraOn)
            AppLog.event("call_background_camera", ["phase": "background", "cameraOn": "\(cameraOn)",
                                                    "restore": "\(backgroundCamera.cameraWasOn)"])
            remote.enterBackground()
            if cameraOn { toggleCamera() }
            camera?.stop(); camera = nil
        }
    }
    func enterForeground() {
        MainStall.run("CallController.enterForeground") {
            remote.enterForeground()
            let restore = backgroundCamera.enterForeground(cameraOn: cameraOn, callEnded: ended != nil)
            AppLog.event("call_background_camera", ["phase": "active", "restore": "\(restore)"])
            if restore { toggleCamera() }
        }
    }
    func toggleSpeaker() {
        speaker.toggle(); audio?.setRoute(speaker ? .speaker : .earpiece)
        // The route moves on the audio control queue: look at the earpiece again once it has.
        updateEarPause()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.updateEarPause() }
    }

    /// Android critical heat (owner 2026-11-05: the camera stops, the call keeps its sound). Video on stays unavailable
    /// until the state is below critical; nothing restarts by itself.
    private func applyHeatStop() {
        guard model?.videoBlockedByHeat == true, cameraOn else { return }
        AppLog.event("call_thermal", ["event": "camera_stopped_critical"])
        toggleCamera()
    }

    /// The rungs below the header size with its aspect ratio (the camera frame is scaled to any size).
    private func startLadder(header: StreamHeader) {
        let requested = VideoResolution(header.width, header.height)
        // Manual video settings: nothing adapts to the link (Android "off_exact_rate_control").
        guard !exactVideo else {
            AppLog.event("call_resolution", ["requested": "\(requested)", "effective": "\(requested)", "reason": "manual"]); return
        }
        guard AppSettings.resolutionLadder else {
            AppLog.event("call_resolution", ["requested": "\(requested)", "effective": "\(requested)", "reason": "ladder_off"]); return
        }
        // Even sizes with the header's aspect ratio, from 3/4 of the header down to the 320x180 floor.
        let offered = [0.75, 0.5].map { scale -> VideoResolution in
            VideoResolution(Int((Double(header.width) * scale / 2).rounded()) * 2, Int((Double(header.height) * scale / 2).rounded()) * 2)
        } + [VideoResolution(180, 320), VideoResolution(320, 180)]
        let ladder = CallResolutionLadder(requested: requested, offered: offered, codecId: header.codecId)
        self.ladder = ladder
        let decision = ladder.start(targetBps: engine.effectiveVideoBitrate, nowMs: nowMs)
        if decision.resolution != requested { camera?.setResolution(width: decision.resolution.width, height: decision.resolution.height) }
        AppLog.event("call_resolution", ["requested": "\(requested)", "effective": "\(decision.resolution)", "reason": decision.reason,
                                         "rungs": ladder.rungs.map(\.description).joined(separator: ",")])
    }

    private var nowMs: Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }

    /// Once a second: adapt the encoder to what the link delivers (VideoRateController), within the heat limit (Lower
    /// quality when hot, `ThermalVideoPolicy`). With Manual video settings on nothing follows the link: the call sends the
    /// requested bitrate (after the other device's and a relay's cap) and only heat lowers it (Android CBR).
    private func adaptVideoRate(now: TimeInterval) {
        guard let camera, engine.canSendMedia, cameraOn else { lastRateWindow = nil; return }
        let startKbps = engine.effectiveVideoBitrate / 1000
        let heat = model?.videoHeatPercent() ?? 100
        let heatKbps = ThermalVideoPolicy.scaled(startKbps, percent: heat)
        let heatFps = ThermalVideoPolicy.scaled(requestedVideo.fps, percent: heat)
        // A camera turned off and on while hot starts at the full rate: the limit follows the camera, not only the heat.
        if heat != heatPercent || heatCamera != ObjectIdentifier(camera) {
            if heat != heatPercent { AppLog.event("call_thermal", ["percent": "\(heat)", "fps": "\(heatFps)", "kbps": "\(heatKbps)"]) }
            heatPercent = heat
            heatCamera = ObjectIdentifier(camera)
            camera.setFrameRate(heatFps)
        }
        if exactVideo {
            lastRateWindow = nil
            if camera.bitrateKbps != heatKbps { camera.setBitrate(kbps: heatKbps) }
            return
        }
        if rateController == nil {
            rateController = VideoRateController(startKbps: startKbps, maxKbps: startKbps)
        }
        let encoded = camera.encodedBytes, sent = engine.sentVideoBytes
        defer { lastRateWindow = (now, encoded, sent) }
        guard let last = lastRateWindow, now - last.at >= 0.5 else { return }
        let seconds = now - last.at
        let encodedKbps = Double(encoded - last.encoded) * 8 / seconds / 1000
        var deliveredKbps = Double(sent - last.sent) * 8 / seconds / 1000
        var age = engine.videoQueueAge(now: ConnectionDriver.now)
        #if os(macOS)
        let input = desktopDelivery.rateInput(enabled: model?.desktopCallDeliveryFeedback == true && !relayed,
                                              localQueueAge: age, localDeliveredKbps: deliveredKbps)
        deliveredKbps = input.deliveredKbps; age = input.queueAge
        #endif
        if let target = rateController?.update(queueAge: age, encodedKbps: encodedKbps, deliveredKbps: deliveredKbps) {
            camera.setBitrate(kbps: min(target, heatKbps))
            var fields = ["targetKbps": "\(min(target, heatKbps))", "encodedKbps": String(format: "%.0f", encodedKbps),
                          "deliveredKbps": String(format: "%.0f", deliveredKbps), "queueAgeMs": "\(Int(age * 1000))"]
            #if os(macOS)
            fields["source"] = input.usesPeer ? "peer_delivery" : "local_queue"
            #endif
            AppLog.event("call_rate", fields)
        } else if let target = rateController?.targetKbps, camera.bitrateKbps != min(target, heatKbps) {
            camera.setBitrate(kbps: min(target, heatKbps))
        }
        if let ladder, let target = rateController?.targetKbps,
           let decision = ladder.onTarget(targetBps: min(target, heatKbps) * 1000, nowMs: nowMs) {
            camera.setResolution(width: decision.resolution.width, height: decision.resolution.height)
            AppLog.event("call_resolution", ["requested": "\(ladder.requested)", "effective": "\(decision.resolution)", "reason": decision.reason])
        }
    }

    private func refreshStats() {
        MainStall.run("CallController.refreshStats") {
        let now = ProcessInfo.processInfo.systemUptime
        // The earpiece route settles on the audio queue after the call starts or a headset comes or goes: look again.
        updateEarPause()
        remote.checkStall(at: now, fps: engine.settings.fps,
                          suspended: onHold || phase != .active || !remoteCameraOn || appBackgrounded)
        adaptVideoRate(now: now)
        let sending = camera.flatMap { c in cameraOn ? VideoRequest.line(width: c.width, height: c.height, fps: c.fps, kbps: c.bitrateKbps) : nil }
        if sending != videoSending { videoSending = sending }
        let notes = CallVideoNotes.notes(requestedKbps: requestedVideo.kbps, startKbps: engine.effectiveVideoBitrate / 1000, relayed: relayed,
                                         sendingKbps: cameraOn ? camera?.bitrateKbps : nil, heatPercent: heatPercent, manual: exactVideo,
                                         mac: AppPlatform.isMac, transportCapKbps: transportCapKbps, transport: transport)
        if notes != videoNotes { videoNotes = notes }
        let allows = cameraOn && !exactVideo ? camera?.bitrateKbps : nil
        if allows != videoAllowsKbps { videoAllowsKbps = allows }
        applyHeatStop()
        if now - lastStatsLog >= 5 { lastStatsLog = now; logStats() }
        var parts: [String] = [transport.label]
        if let audio { audio.requestSnapshot(); parts.append(audio.stats) }
        if let camera { parts.append("sent \(camera.encodedFrames) frames") }
        if remote.decodedFrames > 0 { parts.append("\(remote.decoderName): \(remote.decodedFrames) frames") }
        parts.append("rx audio \(engine.receivedAudioPackets)")
        stats = parts.joined(separator: " · ")
        if let fp = fingerprint, let model { verification = model.verificationState(of: fp) }
        }
    }

    private func cleanupMedia() {
        renewalRadio?.stop()
        ringer.stop()
        ringback.stop()
        if audio == nil { ringback.release() }
        stopEarPause()
        if audio != nil || camera != nil { logStats(final: true) }
        audio?.stop(); audio = nil
        prewarmedAudio?.stop(); prewarmedAudio = nil
        camera?.stop(); camera = nil
        stopObservingOrientation()
        remote.stop()
        statsTimer?.invalidate(); statsTimer = nil
        wifiGuest?.leave(); wifiGuest = nil
    }

    /// Android `call_couldnt_reach` (caller) and `call_end_incoming_failed` (callee): a call that never became active.
    /// The technical reason stays in the log, as Android.
    private var couldNotConnectText: String {
        role == .caller ? "Couldn't reach \(label?.title ?? peerName). Try again." : "The incoming call couldn't connect"
    }

    /// Engine and radio reasons as Android's end texts (`CallEndText`, strings `call_end_*`); the log keeps the original.
    /// Apple keeps three outcomes Android has no text for: a peer's local media failure, an identity that could not be
    /// confirmed, and a call the other device cannot play. Any other reason reads "Call ended", never the raw text.
    static func plainReason(_ reason: String) -> String {
        if reason == CallerRevealGate.message { return "Couldn't confirm who this is" }
        let r = reason.lowercased()
        if r.contains("declined") && r.contains("busy") { return "Busy: they're in another call. Try again in a moment." }
        if r.contains("declined") { return "Call declined" }
        if r.contains("caller cancelled") || r.contains("caller canceled") { return "The caller hung up" }
        if r.contains("cancelled") || r.contains("canceled") { return "Call cancelled" }
        if r.contains("local media failure") { return "Their phone had a problem and ended the call" }
        if r.contains("peer ended") || r == "call ended" { return "Call ended" }
        if r.contains("stopped responding") || r.contains("link lost") || r.contains("disconnected") || r.contains("timed out") {
            return "Call dropped: the connection was lost"
        }
        if r.contains("no answer") || r.contains("ring") && r.contains("timeout") { return "No answer" }
        if r.contains("cannot decode") || r.contains("incompatible") { return "Their phone can't play this call" }
        if r.contains("authentication") || r.contains("signature") || r.contains("identity") { return "Couldn't confirm who this is" }
        return "Call ended"
    }

    private func finished(_ reason: String) {
        #if os(macOS)
        model?.desktopCallLinkFinished(self)
        #endif
        var delay: TimeInterval = 2
        if endReason == nil { endReason = reason }
        logTimeline(complete: false)
        if let declined = engine.relayedDecline { AppLog.event("relayed_call", ["event": "declined", "reason": declined.rawValue]) }
        if ended == nil, closedBeforeRinging {
            AppLog.event("call_end", ["reason": reason, "error": "true", "stage": "closed_before_ringing", "shown": "false"])
            ended = ""; phaseText = ""; delay = 0
        } else if ended == nil {
            if missedHere {
                // The caller gave up or the ring timed out: as Android, the callee sees "Missed call", not a failure.
                AppLog.event("call_end", ["reason": reason, "error": "false", "stage": "missed"])
                ended = "Missed call"
            } else if activeSince == nil {
                // The link closed before the call was ever active: say who could not be reached and why.
                failedEarly = true; delay = 6
                AppLog.event("call_end", ["reason": reason, "error": "true", "stage": "link_closed_before_active", "phase": "\(String(describing: phase))"])
                ended = couldNotConnectText
            } else { ended = CallController.plainReason(reason) }
            phaseText = ended ?? reason
        }
        cleanupMedia(); scheduleDismiss(after: delay)
    }

    private func scheduleDismiss(after seconds: TimeInterval = 2) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.model?.callFinished(self)
        }
    }

    var safetyCode: String? {
        guard let mine = model?.fingerprint, let theirs = fingerprint else { return nil }
        return SafetyCode.derive(mine, theirs)
    }
}
