/// B1.3 (Android `CallMediaAccess`): after the system permission question, one decision says whether the call goes on,
/// goes on as voice (only the camera refused, answering or placing), or does not go on and says what is missing.
public enum CallMediaAccess {
    public enum Use: Equatable { case answer, place, cameraOn }
    /// The order in which refused needs are named.
    public enum Need: Equatable { case camera, microphone }
    public enum Step: Equatable { case proceed, voiceInstead, tell }

    public struct Access: Equatable {
        public let granted: Bool
        /// iOS asks once: false for denied and restricted, true for a prompt that was interrupted (notDetermined).
        public let canAskAgain: Bool
        /// Parental controls: Settings cannot lift it, so no Open settings button.
        public let restricted: Bool

        public init(granted: Bool, canAskAgain: Bool = true, restricted: Bool = false) {
            self.granted = granted; self.canAskAgain = canAskAgain; self.restricted = restricted
        }
    }

    public struct Outcome: Equatable {
        public let step: Step
        public let missing: [Need]
        public let opensSettings: Bool

        public init(step: Step, missing: [Need], opensSettings: Bool) {
            self.step = step; self.missing = missing; self.opensSettings = opensSettings
        }
    }

    /// The camera counts only when video is asked for (or "Camera on" is pressed); a refused microphone is never a reason
    /// to answer, only something to say. `voiceWhenCameraRefused` is the promoted switch; with it off the camera-only
    /// refusal is told like every other.
    public static func decide(use: Use, video: Bool, camera: Access, microphone: Access,
                              voiceWhenCameraRefused: Bool) -> Outcome {
        var missing: [Need] = []
        if (use == .cameraOn || video) && !camera.granted { missing.append(.camera) }
        if use != .cameraOn && !microphone.granted { missing.append(.microphone) }
        guard !missing.isEmpty else { return Outcome(step: .proceed, missing: [], opensSettings: false) }
        if voiceWhenCameraRefused, missing == [.camera], use == .answer || use == .place {
            return Outcome(step: .voiceInstead, missing: missing, opensSettings: false)
        }
        let opensSettings = missing.contains { need in
            let access = need == .camera ? camera : microphone
            return !access.canAskAgain && !access.restricted
        }
        return Outcome(step: .tell, missing: missing, opensSettings: opensSettings)
    }

    /// B1F step 1: what "Camera on" does in a call. A prompt that was interrupted (canAskAgain) is asked again once;
    /// only denied (Settings can change it) or restricted (it cannot) tells the user.
    public enum CameraOnAction: Equatable { case request, start, tell(opensSettings: Bool) }

    public static func cameraOn(_ camera: Access) -> CameraOnAction {
        if camera.granted { return .start }
        if camera.canAskAgain { return .request }
        return .tell(opensSettings: !camera.restricted)
    }

    /// Android `call_media_needed_answer` / `_place` / `_camera_on`, with the names joined as Android's list separators.
    public static func text(use: Use, missing: [Need]) -> String {
        let joined = MissingPermissions.join(missing.map { $0 == .camera ? "the camera" : "the microphone" })
        switch use {
        case .answer: return "MeshLive needs access to \(joined) to answer this call."
        case .place: return "MeshLive needs access to \(joined) to make this call."
        case .cameraOn: return "MeshLive needs access to \(joined) to turn your video on."
        }
    }

    /// Android `call_answered_voice_camera_off` / `call_placed_voice_camera_off`.
    public static func voiceNotice(use: Use) -> String {
        switch use {
        case .answer: return "Answered with voice: camera access is off"
        case .place: return "Calling with voice: camera access is off"
        case .cameraOn: return ""
        }
    }
}

/// Android `list_separator` (", ") and `list_last_separator` (" and ").
public enum MissingPermissions {
    public static func join(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        if names.count == 1 { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}
