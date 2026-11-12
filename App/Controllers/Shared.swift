import Foundation
import SwiftUI
import NearbyCore
import VideoToolbox
#if os(iOS)
import UIKit
#else
import AppKit
#endif
#if canImport(NearbyMedia)
import NearbyMedia
#endif

/// The standard request (design decision 2026-10-10, as Android): 426x240 at 15 FPS, 200 kbps, sent portrait (240x426).
/// Calls and broadcasts use Settings › Manual video (`AppModel.videoRequest`, `VideoRequest.standard` by default);
/// only DEBUG automation media still reads these values.
enum MediaDefaults {
    static let width = 240, height = 426, fps = 15, videoKbps = 200
}

/// Remote video decode on a serial queue; decode failures ask the sender for a keyframe (rate-limited). Calls may add the
/// B1.5 recovery ladder (`recovery`); the watch path leaves it nil and keeps BASE exactly.
final class RemoteVideo {
    private var queue = DispatchQueue(label: "io.github.meshlive.app.decode", qos: .userInitiated)
    private var decoder: VideoFrameDecoder?
    private var retirement = DecoderRetirement()
    private var codecId: UInt8 = 0
    private var generation = 0
    private var lastKeyRequest: TimeInterval = 0
    private var headerSize = ""
    private var lastDecodedSize = (0, 0)
    let sink = VideoSink()
    var onNeedKeyFrame: (() -> Void)?
    /// Video arrived but no decoder could be created for its codec (`LocalMediaFailure.videoDecoderSetup`), once.
    var onDecoderUnavailable: ((String) -> Void)?
    private var decoderSetupError: String?
    private(set) var decoderName = ""
    var decodedFrames = 0
    /// The first decoded picture of this call (main thread), for call setup timing.
    var onFirstPicture: (() -> Void)?
    #if os(macOS)
    private(set) var payloadBytes = 0
    #endif

    /// B1.5 calls only: the recovery ladder. nil on the watch path and with `-callVideoRecovery NO` (BASE).
    var recovery: VideoDecoderRecovery?
    /// "Recovering remote video…" and the stopped text; nil after the first picture of the rebuilt decoder.
    var onRecoveryNotice: ((String?) -> Void)?
    /// Fired once when the ladder stops video on this phone.
    var onVideoStopped: (() -> Void)?
    private var health = VideoDecoderHealth()
    private var stall = VideoDecoderStallDetector()
    private var usingSoftware = false
    private var stoppedVideo = false
    private var showingRecoveryNotice = false
    /// B1F step 3: the app's background state, main-confined, so a background invalid session is not a counted failure.
    private var isBackgrounded = false
    private var awaitingForegroundKeyFrame = false
    #if DEBUG
    private var injectedFailures = 0
    private var injectedKeyFailures = 0
    private var injectedStall = 0
    #endif

    init() {
        #if DEBUG
        injectedFailures = RootView.debugArgument("-NearbyInjectDecoderFailures").flatMap(Int.init) ?? 0
        injectedKeyFailures = RootView.debugArgument("-NearbyInjectDecoderKeyFailures").flatMap(Int.init) ?? 0
        if RootView.debugArgument("-NearbyInjectDecoderStall").flatMap(Int.init) == 1 { injectedStall = 30 }
        #endif
    }

    func configure(header: StreamHeader) {
        sink.rotation = header.rotationDegrees
        headerSize = "\(header.width)x\(header.height)"
        // B1F step 5: after the ladder stopped video on this phone, a later header keeps it stopped and its caption.
        if stoppedVideo || recovery?.acceptsNewStream == false {
            stoppedVideo = true
            return
        }
        guard header.codecId != codecId || decoder == nil else { return }
        codecId = header.codecId
        usingSoftware = false
        stoppedVideo = false
        makeDecoder(preferSoftware: false, setupFailureEndsCall: true, notice: false)
    }

    func decode(_ packet: MediaPacket) {
        #if os(macOS)
        payloadBytes += packet.payload.count
        #endif
        guard !stoppedVideo else { return }
        guard let decoder else {
            // A decoder that could not be set up is needed only once video arrives (a voice call never ends over it).
            if let failure = decoderSetupError { decoderSetupError = nil; onDecoderUnavailable?(failure) }
            return
        }
        let generation = generation
        let retirement = self.retirement
        if packet.isCodecConfig {
            queue.async {
                guard !retirement.isRetired else { return }
                decoder.replaceCodecConfig(packet.payload)
            }
            return
        }
        if recovery != nil {
            stall.onInput(at: ProcessInfo.processInfo.systemUptime)
            #if DEBUG
            if injectedKeyFailures > 0, packet.isKeyFrame {
                injectedKeyFailures -= 1
                AppLog.event("decoder_inject", ["kind": "key", "remaining": "\(injectedKeyFailures)"])
                DispatchQueue.main.async {
                    self.decodeFailed(VideoCodecError.failed("injected key frame failure"), keyFrame: true,
                                      generation: generation)
                }
                return
            }
            if injectedFailures > 0 {
                injectedFailures -= 1
                DispatchQueue.main.async {
                    self.decodeFailed(VideoCodecError.failed("injected decoder failure"), keyFrame: packet.isKeyFrame,
                                      generation: generation)
                }
                return
            }
            if injectedStall > 0 { injectedStall -= 1; return }
            #endif
        }
        queue.async { [weak self] in
            guard !retirement.isRetired else { return }
            do {
                try decoder.decode(packet.payload, presentationTimeUs: packet.presentationTimeUs, keyFrame: packet.isKeyFrame)
                if packet.isKeyFrame {
                    DispatchQueue.main.async { self?.keyFrameArrived(generation: generation) }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.decodeFailed(error, keyFrame: packet.isKeyFrame, generation: generation)
                }
            }
        }
    }

    /// B1F step 3: background invalid sessions wait for the one silent rebuild; the next real failure still counts.
    func enterBackground() { isBackgrounded = true }

    func enterForeground() {
        isBackgrounded = false
        stall.onReset(at: ProcessInfo.processInfo.systemUptime)
        guard var recovery, recovery.takeSilentRebuild() else { return }
        self.recovery = recovery
        makeDecoder(preferSoftware: usingSoftware, setupFailureEndsCall: false, notice: false)
        awaitingForegroundKeyFrame = true
        requestKeyFrame(force: true)
    }

    /// Called from `CallController.refreshStats()` (1 Hz): a decoder that takes inputs but produces no output.
    func checkStall(at uptime: TimeInterval, fps: Int, suspended: Bool) {
        guard recovery != nil, !stoppedVideo else { return }
        guard let found = stall.check(at: uptime, fps: fps, suspended: suspended) else { return }
        stall.onReset(at: uptime)
        var recovery = self.recovery!
        let action = recovery.onFailure(otherDecoderExists: otherDecoderExists)
        self.recovery = recovery
        logRecovery(kind: "stall", action: action, recovery: recovery)
        apply(action, kind: "stall", recovery: recovery)
    }

    func requestKeyFrame() { requestKeyFrame(force: false) }

    private func requestKeyFrame(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastKeyRequest > 0.75 else { return }
        lastKeyRequest = now; onNeedKeyFrame?()
    }

    func stop() {
        stoppedVideo = true
        generation += 1
        retireDecoder()
        DispatchQueue.main.async { self.sink.clear() }
    }

    private var otherDecoderExists: Bool { !usingSoftware && codecId == StreamProtocol.codecVP9 }

    private func makeDecoder(preferSoftware: Bool, setupFailureEndsCall: Bool, notice: Bool) {
        generation += 1
        let generation = generation
        retireDecoder()
        queue = DispatchQueue(label: "io.github.meshlive.app.decode.\(generation)", qos: .userInitiated)
        retirement = DecoderRetirement()
        _ = health.apply(.rebuilt)
        stall.onReset(at: ProcessInfo.processInfo.systemUptime)
        do {
            let decoder = try VideoDecoderFactory.make(codecId: codecId, preferSoftware: preferSoftware)
            decoder.onPicture = { [weak self] pixels, _ in
                DispatchQueue.main.async { self?.picture(pixels, generation: generation) }
            }
            self.decoder = decoder
            decoderName = decoder.name
            decoderSetupError = nil
            if notice {
                showingRecoveryNotice = true
                onRecoveryNotice?(VideoRecoveryNotice.recovering)
                requestKeyFrame(force: true)
            }
        } catch {
            self.decoder = nil
            decoderName = "No decoder: \(error)"
            if setupFailureEndsCall {
                decoderSetupError = "\(error)"
            } else {
                logRecovery(kind: "setup", action: .stopVideo, recovery: recovery ?? VideoDecoderRecovery())
                stopVideo(kind: "setup")
            }
        }
    }

    /// The old decoder is retired before its queue is replaced: queued key frames skip (the retirement flag) and
    /// `invalidate()` runs on that same serial queue, behind any in-flight decode, never concurrently with it.
    private func retireDecoder() {
        guard let old = decoder else { return }
        decoder = nil
        retirement.retire()
        let oldQueue = queue
        oldQueue.async { old.invalidate() }
    }

    /// B1F step 4: a key frame that decoded is a boundary; errors before it were ordinary loss.
    private func keyFrameArrived(generation: Int) {
        guard generation == self.generation, !stoppedVideo else { return }
        _ = health.apply(.keyFrame)
    }

    private func picture(_ pixels: CVPixelBuffer, generation: Int) {
        guard generation == self.generation, !stoppedVideo else { return }
        decodedFrames += 1
        _ = health.apply(.picture)
        stall.onOutput(at: ProcessInfo.processInfo.systemUptime)
        if awaitingForegroundKeyFrame, var recovery {
            recovery.onForegroundKeyFrame()
            self.recovery = recovery
            awaitingForegroundKeyFrame = false
        }
        if var recovery {
            recovery.onPicture()
            self.recovery = recovery
            if showingRecoveryNotice, recovery.failureCount == 0 {
                showingRecoveryNotice = false
                onRecoveryNotice?(nil)
            }
        }
        if decodedFrames == 1 { onFirstPicture?() }
        let size = (CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels))
        if size != lastDecodedSize {
            // Android's resolution ladder changes the size in-band at a keyframe; the header is the maximum.
            lastDecodedSize = size
            AppLog.event("decoder_output_size", ["decoded": "\(size.0)x\(size.1)", "header": headerSize])
        }
        sink.show(pixels)
    }

    private func decodeFailed(_ error: Error, keyFrame: Bool, generation: Int) {
        guard generation == self.generation, !stoppedVideo else { return }
        guard var recovery else {
            requestKeyFrame()
            return
        }
        var invalidSession = false
        if case VideoCodecError.failed(let message) = error, message.contains("\(kVTInvalidSessionErr)") {
            invalidSession = true
        }
        if invalidSession, isBackgrounded {
            _ = recovery.onBackgroundInvalidSession()
            self.recovery = recovery
            return
        }
        guard health.apply(.error(keyFramePacket: keyFrame, invalidSession: invalidSession)) else {
            requestKeyFrame()
            return
        }
        let kind = invalidSession ? "invalid_session" : "errors"
        let action = recovery.onFailure(otherDecoderExists: otherDecoderExists)
        self.recovery = recovery
        logRecovery(kind: kind, action: action, recovery: recovery)
        apply(action, kind: kind, recovery: recovery)
    }

    private func apply(_ action: VideoDecoderRecovery.Action, kind: String, recovery: VideoDecoderRecovery) {
        switch action {
        case .rebuildSame:
            makeDecoder(preferSoftware: usingSoftware, setupFailureEndsCall: false, notice: true)
        case .tryOther:
            usingSoftware = true
            makeDecoder(preferSoftware: true, setupFailureEndsCall: false, notice: true)
        case .stopVideo:
            stopVideo(kind: kind)
        }
    }

    private func stopVideo(kind: String) {
        guard !stoppedVideo else { return }
        stoppedVideo = true
        generation += 1
        retireDecoder()
        DispatchQueue.main.async { self.sink.clear() }
        showingRecoveryNotice = true
        onRecoveryNotice?(VideoRecoveryNotice.stopped)
        onVideoStopped?()
    }

    private func logRecovery(kind: String, action: VideoDecoderRecovery.Action, recovery: VideoDecoderRecovery) {
        let actionWord: String
        switch action {
        case .rebuildSame: actionWord = "rebuildSame"
        case .tryOther: actionWord = "tryOther"
        case .stopVideo: actionWord = "stopVideo"
        }
        AppLog.event("call_video_recovery", ["kind": kind, "failures": "\(recovery.failureCount)", "action": actionWord,
                                             "decoder": decoderName, "pictures": "\(recovery.picturesSinceRecovery)"])
    }
}
