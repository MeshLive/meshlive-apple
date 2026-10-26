import Foundation
import AVFoundation
import CoreBluetooth

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
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "undetermined"
        @unknown default: return "unknown"
        }
    }

    static func requestMicrophone(_ done: @escaping (Bool) -> Void) {
        let finish = { (granted: Bool) in DispatchQueue.main.async { done(granted) } }
        if DesktopPreview.enabled { finish(false); return }
        #if os(macOS)
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: finish)
        #else
        if #available(iOS 17.0, *) { AVAudioApplication.requestRecordPermission(completionHandler: finish) }
        else { AVAudioSession.sharedInstance().requestRecordPermission(finish) }
        #endif
    }

    static func requestCamera(_ done: @escaping (Bool) -> Void) {
        if DesktopPreview.enabled { DispatchQueue.main.async { done(false) }; return }
        AVCaptureDevice.requestAccess(for: .video) { granted in DispatchQueue.main.async { done(granted) } }
    }

    /// Requests the microphone, then the camera when `video`; calls back on the main queue.
    static func request(video: Bool, context: String, _ done: @escaping (_ microphone: Bool, _ camera: Bool) -> Void) {
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
