import Foundation

/// A failure in this device's own call media pipeline that reconnecting cannot repair (Android
/// `LocalMediaPipelineException`: decoder setup and the audio decode/playback pipeline). The call hangs up with an
/// error reason (`CallEngine.endForLocalMediaFailure`), so the other phone sees "Their phone had a problem and ended
/// the call" instead of a silent call or a lost link. Microphone and camera problems are not in this set: the call
/// goes on with a notice, as on Android.
public enum LocalMediaFailure: String, Equatable {
    /// Call audio could not start or restart: no session, no Opus codec or no running playback engine.
    case audioPlayback = "audio_playback"
    /// Video arrived but this device could not create a decoder for the negotiated codec.
    case videoDecoderSetup = "video_decoder_setup"

    /// The reason shown on this device's call screen.
    public var message: String {
        switch self {
        case .audioPlayback: return "This phone's call audio stopped working"
        case .videoDecoderSetup: return "This phone couldn't show the video"
        }
    }

    /// iOS refusing the audio session because another app holds audio (a phone call, an alarm) or the app is in the
    /// background: contention, not a broken pipeline, so the call keeps its notice. AVAudioSession error codes
    /// `insufficientPriority` ('!pri'), `cannotInterruptOthers` ('!int') and `cannotStartPlaying` ('!pla').
    public static func isAudioSessionContention(domain: String, code: Int) -> Bool {
        domain == NSOSStatusErrorDomain && [0x2170_7269, 0x2169_6E74, 0x2170_6C61].contains(code)
    }
}
