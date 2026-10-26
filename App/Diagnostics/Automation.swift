import Foundation
import NearbyCore
#if canImport(NearbyMedia)
import NearbyMedia
#endif

/// DEBUG-only remote control through launch arguments (like Android's `test_*` extras), for runs over SSH:
///
///     xcrun devicectl device process launch --device <udid> --terminate-existing io.github.meshlive.app \
///         -NearbyAutoCall first -NearbyCallType voice -NearbyCallSeconds 30
///
/// Arguments:
/// - `-NearbyAutoCall first|<handle>|<short handle>|<12-hex prefix>`: call that person once discovered (60 s wait).
///   `nearest` or `nearest-android` (no iPhones) calls the direct call offer with the strongest signal after 8 s of
///   scanning, so a phone advertising a rotating ID can be called without knowing its current ID.
/// - `-NearbyCallType voice|video` (default voice); `-NearbyCallSeconds N`: hang up N s after the call is active (default 20).
/// - `-NearbyAutoAccept voice|video`: answer incoming calls automatically (every call while the app runs);
///   `-NearbyAnswerSeconds N` hangs an answered call up after N s (default: the caller hangs up).
/// - `-NearbyAvailable 1|0`: be reachable for calls (default unchanged).
/// - `-NearbyRequestPermissions 1`: ask for microphone and camera at launch (one human tap each, first time only).
/// - `-NearbyRelay 1`: experimental "Help pass streams and calls to others nearby" on for this run.
/// - `-experimentalRelayedCalls YES`: relayed calls ring on this phone (target rule; otherwise declined before ringing).
///   Control arms: `-relayedStrangerCalls NO` (relayed calls from contacts only), `-relayedPseudonymousEdges NO` (relay
///   edges without declared throwaways, the pre-Amendment-CP behaviour).
/// - `-NearbyRelayCallee <handle|first>`: EXPERIMENTAL call relay hop for that callee (like Android's test_private_call_relay).
/// - `-NearbyAutoWatch first|<handle>` and `-NearbyWatchSeconds N`: watch a stream.
/// - `-NearbyAutoRadio <title>`: go live audio only (title signed only with `-NearbyLabels 1`), `-NearbyRadioPreset
///   voice|low|music`, `-NearbyRadioSeconds N` (default 120) then end; logs `auto_radio`.
/// - `-NearbyAutoListen first|<handle>|<12-hex prefix>` and `-NearbyListenSeconds N` (default 60): join an
///   audio-only (radio) stream only; logs `auto_listen` with the verified record count at the end.
/// - `-NearbyTransport gatt|l2cap`: transport to advertise; `-NearbyLabels 1`: experimental names and titles.
/// - `-NearbyAudioSelfTest N`: two back-to-back N-second runs of the call audio engine (microphone with voice
///   processing, packets looped back into playout, output volume 0 on a Mac); logs `auto_audio_selftest` with the
///   setup time and stats, so audio bring-up and teardown can be timed without a second device.
/// - `-NearbyVideoSelfTest N`: the viewer side of a live join without a source or camera: a generated moving picture
///   is VP9-encoded off the main thread and fed, packet by packet on the main thread as the link delivers them, to
///   the same `RemoteVideo` a viewer uses (decoder set-up, decode, display). Logs `auto_video_selftest` with the
///   decoder set-up time and decoded frames, so a join can be timed and profiled without a second device.
/// - `-NearbyCallCamera off`: switch this Mac's camera off as soon as a video call is active (receive-only
///   video tests that must not show the room); logs `auto_camera`.
/// Every step is logged as `BENCHMARK auto_*`.
final class Automation {
    let args: [String: String]
    private weak var model: AppModel?
    private var timer: Timer?
    private var started = Date()
    private var callStartedAt: Date?
    private var callActiveAt: Date?
    private var done = false
    private var watchStartedAt: Date?
    private var listenStartedAt: Date?
    private var acceptedCall: ObjectIdentifier?
    private var relayStarted = false
    private var answeredActiveAt: Date?
    private var cameraOffCall: ObjectIdentifier?
    private var selfTestAudio: CallAudio?
    private var selfTestVideo: RemoteVideo?

    static func parse(_ arguments: [String]) -> [String: String] {
        var out: [String: String] = [:]
        var i = 0
        while i < arguments.count {
            let a = arguments[i]
            if a.hasPrefix("-Nearby"), i + 1 < arguments.count { out[String(a.dropFirst(7))] = arguments[i + 1]; i += 2 } else { i += 1 }
        }
        return out
    }

    init?(model: AppModel, arguments: [String] = ProcessInfo.processInfo.arguments) {
        #if DEBUG
        let parsed = Automation.parse(arguments)
        guard !parsed.isEmpty else { return nil }
        args = parsed; self.model = model
        #else
        return nil
        #endif
    }

    /// Generated frames → VP9 (background) → `RemoteVideo` on the main thread, as a viewer receives them.
    private func videoSelfTest(seconds: Double) {
        let width = MediaDefaults.width, height = MediaDefaults.height, fps = MediaDefaults.fps
        let remote = RemoteVideo()
        selfTestVideo = remote
        let began = ProcessInfo.processInfo.systemUptime
        remote.configure(header: StreamHeader(width: width, height: height, fps: fps, codecId: StreamProtocol.codecVP9, includeAudio: false))
        AppLog.event("auto_video_selftest", ["event": "configured", "ms": AppLog.ms(since: began), "decoder": remote.decoderName])
        let queue = DispatchQueue(label: "io.github.meshlive.app.selftest.video", qos: .userInitiated)
        queue.async { [weak self] in
            guard let encoder = try? VP9Encoder(width: width, height: height, fps: fps, bitrateKbps: MediaDefaults.videoKbps) else {
                AppLog.event("auto_video_selftest", ["event": "failure", "message": "no VP9 encoder"]); return
            }
            var picture = I420Picture(width: width, height: height)
            let frames = Int(seconds * Double(fps))
            for index in 0..<frames {
                // A moving gradient: enough change per frame for real encoder and decoder work.
                for row in 0..<height { for col in 0..<width { picture.y[row * width + col] = UInt8(truncatingIfNeeded: col + row + index * 4) } }
                let pts = Int64(index) * 1_000_000 / Int64(fps)
                if let frame = try? encoder.encode(picture, presentationTimeUs: pts, forceKeyFrame: index == 0) {
                    let packet = MediaPacket(flags: frame.keyFrame ? StreamProtocol.flagKeyFrame : 0, presentationTimeUs: pts, payload: frame.data)
                    DispatchQueue.main.async { remote.decode(packet) }
                }
                Thread.sleep(forTimeInterval: 1 / Double(fps))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                AppLog.event("auto_video_selftest", ["event": "done", "sent": "\(frames)", "decoded": "\(remote.decodedFrames)",
                                                     "ms": AppLog.ms(since: began)])
                remote.stop(); self?.selfTestVideo = nil
            }
        }
    }

    /// One loopback run of `CallAudio`; the second run starts right after the first one's stop (teardown ordering).
    private func audioSelfTest(run: Int, seconds: Double) {
        let audio = CallAudio(bitrate: 24_000, route: .earpiece)
        let began = ProcessInfo.processInfo.systemUptime
        var first = true
        audio.onPacket = { [weak audio] pts, packet in
            if first { first = false; AppLog.event("auto_audio_selftest", ["run": "\(run)", "event": "first_packet", "ms": AppLog.ms(since: began)]) }
            audio?.receive(presentationTimeUs: pts, opus: packet)
        }
        audio.onFailure = { message in AppLog.event("auto_audio_selftest", ["run": "\(run)", "event": "failure", "message": message]) }
        selfTestAudio = audio
        audio.start(capture: true)
        AppLog.event("auto_audio_selftest", ["run": "\(run)", "event": "start_returned", "ms": AppLog.ms(since: began)])
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            var fields = audio.logFields; fields["run"] = "\(run)"; fields["event"] = "stats"
            AppLog.event("auto_audio_selftest", fields)
            let stopping = ProcessInfo.processInfo.systemUptime
            audio.stop()
            AppLog.event("auto_audio_selftest", ["run": "\(run)", "event": "stop_returned", "ms": AppLog.ms(since: stopping)])
            self?.selfTestAudio = nil
            if run < 2 { self?.audioSelfTest(run: run + 1, seconds: seconds) }
        }
    }

    func start() {
        AppLog.event("auto_start", args)
        if let t = args["Transport"], let transport = MeshTransport(rawValue: t) { model?.transport = transport }
        if let available = args["Available"] { model?.availableForCalls = available == "1" }
        if let rot = args["RotatingIds"] { model?.rotatingIds = rot == "1" }
        if let fec = args["CallAudioFec"] { AppSettings.callAudioFec = fec == "1" }
        if let ladder = args["ResolutionLadder"] { AppSettings.resolutionLadder = ladder == "1" }
        if args["RequestPermissions"] == "1" { MediaPermissions.request(video: true, context: "launch") { _, _ in } }
        if args["Relay"] == "1" { model?.relayForOthers = true }
        // `-NearbySelfTestDelay N` starts the self-tests N s later (time for a profiler to attach).
        let delay = args["SelfTestDelay"].flatMap(Double.init) ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if let seconds = self.args["AudioSelfTest"].flatMap(Double.init), seconds > 0 { self.audioSelfTest(run: 1, seconds: seconds) }
            if let seconds = self.args["VideoSelfTest"].flatMap(Double.init), seconds > 0 { self.videoSelfTest(seconds: seconds) }
        }
        if let title = args["AutoRadio"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let model = self.model else { return }
                if let labels = self.args["Labels"] { model.peerLabelsEnabled = labels == "1" }
                model.liveTitle = title == "-" ? "" : title
                let preset: UInt8 = self.args["RadioPreset"] == "low" ? AudioLive.presetLowData : self.args["RadioPreset"] == "music" ? AudioLive.presetMusic : AudioLive.presetVoice
                AppLog.event("auto_radio", ["title": title, "preset": "\(preset)"])
                model.goLive(audioOnly: true, preset: preset)
                let seconds = Double(self.args["RadioSeconds"] ?? "120") ?? 120
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    AppLog.event("auto_radio", ["result": "stop", "stats": model.live?.stats ?? "-"])
                    model.live?.stop(); AppLog.flush()
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// The person `-NearbyAutoCall` names, or nil while they are not found (yet).
    private func pick(_ target: String, model: AppModel) -> PersonRow? {
        if target == "nearest" || target == "nearest-android" {
            guard Date().timeIntervalSince(started) >= 8 else { return nil }
            let candidates = model.people.filter { $0.relays == 0 && (target == "nearest" || !$0.isIPhone) }
            return candidates.max { (model.radio.peers[$0.id]?.rssi ?? -127) < (model.radio.peers[$1.id]?.rssi ?? -127) }
        }
        return model.people.first { matches(target, prefixHex: $0.prefixHex) }
    }

    private func matches(_ target: String, prefixHex: String) -> Bool {
        if target == "first" { return true }
        if target.lowercased() == prefixHex.lowercased() { return true }
        guard let prefix = Data(hex: prefixHex), let handle = IdentityHandle.handle(prefix: prefix) else { return false }
        if let parsed = IdentityHandle.parse(target) { return parsed == prefix }
        if let short = IdentityHandle.parseShort(target) { return handle.hasPrefix(short) }
        return false
    }

    private func tick() {
        guard let model else { return }
        if args["CallCamera"] == "off", let call = model.call, call.phase == .active, call.cameraOn,
           cameraOffCall != ObjectIdentifier(call) {
            cameraOffCall = ObjectIdentifier(call)
            call.toggleCamera()
            AppLog.event("auto_camera", ["result": "off", "cameraOn": "\(call.cameraOn)"])
        }
        if let accept = args["AutoAccept"] {
            if let call = model.call, call.phase == .incomingRinging, acceptedCall != ObjectIdentifier(call) {
                acceptedCall = ObjectIdentifier(call); answeredActiveAt = nil
                AppLog.event("auto_accept", ["type": accept, "peer": call.peerPrefixHex ?? "?"])
                call.accept(as: accept == "video" ? .video : .voice)
            }
            if let call = model.call, acceptedCall == ObjectIdentifier(call), call.phase == .active {
                if answeredActiveAt == nil { answeredActiveAt = Date(); AppLog.event("auto_accept", ["result": "active"]) }
                if let limit = args["AnswerSeconds"].flatMap(Double.init), let since = answeredActiveAt, Date().timeIntervalSince(since) >= limit {
                    AppLog.event("auto_accept", ["result": "hang_up", "heldSeconds": String(format: "%.0f", Date().timeIntervalSince(since))])
                    call.logStats(); call.end()
                }
            }
        }
        guard !done else { return }
        let seconds = Double(args["CallSeconds"] ?? "20") ?? 20
        if let target = args["AutoCall"] {
            if callStartedAt == nil {
                if let person = pick(target, model: model) {
                    let type: CallType = args["CallType"] == "video" ? .video : .voice
                    AppLog.event("auto_call", ["target": target, "prefix": person.prefixHex, "handle": person.label.handle, "type": type.rawValue,
                                               "transport": person.transport.rawValue, "rssi": "\(model.radio.peers[person.id]?.rssi ?? 0)"])
                    model.startCall(to: person, type: type)
                    callStartedAt = Date()
                } else if Date().timeIntervalSince(started) > 60 {
                    AppLog.event("auto_call", ["target": target, "result": "not_found", "people": "\(model.people.count)"]); finish()
                }
            } else if let call = model.call {
                if call.phase == .active && callActiveAt == nil { callActiveAt = Date(); AppLog.event("auto_call", ["result": "active"]) }
                if let active = callActiveAt, Date().timeIntervalSince(active) >= seconds {
                    AppLog.event("auto_call", ["result": "hang_up", "heldSeconds": String(format: "%.0f", Date().timeIntervalSince(active))])
                    call.logStats(); call.end(); finish()
                } else if callActiveAt == nil, Date().timeIntervalSince(callStartedAt!) > 90 {
                    AppLog.event("auto_call", ["result": "never_active", "phase": "\(String(describing: call.phase))"]); call.end(); finish()
                }
            } else if Date().timeIntervalSince(callStartedAt!) < 10 && callActiveAt == nil && model.callNotice == nil {
                // Permission request or connect still starting.
            } else {
                AppLog.event("auto_call", ["result": callActiveAt == nil ? "failed" : "call_gone", "notice": model.callNotice ?? "none"]); finish()
            }
        }
        if let target = args["RelayCallee"], !relayStarted {
            if let person = model.people.first(where: { matches(target, prefixHex: $0.prefixHex) }) {
                relayStarted = true
                model.relayForOthers = true
                AppLog.event("auto_relay", ["callee": person.prefixHex, "handle": person.label.handle])
                model.startCallRelay(to: person)
            }
        }
        if let target = args["AutoListen"] {
            if listenStartedAt == nil {
                if let row = model.streams.first(where: { $0.audioOnly && matches(target, prefixHex: $0.announcement.prefixHex) }) {
                    AppLog.event("auto_listen", ["target": target, "prefix": row.announcement.prefixHex, "token": String(format: "%08x", row.announcement.streamToken)])
                    model.startWatching(row); listenStartedAt = Date()
                } else if Date().timeIntervalSince(started) > 60 {
                    AppLog.event("auto_listen", ["target": target, "result": "not_found", "streams": "\(model.streams.count)",
                                                 "radio": "\(model.streams.filter(\.audioOnly).count)"]); finish()
                }
            } else if let s = listenStartedAt, Date().timeIntervalSince(s) >= (Double(args["ListenSeconds"] ?? "60") ?? 60) || model.watch == nil {
                AppLog.event("auto_listen", ["result": model.watch == nil ? "ended" : "stop", "stats": model.watch?.stats ?? "-"])
                model.watch?.stop(); finish()
            }
        }
        if let target = args["AutoWatch"] {
            if watchStartedAt == nil, let row = model.streams.first(where: { matches(target, prefixHex: $0.announcement.prefixHex) }) {
                AppLog.event("auto_watch", ["target": target, "prefix": row.announcement.prefixHex]); model.startWatching(row); watchStartedAt = Date()
            } else if let s = watchStartedAt, Date().timeIntervalSince(s) >= (Double(args["WatchSeconds"] ?? "30") ?? 30) {
                AppLog.event("auto_watch", ["result": "stop"]); model.watch?.stop(); finish()
            }
        }
    }

    /// Stops the call/watch scenario; auto-accept keeps running while the app runs.
    private func finish() { done = true; if args["AutoAccept"] == nil { timer?.invalidate() }; AppLog.flush() }
}


#if DEBUG
extension AppModel {
    /// UI-only broadcast fixture: no microphone, camera, stream engine or media capture is started.
    func showDebugBroadcast() {
        guard let identity else { return }
        let preview = LiveController(model: self, identity: identity, transport: .gatt,
                                     title: "Priya's neighbourhood radio", audioOnly: true)
        preview.running = true
        live = preview
    }
}
#endif
