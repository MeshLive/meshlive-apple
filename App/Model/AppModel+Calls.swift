import Foundation
import NearbyCore

// Calls track (B1): AppModel code for calls goes here.

extension AppModel {
    /// B1.3: after the system asked, one decision: place as asked, place as voice when only the camera was refused, or
    /// place nothing and say what is missing above Nearby. The glare check stays first.
    func finishStartCall(to person: PersonRow, type: CallType, tappedAt: TimeInterval) {
        placingCall = false
        // Glare: the person being dialled called first while the permission question was open.
        if dialSuperseded { dialSuperseded = false; return }
        let voiceSwitch = AppSettings.labSwitch("callVoiceWhenCameraRefused", shipped: true)
        let outcome = CallMediaAccess.decide(use: .place, video: type == .video, camera: MediaPermissions.cameraAccess,
                                             microphone: MediaPermissions.microphoneAccess,
                                             voiceWhenCameraRefused: voiceSwitch)
        switch outcome.step {
        case .proceed:
            placeCall(to: person, type: type, tappedAt: tappedAt)
        case .voiceInstead:
            callAccessNotice = CallMediaAccess.voiceNotice(use: .place)
            callAccessNoticeOpensSettings = false
            logMediaRefusal(use: .place, video: type == .video, outcome: outcome, voiceWhenCameraRefused: voiceSwitch)
            placeCall(to: person, type: .voice, tappedAt: tappedAt)
        case .tell:
            callAccessNotice = CallMediaAccess.text(use: .place, missing: outcome.missing)
            callAccessNoticeOpensSettings = outcome.opensSettings
            logMediaRefusal(use: .place, video: type == .video, outcome: outcome, voiceWhenCameraRefused: voiceSwitch)
        }
    }

    private func logMediaRefusal(use: CallMediaAccess.Use, video: Bool, outcome: CallMediaAccess.Outcome,
                                 voiceWhenCameraRefused: Bool) {
        guard !outcome.missing.isEmpty else { return }
        let missing = outcome.missing.map { $0 == .camera ? "camera" : "microphone" }.joined(separator: "+")
        let useWord: String
        switch use {
        case .answer: useWord = "answer"
        case .place: useWord = "place"
        case .cameraOn: useWord = "cameraOn"
        }
        let step: String
        switch outcome.step {
        case .proceed: step = "proceed"
        case .voiceInstead: step = "voiceInstead"
        case .tell: step = "tell"
        }
        AppLog.event("call_media_refused", ["use": useWord, "video": "\(video)", "missing": missing, "step": step,
                                            "openSettings": "\(outcome.opensSettings)",
                                            "voiceWhenCameraRefused": "\(voiceWhenCameraRefused)"])
    }
}
