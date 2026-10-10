import Foundation
import SwiftUI
import NearbyCore
#if canImport(NearbyMedia)
import NearbyMedia
#endif

/// Default video for user calls and streams (user decision 2026-10-10, as Android): 426x240 at 15 FPS, 200 kbps,
/// portrait on the iPhone (240x426). The resolution ladder steps down from it on weak links.
enum MediaDefaults {
    static let width = 240, height = 426, fps = 15, videoKbps = 200
}

/// Remote video decode on a serial queue; decode failures ask the sender for a keyframe (rate-limited).
final class RemoteVideo {
    private let queue = DispatchQueue(label: "org.nearbyintercom.decode", qos: .userInitiated)
    private var decoder: VideoFrameDecoder?
    private var codecId: UInt8 = 0
    private var lastKeyRequest: TimeInterval = 0
    private var headerSize = ""
    private var lastDecodedSize = (0, 0)
    let sink = VideoSink()
    var onNeedKeyFrame: (() -> Void)?
    private(set) var decoderName = ""
    var decodedFrames = 0

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
    @Published var phase: PrivateCallPhase?
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

    init(model: AppModel, role: PrivateCallRole, peerName: String, peerPrefixHex: String?, identity: SigningIdentity,
         transport: MeshTransport, type: CallType, relayHops: UInt8, rotating: RotatingCallOptions? = nil) {
        self.model = model; self.role = role; self.transport = transport; self.peerName = peerName; self.peerPrefixHex = peerPrefixHex
        callType = type; cameraOn = type == .video; speaker = type == .video
        let expected = peerPrefixHex.flatMap { Data(hex: $0) }
        // Portrait capture; 240x426 keeps software VP9 light and fits the Android call profiles on Bluetooth.
        // Default for user calls (user decision 2026-10-10, as Android): 426x240 (portrait 240x426) at 15 FPS, 200 kbps.
        let settings = CallMediaSettings(width: MediaDefaults.width, height: MediaDefaults.height, fps: MediaDefaults.fps,
                                         videoBitrate: MediaDefaults.videoKbps * 1000, audioBitrate: 24_000)
        engine = CallEngine(role: role, transport: transport, identity: identity, requestedType: type, encodeMask: VideoDecoderSupport.encodeMask,
                            decodeMask: VideoDecoderSupport.decodeMask, settings: settings, expectedPeerPrefix: expected, relayHops: relayHops,
                            labels: model.callLabelOptions(), rotating: rotating)
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
        remote.onNeedKeyFrame = { [weak self] in self?.engine.requestKeyFrame(); self?.pump() }
        relayed = relayHops > 0
        phaseText = role == .caller ? "Calling…" : "Connecting…"
    }

    func attach(_ link: MeshLink) {
        let driver = ConnectionDriver(engine: engine, link: link)
        driver.onFinished = { [weak self] reason in self?.finished(reason) }
        self.driver = driver
        driver.start()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshStats() }
    }

    /// True when the call ended with an error before it was ever active (shown again on the Call screen).
    private(set) var failedEarly = false

    func failed(_ reason: String, stage: String = "connect", detail: String = "") {
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
            if let linkPeer, linkPeer != id { relayed = true }
        case .phase(let p):
            phase = p
            if p == .incomingRinging { ringer.start() } else { ringer.stop() }
            switch p {
            case .outgoingInvite: phaseText = "Calling…"
            case .outgoingRinging: phaseText = "Ringing…"
            case .incomingRinging: phaseText = offeredType == .voice ? "Incoming voice call" : "Incoming video call"
            case .negotiatingMedia: phaseText = "Connecting…"
            case .active: phaseText = ""; if activeSince == nil { activeSince = Date() }
            case .ended: phaseText = "Call ended"
            }
        case .incomingCall(let type):
            offeredType = type; callType = type
            if let runtime = model?.rotating, model?.rotatingIds == true { runtime.tarpit.forgive(epoch: runtime.currentEpoch()) }
        case .offeredTypeChanged(let type):
            offeredType = type; callType = type
            if phase == .incomingRinging { phaseText = type == .voice ? "Incoming voice call" : "Incoming video call" }
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
        case .peerReport: break
        case .peerLabels(let name, let subject):
            // Verified signed labels for this call only; your contact's own label always wins (never cached).
            if let current = label, let prefix = peerPrefixHex.flatMap({ Data(hex: $0) }), prefix.count == 6 {
                let updated = PeerLabel(prefix: prefix, contactName: current.contactName, selfName: name, verified: current.verified)
                label = updated; peerName = updated.title
            }
            self.subject = subject
        case .ended(let reason, let error):
            // An error before the call was ever active stays readable longer and is repeated on the Call screen.
            if error && activeSince == nil { failedEarly = true }
            let plain = CallController.plainReason(reason)
            let shown = error && activeSince == nil ? "Couldn't reach \(label?.title ?? peerName) \u{2013} \(plain.lowercased())" : plain
            ended = shown; phaseText = shown; cleanupMedia(); scheduleDismiss(after: error ? 6 : 2)
        }
    }

    private let mediaClock = ProcessInfo.processInfo.systemUptime

    private var lastStatsLog: TimeInterval = 0
    private func log(_ event: CallEngine.Event) {
        switch event {
        case .linkAuthenticated(let id): AppLog.event("call_auth", ["stage": "link", "peer": id.shortLabel, "transport": transport.rawValue])
        case .peerAuthenticated(let id, let fp):
            AppLog.event("call_auth", ["stage": "endpoint", "peer": id.shortLabel, "handle": IdentityHandle.handle(prefix: id.prefix) ?? "?",
                                       "fingerprint": String(fp.hex.prefix(16)), "codec": "\(engine.selectedCodec.map { $0 == StreamProtocol.codecVP9 ? "vp9" : "av1" } ?? "none")",
                                       "peerCaps": engine.endpoint.map { String(format: "t%02x/e%02x/d%02x/max%d", $0.peerCapabilities.transportMask, $0.peerCapabilities.encodeCodecMask, $0.peerCapabilities.decodeCodecMask, $0.peerCapabilities.maxBitrateKbps) } ?? "?"])
        case .phase(let p): AppLog.event("call_phase", ["role": role == .caller ? "caller" : "callee", "phase": "\(p)", "callId": engine.state?.callId.uuidString ?? "-"])
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
        let camera = CameraVideo(width: header.width, height: header.height, fps: header.fps, bitrateKbps: engine.settings.videoBitrate / 1000,
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
    func accept(as type: CallType) {
        MediaPermissions.request(video: type == .video, context: "incoming") { [weak self] _, _ in
            guard let self, self.phase == .incomingRinging else { return }
            do { self.callType = type; try self.engine.accept(as: type); self.pump() } catch { self.stats = "\(error)" }
        }
    }
    func decline() { try? engine.decline(.rejected); pump() }
    func end() { engine.end(); pump() }

    func toggleMute() { setMuted(!muted) }
    /// `muted` stays true while talking by holding Mute, so the button and state line still read "muted".
    func setMuted(_ value: Bool, keepTalking: Bool = false) {
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
        let decision = ladder.start(targetBps: engine.settings.videoBitrate, nowMs: nowMs)
        if decision.resolution != requested { camera?.setResolution(width: decision.resolution.width, height: decision.resolution.height) }
        AppLog.event("call_resolution", ["requested": "\(requested)", "effective": "\(decision.resolution)", "reason": decision.reason,
                                         "rungs": ladder.rungs.map(\.description).joined(separator: ",")])
    }

    private var nowMs: Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }

    /// Once a second: adapt the encoder to what the link delivers (VideoRateController).
    private func adaptVideoRate(now: TimeInterval) {
        guard let camera, engine.canSendMedia, cameraOn else { lastRateWindow = nil; return }
        if rateController == nil {
            let requested = engine.settings.videoBitrate / 1000
            rateController = VideoRateController(startKbps: requested, maxKbps: requested)
        }
        let encoded = camera.encodedBytes, sent = engine.sentVideoBytes
        defer { lastRateWindow = (now, encoded, sent) }
        guard let last = lastRateWindow, now - last.at >= 0.5 else { return }
        let seconds = now - last.at
        let encodedKbps = Double(encoded - last.encoded) * 8 / seconds / 1000
        let deliveredKbps = Double(sent - last.sent) * 8 / seconds / 1000
        let age = engine.videoQueueAge(now: ConnectionDriver.now)
        if let target = rateController?.update(queueAge: age, encodedKbps: encodedKbps, deliveredKbps: deliveredKbps) {
            camera.setBitrate(kbps: target)
            AppLog.event("call_rate", ["targetKbps": "\(target)", "encodedKbps": String(format: "%.0f", encodedKbps),
                                       "deliveredKbps": String(format: "%.0f", deliveredKbps), "queueAgeMs": "\(Int(age * 1000))"])
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
        var delay: TimeInterval = 2
        if ended == nil {
            if activeSince == nil {
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
    let remote = RemoteVideo()
    private let identity: SigningIdentity
    private var engine: StreamViewerEngine?
    private var driver: ConnectionDriver?
    private var audio: CallAudio?
    private var timeout: Timer?
    private var statsTimer: Timer?

    init(model: AppModel, identity: SigningIdentity, offer: DiscoveryAnnouncement, name: String, route: String, transport: MeshTransport) {
        self.model = model; self.identity = identity; self.offer = offer; self.name = name; self.route = route; self.transport = transport
        timeout = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
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
        let engine = StreamViewerEngine(transport: transport, identity: identity, decodeMask: VideoDecoderSupport.decodeMask,
                                        expectedAdjacentPrefix: offer.nodeIdPrefix, labels: model?.peerLabelsEnabled ?? false)
        engine.identityGate = model?.book
        engine.onEvent = { [weak self] in self?.handle($0) }
        self.engine = engine
        let driver = ConnectionDriver(engine: engine, link: link)
        driver.onFinished = { [weak self] reason in self?.finish(reason) }
        self.driver = driver
        driver.start()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let engine = self.engine else { return }
            self.stats = "\(self.transport.label) · \(engine.videoPackets) video / \(engine.audioPackets) audio packets · \(self.remote.decoderName)"
        }
    }

    private func handle(_ event: StreamViewerEngine.Event) {
        switch event {
        case .sourceAuthenticated(let adjacent, let source, _): AppLog.event("watch_auth", ["adjacent": adjacent.shortLabel, "source": source.shortLabel])
        case .header(let h): AppLog.event("watch_header", ["codec": "\(h.codecId)", "size": "\(h.width)x\(h.height)", "fps": "\(h.fps)", "audio": "\(h.hasAudio)"])
        case .state(let s): AppLog.event("watch_state", ["state": "\(s)"])
        case .ended(let r, let e): AppLog.event("watch_end", ["reason": r, "error": "\(e)", "video": "\(engine?.videoPackets ?? 0)", "audio": "\(engine?.audioPackets ?? 0)", "decoded": "\(remote.decodedFrames)"])
        case .title: AppLog.event("watch_title", ["title": "set"])
        default: break
        }
        switch event {
        case .linkAuthenticated: break
        case .sourceAuthenticated(_, _, let fp):
            sourceFingerprint = fp; model?.noteAuthenticated(fp); state = "Waiting for video…"
        case .header(let h):
            remote.configure(header: h)
            if h.hasAudio {
                let audio = CallAudio(bitrate: 24_000, route: .speaker)
                audio.start(capture: false); self.audio = audio
            }
            state = ""
        case .audio(let p): audio?.receive(presentationTimeUs: p.presentationTimeUs, opus: p.payload)
        case .video(let p): remote.decode(p)
        case .rotation(let d): remote.sink.rotation = d
        case .state(let s):
            paused = s == .paused
            state = s == .paused ? "Paused by the broadcaster" : s == .ended ? "The broadcast ended" : ""
            if s == .live { remote.requestKeyFrame() }
        case .envelope: break
        case .title(let t): signedTitle = t
        case .routeWithdrawn: state = "This way to the stream is full. Try another one nearby."
        case .ended(let reason, _): finish(reason)
        }
    }

    func stop() { driver?.cancel(); finish("Stopped watching") }

    private func finish(_ reason: String) {
        guard ended == nil else { return }
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

    init(model: AppModel, identity: SigningIdentity, transport: MeshTransport, labels: Bool = false, title: String? = nil) {
        self.model = model; self.identity = identity; self.transport = transport; labelsEnabled = labels; self.title = title
        header = StreamHeader(width: MediaDefaults.width, height: MediaDefaults.height, fps: MediaDefaults.fps, codecId: StreamProtocol.codecVP9,
                              rotationDegrees: 0, includeAudio: true)
        routeToken = (try? StreamRouteToken.forAdvertiser(logical: logicalToken, prefix: identity.nodeId.prefix)) ?? 0
    }

    func offerAnnouncement(prefix: Data) -> DiscoveryAnnouncement {
        var flags = DiscoveryAnnouncement.flagStreamAvailable
        if transport == .gatt { flags |= DiscoveryAnnouncement.flagGattTransport }
        if paused { flags |= DiscoveryAnnouncement.flagStreamPaused }
        let full = sessions.count >= maxViewers ? DiscoveryAnnouncement.sequenceSourceFull : 0
        return DiscoveryAnnouncement(nodeIdPrefix: prefix, flags: flags, capabilitySummary: NodeCapabilities.codecVP9, streamToken: routeToken, routeCost: 0,
                                     sequence: (generation & 0x7f) | full, streamWidth: UInt16(header.width), streamHeight: UInt16(header.height),
                                     streamFps: UInt8(header.fps), streamBitrateKbps: UInt16(MediaDefaults.videoKbps))
    }

    func start() {
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
                                                expectedViewerPrefix: viewerPrefix, streamId: self.streamId, labels: self.labelsEnabled, title: self.title)
                engine.identityGate = model.book
                let driver = ConnectionDriver(engine: engine, link: link)
                engine.onEvent = { [weak self] event in
                    switch event {
                    case .viewerAuthenticated(let id, let fp):
                        model.noteAuthenticated(fp)
                        engine.sendAudioConfig()
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
