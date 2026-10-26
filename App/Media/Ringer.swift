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
        // thread, and ordered with call audio on its control queue.
        CallAudio.onAudioControl {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.ambient, mode: .default, options: [])
            try? session.setActive(true)
        }
        #endif
        if let player = try? AVAudioPlayer(data: Ringer.tone) {
            player.numberOfLoops = -1
            player.volume = 1
            player.play()
            self.player = player
        }
        #if os(iOS)
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        vibration = Timer.scheduledTimer(withTimeInterval: Ringer.period, repeats: true) { _ in AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
        AppLog.event("ringer", ["state": "start", "silentSwitchRespected": "true", "category": AVAudioSession.Category.ambient.rawValue])
        #else
        AppLog.event("ringer", ["state": "start"])
        #endif
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
