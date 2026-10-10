import Foundation
import AVFoundation
import NearbyCore

struct AudioMetrics: Codable {
    var requestedRate: Double = 0
    var sessionRate: Double = 0
    var captureRate: Double = 0
    var captureChannels: UInt32 = 0
    var ioDuration: Double = 0
    var route = "Not active"
    var conversion = "Not active"
    var voiceProcessing = false
    var jitterMilliseconds = 0
    var underruns = 0
    var overflows = 0
    var captureDroppedSamples: UInt64 = 0
    var encodedPackets = 0
    var receivedPackets = 0
}

private final class AudioRing {
    let pointer: OpaquePointer
    init() throws { guard let p = nearby_ring_create(32_768) else { throw ProtocolError.limit("Capture ring allocation failed") }; pointer = p }
    deinit { nearby_ring_destroy(pointer) }
}

/// Hardware setup occurs on main; conversion, encoding and jitter scheduling use a serial media queue.
/// The input tap only copies channel 0 into a preallocated SPSC C ring.
final class VoiceEngine {
    private let queue = DispatchQueue(label: "org.nearbyintercom.voice", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var worker: AudioWorker?
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var attempt = UUID()
    private var pendingPermission = false
    private var enabled = false
    private let receiveMailbox = BoundedMailbox<AudioPacket>(capacity: 16)
    private var speaker = true
    var onPacket: ((AudioPacket) -> Void)?
    var onStatus: ((String, Bool) -> Void)?
    var onMetrics: ((AudioMetrics) -> Void)?
    var onFailure: ((String) -> Void)?
    var onProtocolFailure: ((String) -> Void)?
    private var applicationActive = true
    private var pendingConfiguration: MediaProfile?

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            if let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               AVAudioSession.InterruptionType(rawValue: raw) == .began {
                self.stop(); self.onFailure?("Audio interrupted; enable audio again to resume")
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.enabled, let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange:
                self.stop(); self.onFailure?("Audio route changed; enable audio again for the new format")
            default: break
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop(); self?.onFailure?("Audio services reset; enable audio again")
        })
    }
    func enable(profile: MediaProfile, speaker: Bool) {
        guard !enabled, !pendingPermission else { return }
        pendingPermission = true; self.speaker = speaker
        let token = attempt
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.attempt == token else { return }; self.pendingPermission = false
                guard granted else { self.onFailure?("Microphone permission denied. Enable it in Settings."); return }
                guard self.applicationActive else { self.pendingConfiguration = profile; return }
                do { try self.configure(profile) } catch { self.stop(); self.onFailure?("Audio setup failed: \(error)") }
            }
        }
    }
    private func configure(_ profile: MediaProfile) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try session.setPreferredSampleRate(48_000); try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        try session.overrideOutputAudioPort(speaker ? .speaker : .none)
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        self.engine = engine; self.player = player
        try engine.inputNode.setVoiceProcessingEnabled(true)
        let actual = engine.inputNode.outputFormat(forBus: 0)
        guard actual.sampleRate > 0, actual.channelCount > 0, actual.commonFormat == .pcmFormatFloat32, !actual.isInterleaved else {
            throw ProtocolError.incompatible("Capture format is not planar Float32; inspect the route")
        }
        let monoInput = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: actual.sampleRate, channels: 1, interleaved: false)!
        let negotiated = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(profile.sampleRate), channels: 1, interleaved: false)!
        let ring = try AudioRing()
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: negotiated)
        let token = attempt
        var metrics = AudioMetrics()
        metrics.requestedRate = 48_000; metrics.sessionRate = session.sampleRate; metrics.captureRate = actual.sampleRate
        metrics.captureChannels = actual.channelCount; metrics.ioDuration = session.ioBufferDuration
        metrics.route = session.currentRoute.outputs.map { $0.portName + " (" + $0.portType.rawValue + ")" }.joined(separator: ", ")
        metrics.conversion = "Channel 0: \(Int(actual.sampleRate)) Hz Float32 → \(profile.sampleRate) Hz mono, AVAudioConverter"
        metrics.voiceProcessing = engine.inputNode.isVoiceProcessingEnabled
        let worker = try AudioWorker(profile: profile, input: monoInput, output: negotiated, ring: ring, player: player, metrics: metrics)
        let packetMailbox = BoundedMailbox<AudioPacket>(capacity: 16)
        let metricsMailbox = BoundedMailbox<AudioMetrics>(capacity: 1)
        worker.onPacket = { [weak self] packet in
            guard let schedule = packetMailbox.offer(packet) else { throw ProtocolError.limit("Audio handoff queue full") }
            if schedule {
                DispatchQueue.main.async {
                    let packets = packetMailbox.takeAll()
                    guard let self, self.attempt == token else { return }
                    for packet in packets { self.onPacket?(packet) }
                }
            }
        }
        worker.onFailure = { [weak self] reason in DispatchQueue.main.async { guard let self, self.attempt == token else { return }; self.stop(); self.onFailure?(reason) } }
        worker.onProtocolFailure = { [weak self] reason in DispatchQueue.main.async { guard let self, self.attempt == token else { return }; self.stop(); self.onProtocolFailure?(reason) } }
        worker.onMetrics = { [weak self] metrics in
            guard let notify = metricsMailbox.offerLatest(metrics), notify else { return }
            DispatchQueue.main.async {
                let values = metricsMailbox.takeAll()
                guard let self, self.attempt == token, let metrics = values.last else { return }; self.onMetrics?(metrics)
            }
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: actual) { [ring] buffer, _ in
            guard let source = buffer.floatChannelData?[0] else { return }
            _ = nearby_ring_write(ring.pointer, source, buffer.frameLength)
        }
        engine.prepare(); try engine.start(); player.play()
        enabled = true
        queue.async { [weak self] in self?.worker = worker }
        let timer = DispatchSource.makeTimerSource(queue: queue); self.timer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.worker?.tick() }; timer.resume()
        onMetrics?(metrics); onStatus?("Microphone active locally. Hold to transmit.", true)
    }
    func talk(_ pressed: Bool) {
        guard enabled else { return }
        queue.async { [weak self] in self?.worker?.talk(pressed) }
        onStatus?(pressed ? "Microphone active — transmitting" : "Microphone active locally. Hold to transmit.", true)
    }
    func mute() {
        // Releasing hardware is an unambiguous mute; a fresh Enable restores audio.
        stop(); onStatus?("Microphone off; audio muted", false)
    }
    func setApplicationActive(_ active: Bool) {
        applicationActive = active
        if active, let profile = pendingConfiguration {
            pendingConfiguration = nil
            do { try configure(profile) } catch { stop(); onFailure?("Audio setup failed: \(error)") }
        }
    }
    func finishTalking(completion: @escaping () -> Void) {
        queue.async { [weak self] in self?.worker?.talk(false); DispatchQueue.main.async(execute: completion) }
    }
    func setSpeaker(_ speaker: Bool) {
        self.speaker = speaker
        guard enabled else { return }
        do { try AVAudioSession.sharedInstance().overrideOutputAudioPort(speaker ? .speaker : .none) }
        catch { onFailure?("Route override failed: \(error)") }
    }
    func receive(_ packet: AudioPacket) {
        guard enabled else { return }
        guard let schedule = receiveMailbox.offer(packet) else { stop(); onFailure?("Audio receive handoff overflow"); return }
        if schedule {
            queue.async { [weak self] in
                guard let self else { return }
                for packet in self.receiveMailbox.takeAll() { self.worker?.receive(packet) }
            }
        }
    }
    func cancelReceive(_ stream: UInt32) { queue.async { [weak self] in self?.worker?.cancelReceive(stream) } }
    func stop() {
        attempt = UUID(); pendingPermission = false; pendingConfiguration = nil; enabled = false
        timer?.setEventHandler {}; timer?.cancel(); timer = nil
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); player?.stop()
        engine = nil; player = nil
        queue.async { [weak self] in self?.worker?.cancel(); self?.worker = nil }
        _ = receiveMailbox.takeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onStatus?("Microphone off", false)
    }
    deinit { timer?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }
}

private final class AudioWorker {
    let profile: MediaProfile
    let ring: AudioRing
    let player: AVAudioPlayerNode
    let input: AVAudioPCMBuffer
    let output: AVAudioPCMBuffer
    let converter: PCMResampler
    private var jitter: JitterBuffer
    private var encoder: UnsafeMutableRawPointer?
    private var decoder: UnsafeMutableRawPointer?
    private var samples: [Float] = []
    private var stream: UInt32 = 0
    private var timestamp: UInt64 = 0
    private var transmitting = false
    private var first = true
    private var metrics: AudioMetrics
    private var ticks = 0
    private var scheduled = 0
    private let completionLock = NSLock()
    private var completed = 0
    private var completionGeneration = 0
    private var cancelled = false
    private var awaitingReceiveStart = true
    private var receivingStream: UInt32 = 0
    private var encoded = [UInt8](repeating: 0, count: 1275)
    var onPacket: ((AudioPacket) throws -> Void)?
    var onFailure: ((String) -> Void)?
    var onProtocolFailure: ((String) -> Void)?
    var onMetrics: ((AudioMetrics) -> Void)?
    init(profile: MediaProfile, input: AVAudioFormat, output: AVAudioFormat, ring: AudioRing, player: AVAudioPlayerNode, metrics: AudioMetrics) throws {
        self.profile = profile; self.ring = ring; self.player = player; self.metrics = metrics
        guard let i = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4096),
              let o = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 4096) else { throw ProtocolError.state("Audio conversion allocation failed") }
        converter = try PCMResampler(input: input, output: output); self.input = i; self.output = o; jitter = JitterBuffer(sampleRate: profile.sampleRate)
        samples.reserveCapacity(8192)
        if profile.codec == .opus {
            var error: Int32 = 0
            encoder = nearby_opus_encoder(Int32(profile.sampleRate), Int32(profile.bitrate), &error)
            guard error == 0, encoder != nil else { throw ProtocolError.incompatible("Pinned Opus encoder unavailable") }
            decoder = nearby_opus_decoder(Int32(profile.sampleRate), &error)
            guard error == 0, decoder != nil else { throw ProtocolError.incompatible("Pinned Opus decoder unavailable") }
        }
    }
    func talk(_ pressed: Bool) {
        guard !cancelled else { return }
        guard pressed != transmitting else { return }
        if pressed {
            discardCapture(); converter.reset(); samples.removeAll(keepingCapacity: true)
            if let encoder, nearby_opus_encoder_reset(encoder) != 0 { onFailure?("Opus encoder reset failed"); cancel(); return }
            guard stream < UInt32.max else { onFailure?("Audio stream counter exhausted"); return }
            stream += 1; timestamp = 0; first = true; transmitting = true; nearby_ring_enable(ring.pointer, 1)
        } else {
            nearby_ring_enable(ring.pointer, 0)
            do {
                try capture(flush: true)
                let valid = samples.count
                if valid > 0 {
                    samples.append(contentsOf: repeatElement(Float(0), count: packetSamples - valid))
                    try packet(final: true, valid: valid)
                } else { try emit(payload: Data(), final: true, valid: 0) }
            } catch { onFailure?("Final audio packet failed: \(error)") }
            transmitting = false
        }
    }
    private var packetSamples: Int { Int(profile.sampleRate / 50) }
    func tick() {
        guard !cancelled else { return }
        ticks += 1
        do { if transmitting { try capture(flush: false) }; try playout() }
        catch {
            if let failure = error as? ProtocolError, case .malformed = failure { onProtocolFailure?("Peer audio rejected: \(failure)") }
            else { onFailure?("Audio pipeline failed: \(error)") }
            cancel()
        }
        metrics.captureDroppedSamples = nearby_ring_drops(ring.pointer)
        if metrics.captureDroppedSamples > 0 { onFailure?("Capture queue overflow; audio stopped"); cancel() }
        if ticks % 50 == 0 {
            metrics.jitterMilliseconds = jitter.bufferedMilliseconds; metrics.underruns = jitter.underruns
            metrics.overflows = jitter.overflows; onMetrics?(metrics)
        }
    }
    private func discardCapture() { while nearby_ring_read(ring.pointer, input.floatChannelData![0], input.frameCapacity) > 0 {} }
    private func capture(flush: Bool) throws {
        var processed = 0
        while true {
            let count = nearby_ring_read(ring.pointer, input.floatChannelData![0], input.frameCapacity)
            if count == 0 { break }
            input.frameLength = count; try convert(input, ending: false); processed += Int(count)
            guard processed <= 16384 else { throw ProtocolError.limit("Capture processing backlog") }
        }
        if flush { try convert(nil, ending: true) }
    }
    private func convert(_ source: AVAudioPCMBuffer?, ending: Bool) throws {
        samples.append(contentsOf: try converter.convert(source, ending: ending))
        while samples.count >= packetSamples { try packet(final: false, valid: packetSamples) }
    }
    private func packet(final: Bool, valid: Int) throws {
        let payload: Data
        if let encoder {
            let count = samples.withUnsafeBufferPointer { ptr in nearby_opus_encode(encoder, ptr.baseAddress!, Int32(packetSamples), &encoded, Int32(encoded.count)) }
            guard count > 0 else { throw ProtocolError.state("Opus encode error \(count)") }; payload = Data(encoded.prefix(Int(count)))
        } else {
            var bytes = Data(capacity: packetSamples * 2)
            for value in samples.prefix(packetSamples) {
                let clamped = max(-1, min(1, value.isFinite ? value : 0)); let v = Int16(clamped * 32767)
                bytes.append(UInt8(truncatingIfNeeded: v)); bytes.append(UInt8(truncatingIfNeeded: v >> 8))
            }
            payload = bytes
        }
        samples.removeFirst(packetSamples); try emit(payload: payload, final: final, valid: valid)
    }
    private func emit(payload: Data, final: Bool, valid: Int) throws {
        try onPacket?(AudioPacket(stream: stream, timestamp: timestamp, final: final, discontinuity: first, validSamples: UInt16(valid), payload: payload))
        first = false; timestamp += UInt64(packetSamples); metrics.encodedPackets += 1
    }
    func receive(_ packet: AudioPacket) {
        guard !cancelled else { return }
        if awaitingReceiveStart && !packet.discontinuity { return }
        awaitingReceiveStart = false; receivingStream = packet.stream
        if packet.discontinuity {
            resetPlayback()
            if let decoder, nearby_opus_decoder_reset(decoder) != 0 { onFailure?("Opus decoder reset failed"); cancel(); return }
        }
        do { try jitter.push(packet); metrics.receivedPackets += 1 } catch { onProtocolFailure?("Audio stream rejected: \(error)"); cancel() }
    }
    func cancelReceive(_ stream: UInt32) {
        if stream == receivingStream { jitter.interrupt(); awaitingReceiveStart = true; resetPlayback() }
    }
    private func resetPlayback() {
        completionLock.lock(); completionGeneration += 1; completed = 0; completionLock.unlock()
        player.stop(); scheduled = 0; player.play()
    }
    private func playout() throws {
        completionLock.lock(); let completions = completed; completed = 0; completionLock.unlock()
        scheduled = max(0, scheduled - completions)
        guard scheduled < 4 else { return } // hardware scheduling is bounded to 80 ms
        let running = jitter.running
        guard let packet = jitter.pop() else {
            if running { try schedule(nil, valid: packetSamples) }; return
        }
        if packet.validSamples == 0 { return }
        try schedule(packet, valid: Int(packet.validSamples))
    }
    private func schedule(_ packet: AudioPacket?, valid: Int) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: output.format, frameCapacity: AVAudioFrameCount(packetSamples)) else { throw ProtocolError.limit("Playback allocation failed") }
        buffer.frameLength = AVAudioFrameCount(valid)
        let destination = buffer.floatChannelData![0]
        if let decoder {
            let count: Int32
            if let packet {
                count = packet.payload.withUnsafeBytes { raw in nearby_opus_decode(decoder, raw.bindMemory(to: UInt8.self).baseAddress, Int32(raw.count), destination, Int32(packetSamples)) }
            } else { count = nearby_opus_decode(decoder, nil, 0, destination, Int32(packetSamples)) }
            guard count == packetSamples else { throw ProtocolError.malformed("Opus decoded duration differs from 20 ms") }
        } else if let packet {
            for i in 0..<valid {
                let bits = UInt16(packet.payload[i * 2]) | UInt16(packet.payload[i * 2 + 1]) << 8
                destination[i] = Float(Int16(bitPattern: bits)) / 32768
            }
        } else { destination.initialize(repeating: 0, count: valid) }
        scheduled += 1
        completionLock.lock(); let generation = completionGeneration; completionLock.unlock()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }; self.completionLock.lock()
            if self.completionGeneration == generation { self.completed += 1 }
            self.completionLock.unlock()
        }
    }
    func cancel() { cancelled = true; nearby_ring_enable(ring.pointer, 0); transmitting = false; jitter.interrupt(); samples.removeAll(); player.stop() }
    deinit { nearby_opus_encoder_destroy(encoder); nearby_opus_decoder_destroy(decoder) }
}
