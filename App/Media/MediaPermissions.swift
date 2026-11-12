import Foundation
import AVFoundation
import CoreBluetooth
import NearbyCore

/// Microphone and camera permission, requested explicitly when a call starts or is answered (like Android's
/// runtime permission request at call start), so the system prompt appears before media begins and the
/// result is logged (`BENCHMARK permissions`).
enum MediaPermissions {
    static var microphone: String {
        #if os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "undetermined"
        @unknown default: return "unknown"
        }
        #else
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return "granted"
            case .denied: return "denied"
            case .undetermined: return "undetermined"
            @unknown default: return "unknown"
            }
        }
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown"
        }
        #endif
    }

    /// Read-only (never prompts); logged at launch so a rebuild shows whether macOS kept the Bluetooth permission.
    static var bluetooth: String {
        switch CBManager.authorization {
        case .allowedAlways: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "undetermined"
        @unknown default: return "unknown"
        }
    }

    static var camera: String {
        #if DEBUG
        if let forced = forcedCameraPermission { return cameraWord(forced) }
        #endif
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "undetermined"
        @unknown default: return "unknown"
        }
    }

    /// The scanner's camera state. The DEBUG fixture forces it for UI tests; a forced state never prompts.
    static var cameraPermission: QrScannerCamera {
        #if DEBUG
        if let forced = forcedCameraPermission { return forced }
        #endif
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    /// The decision's view of the two permissions; the DEBUG fixtures force both states.
    static var cameraAccess: CallMediaAccess.Access { access(cameraPermission) }

    static var microphoneAccess: CallMediaAccess.Access {
        #if DEBUG
        if let forced = forcedMicrophonePermission { return access(forced) }
        #endif
        switch microphone {
        case "granted": return CallMediaAccess.Access(granted: true, canAskAgain: false)
        case "undetermined": return CallMediaAccess.Access(granted: false, canAskAgain: true)
        case "restricted": return CallMediaAccess.Access(granted: false, canAskAgain: false, restricted: true)
        default: return CallMediaAccess.Access(granted: false, canAskAgain: false)
        }
    }

    private static func access(_ camera: QrScannerCamera) -> CallMediaAccess.Access {
        switch camera {
        case .authorized: return CallMediaAccess.Access(granted: true, canAskAgain: false)
        case .notDetermined: return CallMediaAccess.Access(granted: false, canAskAgain: true)
        case .denied: return CallMediaAccess.Access(granted: false, canAskAgain: false)
        case .restricted: return CallMediaAccess.Access(granted: false, canAskAgain: false, restricted: true)
        case .unknown: return CallMediaAccess.Access(granted: false, canAskAgain: false)
        }
    }

    #if DEBUG
    private static var forcedCameraPermission: QrScannerCamera? {
        RootView.debugArgument("-NearbyFixtureCameraPermission").flatMap(QrScannerCamera.init(fixture:))
    }

    private static var forcedMicrophonePermission: QrScannerCamera? {
        RootView.debugArgument("-NearbyFixtureMicrophonePermission").flatMap(QrScannerCamera.init(fixture:))
    }

    private static func cameraWord(_ camera: QrScannerCamera) -> String {
        switch camera {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "undetermined"
        case .unknown: return "unknown"
        }
    }
    #endif

    static func requestMicrophone(_ done: @escaping (Bool) -> Void) {
        let finish = { (granted: Bool) in DispatchQueue.main.async { done(granted) } }
        #if DEBUG
        if let forced = forcedMicrophonePermission { finish(forced == .authorized); return }
        #endif
        if DesktopPreview.enabled { finish(false); return }
        #if os(macOS)
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: finish)
        #else
        if #available(iOS 17.0, *) { AVAudioApplication.requestRecordPermission(completionHandler: finish) }
        else { AVAudioSession.sharedInstance().requestRecordPermission(finish) }
        #endif
    }

    static func requestCamera(_ done: @escaping (Bool) -> Void) {
        #if DEBUG
        if let forced = forcedCameraPermission { DispatchQueue.main.async { done(forced == .authorized) }; return }
        #endif
        if DesktopPreview.enabled { DispatchQueue.main.async { done(false) }; return }
        AVCaptureDevice.requestAccess(for: .video) { granted in DispatchQueue.main.async { done(granted) } }
    }

    /// Requests the microphone, then the camera when `video`; calls back on the main queue.
    static func request(video: Bool, context: String, _ done: @escaping (_ microphone: Bool, _ camera: Bool) -> Void) {
        #if DEBUG
        // UI fixtures: the forced states are what `decide` reads, and the system is never asked.
        if forcedMicrophonePermission != nil || forcedCameraPermission != nil {
            let mic = forcedMicrophonePermission.map { $0 == .authorized } ?? (microphone == "granted")
            let cam = forcedCameraPermission.map { $0 == .authorized } ?? (camera == "granted")
            AppLog.event("permissions", ["context": context, "microphone": mic ? "granted" : "denied",
                                         "camera": cam ? "granted" : "denied", "fixture": "1"])
            DispatchQueue.main.async { done(mic, cam) }
            return
        }
        #endif
        let micBefore = microphone, cameraBefore = camera
        requestMicrophone { mic in
            let finish = { (cam: Bool) in
                AppLog.event("permissions", ["context": context, "microphone": mic ? "granted" : "denied", "microphoneBefore": micBefore,
                                             "camera": video ? (cam ? "granted" : "denied") : camera, "cameraBefore": cameraBefore,
                                             "videoRequested": "\(video)"])
                done(mic, cam)
            }
            if video { requestCamera(finish) } else { finish(camera == "granted") }
        }
    }
}
