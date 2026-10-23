import Foundation
import AVFoundation
import NearbyCore

/// Two-way Opus audio for calls and streams: mono 48 kHz, 20 ms raw Opus packets with BTV3
/// microsecond timestamps (sample clock), like Android's MediaCodec Opus path.
/// Capture: input tap -> channel 0 -> AVAudioConverter to 48 kHz -> 960-sample frames -> libopus.
/// Playout: AudioPlayout slots -> libopus decode / PLC -> AVAudioPlayerNode, self-clocked by buffer completions.
///
/// Playback never depends on capture: if the microphone is denied or its setup fails, the call still plays
/// the peer's audio (playback-only), and the reason is reported. Every step is logged (`BENCHMARK audio_*`).
///
/// Bring-up (measured on an iPhone 14 Plus, iOS 26.5): enabling voice processing switches the session's I/O
/// unit, which posts a category route change and an AVAudioEngineConfigurationChange about 100 ms after
/// start; the engine is then stopped, and for a few hundred ms the input node reports a 0 Hz format. The old
/// code restarted at once, saw 0 Hz, and fell back to playback-only for the whole call (iPhone -> Android
/// silent). Now restarts are debounced, an invalid input format is retried, voice processing is dropped only
/// after repeated failures, and a playback-only fallback keeps retrying the microphone.
final class CallAudio {
    enum Route { case speaker, earpiece }
    struct Counters {
        var tapBuffers = 0, capturedFrames = 0, encodedPackets = 0, encodeErrors = 0, mutedFrames = 0
        var receivedPackets = 0, decodedPackets = 0, decodeErrors = 0, concealedFrames = 0, silentFrames = 0, scheduledBuffers = 0, fecRecovered = 0
    }
    private let queue = DispatchQueue(label: "org.nearbyintercom.audio", qos: .userInteractive)
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var resampler: PCMResampler?
    private var encoder: UnsafeMutableRawPointer?
    private var decoder: UnsafeMutableRawPointer?
    private var framer = AudioCaptureFramer()
    /// Shared media clock origin (uptime) for audio and video BTV3 timestamps.
    var clockStart = ProcessInfo.processInfo.systemUptime
    private var playout = AudioPlayout()
    private var scheduled = 0
    private var running = false
    private var counters = Counters()
    private let format48 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    var captureEnabled = true
    /// Encoded 20 ms packet with its presentation time (microseconds since this audio started).
    var onPacket: ((Int64, Data) -> Void)?
    var onFailure: ((String) -> Void)?
    /// Another app or the system took the audio (a phone call, Siri, an alarm): true when it began, false when it ended.
    var onInterruption: ((Bool) -> Void)?
    private(set) var startedAtUptime: TimeInterval = 0
    private(set) var capturing = false
    private(set) var voiceProcessing = false
    let bitrate: Int
    private(set) var route: Route
    private var observers: [NSObjectProtocol] = []
    private var wantCapture = false
    private var stopped = false
    private var restartPending = false
    private var bringUpGeneration = 0
    private var captureRetries = 0
    private var configurationRestarts: [TimeInterval] = []
    private var tapInstalled = false
    /// Playback chain generation: buffer completions from a stopped engine never continue a new chain.
    private var playGeneration = 0

    /// Experimental call FEC (Settings > Advanced, off; Android test_call_native_opus): in-band FEC, 10 % loss hint.
    let fec: Bool
    static let fecLossPercent = 10

    /// EXPERIMENTAL CallKit: the system activates and deactivates the audio session of a call answered on the native
    /// call screen; bring-up waits for `systemSessionActivated()` (CallKit's provider(_:didActivate:)).
    private let systemSession: Bool
    private var systemSessionActive: Bool
    private var setUpDone = false

    init(bitrate: Int = 24_000, route: Route, fec: Bool = false, systemSession: Bool = false, systemSessionActive: Bool = false) {
        self.bitrate = bitrate; self.route = route; self.fec = fec
        self.systemSession = systemSession; self.systemSessionActive = systemSessionActive
        playout.fecRecovery = fec
    }

    static var opusAvailable: Bool { nearby_opus_available() == 1 }

    /// Starts playback, and capture when the microphone is allowed (permission is requested if undecided).
    func start(capture: Bool) {
        guard capture else { setUp(capture: false); return }
        MediaPermissions.requestMicrophone { granted in
            guard !self.stopped else { return }
            if !granted { self.onFailure?("Microphone is off for MeshLive. Turn it on in Settings to talk; you can still hear them.") }
            self.setUp(capture: granted)
        }
    }

    private func setUp(capture: Bool) {
        wantCapture = capture
        AppLog.event("audio_setup", ["capture": "\(capture)", "microphone": MediaPermissions.microphone, "opus": "\(CallAudio.opusAvailable)",
                                     "route": route == .speaker ? "speaker" : "earpiece"])
        installObservers()
        setUpDone = true
        guard !systemSession || systemSessionActive else { AppLog.event("audio_setup", ["waiting": "callkit_session"]); return }
        bringUp(reason: "start", attempt: 0)
    }

    func systemSessionActivated() {
        guard systemSession, !systemSessionActive else { return }
        systemSessionActive = true
        if setUpDone { bringUp(reason: "callkit_session", attempt: 0) }
    }

    /// (Re)starts the engine. With capture wanted it tries up to 8 times, 250 ms apart (voice processing for the
    /// first 4), then runs playback-only and retries the microphone after 3 s, up to 5 times.
    private func bringUp(reason: String, attempt: Int) {
        guard !stopped else { return }
        bringUpGeneration += 1
        let generation = bringUpGeneration
        tearDownEngine()
        do { try configureSession() } catch {
            AppLog.event("audio_error", ["stage": "session", "reason": reason, "error": describe(error)])
            onFailure?("Audio could not start: \(describe(error))"); return
        }
        if wantCapture {
            let vp = attempt < 4
            do {
                try startEngine(capture: true, voiceProcessing: vp)
                AppLog.event("audio_capture_started", ["reason": reason, "attempt": "\(attempt)", "voiceProcessing": "\(vp)"])
                captureRetries = 0
                logSession(reason)
                return
            } catch {
                AppLog.event("audio_error", ["stage": "capture", "reason": reason, "attempt": "\(attempt)", "voiceProcessing": "\(vp)", "error": describe(error)])
                tearDownEngine()
            }
            if attempt < 7 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self, generation == self.bringUpGeneration else { return }
                    self.bringUp(reason: reason, attempt: attempt + 1)
                }
                return
            }
        }
        do {
            try startEngine(capture: false, voiceProcessing: false)
            logSession(reason + (wantCapture ? " (playback only)" : ""))
        } catch {
            AppLog.event("audio_error", ["stage": "playback", "reason": reason, "error": describe(error)])
            onFailure?("Audio could not start: \(describe(error))"); return
        }
        if wantCapture {
            onFailure?("Microphone could not start yet; retrying. You can still hear them.")
            guard captureRetries < 5 else { onFailure?("Microphone could not start. You can still hear them."); return }
            captureRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, generation == self.bringUpGeneration, !self.capturing else { return }
                self.bringUp(reason: "microphone retry \(self.captureRetries)", attempt: 0)
            }
        }
    }

    private func describe(_ error: Error?) -> String {
        guard let error else { return "unknown" }
        let ns = error as NSError
        return ns.domain == NSOSStatusErrorDomain || ns.domain.hasPrefix("com.apple") ? "\(ns.domain) \(ns.code)" : "\(error)"
    }

    private func configureSession() throws {
        guard CallAudio.opusAvailable else { throw RadioError.unavailable("Opus is not linked (run Scripts/prepare-opus.sh)") }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: route == .speaker ? .videoChat : .voiceChat,
                                options: [.allowBluetoothHFP, .allowBluetoothA2DP])
        try? session.setPreferredSampleRate(48_000)
        try? session.setPreferredIOBufferDuration(0.01)
        if !systemSession { try session.setActive(true) }
        try? session.overrideOutputAudioPort(route == .speaker ? .speaker : .none)
        if encoder == nil || decoder == nil {
            var error: Int32 = 0
            encoder = nearby_opus_encoder(48_000, Int32(bitrate), &error)
            decoder = nearby_opus_decoder(48_000, &error)
            guard encoder != nil, decoder != nil else { throw RadioError.setup("Opus codec setup failed (\(error))") }
            if fec {
                let result = nearby_opus_encoder_set_fec(encoder, 1, Int32(CallAudio.fecLossPercent))
                AppLog.event("audio_fec", ["enabled": "\(result == 0)", "lossPercent": "\(CallAudio.fecLossPercent)"])
            }
        }
    }

    private func startEngine(capture: Bool, voiceProcessing: Bool) throws {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        self.engine = engine; self.player = player
        if capture && voiceProcessing { try engine.inputNode.setVoiceProcessingEnabled(true) }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format48)
        if capture { try installTap(on: engine, voiceProcessing: voiceProcessing) }
        engine.prepare()
        try engine.start()
        guard engine.isRunning else { throw RadioError.setup("Audio engine did not start") }
        capturing = capture; self.voiceProcessing = capture && voiceProcessing
        startPlayback(player)
        startedAtUptime = ProcessInfo.processInfo.systemUptime
    }

    /// Reads the input format (it must be valid: 0 Hz means the session is still switching) and installs the tap.
    private func installTap(on engine: AVAudioEngine, voiceProcessing: Bool) throws {
        let input = engine.inputNode.outputFormat(forBus: 0)
        AppLog.event("audio_input", ["rate": "\(input.sampleRate)", "channels": "\(input.channelCount)", "voiceProcessing": "\(voiceProcessing)",
                                      "available": "\(AVAudioSession.sharedInstance().isInputAvailable)"])
        guard input.sampleRate > 0, input.channelCount > 0 else { throw RadioError.setup("Microphone format not ready (\(input.sampleRate) Hz)") }
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate, channels: 1, interleaved: false)!
        let newResampler = try PCMResampler(input: mono, output: format48)
        queue.sync { resampler = newResampler }
        engine.inputNode.installTap(onBus: 0, bufferSize: 960, format: input) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard let copy = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(count)) else { return }
            copy.frameLength = AVAudioFrameCount(count)
            copy.floatChannelData![0].update(from: channel, count: count)
            self.queue.async { self.encode(copy) }
        }
        tapInstalled = true
    }

    private func startPlayback(_ player: AVAudioPlayerNode) {
        player.play()
        let generation: Int = queue.sync { running = true; playGeneration += 1; scheduled = 0; return playGeneration }
        queue.async { for _ in 0..<3 { self.scheduleNext(generation) } }
    }

    /// After a configuration change the same engine is reused when possible: tap re-installed with the
    /// current input format, player reconnected, engine restarted.
    private func resumeSameEngine() -> Bool {
        guard let engine, let player else { return false }
        queue.sync { running = false }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        player.stop()
        do {
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: format48)
            if wantCapture { try installTap(on: engine, voiceProcessing: voiceProcessing) }
            engine.prepare()
            try engine.start()
            guard engine.isRunning else { throw RadioError.setup("Audio engine did not restart") }
            capturing = wantCapture
            startPlayback(player)
            AppLog.event("audio_resumed", ["capture": "\(capturing)", "voiceProcessing": "\(voiceProcessing)"])
            logSession("resumed")
            return true
        } catch {
            AppLog.event("audio_error", ["stage": "resume", "error": describe(error)])
            return false
        }
    }

    private func tearDownEngine() {
        queue.sync { running = false; playGeneration += 1 }
        if let engine, tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        player?.stop(); engine?.stop()
        engine = nil; player = nil; capturing = false; voiceProcessing = false
        queue.sync { scheduled = 0 }
    }

    private func logSession(_ event: String) {
        let s = AVAudioSession.sharedInstance()
        let outputs = s.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: "+")
        let inputs = s.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: "+")
        AppLog.event("audio_session", ["event": event, "category": s.category.rawValue, "mode": s.mode.rawValue, "rate": "\(s.sampleRate)",
                                        "ioBufferMs": String(format: "%.1f", s.ioBufferDuration * 1000), "outputs": outputs.isEmpty ? "none" : outputs,
                                        "inputs": inputs.isEmpty ? "none" : inputs, "capture": "\(capturing)", "voiceProcessing": "\(voiceProcessing)",
                                        "engineRunning": "\(engine?.isRunning ?? false)", "outputVolume": String(format: "%.2f", s.outputVolume)])
    }

    /// Interruptions (a phone call, Siri), route changes and media-server resets restart the engine.
    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init) ?? .began
            AppLog.event("audio_interruption", ["type": type == .began ? "began" : "ended"])
            self.onInterruption?(type == .began)
            if type == .ended { self.restart("interruption ended") }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            AppLog.event("audio_route_change", ["reason": "\(reason)"]); self?.logSession("route_change")
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            AppLog.event("audio_media_services_reset"); self?.restart("media services reset")
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            guard let self, let engine = note.object as? AVAudioEngine, engine === self.engine else { return }
            AppLog.event("audio_engine_configuration_change", ["running": "\(engine.isRunning)", "capture": "\(self.capturing)"])
            self.restart("engine configuration change")
        })
    }

    /// Debounced (300 ms, coalesced) so a burst of route/configuration changes restarts once, after the
    /// session settles; at most 6 configuration restarts per 20 s to avoid a restart loop.
    private func restart(_ why: String) {
        guard !stopped, !restartPending else { return }
        let now = ProcessInfo.processInfo.systemUptime
        configurationRestarts = configurationRestarts.filter { now - $0 < 20 } + [now]
        guard configurationRestarts.count <= 6 else {
            AppLog.event("audio_error", ["stage": "restart_loop", "why": why]); return
        }
        restartPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.stopped else { return }
            self.restartPending = false
            AppLog.event("audio_restart", ["why": why])
            if why == "engine configuration change", self.resumeSameEngine() { return }
            self.bringUp(reason: why, attempt: 0)
        }
    }

    private func encode(_ buffer: AVAudioPCMBuffer) {
        guard running, let resampler, let encoder else { return }
        counters.tapBuffers += 1
        if counters.tapBuffers == 1 { AppLog.event("audio_capture_first_buffer", ["frames": "\(buffer.frameLength)", "rate": "\(buffer.format.sampleRate)"]) }
        guard let samples = try? resampler.convert(buffer) else { counters.encodeErrors += 1; return }
        var out = [UInt8](repeating: 0, count: 1500)
        let clock = clockStart
        for (pts, frame) in framer.append(samples, captureTimeUs: { Int64((ProcessInfo.processInfo.systemUptime - clock) * 1_000_000) }) {
            counters.capturedFrames += 1
            guard captureEnabled else { counters.mutedFrames += 1; continue }
            let n = frame.withUnsafeBufferPointer { f in out.withUnsafeMutableBufferPointer { o in nearby_opus_encode(encoder, f.baseAddress, 960, o.baseAddress, Int32(o.count)) } }
            guard n > 0 else { counters.encodeErrors += 1; continue }
            counters.encodedPackets += 1
            let packet = Data(out[0..<Int(n)])
            DispatchQueue.main.async { self.onPacket?(pts, packet) }
        }
    }

    /// Remote Opus packet (already split from BTA1/BTA2 batches).
    func receive(presentationTimeUs: Int64, opus: Data) {
        queue.async { self.counters.receivedPackets += 1; self.playout.push(presentationTimeUs: presentationTimeUs, payload: opus) }
    }

    private func scheduleNext(_ generation: Int) {
        guard running, generation == playGeneration, let player, let decoder,
              let buffer = AVAudioPCMBuffer(pcmFormat: format48, frameCapacity: 960) else { return }
        buffer.frameLength = 960
        let out = buffer.floatChannelData![0]
        switch playout.pop() {
        case .packet(let data):
            let n = data.withUnsafeBytes { nearby_opus_decode(decoder, $0.bindMemory(to: UInt8.self).baseAddress, Int32(data.count), out, 960) }
            if n == 960 { counters.decodedPackets += 1 } else { counters.decodeErrors += 1; out.initialize(repeating: 0, count: 960) }
        case .conceal:
            counters.concealedFrames += 1
            if nearby_opus_decode(decoder, nil, 0, out, 960) != 960 { out.initialize(repeating: 0, count: 960) }
        case .silence:
            counters.silentFrames += 1
            out.initialize(repeating: 0, count: 960)
        case .recover(let following):
            counters.fecRecovered += 1
            let n = following.withUnsafeBytes { nearby_opus_decode_fec(decoder, $0.bindMemory(to: UInt8.self).baseAddress, Int32(following.count), out, 960) }
            if n != 960 { out.initialize(repeating: 0, count: 960) }
        }
        scheduled += 1; counters.scheduledBuffers += 1
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.queue.async { self.scheduled -= 1; self.scheduleNext(generation) }
        }
    }

    var stats: String {
        queue.sync { "jitter \(playout.bufferedMilliseconds) ms · underruns \(playout.underruns) · concealed \(playout.concealed)" }
    }

    /// Log fields: captured/encoded and received/decoded/played counts plus engine state.
    var logFields: [String: String] {
        let (c, played, underruns, late, jitter) = queue.sync { (counters, playout.played, playout.underruns, playout.late, playout.bufferedMilliseconds) }
        return ["audioTapBuffers": "\(c.tapBuffers)", "audioCaptured": "\(c.capturedFrames)", "audioEncoded": "\(c.encodedPackets)",
                "audioEncodeErrors": "\(c.encodeErrors)", "audioMutedFrames": "\(c.mutedFrames)",
                "audioReceived": "\(c.receivedPackets)", "audioDecoded": "\(c.decodedPackets)", "audioDecodeErrors": "\(c.decodeErrors)",
                "audioPlayed": "\(played)", "audioConcealed": "\(c.concealedFrames)", "audioSilent": "\(c.silentFrames)",
                "audioUnderruns": "\(underruns)", "audioLate": "\(late)", "audioJitterMs": "\(jitter)", "audioFecRecovered": "\(c.fecRecovered)",
                "audioEngine": engine?.isRunning == true ? "running" : "stopped", "audioCapture": "\(capturing)", "audioVP": "\(voiceProcessing)"]
    }

    func setRoute(_ route: Route) {
        self.route = route
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(route == .speaker ? .speaker : .none)
        logSession("route_set")
    }

    func stop() {
        stopped = true
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        tearDownEngine()
        queue.sync {
            if let encoder { nearby_opus_encoder_destroy(encoder) }
            if let decoder { nearby_opus_decoder_destroy(decoder) }
            encoder = nil; decoder = nil; framer.reset(); playout.reset()
        }
        if !systemSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
}
