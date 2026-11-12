import Foundation
import AVFoundation
import AudioToolbox

/// Incoming-call ringer. It uses the `.ambient` audio session category, so the Ring/Silent switch silences it
/// like any iPhone ringtone; it vibrates every cycle (iOS applies the user's "vibrate on silent" setting).
/// Focus modes govern notifications, which MeshLive does not use while open; CallKit (planned) would make
/// Focus and the system ringer apply fully. The tone is generated (two-tone 440 + 480 Hz, ring-ring, pause).
final class Ringer {
    private var player: AVAudioPlayer?
    private var vibration: Timer?
    private(set) var ringing = false

    func start() {
        guard !DesktopPreview.enabled else { return }
        guard !ringing else { return }
        ringing = true
        #if os(iOS)
        // Session changes can block for a few hundred ms (Android saw 288-453 ms on route reads): never on the main
        // thread, and ordered with call audio on its control queue. The tone starts only after the ambient category
        // is in place, so the Ring/Silent switch applies to it.
        CallAudio.onAudioControl {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.ambient, mode: .default, options: [])
            try? session.setActive(true)
            let category = session.category.rawValue
            DispatchQueue.main.async { [weak self] in
                guard let self, self.ringing else { return }
                self.startTone()
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                self.vibration = Timer.scheduledTimer(withTimeInterval: Ringer.period, repeats: true) { _ in AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
                AppLog.event("ringer", ["state": "start", "silentSwitchRespected": "\(category == AVAudioSession.Category.ambient.rawValue)", "category": category])
            }
        }
        #else
        startTone()
        AppLog.event("ringer", ["state": "start"])
        #endif
    }

    private func startTone() {
        guard let player = try? AVAudioPlayer(data: Ringer.tone) else { return }
        player.numberOfLoops = -1
        player.volume = LabSwitch.playbackGain()
        player.play()
        self.player = player
        if LabSwitch.isDebugBuild { AppLog.info("playback_gain: applied=\(LabSwitch.playbackGain()) | path=ringer") }
    }

    func stop() {
        guard ringing else { return }
        ringing = false
        player?.stop(); player = nil
        vibration?.invalidate(); vibration = nil
        AppLog.event("ringer", ["state": "stop"])
    }

    static let period: TimeInterval = 3

    /// 3 s of 16-bit mono 16 kHz PCM in a WAV container: 0.4 s tone, 0.2 s gap, 0.4 s tone, 2 s silence.
    static let tone: Data = {
        let rate = 16_000
        var samples = [Int16](repeating: 0, count: Int(period * Double(rate)))
        for (start, length) in [(0.0, 0.4), (0.6, 0.4)] {
            let first = Int(start * Double(rate)), count = Int(length * Double(rate))
            for i in 0..<count {
                let t = Double(i) / Double(rate)
                let envelope = min(1, min(t, length - t) / 0.01)          // 10 ms fades, no clicks
                let value = 0.35 * envelope * (sin(2 * .pi * 440 * t) + sin(2 * .pi * 480 * t)) / 2
                samples[first + i] = Int16(value * Double(Int16.max))
            }
        }
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let payload = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + payload)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(payload))
        for s in samples { withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }()
}

/// Outgoing ringback (Android `CallRinger.startRingback`, on with no Settings row; DEBUG control arm `-ringback NO`):
/// while the other device rings, the caller hears a ringing tone instead of silence; any other call phase stops it.
/// Android plays `ToneGenerator.TONE_SUP_RINGTONE` on the voice-call stream (earpiece) for a voice call and on the music
/// stream (loudspeaker) for a video call (`RingbackPolicy`). Here the tone is generated (no audio file) and plays on the
/// call's own route: the earpiece unless the speaker is on. DEBUG `-NearbyPlaybackGain 0.01` plays it at that fraction
/// (the owner's test volume rule, as Android `test_playback_gain`). Nothing is recorded.
final class Ringback {
    private var player: AVAudioPlayer?
    private(set) var playing = false
    /// This ringback activated the call audio session; `release()` gives it back when no call audio followed.
    private var sessionTaken = false

    func start(speaker: Bool) {
        guard !DesktopPreview.enabled, !playing else { return }
        playing = true
        #if os(iOS)
        sessionTaken = true
        // On the audio control queue, in order with call audio (session changes can block). The call's own audio
        // bring-up later sets the same category, so the ringback never deactivates the session while a call goes on.
        CallAudio.onAudioControl {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playAndRecord, mode: speaker ? .videoChat : .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP])
            try? session.setActive(true)
            try? session.overrideOutputAudioPort(speaker ? .speaker : .none)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.playing else { return }
                self.play(speaker: speaker)
            }
        }
        #else
        play(speaker: speaker)
        #endif
    }

    private func play(speaker: Bool) {
        guard let player = try? AVAudioPlayer(data: Ringback.tone) else { return }
        player.numberOfLoops = -1
        player.volume = Ringback.gain
        player.play()
        self.player = player
        AppLog.event("ringback", ["state": "start", "speaker": "\(speaker)", "gain": "\(Ringback.gain)"])
        if LabSwitch.isDebugBuild { AppLog.info("playback_gain: applied=\(Ringback.gain) | path=ringback") }
    }

    func stop() {
        guard playing else { return }
        playing = false
        player?.stop(); player = nil
        AppLog.event("ringback", ["state": "stop"])
    }

    /// The call ended before its own audio started: give the session back so other apps' sound resumes.
    func release() {
        #if os(iOS)
        guard sessionTaken else { return }
        sessionTaken = false
        CallAudio.onAudioControl { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        #endif
    }

    /// DEBUG `-NearbyPlaybackGain <0...1>`; release builds play at full player volume under the system volume.
    static var gain: Float { LabSwitch.playbackGain() }

    /// 5 s of 16-bit mono 16 kHz PCM in a WAV container: 1 s of 425 Hz, then 4 s of silence (the CEPT ringing tone AOSP
    /// `ToneGenerator` plays for `TONE_SUP_RINGTONE` by default), with 10 ms fades.
    static let tone: Data = {
        let rate = 16_000, length = 1.0
        var samples = [Int16](repeating: 0, count: 5 * rate)
        for i in 0..<Int(length * Double(rate)) {
            let t = Double(i) / Double(rate)
            let envelope = min(1, min(t, length - t) / 0.01)
            samples[i] = Int16(0.35 * envelope * sin(2 * .pi * 425 * t) * Double(Int16.max))
        }
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let payload = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + payload)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(payload))
        for s in samples { withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }()
}
