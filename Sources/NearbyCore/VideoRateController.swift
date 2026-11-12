import Foundation

/// Sender-side video rate control from what the link actually carries (Android adapts its call encoder the
/// same way: "sending X of 300 kbps ... delivered ... peer queue"). Measured on an iPhone 14 Plus -> M31 GATT
/// call: the iPhone encoded ~240 kbps of VP9 while the GATT client direction delivered ~125-135 kbps, so
/// video waited longer and longer in the send queue (receiver lateness grew to 3.9 s; a third of the frames
/// were still queued when the call ended). Each window compares the queue age and the delivered video rate
/// with what the encoder produced, and moves the encoder target: down below the delivered rate when a backlog
/// builds, and up slowly while the queue stays near empty. Requested maximum and a floor bound it.
public struct VideoRateController {
    public let maxKbps: Int
    public let minKbps: Int
    public private(set) var targetKbps: Int
    private var calmWindows = 0

    public init(startKbps: Int, maxKbps: Int, minKbps: Int = 48) {
        self.maxKbps = maxKbps; self.minKbps = min(minKbps, maxKbps)
        targetKbps = max(self.minKbps, min(maxKbps, startKbps))
    }

    /// One measurement window (about 1 s). Returns the new encoder target when it changes.
    /// - Parameters:
    ///   - queueAge: age of the oldest unsent video frame at the end of the window.
    ///   - encodedKbps: video bitrate the encoder produced in the window.
    ///   - deliveredKbps: video bitrate handed to the transport in the window.
    public mutating func update(queueAge: TimeInterval, encodedKbps: Double, deliveredKbps: Double) -> Int? {
        // No evidence: the encoder barely produced (camera starting, app stalled or backgrounded). Measured case:
        // a 9 s main-queue stall gave encoded 5 / delivered 4 kbps and drove the target to the floor.
        guard encodedKbps >= max(8, Double(targetKbps) * 0.2) else { calmWindows = 0; return nil }
        var next = targetKbps
        let backlog = queueAge > 0.5 || (queueAge > 0.25 && deliveredKbps < encodedKbps * 0.9)
        if backlog {
            // Aim below what actually got through, lower still when the backlog is already long.
            let basis = deliveredKbps > 1 ? deliveredKbps : Double(targetKbps) * 0.5
            let drain = queueAge > 1 ? 0.7 : 0.85
            next = Int(min(Double(targetKbps) * 0.85, basis * drain))
            calmWindows = 0
        } else if queueAge < 0.15 {
            calmWindows += 1
            if calmWindows >= 2 { next = Int(Double(targetKbps) * 1.08) + 4; calmWindows = 0 }
        } else {
            calmWindows = 0
        }
        next = max(minKbps, min(maxKbps, next))
        guard next != targetKbps else { return nil }
        targetKbps = next
        return next
    }
}

// MARK: - Video quality (Android Settings › Video quality and Manual video)

/// What the user asked to send (Android `VideoSettings`): 240p, 360p or 480p, 15, 24 or 30 FPS, 100 kbps up in 25 kbps
/// steps. Kept exactly as chosen; what lowers it for one call or broadcast (the other device's limit, a relayed route,
/// the link, heat) is shown beside it and never written back.
public struct VideoRequest: Equatable {
    /// The short side: 240, 360 or 480 (Android `VideoSettings.RESOLUTIONS`).
    public let lines: Int
    public let fps: Int
    public let kbps: Int

    public static let lineOptions = [240, 360, 480]
    /// Android `VideoSettings.FPS_OPTIONS`.
    public static let fpsOptions = [15, 24, 30]
    public static let minKbps = 100
    public static let stepKbps = 25
    /// Android `VideoSettings.MAX_BIT_RATE_KBPS`.
    public static let absoluteMaxKbps = 1_500
    /// Design decision 2026-10-10, as Android: 426x240 (sent portrait 240x426) at 15 FPS, 200 kbps (`MediaDefaults`).
    public static let standard = VideoRequest(checked: 240, fps: 15, kbps: 200)

    private init(checked lines: Int, fps: Int, kbps: Int) { self.lines = lines; self.fps = fps; self.kbps = kbps }

    /// A request from stored or chosen values; nil when a value is not one Android offers.
    public init?(lines: Int, fps: Int, kbps: Int) {
        guard Self.lineOptions.contains(lines), Self.fpsOptions.contains(fps),
              (Self.minKbps...Self.absoluteMaxKbps).contains(kbps), (kbps - Self.minKbps) % Self.stepKbps == 0 else { return nil }
        self.init(checked: lines, fps: fps, kbps: kbps)
    }

    /// The long side of Android's 16:9 sizes (426, 640, 854).
    public static func longSide(_ lines: Int) -> Int {
        switch lines {
        case 360: return 640
        case 480: return 854
        default: return 426
        }
    }
    /// Apple sends portrait, short side first (240x426 as `MediaDefaults`).
    public var width: Int { lines }
    public var height: Int { Self.longSide(lines) }
    /// Android's picker text: "426×240 (240p)".
    public static func resolutionTitle(_ lines: Int) -> String { "\(longSide(lines))\u{00D7}\(lines) (\(lines)p)" }

    /// The bitrate slider's end (Android `bitrateSliderMaximumKbps`: the transport maximum,
    /// `MeshTransport.maxVideoBitrateKbps` GATT 1100 and L2CAP CoC 1200, or the current request when that is higher, so a
    /// stored value is never cut).
    public static func sliderMaxKbps(_ transport: MeshTransport, current: Int) -> Int { max(Int(transport.maxVideoBitrateKbps), current) }

    /// One line for a size, frame rate and bitrate: "240x426 · 15 FPS · 200 kbps".
    public static func line(width: Int, height: Int, fps: Int, kbps: Int) -> String {
        "\(width)x\(height) \u{00B7} \(fps) FPS \u{00B7} \(kbps) kbps"
    }
}

/// Android "Lower quality when hot" (`ThermalGuardPolicy`) on Apple's thermal states (`ProcessInfo.ThermalState` raw
/// values: 0 nominal, 1 fair, 2 serious, 3 critical). Android keeps 90 % at MODERATE and 80 % at SEVERE; Apple asks apps
/// to lower frame rates from `serious` and to cut work further at `critical`, so both give 80 % and fair keeps 100 %.
/// At `critical` video stops either way (`ThermalVideoState.blocksVideo`, Android `shouldBlockStreaming`).
public enum ThermalVideoPolicy {
    public static func percent(thermalState: Int, reduction: Bool) -> Int {
        guard reduction else { return 100 }
        return thermalState >= 2 ? 80 : 100
    }

    /// Android `scale`: rounded, at least 1, never above the value.
    public static func scaled(_ value: Int, percent: Int) -> Int {
        guard value > 0 else { return value }
        return min(value, max(1, (value * percent + 50) / 100))
    }
}

/// Android "Warn when video freezes" (`ViewerFrameAge`, Experimental, off): the viewer's picture is stale after the
/// larger of 1.5 s and three frame intervals without a new picture. Counted on this device from its last picture; it is
/// not the delay from the camera.
public enum ViewerFreeze {
    public static let minStaleMs = 1_500

    public static func thresholdMs(fps: Int) -> Int { max(minStaleMs, 3 * 1_000 / max(1, fps)) }

    /// How long the picture has been frozen, or nil while it is fine. `sinceMs` is the later of the last picture and the
    /// last resume (nil before the first picture); `quiet` is true while paused, with the camera off or after the end.
    public static func stalledMs(nowMs: Int, sinceMs: Int?, fps: Int, quiet: Bool) -> Int? {
        guard !quiet, let since = sinceMs else { return nil }
        let gap = nowMs - since
        return gap > thresholdMs(fps: fps) ? gap : nil
    }

    /// Android `ViewerFrameAgeText.age`: "<1 s", "3.2 s", "1 min 05 s" (tenths rounded down so a rising age never reads ahead).
    public static func ageText(_ ms: Int) -> String {
        let safe = max(0, ms)
        if safe < 1_000 { return "<1 s" }
        if safe < 60_000 { return String(format: "%.1f s", Double(safe / 100) / 10.0) }
        return String(format: "%d min %02d s", safe / 60_000, safe / 1_000 % 60)
    }

    public static let stalledTitle = "Picture stalled \u{2014} waiting"
    public static func lastPicture(_ ms: Int) -> String { "Last picture \(ageText(ms)) ago" }
}

/// Android Calls › Nearby search (`NearbyPeopleSession`): the field shows with more than 8 people nearby or a typed
/// search; a row stays when its shown name contains the text, ignoring case.
public enum NearbySearch {
    public static func showsField(people: Int, query: String) -> Bool { people > 8 || !query.isEmpty }

    public static func matches(_ name: String, query: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespaces)
        return term.isEmpty || name.range(of: term, options: .caseInsensitive) != nil
    }
}

/// Call info › Video: why what is sent differs from what was requested (one plain line per reason, none when equal).
/// `transportCapKbps` is Android's per-transport call budget with Manual video on (`CallTransportCap`), nil otherwise.
public enum CallVideoNotes {
    public static func notes(requestedKbps: Int, startKbps: Int, relayed: Bool, sendingKbps: Int?, heatPercent: Int,
                             manual: Bool, mac: Bool, transportCapKbps: Int? = nil, transport: MeshTransport = .gatt) -> [String] {
        var notes: [String] = []
        let budget = CallTransportCap.startKbps(requested: requestedKbps, cap: transportCapKbps)
        if budget < requestedKbps { notes.append(CallTransportCap.note(cap: budget, transport: transport)) }
        if startKbps < budget {
            notes.append(relayed ? "Calls through other phones send at most \(startKbps) kbps."
                                 : "The other device accepts at most \(startKbps) kbps.")
        }
        if heatPercent < 100 { notes.append(mac ? "Lowered while this Mac is hot." : "Lowered while this phone is hot.") }
        if manual {
            notes.append("Manual video settings: nothing adapts to the link.")
        } else if let sending = sendingKbps, sending < ThermalVideoPolicy.scaled(startKbps, percent: heatPercent) {
            notes.append("Lowered to what the link delivers.")
        }
        return notes
    }
}

// MARK: - Video follow-ups (Android critical heat stop, call transport budget, remote call video fit)

/// Android "Video stops if the phone gets too hot" (`ThermalGuardPolicy.shouldBlockStreaming`) and the 30 s restore of
/// Lower quality when hot (`THERMAL_RECOVERY_DELAY_MS`). Thermal states are `ProcessInfo.ThermalState` raw values.
public struct ThermalVideoState {
    public static let criticalState = 3
    public static let restoreDelayMs = 30_000
    /// The current limit in percent of the requested FPS and bitrate.
    public private(set) var percent = 100
    private var coolerSinceMs: Int?

    public init() {}

    /// True while video must stop and may not start: `critical`, with Lower quality when hot on or off. `enabled` false
    /// is the DEBUG control arm (`-thermalCriticalStop NO`).
    public static func blocksVideo(thermalState: Int, enabled: Bool = true) -> Bool { enabled && thermalState >= criticalState }

    /// Calls at critical heat (decision 2026-11-06, every platform): heat never refuses a call, only its video. A call
    /// placed or answered while video is blocked goes on as voice; a voice call is unchanged.
    public static func callType(_ requested: CallType, videoBlocked: Bool) -> CallType { videoBlocked ? .voice : requested }

    /// A hotter state (or the switch turned off) applies at once; a cooler one only after 30 s at that state.
    public mutating func update(thermalState: Int, reduction: Bool, nowMs: Int) -> Int {
        let target = ThermalVideoPolicy.percent(thermalState: thermalState, reduction: reduction)
        if !reduction || target <= percent { percent = target; coolerSinceMs = nil; return percent }
        let since = coolerSinceMs ?? nowMs
        coolerSinceMs = since
        if nowMs - since >= Self.restoreDelayMs { percent = target; coolerSinceMs = nil }
        return percent
    }
}

/// Android `privateCallVideoSettings`: with Manual video settings on (exact rate control) a call starts at most at the
/// transport's per-direction budget, GATT 180 and L2CAP CoC 200 kbps (Classic 250 has no Apple transport). With it off
/// the request is kept and rate control follows the link (Android `preserveSelectedBitrate`). The request is never
/// changed; call info and Connection show the cap.
public enum CallTransportCap {
    public static func kbps(_ transport: MeshTransport) -> Int { transport == .l2cap ? 200 : 180 }

    /// The budget for a new call, or nil when it does not apply. `enabled` false is the DEBUG control arm
    /// (`-callTransportCap NO`).
    public static func cap(transport: MeshTransport, manual: Bool, enabled: Bool) -> Int? {
        enabled && manual ? kbps(transport) : nil
    }

    /// What a new call starts with: the request, or the budget when that is lower (never above the request).
    public static func startKbps(requested: Int, cap: Int?) -> Int { cap.map { min(requested, $0) } ?? requested }

    /// Android's transport names without "Android only".
    public static func transportName(_ transport: MeshTransport) -> String {
        transport == .l2cap ? "Bluetooth LE (L2CAP CoC)" : "Bluetooth LE (GATT)"
    }

    public static func note(cap: Int, transport: MeshTransport) -> String { "Limited to \(cap) kbps on \(transportName(transport))." }
}

/// Android `RemoteVideoFit` (on; DEBUG control arm `-remoteVideoFit NO`): in a call the other person's video fills the
/// view when the shapes are close, and is shown whole with black bars when they differ strongly (longer over shorter
/// aspect 1.8 or more) or one is landscape and the other portrait (beyond 1.15 of square). A double-tap flips it for the
/// rest of the call; Fill screen with video off always shows the whole picture. Presentation only.
public enum RemoteVideoFit {
    public static let strongMismatch = 1.8
    public static let nearSquare = 1.15

    /// True = fill (edges cropped), false = the whole picture. `videoAspect` is width / height as displayed (after the
    /// sender's rotation).
    public static func automaticFill(videoAspect: Double, viewWidth: Double, viewHeight: Double) -> Bool {
        guard viewWidth > 0, viewHeight > 0, videoAspect > 0 else { return true }
        let viewAspect = viewWidth / viewHeight
        if max(videoAspect / viewAspect, viewAspect / videoAspect) >= strongMismatch { return false }
        let opposite = (videoAspect >= nearSquare && viewAspect <= 1 / nearSquare)
            || (videoAspect <= 1 / nearSquare && viewAspect >= nearSquare)
        return !opposite
    }

    /// What to draw: the rule off = the Fill setting alone; this call's double-tap choice wins; Fill off = whole picture.
    public static func fill(enabled: Bool, fillSetting: Bool, override: Bool?, videoAspect: Double,
                            viewWidth: Double, viewHeight: Double) -> Bool {
        guard enabled else { return fillSetting }
        if let override { return override }
        guard fillSetting else { return false }
        return automaticFill(videoAspect: videoAspect, viewWidth: viewWidth, viewHeight: viewHeight)
    }
}
