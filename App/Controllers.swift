import Foundation
import SwiftUI
import NearbyCore
#if canImport(NearbyMedia)
import NearbyMedia
#endif

/// Default video for user calls and streams (design decision 2026-10-10, as Android): 426x240 at 15 FPS, 200 kbps,
/// portrait on the iPhone (240x426). The resolution ladder steps down from it on weak links.
enum MediaDefaults {
    static let width = 240, height = 426, fps = 15, videoKbps = 200
}

/// Remote video decode on a serial queue; decode failures ask the sender for a keyframe (rate-limited).
final class RemoteVideo {
    private let queue = DispatchQueue(label: "io.github.meshlive.app.decode", qos: .userInitiated)
    private var decoder: VideoFrameDecoder?
    private var codecId: UInt8 = 0
    private var lastKeyRequest: TimeInterval = 0
    private var headerSize = ""
    private var lastDecodedSize = (0, 0)
    let sink = VideoSink()
    var onNeedKeyFrame: (() -> Void)?
    private(set) var decoderName = ""
    var decodedFrames = 0
    #if os(macOS)
    private(set) var payloadBytes = 0
    #endif

    func configure(header: StreamHeader) {
        sink.rotation = header.rotationDegrees
        headerSize = "\(header.width)x\(header.height)"
        guard header.codecId != codecId || decoder == nil else { return }
        codecId = header.codecId
        do {
            let d = try VideoDecoderFactory.make(codecId: header.codecId)
            d.onPicture = { [weak self] pixels, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.decodedFrames += 1
                    let size = (CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels))
                    if size != self.lastDecodedSize {
                        // Android's resolution ladder changes the size in-band at a keyframe; the header is the maximum.
                        self.lastDecodedSize = size
                        AppLog.event("decoder_output_size", ["decoded": "\(size.0)x\(size.1)", "header": self.headerSize])
                    }
                    self.sink.show(pixels)
                }
            }
            decoder = d; decoderName = d.name
        } catch { decoder = nil; decoderName = "No decoder: \(error)" }
    }

    func decode(_ packet: MediaPacket) {
        #if os(macOS)
        payloadBytes += packet.payload.count
        #endif
        guard let decoder else { return }
        if packet.isCodecConfig { queue.async { decoder.replaceCodecConfig(packet.payload) }; return }
        queue.async {
            do { try decoder.decode(packet.payload, presentationTimeUs: packet.presentationTimeUs, keyFrame: packet.isKeyFrame) }
            catch { DispatchQueue.main.async { self.requestKeyFrame() } }
        }
    }

    func requestKeyFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastKeyRequest > 0.75 else { return }
        lastKeyRequest = now; onNeedKeyFrame?()
    }

    func stop() { queue.async { self.decoder?.invalidate() }; DispatchQueue.main.async { self.sink.clear() } }
}

// MARK: - Calls

final class CallController: ObservableObject, Identifiable {
    let id = UUID()
    weak var model: AppModel?
    let role: PrivateCallRole
    let transport: MeshTransport
    @Published var phase: PrivateCallPhase? { didSet { if phase == .incomingRinging { rang = true } } }
    /// This incoming call rang here (a link that failed before ringing is not a missed call).
    private(set) var rang = false
    @Published var phaseText = ""
    @Published var peerName: String
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
    /// The stranger notice under a ring (nil for a contact): a relayed stranger call names the possible relay in the middle.
    @Published var ringNotice: String?

    private func ringText(_ type: CallType) -> String {
        if engine.isRelayed { relayed = true }
        ringNotice = engine.peerIsStranger ? RelayedCallPolicy.strangerRingStatus(viaRelay: engine.isRelayed) : nil
        let base = type == .voice ? "Incoming voice call" : "Incoming video call"
        return engine.isRelayed ? "\(base) \(RelayedCallPolicy.viaRelayStatus)" : base
    }
    @Published var stats = ""
    @Published var label: PeerLabel?
    @Published var activeSince: Date?
    /// True while Mute is held down during a muted call (talking until release).
    @Published var talking = false
    /// Another app or the system has the audio (a phone call, Siri): the microphone is off and the peer sees
    /// "muted" (signal 9, as Android sends on audio-focus loss) until it ends.
    @Published var onHold = false
    private var mutedBeforeHold = false
    private let ringer = Ringer()
    @Published var subject: String?
    /// Visible media problem (microphone/camera/audio), shown on the call screen.
    @Published var mediaProblem: String?
    let remote = RemoteVideo()
    private var rateController: VideoRateController?
    /// Call resolution ladder (on for user calls, like Android; DEBUG -NearbyResolutionLadder 0 turns it off).
    private var ladder: CallResolutionLadder?
    private var lastRateWindow: (at: TimeInterval, encoded: Int, sent: UInt64)?
    private var audioFromEncoder = 0, videoFromEncoder = 0, videoShed = 0, remoteAudioWithoutPlayer = 0, remoteAudioEvents = 0, remoteVideoEvents = 0
    private var engine: CallEngine
    private var driver: ConnectionDriver?
    private var audio: CallAudio?
    private(set) var camera: CameraVideo?
    private var statsTimer: Timer?
    private var linkPeer: NodeId?
    #if os(macOS)
    private let desktopDelivery = DesktopCallDelivery()
    #endif

    init(model: AppModel, role: PrivateCallRole, peerName: String, peerPrefixHex: String?, identity: SigningIdentity,
         transport: MeshTransport, type: CallType, relayHops: UInt8, rotating: RotatingCallOptions? = nil, bmh3: Bmh3CallOptions? = nil) {
        self.model = model; self.role = role; self.transport = transport; self.peerName = peerName; self.peerPrefixHex = peerPrefixHex
        callType = type; cameraOn = type == .video
        #if os(macOS)
        speaker = true
        #else
        speaker = type == .video
        #endif
        let expected = peerPrefixHex.flatMap { Data(hex: $0) }
        // Portrait capture; 240x426 keeps software VP9 light and fits the Android call profiles on Bluetooth.
        // Default for user calls (design decision 2026-10-10, as Android): 426x240 (portrait 240x426) at 15 FPS, 200 kbps.
        let settings = CallMediaSettings(width: MediaDefaults.width, height: MediaDefaults.height, fps: MediaDefaults.fps,
                                         videoBitrate: MediaDefaults.videoKbps * 1000, audioBitrate: 24_000)
        engine = CallEngine(role: role, transport: transport, identity: identity, requestedType: type, encodeMask: VideoDecoderSupport.encodeMask,
                            decodeMask: VideoDecoderSupport.decodeMask, settings: settings, expectedPeerPrefix: expected, relayHops: relayHops,
                            labels: model.callLabelOptions(), rotating: rotating, bmh3: bmh3)
        if rotating != nil, role == .callee {
            // RV8 tarpit: strangers' link hellos wait 2^(n-6) s per epoch; verified contacts never wait.
            let runtime = model.rotating
            engine.responderHelloDelay = { [weak model] peer in
                if model?.contacts.contains(where: { $0.nodePrefixHex == peer.prefix.hex }) == true { return 0 }
                let ms = runtime.tarpit.nextDelayMs(epoch: runtime.currentEpoch())
                AppLog.event("rotating_ids", ["event": "tarpit", "delayMs": "\(ms)"])
                return TimeInterval(ms) / 1000
            }
        }
        engine.identityGate = model.book
        engine.onEvent = { [weak self] in self?.handle($0) }
        #if os(macOS)
        engine.onMediaSubmitted = { [weak self] bytes, audio, at in self?.desktopDelivery.submitted(payloadBytes: bytes, audio: audio, at: at) }
        #endif
        remote.onNeedKeyFrame = { [weak self] in self?.engine.requestKeyFrame(); self?.pump() }
        relayed = relayHops > 0
        engine.acceptRelayedCalls = model.relayedCalls
        engine.acceptRelayedStrangerCalls = AppSettings.relayedStrangerCalls
        phaseText = role == .caller ? "Calling…" : "Connecting…"
    }

    func attach(_ link: MeshLink) {
        #if os(macOS)
        guard driver == nil, model?.desktopCallLinkAttached(self) == true else { link.close(); return }
        #else
        guard driver == nil, ended == nil else { link.close(); return }
        #endif
        let driver = ConnectionDriver(engine: engine, link: link)
        driver.onFinished = { [weak self] reason in self?.finished(reason) }
        self.driver = driver
        linkAttachedAt = ProcessInfo.processInfo.systemUptime
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

    private func handle(_ event: CallEngine.Event) {
        log(event)
        switch event {
        case .linkAuthenticated(let id): linkPeer = id
        case .peerAuthenticated(let id, let fp):
            fingerprint = fp
            peerPrefixHex = id.prefix.hex
            model?.noteAuthenticated(fp)
            verification = model?.verificationState(of: fp) ?? .unverified
            let contact = model?.contactName(prefixHex: id.prefix.hex)
            let newLabel = PeerLabel(prefix: id.prefix, contactName: contact, verified: verification == .verified)
            label = newLabel; peerName = newLabel.title
            if let linkPeer, linkPeer != id, !engine.linkPeerPseudonymous { relayed = true }
        case .peerStranger:
            // BMH3 pseudonyms: a throwaway key; the real identity (and the call history entry) only after its reveal.
            fingerprint = nil; verification = .unverified
            label = nil; peerName = "Unverified stranger"
            if model?.desktopGeneratedNames == true, let name = DesktopNearbyNames.shared?.name(forStranger: engine) {
                peerName = name.text
            }
        case .phase(let p):
            phase = p
            if p == .incomingRinging { ringer.start() } else { ringer.stop() }
            CallNotifier.shared.update(for: self)
            switch p {
            case .outgoingInvite: phaseText = "Calling…"
            case .outgoingRinging: phaseText = "Ringing…"
            case .incomingRinging: phaseText = ringText(offeredType)
            case .negotiatingMedia: phaseText = "Connecting…"
            case .active: phaseText = ""; if activeSince == nil { activeSince = Date() }
            case .ended: phaseText = "Call ended"
            }
        case .incomingCall(let type):
            offeredType = type; callType = type
            if let runtime = model?.rotating, model?.rotatingIds == true { runtime.tarpit.forgive(epoch: runtime.currentEpoch()) }
        case .offeredTypeChanged(let type):
            offeredType = type; callType = type
            if phase == .incomingRinging { phaseText = ringText(type) }
        case .startLocalMedia(let header, let type):
            callType = type; cameraOn = type == .video
            startMedia(header: header, video: type == .video)
        case .remoteHeader(let header): remote.configure(header: header)
        case .remoteAudio(let packet):
            remoteAudioEvents += 1
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
        case .peerLabels(let name, let subject):
            // Verified signed labels for this call only; your contact's own label always wins (never cached).
            if let current = label, let prefix = peerPrefixHex.flatMap({ Data(hex: $0) }), prefix.count == 6 {
                let updated = PeerLabel(prefix: prefix, contactName: current.contactName, selfName: name, verified: current.verified)
                label = updated; peerName = updated.title
            }
            self.subject = subject
        case .ended(let reason, let error):
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
            let shown = missed ? "Missed call"
                : error && activeSince == nil ? "Couldn't reach \(label?.title ?? peerName) \u{2013} \(plain.lowercased())" : plain
            ended = shown; phaseText = shown; cleanupMedia(); scheduleDismiss(after: error ? 6 : 2)
        }
    }

    private let mediaClock = ProcessInfo.processInfo.systemUptime
    /// When the Bluetooth link was attached: `linkMs` on call_auth and call_phase times the handshake and setup.
    private var linkAttachedAt: TimeInterval?
    private var linkMs: String { linkAttachedAt.map { "\(Int(((ProcessInfo.processInfo.systemUptime - $0) * 1000).rounded()))" } ?? "-" }

    private var lastStatsLog: TimeInterval = 0
    private func log(_ event: CallEngine.Event) {
        switch event {
        case .linkAuthenticated(let id): AppLog.event("call_auth", ["stage": "link", "peer": id.shortLabel, "transport": transport.rawValue, "linkMs": linkMs])
        case .peerAuthenticated(let id, let fp):
            AppLog.event("call_auth", ["stage": "endpoint", "linkMs": linkMs, "peer": id.shortLabel, "handle": IdentityHandle.handle(prefix: id.prefix) ?? "?",
                                       "fingerprint": String(fp.hex.prefix(16)), "codec": "\(engine.selectedCodec.map { $0 == StreamProtocol.codecVP9 ? "vp9" : "av1" } ?? "none")",
                                       "peerCaps": engine.endpoint.map { String(format: "t%02x/e%02x/d%02x/max%d", $0.peerCapabilities.transportMask, $0.peerCapabilities.encodeCodecMask, $0.peerCapabilities.decodeCodecMask, $0.peerCapabilities.maxBitrateKbps) } ?? "?"])
        case .peerStranger:
            AppLog.event("bmh3", ["event": "peer", "layer": "endpoint", "pseudonymous": "true", "linkBmh3": "\(engine.linkUsedBmh3)"])
        case .phase(let p): AppLog.event("call_phase", ["role": role == .caller ? "caller" : "callee", "phase": "\(p)", "callId": engine.state?.callId.uuidString ?? "-", "linkMs": linkMs])
        case .incomingCall(let t), .offeredTypeChanged(let t): AppLog.event("call_offer", ["type": t.rawValue])
        case .startLocalMedia(let h, let t): AppLog.event("call_media_start", ["type": t.rawValue, "codec": "\(h.codecId)", "size": "\(h.width)x\(h.height)", "fps": "\(h.fps)"])
        case .remoteHeader(let h): AppLog.event("call_remote_header", ["codec": "\(h.codecId)", "size": "\(h.width)x\(h.height)", "fps": "\(h.fps)", "rotation": "\(h.rotationDegrees)", "audio": "\(h.hasAudio)"])
        case .remoteCamera(let on): AppLog.event("call_signal", ["remoteCamera": "\(on)"])
        case .remoteMuted(let m): AppLog.event("call_signal", ["remoteMuted": "\(m)"])
        case .keyFrameRequested: AppLog.event("call_signal", ["keyFrameRequested": "true"])
        case .peerLabels(let n, let s): AppLog.event("call_labels", ["name": n == nil ? "none" : "set", "subject": s == nil ? "none" : "set"])
        case .ended(let reason, let error):
            AppLog.event("call_end", ["reason": reason, "error": "\(error)", "audioTx": "\(engine.sentAudioPackets)", "audioRx": "\(engine.receivedAudioPackets)",
                                      "videoTx": "\(engine.sentVideoPackets)", "videoRx": "\(engine.receivedVideoPackets)", "decoded": "\(remote.decodedFrames)",
                                      "rxBytes": "\(engine.receivedBytes)", "txBytes": "\(engine.sentBytes)"])
            AppLog.flush()
        case .remoteAudio, .remoteVideo, .remoteRotation, .peerReport: break
        }
    }

    func logStats(final: Bool = false) {
        var fields: [String: String] = ["final": "\(final)", "phase": "\(String(describing: phase))",
            "audioFromEncoder": "\(audioFromEncoder)", "audioSent": "\(engine.sentAudioPackets)", "audioRx": "\(engine.receivedAudioPackets)",
            "remoteAudioEvents": "\(remoteAudioEvents)", "remoteAudioNoPlayer": "\(remoteAudioWithoutPlayer)",
            "videoFromEncoder": "\(videoFromEncoder)", "videoSent": "\(engine.sentVideoPackets)", "videoShed": "\(videoShed)",
            "videoRx": "\(engine.receivedVideoPackets)", "remoteVideoEvents": "\(remoteVideoEvents)", "decoded": "\(remote.decodedFrames)", "decoder": remote.decoderName,
            "muted": "\(muted)", "cameraOn": "\(cameraOn)", "canSendMedia": "\(engine.canSendMedia)",
            "rxBytes": "\(engine.receivedBytes)", "txBytes": "\(engine.sentBytes)", "mediaProblem": mediaProblem ?? "none",
            "audioStarted": "\(audio != nil)", "cameraStarted": "\(camera != nil)"]
        if let audio { fields.merge(audio.logFields) { a, _ in a } }
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

    private func startMedia(header: StreamHeader, video: Bool) {
        let audio = CallAudio(bitrate: 24_000, route: speaker ? .speaker : .earpiece, fec: AppSettings.callAudioFec)
        audio.clockStart = mediaClock
        audio.onPacket = { [weak self] pts, data in
            guard let self else { return }
            self.audioFromEncoder += 1
            self.engine.sendAudio(presentationTimeUs: pts, opus: data); self.pump()
        }
        audio.onFailure = { [weak self] message in self?.stats = message; self?.mediaProblem = message; AppLog.event("call_error", ["stage": "audio", "message": message]) }
        audio.onInterruption = { [weak self] began in self?.audioInterrupted(began) }
        audio.captureEnabled = !muted
        audio.start(capture: true)
        self.audio = audio
        if video { startCamera(header: header) }
    }

    private func startCamera(header: StreamHeader) {
        guard camera == nil, VP9Encoder.isAvailable else { return }
        let camera = CameraVideo(width: header.width, height: header.height, fps: header.fps, bitrateKbps: engine.effectiveVideoBitrate / 1000,
                                 front: true, clockStart: mediaClock)
        camera.onFrame = { [weak self] flags, pts, data in
            guard let self else { return }
            self.videoFromEncoder += 1
            if !self.engine.sendVideo(flags: flags, presentationTimeUs: pts, payload: data) { self.videoShed += 1; self.camera?.requestKeyFrame() }
            self.pump()
        }
        camera.onFailure = { [weak self] message in
            self?.stats = message
            if self?.mediaProblem == nil { self?.mediaProblem = message }
            AppLog.event("call_error", ["stage": "camera", "message": message])
        }
        camera.start()
        self.camera = camera
        startLadder(header: header)
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

    func accept(as type: CallType) {
        answeredHere = true
        MediaPermissions.request(video: type == .video, context: "incoming") { [weak self] _, _ in
            guard let self, self.phase == .incomingRinging else { return }
            do { self.callType = type; try self.engine.accept(as: type); self.pump() } catch { self.stats = "\(error)" }
        }
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

    func toggleCamera() {
        cameraOn.toggle()
        engine.setCameraEnabled(cameraOn)
        if cameraOn {
            if camera == nil, let header = engine.localHeader { startCamera(header: header) } else { camera?.requestKeyFrame() }
        } else if !UserDefaults.standard.bool(forKey: "NearbyKeepCameraWhenOff") {
            // Camera off releases the capture device, so the camera light goes out; turning it on
            // starts a fresh camera (and keyframe) through the path above. Control: -NearbyKeepCameraWhenOff 1.
            camera?.stop(); camera = nil
        }
        pump()
    }
    func flipCamera() { camera?.flip() }

    private var cameraBeforeBackground = false
    /// iOS stops the camera in the background: tell the peer (Camera off) and resume on return.
    func enterBackground() {
        cameraBeforeBackground = cameraOn
        if cameraOn { toggleCamera() }
        camera?.stop(); camera = nil
    }
    func enterForeground() {
        if cameraBeforeBackground && !cameraOn && ended == nil { toggleCamera() }
        cameraBeforeBackground = false
    }
    func toggleSpeaker() { speaker.toggle(); audio?.setRoute(speaker ? .speaker : .earpiece) }

    /// The rungs below the header size with its aspect ratio (the camera frame is scaled to any size).
    private func startLadder(header: StreamHeader) {
        let requested = VideoResolution(header.width, header.height)
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

    /// Once a second: adapt the encoder to what the link delivers (VideoRateController).
    private func adaptVideoRate(now: TimeInterval) {
        guard let camera, engine.canSendMedia, cameraOn else { lastRateWindow = nil; return }
        if rateController == nil {
            let requested = engine.effectiveVideoBitrate / 1000
            rateController = VideoRateController(startKbps: requested, maxKbps: requested)
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
            camera.setBitrate(kbps: target)
            var fields = ["targetKbps": "\(target)", "encodedKbps": String(format: "%.0f", encodedKbps),
                          "deliveredKbps": String(format: "%.0f", deliveredKbps), "queueAgeMs": "\(Int(age * 1000))"]
            #if os(macOS)
            fields["source"] = input.usesPeer ? "peer_delivery" : "local_queue"
            #endif
            AppLog.event("call_rate", fields)
        }
        if let ladder, let target = rateController?.targetKbps, let decision = ladder.onTarget(targetBps: target * 1000, nowMs: nowMs) {
            camera.setResolution(width: decision.resolution.width, height: decision.resolution.height)
            AppLog.event("call_resolution", ["requested": "\(ladder.requested)", "effective": "\(decision.resolution)", "reason": decision.reason])
        }
    }

    private func refreshStats() {
        let now = ProcessInfo.processInfo.systemUptime
        adaptVideoRate(now: now)
        if now - lastStatsLog >= 5 { lastStatsLog = now; logStats() }
        var parts: [String] = [transport.label]
        if let audio { parts.append(audio.stats) }
        if let camera { parts.append("sent \(camera.encodedFrames) frames") }
        if remote.decodedFrames > 0 { parts.append("\(remote.decoderName): \(remote.decodedFrames) frames") }
        parts.append("rx audio \(engine.receivedAudioPackets)")
        stats = parts.joined(separator: " · ")
        if let fp = fingerprint, let model { verification = model.verificationState(of: fp) }
    }

    private func cleanupMedia() {
        ringer.stop()
        if audio != nil || camera != nil { logStats(final: true) }
        audio?.stop(); audio = nil
        camera?.stop(); camera = nil
        remote.stop()
        statsTimer?.invalidate(); statsTimer = nil
    }

    /// Engine and radio reasons in plain words for the screen (the log keeps the original).
    static func plainReason(_ reason: String) -> String {
        if reason == CallerRevealGate.message { return "Couldn't confirm who this is" }
        let r = reason.lowercased()
        if r.contains("declined") && r.contains("busy") { return "Busy" }
        if r.contains("declined") { return "Declined" }
        if r.contains("cancelled") || r.contains("canceled") { return "Call cancelled" }
        if r.contains("local media failure") { return "Their phone had a problem and ended the call" }
        if r.contains("peer ended") || r == "call ended" { return "Call ended" }
        if r.contains("stopped responding") || r.contains("link lost") || r.contains("disconnected") || r.contains("timed out") { return "Lost connection" }
        if r.contains("no answer") || r.contains("ring") && r.contains("timeout") { return "No answer" }
        if r.contains("cannot decode") || r.contains("incompatible") { return "Their phone can't play this call" }
        if r.contains("authentication") || r.contains("signature") || r.contains("identity") { return "Couldn't confirm who this is" }
        return reason.replacingOccurrences(of: "peer", with: "other phone").replacingOccurrences(of: "Peer", with: "Other phone")
    }

    private func finished(_ reason: String) {
        #if os(macOS)
        model?.desktopCallLinkFinished(self)
        #endif
        var delay: TimeInterval = 2
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
                ended = "Couldn't reach \(label?.title ?? peerName) \u{2013} \(CallController.plainReason(reason).lowercased())"
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

// MARK: - Watching (viewer: we advertise a request; the Android source connects to us)

final class WatchController: ObservableObject {
    weak var model: AppModel?
    let offer: DiscoveryAnnouncement
    let name: String
    /// "direct" / "via 2 phones".
    let route: String
    let transport: MeshTransport
    @Published var state = "Joining…"
    @Published var awaitingSource = true
    @Published var paused = false
    @Published var ended: String?
    @Published var stats = ""
    @Published var sourceFingerprint: IdentityFingerprint?
    @Published var signedTitle: String?
    /// The source's stream header arrived: the join worked (StreamJoinRetry).
    private(set) var joined = false
    /// The user left (not a failed join).
    private(set) var stoppedByUser = false
    /// Experimental audio-only live: the selected offer is a radio stream (no video; screen-off playback).
    let isRadio: Bool
    private let routeKey: StreamRoutePenalties.Route
    private var audioInboundGuard: AudioLiveRelayInboundGuard?
    /// The verified BTL1 preset once the header arrived (1 Low data, 2 Voice, 3 Music).
    @Published var radioPreset: UInt8?
    let remote = RemoteVideo()
    private let identity: SigningIdentity
    private var engine: StreamViewerEngine?
    private var driver: ConnectionDriver?
    private var audio: CallAudio?
    private var timeout: Timer?
    private var statsTimer: Timer?

    // EXPERIMENTAL forwarding (Settings > Advanced, off by default): pass this stream on to one child.
    let forwardingEnabled: Bool
    @Published var sharing = false
    private(set) var forwardOffer: DiscoveryAnnouncement?
    private var adjacentNodeId: NodeId?
    private var core: StreamForwardingCore?
    private var forwarder: (engine: StreamForwarderEngine, driver: ConnectionDriver, row: UUID)?
    private var connectingChild: UUID?
    private var downstreamToken: UInt32 = 0
    private var health = RelayChildHealthPolicy()
    private var healthTimer: Timer?
    private var lastUpstreamKeyRequest: TimeInterval = 0
    private var childSince: TimeInterval?
    private var bytesAtChildStart: (in: UInt64, out: UInt64) = (0, 0)

    init(model: AppModel, identity: SigningIdentity, offer: DiscoveryAnnouncement, name: String, route: String, transport: MeshTransport, routeKey: StreamRoutePenalties.Route) {
        self.model = model; self.identity = identity; self.offer = offer; self.name = name; self.route = route; self.transport = transport
        self.routeKey = routeKey
        isRadio = offer.isAudioOnlyOffer
        forwardingEnabled = model.relayForOthers && offer.streamToken != 0
        // DEBUG -NearbyWatchTimeout N shortens the wait for UI tests of a failed join.
        let wait = RootView.debugArgument("-NearbyWatchTimeout").flatMap(Double.init) ?? 45
        timeout = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            guard let self, self.awaitingSource else { return }
            self.finish("Could not join. Move closer and try again. The broadcaster's phone needs \"Find iPhones\" turned on.")
        }
        remote.onNeedKeyFrame = { [weak self] in self?.engine?.requestKeyFrame(); self?.driver?.pump() }
    }

    func attach(_ link: MeshLink) {
        AppLog.event("watch_link", ["transport": link.transport.rawValue, "expected": transport.rawValue])
        guard awaitingSource, link.transport == transport else { link.close(); return }
        awaitingSource = false
        state = "Authenticating…"
        // Signing maxChildren 1 makes the source send BMV1 envelopes this phone can pass on (exactly 1: more is BGK1).
        let engine = StreamViewerEngine(transport: transport, identity: identity, decodeMask: VideoDecoderSupport.decodeMask,
                                        expectedAdjacentPrefix: offer.nodeIdPrefix, maxChildren: forwardingEnabled ? 1 : 0,
                                        labels: model?.peerLabelsEnabled ?? false,
                                        rotatingOffer: offer.rotating ? offer : nil, expectAudioOnly: isRadio,
                                        allowAudioOnly: AppSettings.audioLive)
        engine.onTimeReports = AppSettings.onTimeReports
        engine.onAudioLivePayload = { [weak self] bytes in
            self?.audioInboundGuard?.onBytes(bytes, now: ConnectionDriver.now)
        }
        let routeKey = self.routeKey
        engine.isParentBlocked = { [weak model = self.model] _ in
            // The route only, as Android: no node is ever penalised, even one seen over an authenticated link.
            model?.streamRoutePenalties.isPenalized(routeKey, authenticatedNode: nil, now: ConnectionDriver.now) ?? false
        }
        if offer.rotating {
            // Android rotid_downgrade: this viewer's request carries its fixed prefix while it waits for the source.
            AppLog.event("rotating_ids", ["event": "downgrade", "role": "viewer"])
        }
        engine.identityGate = model?.book
        engine.onEvent = { [weak self] in self?.handle($0) }
        self.engine = engine
        let driver = ConnectionDriver(engine: engine, link: link)
        driver.onFinished = { [weak self] reason in self?.finish(reason) }
        self.driver = driver
        driver.start()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let engine = self.engine else { return }
            if self.isRadio {
                let verified = engine.audioLiveGuard?.verifiedRecords ?? 0
                self.stats = "\(self.transport.label) · audio only · \(verified) signed records verified · \(engine.audioPackets) Opus frames"
            } else {
                self.stats = "\(self.transport.label) · \(engine.videoPackets) video / \(engine.audioPackets) audio packets · \(self.remote.decoderName)"
            }
        }
    }

    private func handle(_ event: StreamViewerEngine.Event) {
        switch event {
        case .sourceAuthenticated(let adjacent, let source, _): AppLog.event("watch_auth", ["adjacent": adjacent.shortLabel, "source": source.shortLabel])
        case .header(let h): AppLog.event("watch_header", ["codec": "\(h.codecId)", "size": "\(h.width)x\(h.height)", "fps": "\(h.fps)", "audio": "\(h.hasAudio)"])
        case .audioLiveHeader(let h): AppLog.event("watch_header", ["kind": "audio_only", "preset": "\(h.preset)"])
        case .state(let s): AppLog.event("watch_state", ["state": "\(s)"])
        case .ended(let r, let e): AppLog.event("watch_end", ["reason": r, "error": "\(e)", "video": "\(engine?.videoPackets ?? 0)", "audio": "\(engine?.audioPackets ?? 0)", "decoded": "\(remote.decodedFrames)"])
        case .title: AppLog.event("watch_title", ["title": "set"])
        default: break
        }
        switch event {
        case .linkAuthenticated: break
        case .sourceAuthenticated(let adjacent, _, let fp):
            adjacentNodeId = adjacent
            sourceFingerprint = fp; model?.noteAuthenticated(fp); state = isRadio ? "Waiting for sound…" : "Waiting for video…"
        case .header(let h):
            joined = true
            remote.configure(header: h)
            if h.hasAudio {
                let audio = CallAudio(bitrate: 24_000, route: .speaker)
                audio.start(capture: false); self.audio = audio
            }
            state = ""
            if forwardingEnabled { considerForwarding(header: h) }
        case .audioLiveHeader(let h):
            radioPreset = h.preset
            audioInboundGuard = AudioLiveRelayInboundGuard(nominalKbps: Double(AudioLive.presetKbps(h.preset)))
            if forwardingEnabled { considerForwarding(header: nil, audioPreset: h.preset) }
            let audio = CallAudio(bitrate: AudioLive.presetKbps(h.preset) * 1_000, route: .speaker)
            audio.start(capture: false); self.audio = audio
            state = ""
        case .audioConfig: break
        case .audio(let p): audio?.receive(presentationTimeUs: p.presentationTimeUs, opus: p.payload)
        case .video(let p): remote.decode(p)
        case .rotation(let d): remote.sink.rotation = d
        case .state(let s):
            let wasPaused = paused
            paused = s == .paused
            audioInboundGuard?.onPausedChanged(paused, now: ConnectionDriver.now)
            switch s {
            case .paused: state = "Paused by the broadcaster"
            case .ended: state = "The broadcast ended"
            case .liveMuted: state = "Muted"
            case .liveCameraOff: state = "Camera off"
            case .liveMutedCameraOff: state = "Muted, camera off"
            case .live: state = ""
            }
            // An audio-only receiver never asks for a keyframe (PROTOCOL: no type 5 on a radio stream).
            if !isRadio, s == .live || (s.isLive && wasPaused) { remote.requestKeyFrame() }
        case .envelope(let e): relay(e)
        case .title(let t): signedTitle = t
        case .routeWithdrawn: state = "This way to the stream is full. Try another one nearby."
        case .ended(let reason, _):
            if engine?.audioMarkerMismatch != nil {
                model?.penalizeStreamRoute(routeKey)
            }
            finish(reason)
        }
    }

    func stop() { stoppedByUser = true; driver?.cancel(); finish("Stopped watching") }

    // MARK: Experimental forwarding

    /// Admission after the header (Android: skipped when the offer's bitrate is unknown), then the offer onward.
    private func considerForwarding(header: StreamHeader?, audioPreset: UInt8? = nil) {
        guard let model, forwardOffer == nil, let engine, engine.meshStreamId != nil, engine.mediaOpenKey != nil else {
            AppLog.event("relay_admission", ["started": "false", "reason": "no mesh stream (source sent direct records)"]); return
        }
        if isRadio, model.audioRelayMemory.blockedFor(transport, now: ConnectionDriver.now) > 0 { return }
        guard RotatingStreamPolicy.mayForward(offer: offer, rotatingIds: model.rotatingIds) else {
            AppLog.event("relay_admission", ["started": "false", "reason": "rotating offer: a fixed-prefix forwarder offer would show this phone's ID"]); return
        }
        let learned = AppSettings.relayLearned
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let decision = RelayAdmission.evaluate(learned: learned, advertisedKbps: Int(offer.streamBitrateKbps), fps: header?.fps ?? 0, nowMs: nowMs, audioPreset: audioPreset)
        AppLog.event("relay_admission", ["cold_start": "\(decision.coldStart)", "needKbps": String(format: "%.0f", decision.needKbps),
                                         "budgetKbps": String(format: "%.0f", decision.budgetKbps), "measuredKbps": String(format: "%.0f", decision.measuredKbps),
                                         "fits": "\(decision.fits)", "proven": "\(learned.provenKbps)", "ceiling": "\(learned.ceilingKbps.map(String.init) ?? "none")"])
        guard decision.fits, let own = model.identityPrefix else { return }
        downstreamToken = StreamRouteToken.downstream(upstreamRouteToken: offer.streamToken, parentPrefix: offer.nodeIdPrefix, ownPrefix: own)
        var flags = DiscoveryAnnouncement.flagStreamAvailable | DiscoveryAnnouncement.flagRelayCapable
        if transport == .gatt { flags |= DiscoveryAnnouncement.flagGattTransport }
        forwardOffer = DiscoveryAnnouncement(nodeIdPrefix: own, flags: flags, capabilitySummary: audioPreset != nil ? 0x40 : StreamProtocol.capabilityMask(codecId: header!.codecId),
                                             streamToken: downstreamToken, routeCost: min(offer.routeCost + 1, 15),
                                             streamWidth: UInt16(header?.displayWidth ?? 0), streamHeight: UInt16(header?.displayHeight ?? 0),
                                             streamFps: UInt8(header?.fps ?? 0), streamBitrateKbps: audioPreset.map { UInt16(AudioLive.presetKbps($0)) } ?? offer.streamBitrateKbps)
        AppLog.event("relay_offer", ["token": String(format: "%08x", downstreamToken), "routeCost": "\(min(offer.routeCost + 1, 15))", "transport": transport.rawValue])
        if healthTimer == nil {
            healthTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkChildHealth() }
        }
        model.refreshAdvertising()
    }

    private func relay(_ envelope: MeshEnvelope) {
        guard forwardingEnabled else { return }
        if core == nil, let adjacent = adjacentNodeId {
            core = StreamForwardingCore(localNodeId: identity.nodeId, upstreamPeerNodeId: adjacent, streamId: envelope.streamId, sourceNodeId: envelope.sourceNodeId, audioOnly: isRadio)
        }
        guard let core else { return }
        do {
            switch try core.receive(envelope) {
            case .forward(let copy, _):
                // Relay-child media age: a slow child skips to a keyframe; its paced recovery request goes upstream.
                if forwarder?.engine.forward(copy, now: ConnectionDriver.now) == .shedWaitingForKeyFrame { requestUpstreamKeyFrame(force: true) }
                forwarder?.driver.pump()
            case .waitingForJoinKeyFrame: requestUpstreamKeyFrame()
            case .rejected: break
            }
        } catch {
            AppLog.event("relay_error", ["stage": "core", "error": "\(error)"])
        }
    }

    private func requestUpstreamKeyFrame(force: Bool = false) {
        guard !isRadio else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastUpstreamKeyRequest > 1 else { return }
        lastUpstreamKeyRequest = now
        engine?.requestKeyFrame(); driver?.pump()
    }

    /// Children advertise a viewer request carrying this phone's downstream token; connect as central.
    func viewerRequestsChanged(_ peers: [DiscoveredPeer]) {
        guard forwardOffer != nil, forwarder == nil, connectingChild == nil, ended == nil, let model, let identity = Optional(identity) else { return }
        guard let peer = peers.first(where: { $0.announcement.isViewerRequest(routeToken: downstreamToken) && $0.announcement.transport == transport }),
              let engine, let source = engine.mediaSourceNodeId, let streamId = engine.meshStreamId, let key = engine.mediaOpenKey, engine.header != nil || engine.audioLiveHeader != nil else { return }
        if isRadio, model.audioRelayMemory.blockedFor(transport, now: ConnectionDriver.now) > 0 { return }
        connectingChild = peer.id
        AppLog.event("relay_child", ["stage": "connect", "prefix": peer.prefixHex, "transport": transport.rawValue])
        let grant = ForwardedStreamGrant(sourceNodeId: source, streamId: streamId, key: key)
        model.radio.connect(to: peer.id, transport: transport) { [weak self] result in
            guard let self else { return }
            self.connectingChild = nil
            guard case .success(let link) = result, self.ended == nil, self.forwarder == nil else {
                if case .success(let l) = result { l.close() }
                AppLog.event("relay_child", ["stage": "connect_failed"]); return
            }
            let labels = self.engine?.labelInbox.verifiedEncoded().isEmpty == false ? try? SignedLabelCodec.encodeContainer(self.engine!.labelInbox.verifiedEncoded()) : nil
            let child = StreamForwarderEngine(transport: self.transport, identity: identity, grant: grant, codecId: self.engine?.header?.codecId ?? 0,
                                              expectedChildPrefix: peer.announcement.nodeIdPrefix, labelsContainer: labels, audioOnly: self.isRadio)
            child.linkPacing = AppSettings.linkPacing; child.onTimeSeedRaise = AppSettings.onTimeSeedRaise
            child.mediaAge = AppSettings.relayChildMediaAge
            child.identityGate = model.book
            let driver = ConnectionDriver(engine: child, link: link)
            child.onEvent = { [weak self] in self?.handleChild($0) }
            driver.onFinished = { [weak self] reason in self?.removeChild(reason) }
            self.forwarder = (child, driver, peer.id)
            self.engine?.holdEndAck = true
            driver.start()
            model.refreshAdvertising()   // presence stops while a child is connected
        }
    }

    private func handleChild(_ event: StreamForwarderEngine.Event) {
        guard let forwarder else { return }
        switch event {
        case .childAuthenticated(let id, _):
            AppLog.event("relay_child", ["stage": "authenticated", "child": id.shortLabel])
            do {
                for e in try core?.addChild(id) ?? [] { forwarder.engine.forward(e) }
                forwarder.driver.pump()
                requestUpstreamKeyFrame(force: true)      // a join needs a fresh keyframe
                health = RelayChildHealthPolicy(sheddingActive: forwarder.engine.mediaAge)
                childSince = ProcessInfo.processInfo.systemUptime
                bytesAtChildStart = (engine?.receivedMediaBytes ?? 0, 0)
                sharing = true
                audioInboundGuard?.onChildCount(1, now: ConnectionDriver.now)
            } catch { AppLog.event("relay_error", ["stage": "add_child", "error": "\(error)"]); forwarder.driver.cancel() }
        case .keyFrameRequested: requestUpstreamKeyFrame(force: true)
        case .endAcknowledged: engine?.releaseEndAck(); driver?.pump()
        case .routeWithdrawalAcknowledged, .report: break
        case .ended(let reason, let error): AppLog.event("relay_child", ["stage": "ended", "reason": reason, "error": "\(error)"])
        }
    }

    private func removeChild(_ reason: String) {
        guard let f = forwarder else { return }
        if let child = f.engine.endpoint?.peerNodeId { core?.removeChild(child) }
        learnFromChild(engine: f.engine, withdrawn: f.engine.isWithdrawing)
        forwarder = nil; sharing = false; childSince = nil
        audioInboundGuard?.onChildCount(0, now: ConnectionDriver.now)
        AppLog.event("relay_child", ["stage": "removed", "reason": reason, "forwarded": "\(f.engine.forwardedEnvelopes)"])
        if let engine, engine.holdEndAck { engine.holdEndAck = false; engine.releaseEndAck() }
        if ended == nil { model?.refreshAdvertising() }   // offer again
    }

    /// Withdraw a child whose link stays behind live (hop-local; it can reroute).
    private func checkChildHealth() {
        if isRadio, forwardOffer == nil, let preset = radioPreset,
           model?.audioRelayMemory.blockedFor(transport, now: ConnectionDriver.now) == 0 {
            considerForwarding(header: nil, audioPreset: preset)
        }
        guard let f = forwarder, f.engine.ready else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if isRadio {
            if audioInboundGuard?.shouldDropChild(now: now) == true {
                model?.audioRelayMemory.onDropped(transport, now: now)
                forwardOffer = nil; model?.refreshAdvertising()
                audioInboundGuard?.onChildCount(0, now: now)
                state = "Forwarding stopped to keep your sound playing"
                f.engine.withdrawRoute(); f.driver.pump()
            } else if audioInboundGuard?.childCarriedHealthily(now: now) == true {
                model?.audioRelayMemory.onHealthy(transport)
            }
            return
        }
        let backlog = f.engine.backlog(now: now)
        if health.shouldWithdraw(backlog: backlog, now: now) {
            AppLog.event("relay_withdraw", ["backlogMs": "\(Int(backlog * 1000))", "queued": "\(f.engine.queuedEnvelopes)"])
            learnFromChild(engine: f.engine, withdrawn: true)
            f.engine.withdrawRoute(); f.driver.pump()
        }
    }

    /// Proven after a clean relay of at least 10 s (two 5 s windows); a withdrawal records a ceiling.
    private func learnFromChild(engine child: StreamForwarderEngine, withdrawn: Bool) {
        guard let since = childSince, let viewer = engine else { return }
        let seconds = ProcessInfo.processInfo.systemUptime - since
        guard seconds >= 2 else { return }
        let kbps = Int(Double((viewer.receivedMediaBytes - bytesAtChildStart.in) + child.forwardedBytes) * 8 / seconds / 1000)
        var learned = AppSettings.relayLearned
        if withdrawn {
            learned.ceilingKbps = kbps; learned.ceilingMeasuredAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        } else if seconds >= 10 {
            learned.provenKbps = max(learned.provenKbps, kbps)
        } else { return }
        AppSettings.relayLearned = learned
        AppLog.event("relay_learned", ["kbps": "\(kbps)", "withdrawn": "\(withdrawn)", "proven": "\(learned.provenKbps)", "ceiling": "\(learned.ceilingKbps.map(String.init) ?? "none")"])
        childSince = nil
    }

    private func finish(_ reason: String) {
        guard ended == nil else { return }
        healthTimer?.invalidate(); forwarder?.driver.cancel(); forwardOffer = nil
        ended = reason; state = reason; awaitingSource = false
        timeout?.invalidate(); statsTimer?.invalidate()
        audio?.stop(); audio = nil; remote.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.model?.watchFinished(self)
        }
    }
}

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
    private(set) var routeToken: UInt32 = 0
    private var sessions: [UUID: (engine: StreamSourceEngine, driver: ConnectionDriver)] = [:]
    private var connecting: Set<UUID> = []
    private(set) var camera: CameraVideo?
    private var audio: CallAudio?
    private let header: StreamHeader
    private var generation: UInt8 = 0
    let maxViewers = 3
    private var statsTimer: Timer?
    private let streamId = UUID()

    let labelsEnabled: Bool
    let title: String?

    // Experimental audio-only live ("radio"): microphone only, Opus in 200 ms records signed by a per-stream key.
    let audioOnly: Bool
    let preset: UInt8
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

    func toggleMute() {
        guard audioOnly else { return }
        muted.toggle()
        if muted { batch = batch.map { MediaPacket(flags: $0.flags, presentationTimeUs: $0.presentationTimeUs, payload: Self.silenceFrame) } }
        AppLog.event("radio_mute", ["muted": "\(muted)"])
    }

    init(model: AppModel, identity: SigningIdentity, transport: MeshTransport, labels: Bool = false, title: String? = nil,
         audioOnly: Bool = false, preset: UInt8 = AudioLive.presetVoice) {
        self.model = model; self.identity = identity; self.transport = transport; labelsEnabled = labels; self.title = title
        self.audioOnly = audioOnly; self.preset = AudioLive.isValidPreset(preset) ? preset : AudioLive.presetVoice
        header = StreamHeader(width: MediaDefaults.width, height: MediaDefaults.height, fps: MediaDefaults.fps, codecId: StreamProtocol.codecVP9,
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
                                     streamFps: UInt8(header.fps), streamBitrateKbps: UInt16(MediaDefaults.videoKbps))
    }

    func start() {
        if audioOnly { startRadio(); return }
        guard VP9Encoder.isAvailable else { state = "Video can't start on this phone."; return }
        running = true
        let clock = ProcessInfo.processInfo.systemUptime
        let audio = CallAudio(bitrate: 32_000, route: .speaker)
        audio.clockStart = clock
        audio.onPacket = { [weak self] pts, data in self?.broadcast { $0.sendAudio(presentationTimeUs: pts, opus: data) } }
        audio.start(capture: true)
        self.audio = audio
        let camera = CameraVideo(width: header.width, height: header.height, fps: header.fps, bitrateKbps: MediaDefaults.videoKbps, front: false,
                                 clockStart: clock)
        camera.onFrame = { [weak self] flags, pts, data in self?.broadcast { $0.sendVideo(flags: flags, presentationTimeUs: pts, payload: data) } }
        camera.onFailure = { [weak self] message in self?.state = message }
        camera.start()
        self.camera = camera
        state = "Live. Waiting for viewers…"
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.stats = "\(self.transport.label) · \(self.sessions.count) viewer(s) · sent \(self.camera?.encodedFrames ?? 0) frames"
        }
    }

    /// Audio-only: the identity key certifies a fresh stream key once; the microphone's 20 ms Opus frames are
    /// batched into 200 ms records with contiguous timestamps, each signed once and sent to every listener.
    private func startRadio() {
        guard CallAudio.opusAvailable else { state = "Audio can't start on this phone."; return }
        do { signer = try AudioLiveSigner(identity: identity, streamId: streamId, preset: preset) }
        catch { state = "Could not start: \(error)"; return }
        signedConfig = try? signer?.sign(flags: StreamProtocol.flagAudio | StreamProtocol.flagCodecConfig, presentationTimeUs: 0, body: OpusHead.make())
        running = true
        let audio = CallAudio(bitrate: AudioLive.presetKbps(preset) * 1_000, route: .speaker)
        audio.onPacket = { [weak self] pts, data in self?.radioFrame(pts: pts, opus: data) }
        audio.onFailure = { [weak self] message in self?.state = message }
        audio.start(capture: true)
        self.audio = audio
        AppLog.event("radio_start", ["preset": "\(preset)", "stream": streamId.uuidString.prefix(8).description, "transport": transport.rawValue])
        state = "Live. Waiting for listeners…"
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.stats = "\(self.transport.label) · audio only · \(self.sessions.count) listener(s) · \(self.signedRecords) signed records"
        }
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
        for peer in peers where peer.announcement.isViewerRequest(routeToken: routeToken) && peer.announcement.transport == transport {
            guard sessions[peer.id] == nil, !connecting.contains(peer.id), sessions.count + connecting.count < maxViewers else { continue }
            connecting.insert(peer.id)
            let viewerPrefix = peer.announcement.nodeIdPrefix
            model.radio.connect(to: peer.id, transport: transport) { [weak self] result in
                guard let self else { return }
                self.connecting.remove(peer.id)
                guard case .success(let link) = result, self.running else { if case .success(let l) = result { l.close() }; return }
                let engine = StreamSourceEngine(transport: self.transport, identity: self.identity, header: self.header,
                                                expectedViewerPrefix: viewerPrefix, streamId: self.streamId, labels: self.labelsEnabled, title: self.title,
                                                linkPacing: AppSettings.linkPacing, audioLive: self.signer)
                engine.onTimeSeedRaise = AppSettings.onTimeSeedRaise
                engine.identityGate = model.book
                let driver = ConnectionDriver(engine: engine, link: link)
                engine.onEvent = { [weak self] event in
                    switch event {
                    case .viewerAuthenticated(let id, let fp):
                        model.noteAuthenticated(fp)
                        if let config = self?.signedConfig { engine.sendSignedAudio(config) } else { engine.sendAudioConfig() }
                        self?.camera?.requestKeyFrame()
                        self?.viewers.append(model.contactName(prefixHex: id.prefix.hex) ?? "Viewer \(id.shortLabel.prefix(6))")
                        self?.state = "Live"
                    case .keyFrameRequested: self?.camera?.requestKeyFrame()
                    default: break
                    }
                }
                driver.onFinished = { [weak self] _ in
                    self?.sessions[peer.id] = nil
                    self?.viewers = self?.sessions.keys.map { "Viewer \($0.uuidString.prefix(4))" } ?? []
                    self?.generation &+= 1
                    self?.model?.refreshAdvertising()
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
        if !paused { camera?.requestKeyFrame() }
        model?.refreshAdvertising()
    }

    func stop() {
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


// MARK: - Experimental call relay hop (default off)

/// One relay hop for one call: child (callee or next relay) first as central, then one parent as peripheral.
/// End-to-end records are copied unchanged; this phone never sees the call's audio or video.
final class CallRelayController: ObservableObject {
    weak var model: AppModel?
    let row: UUID
    let transport: MeshTransport
    let hop: CallRelayHop
    @Published var state = "Connecting to the callee"
    private var childDriver: ConnectionDriver?
    private var parentDriver: ConnectionDriver?
    private var timer: Timer?
    private var done = false

    init(model: AppModel, identity: SigningIdentity, row: UUID, childOffer: DiscoveryAnnouncement, transport: MeshTransport) {
        self.model = model; self.row = row; self.transport = transport
        hop = CallRelayHop(identity: identity, transport: transport, childOffer: childOffer,
                           hiddenIdentities: model.hiddenIdentities, pins: model.bmh3Pins,
                           pseudonymousEdges: model.bmh3Pseudonyms && model.rotatingIds && AppSettings.relayedPseudonymousEdges)
        hop.onStateChange = { [weak self] s in self?.stateChanged(s) }
        // Backpressure: a hop that drained lets the other one parse again, outside the sealing path that reported it.
        hop.onIngressResumable = { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.done else { return }
                self.hop.resumeIngress(now: ConnectionDriver.now)
                self.childDriver?.pump(); self.parentDriver?.pump()
            }
        }
    }

    var awaitingParent: Bool { hop.state == .waitingForParent && hop.parent == nil }
    var parentOffer: DiscoveryAnnouncement? { hop.parent == nil ? hop.parentOffer : nil }

    func start() {
        AppLog.event("relay_call", ["stage": "connect_child", "callee": hop.calleePrefix.hex, "childCost": "\(hop.childOffer.routeCost)", "transport": transport.rawValue])
        model?.radio.connect(to: row, transport: transport) { [weak self] result in
            guard let self, !self.done else { return }
            switch result {
            case .success(let link):
                let driver = ConnectionDriver(engine: self.hop.child, link: link)
                driver.onFinished = { [weak self] reason in self?.hop.close("Child link: \(reason)") }
                self.childDriver = driver
                driver.start()
            case .failure(let error):
                self.finish("Could not reach the callee: \(error)")
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.hop.tick(now: ConnectionDriver.now)
            self.childDriver?.pump(); self.parentDriver?.pump()
        }
    }

    func attachParent(_ link: MeshLink) {
        guard link.transport == transport, let engine = hop.attachParent() else { link.close(); return }
        AppLog.event("relay_call", ["stage": "parent_connected", "transport": link.transport.rawValue])
        let driver = ConnectionDriver(engine: engine, link: link)
        driver.onFinished = { [weak self] reason in self?.hop.close("Parent link: \(reason)") }
        parentDriver = driver
        driver.start()
        // Copied records are pulled by each link's own driver; pump the other side when one receives.
        engine.onRecordCopied = { [weak self] in self?.childDriver?.pump() }
        hop.child.onRecordCopied = { [weak self] in self?.parentDriver?.pump() }
    }

    private func stateChanged(_ s: CallRelayHop.State) {
        switch s {
        case .connectingChild: state = "Connecting to the callee"
        case .waitingForParent:
            state = "Passing calls on for a phone near you"
            AppLog.event("relay_call", ["stage": "child_authenticated", "offerCost": "\(hop.parentOffer?.routeCost ?? 0)"])
            model?.refreshAdvertising()
        case .relaying:
            state = "Passing a call on"
            AppLog.event("relay_call", ["stage": "relaying"])
            model?.refreshAdvertising()
        case .closed(let reason): finish(reason)
        }
    }

    func stop() { hop.close("Stopped") }

    private func finish(_ reason: String) {
        guard !done else { return }
        done = true
        timer?.invalidate()
        AppLog.event("relay_call", ["stage": "closed", "reason": reason, "copiedToCallee": "\(hop.child.copiedRecords)", "copiedToCaller": "\(hop.parent?.copiedRecords ?? 0)"])
        // Let copied final records (hang-up) drain before closing (Android drains 400 ms).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.childDriver?.cancel(); self.parentDriver?.cancel()
            self.model?.callRelayFinished(self)
        }
    }
}
