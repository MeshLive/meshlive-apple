import Foundation
import SwiftUI
import UIKit
import CoreImage
import NearbyCore

struct ChatLine: Identifiable {
    let id = UUID()
    let messageID: UInt32
    let outgoing: Bool
    let text: String
    var status: String
}
struct DiagnosticEvent: Codable {
    let elapsed: Double
    let name: String
    let detail: String
}

final class AppModel: ObservableObject {
    @Published var state = "Stopped"
    @Published var running = false
    @Published var peers: [NearbyPeer] = []
    @Published var verificationCode = ""
    @Published var fingerprint = ""
    @Published var ready = false
    @Published var confirmed = false
    @Published var lines: [ChatLine] = []
    @Published var microphoneActive = false
    @Published var audioStatus = "Microphone off"
    @Published var audioMetrics = AudioMetrics()
    @Published var metricsText = "No active session"
    @Published var speaker = true
    @Published var isTalking = false
    @Published var duplex = false
    @Published var voiceCheckConfirmed = false
    @Published var videoSending = false
    @Published var localVideoRunning = false
    @Published var videoImage: UIImage?
    @Published var videoMetrics = VideoMetrics()
    @Published var diagnosticSummary = ""
    @Published var error: String?
    @Published var selectedTransport: TransportKind = .l2cap
    private(set) var opusAvailable = nearby_opus_available() != 0
    private var transport: BluetoothTransport?
    private var session: SecureSession?
    private let voice = VoiceEngine()
    private var timer: Timer?
    private var gate = AttemptGate()
    private var runID = UUID()
    private var started = ProcessInfo.processInfo.systemUptime
    private var events: [DiagnosticEvent] = []
    private var physicalContract = "Foreground only; no physical exchange verified in development environment"
    private var transportName = "none"
    private var lastDisconnect = ""
    private var roleName = "none"
    private var submissionCount: UInt64 = 0
    private var audioSent: UInt64 = 0
    private var audioReceived: UInt64 = 0
    private var receivedAudioStream: UInt32 = 0
    private var nextStreamBase: UInt32 = 0
    private var currentLocalStream: UInt32 = 0
    private var audioObserver: NSObjectProtocol?
    private var localAudioCheck = false
    private var video: PatternVideo?
    private var videoAttempt = UUID()
    private var waitingForVideoKeyframe = true
    private var dataCheck: Timer?
    private var dataCheckIDs = Set<UInt32>()
    private var dataCheckSubmitted = 0
    private var dataCheckAcknowledged = 0
    private let imageContext = CIContext()
    private var closeCleanupDeadline: TimeInterval?
    private var pendingCloseReason: String?
    private var peakQueuedBytes = 0
    private var peakQueueAgeMS: Double = 0
    private var videoReceiveBlocked = false
    var profileDescription: String {
        guard let profile = session?.profile else { return opusAvailable ? "Opus available; not negotiated" : "PCM diagnostic available; Opus not installed" }
        return "\(profile.codec == .opus ? "Opus" : "PCM diagnostic") · \(profile.sampleRate) Hz mono · 20 ms · \(profile.bitrate / 1000) kbps"
    }
    var canDuplex: Bool { ready && microphoneActive && session?.profile?.codec == .opus && transportName == "l2cap" }
    var canVideo: Bool { canDuplex && voiceCheckConfirmed && session?.profile?.video == true }

    init() {
        voice.onStatus = { [weak self] status, active in self?.audioStatus = status; self?.microphoneActive = active }
        voice.onMetrics = { [weak self] metrics in self?.audioMetrics = metrics }
        voice.onFailure = { [weak self] reason in
            if let self, self.ready { try? self.session?.cancelAudio(stream: self.currentLocalStream, now: self.now) }
            self?.isTalking = false; self?.duplex = false; self?.error = reason; self?.log("audio.stopped", reason)
        }
        voice.onProtocolFailure = { [weak self] reason in self?.error = reason; self?.stop(reason: "Peer audio protocol violation") }
        voice.onPacket = { [weak self] packet in
            guard let self else { return }
            if self.localAudioCheck { self.voice.receive(packet) } else { self.sendAudio(packet) }
        }
        audioObserver = NotificationCenter.default.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in self?.stop(reason: "Screen locked", immediate: true) }
    }
    func start(host: Bool) {
        stop(reason: "New run", immediate: true)
        let token = gate.renew(); runID = UUID(); started = now; events.removeAll(); lines.removeAll(); peers.removeAll()
        ready = false; confirmed = false; voiceCheckConfirmed = false; verificationCode = ""; fingerprint = ""; lastDisconnect = ""; error = nil
        transportName = "none"; roleName = host ? "host" : "join"; submissionCount = 0; audioSent = 0; audioReceived = 0
        nextStreamBase = 0; currentLocalStream = 0; receivedAudioStream = 0
        diagnosticSummary = ""; dataCheckIDs.removeAll(); dataCheckSubmitted = 0; dataCheckAcknowledged = 0
        audioMetrics = AudioMetrics(); videoMetrics = VideoMetrics()
        peakQueuedBytes = 0; peakQueueAgeMS = 0
        videoReceiveBlocked = false
        let bluetooth = BluetoothTransport(mode: host ? .host : .join, preferred: selectedTransport)
        transport = bluetooth
        bluetooth.onState = { [weak self] state in guard let self, self.gate.accepts(token) else { return }; self.state = state; self.log("state", state) }
        bluetooth.onPeers = { [weak self] peers in guard let self, self.gate.accepts(token) else { return }; self.peers = peers }
        bluetooth.onReady = { [weak self] kind, hostToken in guard let self, self.gate.accepts(token) else { return }; self.beginSession(host: host, kind: kind, hostToken: hostToken, attempt: token) }
        bluetooth.onRecord = { [weak self] record in
            guard let self, self.gate.accepts(token) else { return }
            do { try self.session?.receive(record, now: self.now) } catch { self.error = "Session rejected: \(error)" }
        }
        bluetooth.onFailure = { [weak self] reason in guard let self, self.gate.accepts(token) else { return }; if self.pendingCloseReason == nil { self.error = reason }; self.finish(self.pendingCloseReason ?? reason) }
        bluetooth.onEvent = { [weak self] name, detail in guard let self, self.gate.accepts(token) else { return }; self.log(name, detail) }
        bluetooth.onSubmission = { [weak self] _ in guard let self, self.gate.accepts(token) else { return }; self.submissionCount += 1 }
        running = true; bluetooth.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.gate.accepts(token) else { return }
            do { try self.session?.tick(now: self.now) } catch { self.error = String(describing: error) }
            self.refreshMetrics()
            if let deadline = self.closeCleanupDeadline, self.now >= deadline { self.finish(self.pendingCloseReason ?? "Peer close cleanup deadline"); return }
            if let transport = self.transport, transport.queueAge > 3 { self.finish("Transport stalled: oldest queued data exceeds 3 seconds") }
        }
        log("run.start", "\(roleName), requested \(selectedTransport)")
    }
    private func beginSession(host: Bool, kind: TransportKind, hostToken: Data, attempt: UUID) {
        do {
            let identity = try IdentityStore.load()
            let capabilities = Capabilities(transport: kind, opus: opusAvailable, pcm: true, video: opusAvailable && kind == .l2cap, name: "iPhone")
            let session = SecureSession(role: host ? .responder : .initiator, identity: identity, capabilities: capabilities, hostToken: hostToken, now: now)
            self.session = session; transportName = kind == .gatt ? "gatt" : "l2cap"
            session.onSend = { [weak self] record in
                guard let self, self.gate.accepts(attempt), let transport = self.transport else { throw ProtocolError.state("Stale connection attempt") }
                try transport.send(record)
            }
            session.onEvent = { [weak self] event in guard let self, self.gate.accepts(attempt) else { return }; self.handle(event) }
            state = "Establishing encrypted session"; try session.start(now: now)
        } catch { self.error = "Identity/session failed: \(error)"; finish(self.error!) }
    }
    private func handle(_ event: SessionEvent) {
        switch event {
        case .verification(let code, let fingerprint):
            verificationCode = code; self.fingerprint = fingerprint; state = "Compare code on both iPhones"; log("session.verification", "Waiting for explicit comparison")
        case .ready(let profile): ready = true; state = "Verified · \(transportName.uppercased())"; log("session.ready", "Audio codec \(profile.codec.rawValue), rate \(profile.sampleRate)")
        case .submitted(let id): update(id, status: "Submitted locally")
        case .acknowledged(let id):
            update(id, status: "Remote app acknowledged"); log("data.acknowledged", "Message \(id)")
            if dataCheckIDs.remove(id) != nil { dataCheckAcknowledged += 1; diagnosticSummary = "Data check: \(dataCheckAcknowledged)/\(dataCheckSubmitted) remotely acknowledged" }
        case .cancelled(let id): update(id, status: "Cancellation requested; peer may already have received")
        case .text(let id, let text): append(ChatLine(messageID: id, outgoing: false, text: text, status: "Received by app"))
        case .audio(let packet):
            audioReceived += 1; receivedAudioStream = packet.stream
            voice.receive(packet)
        case .audioCancelled(let stream): voice.cancelReceive(stream)
        case .closed(let reason):
            if session?.receivedOrderlyClose == true {
                voice.stop(); stopVideo(); isTalking = false; duplex = false; ready = false
                pendingCloseReason = reason; closeCleanupDeadline = now + 2; state = "Peer closed; waiting for link cleanup"
            } else { finish(reason) }
        case .videoConfig(let data):
            guard !videoReceiveBlocked else { return }
            do { let config = try VideoConfiguration(decoding: data); getVideo().receiveConfig(config) }
            catch { self.error = "Video configuration rejected: \(error)"; stop(reason: "Malformed video configuration") }
        case .video(let data):
            guard !videoReceiveBlocked else { return }
            do { getVideo().receive(try VideoFrame(decoding: data)) }
            catch { self.error = "Video frame rejected: \(error)"; stop(reason: "Malformed video frame") }
        }
    }
    func verify() {
        do { try session?.verify(now: now); confirmed = true; state = ready ? "Verified" : "Waiting for peer confirmation" }
        catch { self.error = String(describing: error) }
    }
    func reject() { stop(reason: "Peer verification rejected") }
    func connect(_ peer: NearbyPeer) { transport?.connect(peer.id) }
    func sendText(_ text: String) {
        do {
            guard let session else { return }
            let id = try session.sendText(text, now: now)
            append(ChatLine(messageID: id, outgoing: true, text: text, status: "Submitted locally"))
        } catch { self.error = String(describing: error) }
    }
    func cancel(_ id: UInt32) { do { try session?.cancelMessage(id, now: now) } catch { self.error = String(describing: error) } }
    func enableAudio() {
        guard ready, let profile = session?.profile else { return }
        if currentLocalStream > nextStreamBase { nextStreamBase = currentLocalStream }
        voice.enable(profile: profile, speaker: speaker)
    }
    func enableLocalAudioCheck() {
        guard !running else { return }; localAudioCheck = true; voice.enable(profile: .init(codec: .pcmDiagnostic, video: false), speaker: speaker)
        log("audio.local.check", "Local microphone/route check, no Bluetooth connection")
    }
    func talk(_ pressed: Bool) {
        guard ready || localAudioCheck, microphoneActive, !duplex else { return }; isTalking = pressed; voice.talk(pressed)
    }
    func setDuplex(_ enabled: Bool) {
        guard !enabled || canDuplex else { return }
        duplex = enabled; isTalking = enabled; voice.talk(enabled); log("audio.duplex", enabled ? "Experimental voice-processing capture active" : "Stopped")
    }
    func mute() {
        isTalking = false; duplex = false
        let token = gate.current
        voice.finishTalking { [weak self] in guard let self, self.gate.accepts(token) else { return }; self.voice.mute() }
    }
    func startDataCheck() {
        guard ready, dataCheck == nil else { return }
        dataCheckSubmitted = 0; dataCheckAcknowledged = 0; dataCheckIDs.removeAll()
        let token = gate.current; var count = 0
        diagnosticSummary = "30-second data check started"
        dataCheck = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, self.gate.accepts(token), self.ready, let session = self.session else { timer.invalidate(); return }
            do {
                let payload = "Diagnostic \(self.runID.uuidString) #\(count): " + String(repeating: "0123456789", count: 40)
                let id = try session.sendText(payload, now: self.now); self.dataCheckIDs.insert(id); self.dataCheckSubmitted += 1; count += 1
                if count == 30 { timer.invalidate(); self.dataCheck = nil; self.log("data.check.submitted", "30 records; await remote ACK summary") }
            } catch { timer.invalidate(); self.dataCheck = nil; self.error = "Data check failed: \(error)" }
        }
    }
    private func getVideo() -> PatternVideo {
        if let video { return video }
        let video = PatternVideo(); self.video = video; let token = videoAttempt
        let frameMailbox = BoundedMailbox<VideoFrame>(capacity: 2)
        let imageMailbox = BoundedMailbox<CVPixelBuffer>(capacity: 1)
        let metricsMailbox = BoundedMailbox<VideoMetrics>(capacity: 1)
        video.onConfig = { [weak self] config in DispatchQueue.main.async {
            guard let self, self.videoAttempt == token, self.videoSending else { return }
            do { try self.session?.sendVideo(kind: .videoConfig, payload: config.encoded, now: self.now) } catch { self.error = "Video config send failed: \(error)"; self.stop(reason: "Video configuration submission failed") }
        } }
        video.onFrame = { [weak self, weak video] frame in
            guard let notify = frameMailbox.offer(frame) else { video?.requestKeyframe(); return }
            if notify { DispatchQueue.main.async {
                let frames = frameMailbox.takeAll()
                guard let self, self.videoAttempt == token, self.videoSending else { return }
                for frame in frames {
                    guard let transport = self.transport, transport.queuedBytes < 2048, transport.queueAge < 0.1, !self.isTalking else { self.waitingForVideoKeyframe = true; video?.requestKeyframe(); continue }
                    if self.waitingForVideoKeyframe && !frame.keyframe { video?.requestKeyframe(); continue }
                    self.waitingForVideoKeyframe = false
                    do { try self.session?.sendVideo(kind: .video, payload: frame.encoded, now: self.now) } catch { self.error = "Video send failed: \(error)"; self.stop(reason: "Video transport failed"); break }
                }
            } }
        }
        video.onImage = { [weak self] pixel in
            guard let notify = imageMailbox.offer(pixel), notify else { return }
            DispatchQueue.main.async {
                let images = imageMailbox.takeAll()
                guard let self, self.videoAttempt == token, let pixel = images.last else { return }
                let image = CIImage(cvPixelBuffer: pixel)
                if let cg = self.imageContext.createCGImage(image, from: image.extent) { self.videoImage = UIImage(cgImage: cg) }
            }
        }
        video.onMetrics = { [weak self] metrics in
            guard let notify = metricsMailbox.offerLatest(metrics), notify else { return }
            DispatchQueue.main.async {
                let values = metricsMailbox.takeAll()
                guard let self, self.videoAttempt == token, let metrics = values.last else { return }; self.videoMetrics = metrics
            }
        }
        video.onFailure = { [weak self] reason in DispatchQueue.main.async {
            guard let self, self.videoAttempt == token else { return }; self.error = reason; self.log("video.failed", reason); self.stopVideo()
        } }
        return video
    }
    func startLocalVideoCheck() {
        guard !running else { return }; stopVideo(); localVideoRunning = true
        let token = videoAttempt
        getVideo().start(loopback: true, frames: 30) { [weak self] in DispatchQueue.main.async { guard let self, self.videoAttempt == token else { return }; self.localVideoRunning = false } }
    }
    func startVideo() { guard canVideo else { return }; videoReceiveBlocked = false; videoSending = true; waitingForVideoKeyframe = true; getVideo().start(); log("video.start", "Generated pattern; audio has priority") }
    func stopVideo() { videoReceiveBlocked = true; videoAttempt = UUID(); video?.stop(); video = nil; videoSending = false; localVideoRunning = false }
    func route(_ speaker: Bool) { self.speaker = speaker; voice.setSpeaker(speaker) }
    private func sendAudio(_ packet: AudioPacket) {
        guard ready else { return }
        guard let transport, transport.queuedBytes < 8192, transport.queueAge < 0.25 else {
            voice.stop(); isTalking = false; duplex = false; stop(reason: "Audio transport overload; session closed to bound delay"); return
        }
        // Worker stream counters restart when hardware is re-enabled; session stream IDs never do.
        let id = nextStreamBase + packet.stream; currentLocalStream = max(currentLocalStream, id)
        let mapped = AudioPacket(stream: id, timestamp: packet.timestamp, final: packet.final, discontinuity: packet.discontinuity, validSamples: packet.validSamples, payload: packet.payload)
        do { try session?.sendAudio(mapped, now: now); audioSent += 1 } catch { self.error = "Audio send failed: \(error)"; finish(self.error!) }
    }
    func inactive() { voice.setApplicationActive(false); if microphoneActive { mute(); log("audio.inactive", "Capture released; re-enable when active") } }
    func active() { voice.setApplicationActive(true) }
    func stop(reason: String = "User Stop", immediate: Bool = false) {
        voice.stop(); localAudioCheck = false; isTalking = false; duplex = false; stopVideo(); dataCheck?.invalidate(); dataCheck = nil
        if !immediate, let session, session.state == .ready || session.state == .verification {
            do { try session.close(reason: reason, now: now); state = "Closing"; ready = false; return }
            catch { self.error = String(describing: error) }
        }
        finish(reason)
    }
    private func finish(_ reason: String) {
        closeCleanupDeadline = nil; pendingCloseReason = nil
        refreshMetrics(); lastDisconnect = reason; log("run.stop", reason)
        gate.renew(); voice.stop(); localAudioCheck = false; stopVideo(); dataCheck?.invalidate(); dataCheck = nil; transport?.stop(); timer?.invalidate(); timer = nil
        session?.onEvent = nil; session?.fail(reason)
        running = false; ready = false; isTalking = false; duplex = false; state = reason
    }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private func append(_ line: ChatLine) { lines.append(line); if lines.count > 64 { lines.removeFirst() } }
    private func update(_ id: UInt32, status: String) { if let index = lines.firstIndex(where: { $0.outgoing && $0.messageID == id }) { lines[index].status = status } }
    private func log(_ name: String, _ detail: String) {
        events.append(DiagnosticEvent(elapsed: max(0, now - started), name: name, detail: detail))
        if events.count > 200 { events.removeFirst(events.count - 200) }
    }
    private func refreshMetrics() {
        guard let transport else { return }
        peakQueuedBytes = max(peakQueuedBytes, transport.queuedBytes)
        peakQueueAgeMS = max(peakQueueAgeMS, transport.queueAge * 1000)
        metricsText = "Transport: \(transportName); PSM: \(transport.currentPSM)\nWrite/update: \(transport.maximumWrite)/\(transport.maximumUpdate) bytes\nSubmitted to OS: \(transport.deliveredToSystem) B · received: \(transport.receivedBytes) B\nQueue: \(transport.queuedBytes) B / \(String(format: "%.0f", transport.queueAge * 1000)) ms\nRemote app ACK: \(session?.applicationBytesAcknowledged ?? 0) text bytes\nAudio sent/received: \(audioSent)/\(audioReceived) packets\nJitter: \(audioMetrics.jitterMilliseconds) ms · underruns: \(audioMetrics.underruns)\nDisconnect: \(lastDisconnect.isEmpty ? "none" : lastDisconnect)"
    }
    func exportDiagnostics() -> String {
        struct Export: Codable {
            let build: String, os: String, model: String, protocolVersion: String, runID: String, sessionID: String, role: String, transport: String, profile: String, operatingContract: String, disconnect: String
            let psm: UInt16, maximumWrite: Int, maximumUpdate: Int, queuedBytes: Int, queueAgeMS: Double
            let peakQueuedBytes: Int, peakQueueAgeMS: Double, microphoneActive: Bool
            let dataCheckSubmitted: Int, dataCheckAcknowledged: Int
            let submittedBytes: UInt64, receivedBytes: UInt64, applicationAcknowledgedBytes: UInt64, submittedRecords: UInt64, audioSent: UInt64, audioReceived: UInt64
            let audio: AudioMetrics
            let video: VideoMetrics
            let events: [DiagnosticEvent]
        }
        var system = utsname(); uname(&system)
        let model = withUnsafePointer(to: &system.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
        let export = Export(build: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?" ) (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))", os: UIDevice.current.systemVersion, model: model, protocolVersion: "NearbyIntercom/v1",
                            runID: runID.uuidString, sessionID: session?.sessionID.map { String(format: "%02x", $0) }.joined() ?? "none", role: roleName, transport: transportName, profile: profileDescription, operatingContract: physicalContract, disconnect: lastDisconnect,
                            psm: transport?.currentPSM ?? 0, maximumWrite: transport?.maximumWrite ?? 0, maximumUpdate: transport?.maximumUpdate ?? 0, queuedBytes: transport?.queuedBytes ?? 0, queueAgeMS: (transport?.queueAge ?? 0) * 1000,
                            peakQueuedBytes: peakQueuedBytes, peakQueueAgeMS: peakQueueAgeMS, microphoneActive: microphoneActive, dataCheckSubmitted: dataCheckSubmitted, dataCheckAcknowledged: dataCheckAcknowledged,
                            submittedBytes: transport?.deliveredToSystem ?? 0, receivedBytes: transport?.receivedBytes ?? 0, applicationAcknowledgedBytes: session?.applicationBytesAcknowledged ?? 0, submittedRecords: submissionCount, audioSent: audioSent, audioReceived: audioReceived, audio: audioMetrics, video: videoMetrics, events: events)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(decoding: encoder.encode(export), as: UTF8.self)) ?? "Export failed"
    }
    deinit { timer?.invalidate(); if let audioObserver { NotificationCenter.default.removeObserver(audioObserver) } }
}
