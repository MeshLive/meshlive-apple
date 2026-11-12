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

// MARK: - Going live (source: we advertise an offer and connect to viewers' requests)

final class LiveController: ObservableObject {
    weak var model: AppModel?
    let transport: MeshTransport
    @Published var running = false
    @Published var paused = false
    @Published var viewers: [String] = []
    @Published var state = ""
    @Published var stats = ""
    private let identity: SigningIdentity
    let logicalToken = StreamRouteToken.newLogicalToken()
    /// The fixed-prefix offer's route token (`logical XOR mask(fixed prefix)`).
    private(set) var routeToken: UInt32 = 0
    /// AB4 (phase 1b item 3): every route token this source advertised enters the window; a viewer request is answered
    /// for the current token and the two it replaced, each for 60 s. With a fixed-prefix offer it is the old single token.
    let requestTokens = RouteTokenWindow()
    /// AB4 (Experimental, `-rotatingSource`): rotating IDs and the source arm on. Then this source signs link hello bit 3,
    /// opens its role-1 ID in BDO1 and answers rotating viewer requests; its offer rotates outside a Visible-by-handle window.
    var rotatingArm: Bool { rotatingSource && (model?.rotatingIds ?? false) }
    private let rotatingSource = AppSettings.rotatingSource
    /// Whether the last advertised offer was the rotating one (going back to rotating after the fixed form restarts it).
    var offerWasRotating: Bool?
    /// AB4 (item 5): the authenticated viewer node of each session.
    private var viewerNodes: [UUID: NodeId] = [:]
    private var sessions: [UUID: (engine: StreamSourceEngine, driver: ConnectionDriver)] = [:]
    private var connecting: Set<UUID> = []
    /// Android `PreAuthAdmissionGate` (on; control arm `-viewerAdmissionBounds NO`): how fast new viewers are dialled.
    private let admission = ViewerAdmissionGate(enabled: { AppSettings.viewerAdmissionBounds })
    /// Authenticated viewers by session, named for the panel: a verified contact's name, else "Viewer" (no ID fragment).
    private var viewerNames: [UUID: String] = [:]
    /// Authenticated viewers' announced IDs by session: a route-recovery request counts as one (first, uncounted) only
    /// when the child it names is one of these (Android `recoveryPreviousSenderKey`: a connected child of this source).
    /// A request's own claim is never enough, or a flood marked "recovery" would skip the admission bound.
    private var viewerPrefixes: [UUID: Data] = [:]
    /// Android keys a request by its announced ID and advertising address.
    private static func admissionKey(_ peer: DiscoveredPeer) -> String { "\(peer.peripheralId.uuidString)|\(peer.prefixHex)" }
    private(set) var camera: CameraVideo?
    private var audio: CallAudio?
    private let header: StreamHeader
    private var generation: UInt8 = 0
    let maxViewers = 3
    private var statsTimer: Timer?
    private let streamId = UUID()

    let labelsEnabled: Bool
    private(set) var title: String?

    // Experimental audio-only live ("radio"): microphone only, Opus in 200 ms records signed by a per-stream key.
    let audioOnly: Bool
    private(set) var preset: UInt8
    private var signer: AudioLiveSigner?
    private var signedConfig: MediaPacket?
    private var batch: [MediaPacket] = []
    private var nextPts: Int64?
    @Published var signedRecords = 0
    /// Audio-only Mute (Android AudioLiveBatcher, review 16): pending units become silence and every later frame
    /// is replaced by a silence frame, so nothing recorded before the tap goes out and the cadence never changes.
    @Published var muted = false
    /// A CELT fullband 20 ms mono frame that decodes to silence (TOC 0xF8, code 0), as Android.
    static let silenceFrame = Data([0xf8, 0xff, 0xfe])
    /// When the broadcast went on air (the top bar's timer).
    @Published private(set) var liveSince: Date?
    /// Video live: Camera off released the camera and its encoder (Android LiveControls); Camera on restarts them.
    @Published private(set) var cameraOff = false
    /// The lens of a video live (iPhone; the Mac uses the selected camera).
    private var front = false
    /// Settings › Manual video when this broadcast was set up (kept as chosen; only heat lowers it).
    private let requestedVideo: VideoRequest
    /// The media clock shared by the audio and the camera of this broadcast (a restarted camera keeps it).
    private var mediaClock: TimeInterval = 0
    /// Microphone level, 0...1 (Android AudioLiveLevel.rms); 0 while muted or paused.
    @Published private(set) var level: Double = 0
    /// Audio only: Android's reminder (a forgotten open microphone stops).
    private var reminder: AudioLiveReminderPolicy?
    private var reminderTimer: Timer?
    private var activeObserver: NSObjectProtocol?
    /// A reminder waits for an answer while MeshLive is frontmost (the in-app alert).
    @Published var reminderShown = false
    /// Why this broadcast stopped by itself; the root shows it after the screen closed.
    private(set) var stoppedNotice: String?
    /// The stopped alert's title (the radio reminder keeps Android's "Audio broadcast stopped").
    private(set) var stoppedTitle = "Audio broadcast stopped"

    func toggleMute() {
        muted.toggle()
        if audioOnly {
            if muted { batch = batch.map { MediaPacket(flags: $0.flags, presentationTimeUs: $0.presentationTimeUs, payload: Self.silenceFrame) } }
            if muted { level = 0 }
            AppLog.event("radio_mute", ["muted": "\(muted)"])
        } else {
            // Android toggleBroadcastMute: the microphone stays open and its Opus units are dropped (nothing is sent);
            // the audio configuration a viewer gets at its start still goes out.
            audio?.captureEnabled = !muted
            AppLog.event("live_mute", ["muted": "\(muted)"])
        }
    }

    /// Audio only, before Start: the title and quality chosen on the broadcast screen.
    func configure(title: String?, preset: UInt8) {
        guard !running else { return }
        self.title = title
        self.preset = AudioLive.isValidPreset(preset) ? preset : AudioLive.presetVoice
    }

    init(model: AppModel, identity: SigningIdentity, transport: MeshTransport, labels: Bool = false, title: String? = nil,
         audioOnly: Bool = false, preset: UInt8 = AudioLive.presetVoice) {
        self.model = model; self.identity = identity; self.transport = transport; labelsEnabled = labels; self.title = title
        self.audioOnly = audioOnly; self.preset = AudioLive.isValidPreset(preset) ? preset : AudioLive.presetVoice
        requestedVideo = model.videoRequest
        header = StreamHeader(width: requestedVideo.width, height: requestedVideo.height, fps: requestedVideo.fps, codecId: StreamProtocol.codecVP9,
                              rotationDegrees: 0, includeAudio: true)
        routeToken = (try? StreamRouteToken.forAdvertiser(logical: logicalToken, prefix: identity.nodeId.prefix)) ?? 0
    }

    func offerAnnouncement(prefix: Data) -> DiscoveryAnnouncement {
        var flags = DiscoveryAnnouncement.flagStreamAvailable
        if transport == .gatt { flags |= DiscoveryAnnouncement.flagGattTransport }
        if paused { flags |= DiscoveryAnnouncement.flagStreamPaused }
        let full = sessions.count >= maxViewers ? DiscoveryAnnouncement.sequenceSourceFull : 0
        if audioOnly {
            // The 0x40 marker with no geometry; the bitrate is the nominal Opus rate (display only).
            return DiscoveryAnnouncement(nodeIdPrefix: prefix, flags: flags, capabilitySummary: AudioLive.summaryAudioOnly, streamToken: routeToken, routeCost: 0,
                                         sequence: (generation & 0x7f) | full, streamBitrateKbps: UInt16(AudioLive.presetKbps(preset)))
        }
        return DiscoveryAnnouncement(nodeIdPrefix: prefix, flags: flags, capabilitySummary: NodeCapabilities.codecVP9, streamToken: routeToken, routeCost: 0,
                                     sequence: (generation & 0x7f) | full, streamWidth: UInt16(header.width), streamHeight: UInt16(header.height),
                                     streamFps: UInt8(header.fps), streamBitrateKbps: UInt16(requestedVideo.kbps))
    }

    /// The offer to advertise now: the fixed-prefix offer (`entry` nil: the source arm off, or a Visible-by-handle window),
    /// or the rotating offer with this epoch's role-1 `entry` (AB4, phase 1b item 1). Its route token enters the window.
    func advertisedOffer(prefix: Data, entry: OpeningEntry?) throws -> DiscoveryAnnouncement {
        let base = offerAnnouncement(prefix: prefix)
        let offer = try entry.map { try RotatingStreamOffer.announcement(base: base, entry: $0, logicalToken: logicalToken) } ?? base
        requestTokens.advance(logical: logicalToken, token: offer.streamToken, nowMs: RotatingDiscoveryRuntime.elapsedMs)
        return offer
    }

    func start() {
        guard model?.sourceGate.allowsGoLive == true else {
            AppLog.event("source_gate", ["event": "refused", "action": "start_live"]); return
        }
        if audioOnly { startRadio(); return }
        guard VP9Encoder.isAvailable else { state = "Video isn't supported on this phone."; return }
        running = true
        let clock = ProcessInfo.processInfo.systemUptime
        let audio = CallAudio(bitrate: 32_000, route: .speaker)
        audio.playbackPath = "stream"
        audio.clockStart = clock
        audio.onPacket = { [weak self] pts, data in self?.broadcast { $0.sendAudio(presentationTimeUs: pts, opus: data) } }
        audio.start(capture: true)
        self.audio = audio
        mediaClock = clock
        startCamera()
        liveSince = Date()
        // The top bar says "You are live" and the viewer count; `state` carries only problems.
        state = ""
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.stats = "\(self.transport.label) · \(self.sessions.count) viewer(s) · sent \(self.camera?.encodedFrames ?? 0) frames"
            self.applyHeatLimit()
        }
    }

    /// Lower quality when hot for the broadcast camera (Android applies the same limit to its stream encoder); critical
    /// heat ends a video live, with the switch on or off (Android `shouldBlockStreaming`).
    private func applyHeatLimit() {
        guard running, !audioOnly else { return }
        if model?.videoBlockedByHeat == true {
            AppLog.event("live_thermal", ["event": "stopped_critical"])
            stoppedTitle = "Live stopped"
            stoppedNotice = AppModel.stoppedHotText
            stop()
            return
        }
        guard let camera, !cameraOff else { return }
        let heat = model?.videoHeatPercent() ?? 100
        let kbps = ThermalVideoPolicy.scaled(requestedVideo.kbps, percent: heat)
        let fps = ThermalVideoPolicy.scaled(requestedVideo.fps, percent: heat)
        if camera.bitrateKbps != kbps { camera.setBitrate(kbps: kbps) }
        if camera.fps != fps {
            camera.setFrameRate(fps)
            AppLog.event("live_thermal", ["percent": "\(heat)", "fps": "\(fps)", "kbps": "\(kbps)"])
        }
    }

    /// A fresh camera and encoder (the first frame is a keyframe) on the broadcast's media clock.
    private func startCamera() {
        let camera = CameraVideo(width: header.width, height: header.height, fps: header.fps, bitrateKbps: requestedVideo.kbps, front: front,
                                 clockStart: mediaClock)
        camera.onFrame = { [weak self] flags, pts, data in self?.broadcast { $0.sendVideo(flags: flags, presentationTimeUs: pts, payload: data) } }
        camera.onFailure = { [weak self] message in self?.state = message }
        camera.start()
        self.camera = camera
    }

    /// Android Camera off / Camera on: off releases the camera and its encoder (no frames are produced or sent; the sound
    /// goes on); on restarts them, keyframe first. Not while paused.
    func toggleCamera() {
        guard running, !audioOnly, !paused else { return }
        if cameraOff {
            cameraOff = false
            startCamera()
        } else {
            cameraOff = true
            camera?.stop(); camera = nil
        }
        AppLog.event("live_camera", ["on": "\(!cameraOff)"])
    }

    /// Android Flip: the other lens (iPhone) or the next camera (Mac). Not while paused or with the camera off.
    func flipCamera() {
        guard running, !audioOnly, !paused, !cameraOff else { return }
        #if os(macOS)
        DesktopCameraDevices.selectNext()
        #else
        front.toggle()
        camera?.flip()
        #endif
        AppLog.event("live_flip", [:])
    }

    /// Audio-only: the identity key certifies a fresh stream key once; the microphone's 20 ms Opus frames are
    /// batched into 200 ms records with contiguous timestamps, each signed once and sent to every listener.
    private func startRadio() {
        guard CallAudio.opusAvailable else { state = "Audio can't start on this phone."; return }
        do { signer = try AudioLiveSigner(identity: identity, streamId: streamId, preset: preset) }
        catch { state = "Could not start: \(error)"; return }
        signedConfig = try? signer?.sign(flags: StreamProtocol.flagAudio | StreamProtocol.flagCodecConfig, presentationTimeUs: 0, body: OpusHead.make())
        running = true
        startRadioMicrophone()
        liveSince = Date()
        startReminder()
        AppLog.event("radio_start", ["preset": "\(preset)", "stream": streamId.uuidString.prefix(8).description, "transport": transport.rawValue])
        state = ""
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.stats = "\(self.transport.label) · audio only · \(self.sessions.count) listener(s) · \(self.signedRecords) signed records"
        }
    }

    /// The radio's microphone (Opus at the preset's rate) on the broadcast's media clock, so a Resume on the Mac keeps
    /// the timestamps running forward. Started by `startRadio()`, and on the Mac again by Resume.
    private func startRadioMicrophone() {
        if mediaClock == 0 { mediaClock = ProcessInfo.processInfo.systemUptime }
        let audio = CallAudio(bitrate: AudioLive.presetKbps(preset) * 1_000, route: .speaker)
        audio.playbackPath = "stream"
        audio.clockStart = mediaClock
        audio.onPacket = { [weak self] pts, data in self?.radioFrame(pts: pts, opus: data) }
        audio.onFailure = { [weak self] message in self?.state = message }
        audio.onCaptureLevel = { [weak self] value in
            guard let self else { return }
            self.level = self.muted || self.paused ? 0 : value
        }
        audio.start(capture: true)
        self.audio = audio
    }

    private func radioFrame(pts: Int64, opus: Data) {
        guard running, !paused, let signer else { return }
        // Contiguous 20 ms steps from the first frame (the listener's unit rule); a resume re-anchors.
        let at = nextPts ?? pts
        nextPts = at + AudioLive.frameUs
        batch.append(MediaPacket(flags: StreamProtocol.flagAudio, presentationTimeUs: at, payload: muted ? Self.silenceFrame : opus))
        guard batch.count >= AudioLive.defaultBatchFrames else { return }
        let units = batch; batch = []
        do {
            let body = try MediaPacket.combineAudio(units)
            let record = try signer.sign(flags: body.flags, presentationTimeUs: body.presentationTimeUs, body: body.payload)
            signedRecords += 1
            broadcast { $0.sendSignedAudio(record) }
        } catch {
            AppLog.event("radio_error", ["stage": "sign", "error": "\(error)"])
        }
    }

    private func broadcast(_ send: (StreamSourceEngine) -> Void) {
        for (_, s) in sessions where s.engine.ready { send(s.engine); s.driver.pump() }
    }

    /// Android viewers advertise requests carrying our route token; we connect to each as central.
    func viewerRequestsChanged(_ peers: [DiscoveredPeer]) {
        guard running, let model else { return }
        // AB4 (phase 1b items 2, 3 and 9): a request whose token is in the window (current, or replaced < 60 s ago), on this
        // source's transport; a rotating (version 5 / compact v2) request only while the rotating arm is on. Off, exactly
        // the old rule (fixed-prefix requests with the one token).
        let rotatingArm = self.rotatingArm
        let nowMs = RotatingDiscoveryRuntime.elapsedMs
        let requests = peers.filter {
            RotatingSourcePolicy.selects($0.announcement, tokens: requestTokens, transport: transport, rotatingArm: rotatingArm, nowMs: nowMs)
                && sessions[$0.id] == nil && !connecting.contains($0.id)
        }
        let now = ConnectionDriver.now
        let children = Set(viewerPrefixes.values)
        let isRecovery: (DiscoveredPeer) -> Bool = {
            // A version 5 request's six spare bytes are an RV18 hint, never a child prefix (hints are not matched here).
            ViewerAdmissionGate.isRecovery(requester: $0.announcement.nodeIdPrefix, namedChild: RotatingSourcePolicy.namedChild($0.announcement),
                                           children: children)
        }
        let selection = admission.select(requests, key: Self.admissionKey, isRecovery: isRecovery, fanOut: maxViewers, now: now)
        if !selection.deferred.isEmpty {
            AppLog.event("viewer_admission", ["chosen": "\(selection.chosen.count)", "deferred": "\(selection.deferred.count)"])
        }
        for peer in selection.chosen {
            guard sessions.count + connecting.count < maxViewers else { break }
            if !isRecovery(peer) { admission.noteAttempt(now: now) }
            let key = Self.admissionKey(peer)
            connecting.insert(peer.id)
            let viewerPrefix = peer.announcement.nodeIdPrefix
            model.radio.connect(to: peer.id, transport: transport) { [weak self] result in
                guard let self else { return }
                self.connecting.remove(peer.id)
                guard case .success(let link) = result, self.running else {
                    if case .success(let l) = result { l.close() } else { self.admission.noteFailure(key, now: ConnectionDriver.now) }
                    return
                }
                // AB4: with the rotating arm on the hop signs bit 3 and opens this source's pinned role-1 entries (evaluated when
                // BDO1 is sent); a selected rotating request needs the viewer's role-2 entry for its six bytes.
                let schedule = model.rotating.streamOffer
                let roleOneEntries: (() -> [OpeningEntry])? = rotatingArm
                    ? { schedule.acceptedEntries(elapsedMs: RotatingDiscoveryRuntime.elapsedMs) } : nil
                let engine = StreamSourceEngine(transport: self.transport, identity: self.identity, header: self.header,
                                                expectedViewerPrefix: viewerPrefix, streamId: self.streamId, labels: self.labelsEnabled, title: self.title,
                                                rotatingEntries: roleOneEntries,
                                                linkPacing: AppSettings.linkPacing, audioLive: self.signer, selectedRequest: peer.announcement)
                if peer.announcement.rotating {
                    engine.onOpeningChecked = { result in AppLog.event("rotid_open", ["role": "viewer", "result": result.logName]) }
                }
                engine.onTimeSeedRaise = AppSettings.onTimeSeedRaise
                engine.identityGate = model.book
                let driver = ConnectionDriver(engine: engine, link: link)
                engine.onEvent = { [weak self] event in
                    switch event {
                    case .viewerAuthenticated(let id, let fp):
                        // Call blocking (Android security review item 14): a blocked person neither watches nor forwards.
                        if model.isBlocked(fp) || model.isBlockedNode(id) {
                            AppLog.event("call_blocking", ["event": "viewer_refused", "reason": "blocked_person"])
                            self?.sessions[peer.id]?.driver.cancel()
                            return
                        }
                        model.noteAuthenticated(fp)
                        if let config = self?.signedConfig { engine.sendSignedAudio(config) } else { engine.sendAudioConfig() }
                        self?.camera?.requestKeyFrame()
                        if let self {
                            // AB4 (item 5): one authenticated link per node; a rotated request's new link replaces the older one.
                            for old in RotatingSourcePolicy.replacedSessions(newKey: peer.id, node: id, rotating: peer.announcement.rotating,
                                                                             authenticated: self.viewerNodes) {
                                AppLog.event("rotating_ids", ["event": "viewer_replaced", "role": "stream"])
                                self.sessions[old]?.driver.cancel()
                            }
                            self.viewerNodes[peer.id] = id
                            self.viewerNames[peer.id] = model.contactName(prefixHex: id.prefix.hex) ?? "Viewer"
                            // A rotating request's six bytes are an RDI, not a prefix a recovery request could name.
                            if !peer.announcement.rotating { self.viewerPrefixes[peer.id] = viewerPrefix }
                            self.viewers = Array(self.viewerNames.values)
                        }
                    case .keyFrameRequested: self?.camera?.requestKeyFrame()
                    default: break
                    }
                }
                driver.onFinished = { [weak self] _ in
                    guard let self else { return }
                    self.sessions[peer.id] = nil
                    self.viewerPrefixes[peer.id] = nil
                    self.viewerNodes[peer.id] = nil
                    // A viewer that never authenticated is a pre-authentication failure (it sorts last for 10 s).
                    if self.viewerNames.removeValue(forKey: peer.id) == nil { self.admission.noteFailure(key, now: ConnectionDriver.now) }
                    self.viewers = Array(self.viewerNames.values)
                    self.generation &+= 1
                    self.model?.refreshAdvertising()
                }
                self.sessions[peer.id] = (engine, driver)
                driver.start()
                self.generation &+= 1
                model.refreshAdvertising()
            }
        }
    }

    func togglePause() {
        paused.toggle()
        // Audio-only: nothing captured before the pause is sent after it; the listener's clock baseline restarts.
        batch = []; nextPts = nil
        for (_, s) in sessions { s.engine.setPaused(paused); s.driver.pump() }
        if paused { level = 0 }
        #if os(macOS)
        // Android audio_live_status_paused: on the Mac, Pause turns the radio microphone off and Resume starts it again.
        // The iPhone keeps it on (iOS may not let a background app start the microphone again).
        if audioOnly && running && AppSettings.radioPauseMicOff {
            if paused {
                audio?.stop(); audio = nil
                AppLog.event("radio_mic", ["on": "false", "reason": "paused"])
            } else if audio == nil {
                startRadioMicrophone()
                AppLog.event("radio_mic", ["on": "true", "reason": "resumed"])
            }
        }
        #endif
        // Camera off ends with Resume: the camera comes back with the broadcast (Android onPaused resets it; the mute stays).
        if !paused && cameraOff { cameraOff = false; startCamera() }
        if !paused { camera?.requestKeyFrame() }
        model?.refreshAdvertising()
    }

    // MARK: Audio-only reminder (Android AudioLiveReminderPolicy)

    /// Starts the reminder (audio only). DEBUG `-NearbyRadioReminderUnit S` uses S seconds as the 5-minute unit.
    func startReminder() {
        guard audioOnly, reminder == nil else { return }
        let unit = RootView.debugArgument("-NearbyRadioReminderUnit").flatMap(Double.init)
        reminder = AudioLiveReminderPolicy(start: ConnectionDriver.now, unitSeconds: unit)
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tickReminder() }
        #if os(iOS)
        let active = UIApplication.didBecomeActiveNotification
        #else
        let active = NSApplication.didBecomeActiveNotification
        #endif
        activeObserver = NotificationCenter.default.addObserver(forName: active, object: nil, queue: .main) { [weak self] _ in self?.userPresent() }
    }

    private func tickReminder() {
        guard running, var policy = reminder else { return }
        let now = ConnectionDriver.now
        policy.onListeners(sessions.count, now: now)
        let decision = policy.decide(now: now)
        reminder = policy
        switch decision {
        case .none: break
        case .remind:
            reminderShown = true
            CallNotifier.shared.postRadioReminder()
            AppLog.event("radio_reminder", ["event": "shown", "listeners": "\(sessions.count)"])
        case .stop:
            AppLog.event("radio_reminder", ["event": "auto_stop"])
            stoppedNotice = "Audio broadcast stopped: nobody answered the reminder."
            stop()
        }
    }

    /// The user is here (the app became active, the notification was opened, or Keep going): Android onUserPresent.
    func userPresent() {
        guard running, var policy = reminder else { return }
        let outstanding = policy.reminderOutstanding
        policy.onUserPresent(now: ConnectionDriver.now)
        reminder = policy
        reminderShown = false
        CallNotifier.shared.clearRadioReminder()
        if outstanding { AppLog.event("radio_reminder", ["event": "answered"]) }
    }

    #if DEBUG
    /// UI fixture only: on air without a microphone, camera or engine (the reminder runs, nothing is sent).
    func debugShowOnAir() {
        running = true
        liveSince = Date()
        startReminder()
    }

    /// UI fixture only: N viewers watching (no sessions, nothing sent).
    func debugSetViewers(_ count: Int) { viewers = Array(repeating: "Viewer", count: max(0, count)) }
    #endif

    func stop() {
        reminderTimer?.invalidate(); reminderTimer = nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver); self.activeObserver = nil }
        CallNotifier.shared.clearRadioReminder()
        reminderShown = false
        guard running else { model?.liveFinished(self); return }
        running = false
        for (_, s) in sessions { s.engine.endStream(); s.driver.pump() }
        camera?.stop(); camera = nil
        audio?.stop(); audio = nil
        statsTimer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            for (_, s) in self.sessions { s.driver.cancel() }
            self.sessions.removeAll()
            self.model?.liveFinished(self)
        }
    }
}
