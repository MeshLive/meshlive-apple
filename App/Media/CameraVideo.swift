import Foundation
import AVFoundation
#if os(iOS)
import UIKit
typealias PlatformVideoView = UIView
#else
import AppKit
typealias PlatformVideoView = NSView
#endif
import SwiftUI
import NearbyCore
#if canImport(NearbyMedia)
import NearbyMedia
#endif

/// Camera -> portrait NV12 -> I420 at the negotiated size -> libvpx VP9 (software; Android accepts only VP9/AV1).
/// Frames are rotated by the capture connection, so the BTV3 header rotation is 0 and the size is portrait.
final class CameraVideo: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "org.nearbyintercom.camera", qos: .userInitiated)
    private var encoder: VP9Encoder?
    private var forceKeyFrame = true
    private var lastFrameUptime: TimeInterval = 0
    private(set) var width: Int, height: Int, fps: Int, bitrateKbps: Int
    private(set) var front: Bool
    private var startUptime: TimeInterval
    /// (flags, presentationTimeUs, VP9 access unit) on the main queue.
    var onFrame: ((UInt8, Int64, Data) -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var encodedFrames = 0
    private(set) var encodedBytes = 0
    private(set) var capturedFrames = 0
    private(set) var skippedFrames = 0
    private(set) var conversionFailures = 0
    private(set) var encodeErrors = 0
    private(set) var running = false
    private var observers: [NSObjectProtocol] = []
    /// Never `queue.sync` from main: the camera queue can be inside `startRunning()` for seconds, and a blocked
    /// main queue stops every link pump and heartbeat (measured: a 9 s stall ended an M31 call). Plain reads of
    /// counters are racy but harmless for logging.
    var logFields: [String: String] {
        ["videoCaptured": "\(capturedFrames)", "videoEncoded": "\(encodedFrames)", "videoEncodedBytes": "\(encodedBytes)",
         "videoSkipped": "\(skippedFrames)", "videoConversionFailures": "\(conversionFailures)", "videoEncodeErrors": "\(encodeErrors)",
         "cameraRunning": "\(running)"]
    }

    /// - Parameter clockStart: uptime shared with the audio clock so BTV3 timestamps align.
    init(width: Int, height: Int, fps: Int, bitrateKbps: Int, front: Bool, clockStart: TimeInterval) {
        self.width = width; self.height = height; self.fps = fps; self.bitrateKbps = bitrateKbps; self.front = front; startUptime = clockStart
    }

    func start() {
        guard !DesktopPreview.enabled else { return }
        MediaPermissions.requestCamera { granted in
            AppLog.event("camera_start", ["permission": granted ? "granted" : "denied", "size": "\(self.width)x\(self.height)", "fps": "\(self.fps)", "kbps": "\(self.bitrateKbps)"])
            guard granted else { self.onFailure?("Camera is off for MeshLive. Turn it on in Settings to send video."); return }
            self.observe()
            self.queue.async { self.configure() }
        }
    }

    private func observe() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            AppLog.event("camera_error", ["stage": "runtime", "error": "\(error?.domain ?? "?") \(error?.code ?? 0)"])
            self?.queue.async { self?.session.startRunning() }
        })
        #if os(macOS)
        observers.append(center.addObserver(forName: DesktopCameraDevices.selectionChanged, object: nil, queue: .main) { [weak self] _ in
            self?.queue.async {
                guard let self else { return }
                self.session.stopRunning()
                self.forceKeyFrame = true
                self.configure()
            }
        })
        #endif
        #if os(iOS)
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { note in
            AppLog.event("camera_interrupted", ["reason": "\(note.userInfo?[AVCaptureSessionInterruptionReasonKey] ?? "?")"])
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { _ in
            AppLog.event("camera_interruption_ended")
        })
        #endif
    }

    private func configure() {
        let started = ProcessInfo.processInfo.systemUptime
        // The call's audio engine owns the audio session (voice processing); the capture session must not
        // reconfigure it (it has no audio input).
        #if os(iOS)
        session.automaticallyConfiguresApplicationAudioSession = false
        #endif
        do {
            encoder = try VP9Encoder(width: width, height: height, fps: fps, bitrateKbps: bitrateKbps, threads: 2, speed: 8)
        } catch {
            AppLog.event("camera_error", ["stage": "encoder", "error": "\(error)"])
            DispatchQueue.main.async { self.onFailure?("Video encoder unavailable: \(error)") }; return
        }
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        #if os(macOS)
        let selectedDevice = DesktopCameraDevices.selected()
        #else
        let selectedDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back)
        #endif
        guard let device = selectedDevice,
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration(); AppLog.event("camera_error", ["stage": "input"])
            DispatchQueue.main.async { self.onFailure?("No camera available") }; return
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration(); AppLog.event("camera_error", ["stage": "output"])
            DispatchQueue.main.async { self.onFailure?("Camera output unavailable") }; return
        }
        session.addOutput(output)
        if let connection = output.connection(with: .video) {
            #if os(macOS)
            if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
            #else
            if #available(iOS 17.0, *) {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            } else if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
            #endif
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = front }
        }
        session.commitConfiguration()
        let configured = ProcessInfo.processInfo.systemUptime
        session.startRunning()
        running = session.isRunning
        let now = ProcessInfo.processInfo.systemUptime
        AppLog.event("camera_running", ["running": "\(session.isRunning)", "front": "\(front)", "preset": session.sessionPreset.rawValue,
                                        "configureMs": "\(Int((configured - started) * 1000))", "startRunningMs": "\(Int((now - configured) * 1000))"])
    }

    func requestKeyFrame() { queue.async { self.forceKeyFrame = true } }
    func setBitrate(kbps: Int) { queue.async { self.encoder?.setBitrate(kbps: kbps); self.bitrateKbps = kbps } }

    /// Resolution ladder: a new frame size (no larger than the call header). The encoder restarts, so the first
    /// frame at the new size is a keyframe; receivers follow it in-band.
    func setResolution(width: Int, height: Int) {
        queue.async {
            guard width != self.width || height != self.height else { return }
            do {
                self.encoder = try VP9Encoder(width: width, height: height, fps: self.fps, bitrateKbps: self.bitrateKbps, threads: 2, speed: 8)
                self.width = width; self.height = height; self.forceKeyFrame = true
            } catch {
                AppLog.event("camera_error", ["stage": "resize", "error": "\(error)"])
            }
        }
    }
    func flip() { queue.async { self.front.toggle(); self.forceKeyFrame = true; self.configure() } }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        queue.async { self.session.stopRunning(); self.encoder = nil; self.running = false }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        capturedFrames += 1
        guard now - lastFrameUptime >= 1.0 / Double(fps) * 0.9, let encoder else { skippedFrames += 1; return }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              let picture = PixelConversion.i420(from: pixels, width: width, height: height) else { conversionFailures += 1; return }
        lastFrameUptime = now
        let pts = Int64((now - startUptime) * 1_000_000)
        do {
            guard let frame = try encoder.encode(picture, presentationTimeUs: pts, forceKeyFrame: forceKeyFrame) else { return }
            forceKeyFrame = false
            encodedFrames += 1; encodedBytes += frame.data.count
            let flags: UInt8 = frame.keyFrame ? StreamProtocol.flagKeyFrame : 0
            DispatchQueue.main.async { self.onFrame?(flags, pts, frame.data) }
        } catch {
            encodeErrors += 1
            if encodeErrors <= 3 { AppLog.event("camera_error", ["stage": "encode", "error": "\(error)"]) }
            DispatchQueue.main.async { self.onFailure?("\(error)") }
        }
    }
}

/// Decoded remote video, shown with AVSampleBufferDisplayLayer and rotated clockwise as the BTV3 header says.
final class VideoSurface: PlatformVideoView {
    let displayLayer = AVSampleBufferDisplayLayer()
    var rotation = 0 {
        didSet {
            #if os(macOS)
            needsLayout = true
            #else
            setNeedsLayout()
            #endif
        }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
        #if os(macOS)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.addSublayer(displayLayer)
        #else
        backgroundColor = .black; clipsToBounds = true
        layer.addSublayer(displayLayer)
        #endif
    }
    required init?(coder: NSCoder) { fatalError() }

    #if os(macOS)
    override func layout() { super.layout(); layoutVideo() }
    #else
    override func layoutSubviews() { super.layoutSubviews(); layoutVideo() }
    #endif

    private func layoutVideo() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        displayLayer.setAffineTransform(.identity)
        #if os(macOS)
        let layout = DesktopVideoLayout(bounds: bounds, clockwiseDegrees: rotation)
        displayLayer.bounds = layout.layerBounds
        displayLayer.position = layout.position
        displayLayer.setAffineTransform(layout.transform)
        #else
        let b = bounds, turned = rotation % 180 != 0
        displayLayer.bounds = turned ? CGRect(x: 0, y: 0, width: b.height, height: b.width) : CGRect(origin: .zero, size: b.size)
        displayLayer.position = CGPoint(x: b.midX, y: b.midY)
        displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(rotation) * .pi / 180))
        #endif
        CATransaction.commit()
    }

    func show(_ pixels: CVPixelBuffer) {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format) == noErr, let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary], let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sample)
    }
}

/// Holds the surface so models can push frames without SwiftUI re-rendering per frame.
final class VideoSink: ObservableObject {
    let surface = VideoSurface(frame: .zero)
    @Published var hasVideo = false
    @Published var rotation = 0
    @Published var aspect: CGFloat = 9.0 / 16.0
    func show(_ pixels: CVPixelBuffer) {
        surface.show(pixels)
        let w = CGFloat(CVPixelBufferGetWidth(pixels)), h = CGFloat(CVPixelBufferGetHeight(pixels))
        let a = rotation % 180 == 0 ? w / h : h / w
        if !hasVideo { hasVideo = true }
        if abs(a - aspect) > 0.01 { aspect = a }
    }
    func clear() { surface.displayLayer.flushAndRemoveImage(); hasVideo = false }
}

#if os(iOS)
struct VideoSurfaceView: UIViewRepresentable {
    @ObservedObject var sink: VideoSink
    func makeUIView(context: Context) -> VideoSurface { sink.surface }
    func updateUIView(_ view: VideoSurface, context: Context) { view.rotation = sink.rotation }
}

/// Live camera preview for the sender.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView { let v = PreviewView(); v.previewLayer.session = session; v.previewLayer.videoGravity = .resizeAspectFill; return v }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

#else
struct VideoSurfaceView: NSViewRepresentable {
    @ObservedObject var sink: VideoSink
    func makeNSView(context: Context) -> VideoSurface { sink.surface }
    func updateNSView(_ view: VideoSurface, context: Context) { view.rotation = sink.rotation }
}

struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer = preview
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVCaptureVideoPreviewLayer)?.session = session
    }
}
#endif
