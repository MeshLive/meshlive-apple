import SwiftUI
import NearbyCore
#if os(iOS)
import AVKit
#endif

/// Call screen (same structure as Android, FaceTime-like on iOS): always dark, full-bleed video, a scrim only
/// behind the controls, one name line and one state line. Encryption, route and verification live in the call info sheet behind the lock button; the
/// screen shows security text only when something is wrong (identity mismatch, loudly).
struct CallView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var call: CallController
    @ObservedObject private var sink: VideoSink
    @State private var showInfo = false
    @State private var controlsVisible = true
    @State private var lastInteraction = Date()
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    #if os(iOS)
    @StateObject private var route = AudioRouteWatcher()
    #endif

    init(call: CallController) { self.call = call; _sink = ObservedObject(wrappedValue: call.remote.sink) }

    private var showsVideo: Bool { sink.hasVideo && call.remoteCameraOn && call.phase == .active }

    var body: some View {
        ZStack {
            Palette.callGround.ignoresSafeArea()
            if showsVideo {
                // Android RemoteVideoFit: fill close shapes, show a strongly different one whole; a double-tap flips it
                // for this call. Fill screen with video off always shows the whole picture.
                GeometryReader { geo in
                    let fill = RemoteVideoFit.fill(enabled: AppSettings.remoteVideoFit, fillSetting: model.videoFill,
                                                   override: call.remoteFitOverride, videoAspect: Double(sink.aspect),
                                                   viewWidth: Double(geo.size.width), viewHeight: Double(geo.size.height))
                    VideoSurfaceView(sink: sink, fill: fill)
                        .onTapGesture(count: 2) {
                            guard AppSettings.remoteVideoFit else { return }
                            call.remoteFitOverride = !fill
                            AppLog.event("call_remote_fit", ["fill": "\(!fill)"])
                        }
                        .onTapGesture { controlsVisible.toggle(); lastInteraction = Date() }
                        .accessibilityElement()
                        .accessibilityLabel("Their video")
                        .accessibilityAction(named: fill ? "Show the whole picture" : "Fill the screen") {
                            guard AppSettings.remoteVideoFit else { return }
                            call.remoteFitOverride = !fill
                        }
                        .accessibilityIdentifier("callRemoteVideo")
                }
                .ignoresSafeArea()
            } else {
                VStack(spacing: 20) {
                    Spacer()
                    // Accessibility text sizes need the room for the controls: a smaller disc.
                    let disc: CGFloat = typeSize.isAccessibilitySize ? 64 : 112
                    // At accessibility sizes the name line is enough; the disc would sit under the wrapped controls.
                    if !typeSize.isAccessibilitySize {
                        if let label = call.label { MonogramView(label: label, size: disc) }
                        else { Circle().fill(Palette.callControl).frame(width: disc, height: disc) }
                    }
                    Spacer(); Spacer()
                }
            }
            if typeSize.isAccessibilitySize {
                ScrollView { overlay }
            } else { overlay }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .sheet(isPresented: $showInfo) { NavigationStack { CallInfoSheet(call: call) }.desktopReadingSize() }
        .preferredColorScheme(.dark)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
            // Controls fade out after 4 s during video and come back on a tap.
            if showsVideo, !voiceOver, controlsVisible, !call.talking, !showHoldHint, now.timeIntervalSince(lastInteraction) > 4 { controlsVisible = false }
            if !showsVideo { controlsVisible = true }
        }
    }

    private var overlay: some View {
        VStack(spacing: 0) {
                if controlsVisible || !showsVideo || voiceOver { topBar.transition(.opacity) }
                if model.mismatchWarning != nil || call.verification == .mismatch { mismatchBanner }
                Spacer()
                if let camera = call.camera, call.cameraOn, call.phase == .active {
                    HStack { Spacer(); CameraPreviewView(session: camera.session).frame(width: 104, height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 6)).padding(.trailing, 16).padding(.bottom, 12) }
                }
                if controlsVisible || !showsVideo || voiceOver { bottomControls.transition(.opacity) }
            }
    }

    @State private var showHoldHint = false
    /// One-time hint, the first time the user mutes a call.
    private func maybeShowHoldHint() {
        guard call.muted, !AppSettings.holdMuteHintShown else { return }
        AppSettings.holdMuteHintShown = true
        withAnimation { showHoldHint = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { withAnimation { showHoldHint = false } }
    }

    private var stateLine: String {
        if let ended = call.ended { return ended }
        if call.onHold { return "On hold" }
        if call.talking { return "Talking\u{2026}" }
        if call.phase == .active, let since = call.activeSince {
            return TimelineFormatter.duration(Date().timeIntervalSince(since))
        }
        return call.phaseText.isEmpty ? "Connecting…" : call.phaseText
    }

    /// Android callTopBar: the name centred, the state line or timer under it, the lock (call info) at the right.
    private var topBar: some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: 48, height: 48).accessibilityHidden(true)
            VStack(alignment: .center, spacing: 4) {
                Group {
                    if let claimed = call.claimedName, call.label?.contactName == nil {
                        Text("~").foregroundColor(Palette.dimInk) + Text(claimed)
                    } else {
                        Text(call.label?.title ?? call.peerName)
                    }
                }
                .font(Typo.title).foregroundStyle(.white).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .multilineTextAlignment(.center)
                .accessibilityLabel(call.claimedNote.map { call.imitates == nil ? "calls itself \(call.claimedName ?? ""), not verified" : "\($0), calls itself \(call.claimedName ?? "")" } ?? (call.label?.title ?? call.peerName))
                if let note = call.claimedNote {
                    Text(note).font(Typo.caption).foregroundStyle(Palette.dimInk).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                        .accessibilityHidden(true)
                }
                // Android call_incoming_claims: on a ring, a self-chosen name is shown, never as checked.
                if call.phase == .incomingRinging, call.claimedNote != nil {
                    Text("calls itself, not checked").font(Typo.caption).foregroundStyle(Palette.dimInk)
                        .accessibilityHidden(true)
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(stateLine).font(Typo.timer).foregroundStyle(.white.opacity(0.75))
                }
                if call.phase == .incomingRinging, let notice = call.ringNotice {
                    Text(notice).font(Typo.caption).foregroundStyle(Palette.dimInk).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                // Android call_incoming_stranger_note: a stranger behind a throwaway key with no name of its own.
                if call.phase == .incomingRinging, call.ringNotice != nil, call.claimedName == nil {
                    Text("Not verified. A new call from the same phone shows a new name.").font(Typo.caption).foregroundStyle(Palette.dimInk)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                if call.remoteMuted && call.phase == .active {
                    Label("Their microphone is off", systemImage: "mic.slash.fill").font(Typo.caption).foregroundStyle(Palette.dimInk)
                }
                if let health = model.healthMessage, call.ended == nil {
                    Label(health, systemImage: "thermometer.medium").font(Typo.caption).foregroundStyle(Palette.accent).accessibilityIdentifier("callHealth")
                }
                if model.showTemperature, call.ended == nil {
                    Label(StatusSheet.health, systemImage: "thermometer.medium").font(Typo.caption).foregroundStyle(Palette.dimInk)
                        .accessibilityIdentifier("deviceTemperature")
                }
                if let problem = call.mediaProblem, call.ended == nil {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").font(Typo.caption).foregroundStyle(Palette.accent)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                if let notice = call.videoNotice, call.ended == nil {
                    Text(notice).font(Typo.caption).foregroundStyle(Palette.dimInk)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("callVideoNotice")
                }
                if let notice = call.accessNotice, call.ended == nil {
                    VStack(spacing: 8) {
                        Text(notice).font(Typo.caption).foregroundStyle(Palette.dimInk)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("callAccessNotice")
                        if call.accessNoticeOpensSettings {
                            Button { AppPlatform.openSettings() } label: {
                                Text("Open settings").font(Typo.caption.weight(.semibold)).foregroundStyle(.black)
                                    .padding(.horizontal, 12).padding(.vertical, 7).background(Color.white, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("callAccessSettings")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            if call.fingerprint != nil {
                Button { showInfo = true; lastInteraction = Date() } label: {
                    Image(systemName: call.verification == .verified ? "lock.shield.fill" : "lock.fill")
                        .font(.title3).frame(width: 48, height: 48)
                        .foregroundStyle(call.verification == .verified ? Palette.connected : Palette.ink)
                }
                .accessibilityLabel("Call info: encryption and verification")
            } else {
                Color.clear.frame(width: 48, height: 48).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 24)
        .background(showsVideo ? AnyView(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea()) : AnyView(Color.clear))
    }

    private var mismatchBanner: some View {
        Button { showInfo = true } label: {
            Label("This contact's ID has changed. Tap for details.", systemImage: "exclamationmark.octagon.fill")
                .font(Typo.secondary.weight(.semibold)).foregroundStyle(.black).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Inverted (white on black screen) instead of red: red is reserved for live.
                .background(Palette.ink, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.horizontal, 16)
    }

    // MARK: Android activeCallControls: Mute, Camera, End, Flip, Speaker; End in the middle; a control with nothing to
    // do keeps its slot (Flip is disabled while the camera is off), so End never moves.

    private var muteSlot: some View {
        MuteControl(call: call, size: 64) { lastInteraction = Date(); maybeShowHoldHint() }
    }

    private var cameraSlot: some View {
        // White while the video is off in a video call (Android "checked"); a voice call's Add video is never white.
        let off = !call.cameraOn && call.callType == .video
        // Android critical heat: video cannot start (turning it off always works).
        let tooHot = model.videoBlockedByHeat && !call.cameraOn
        return RoundControl(icon: call.cameraOn ? "video.fill" : "video.slash.fill",
                            label: call.cameraOn ? "Video off" : (call.callType == .voice ? "Add video" : "Video on"),
                            fill: off ? .white : Palette.callControl, foreground: off ? .black : .white, size: 64) {
            call.toggleCamera(); lastInteraction = Date()
        }
        .disabled(tooHot)
        .opacity(tooHot ? 0.5 : 1)
        .accessibilityHint(tooHot ? AppModel.tooHotText : (call.cameraOn ? "Turn your video off" : (call.callType == .voice ? "Turn on your video. The other person chooses whether to turn on theirs." : "Turn your video on")))
        .accessibilityIdentifier("callCamera")
    }

    private var endSlot: some View {
        RoundControl(icon: "phone.down.fill", label: "End", fill: Palette.callEnd, size: 72) { call.end() }
            .accessibilityHint("Ends the call")
            .accessibilityIdentifier("callEnd")
    }

    /// iPhone: the other lens, whenever the camera is on. Mac: the next camera, with two or more.
    private var flipAvailable: Bool {
        #if os(macOS)
        return call.cameraOn && DesktopCameraDevices.available.count > 1
        #else
        return call.cameraOn
        #endif
    }

    private var flipSlot: some View {
        RoundControl(icon: "camera.rotate.fill", label: "Flip", size: 64) { call.flipCamera(); lastInteraction = Date() }
            .disabled(!flipAvailable)
            .opacity(flipAvailable ? 1 : 0.5)
            .accessibilityHint(AppPlatform.isMac ? "Switch to the next camera" : "Switch between front and back camera")
            .accessibilityIdentifier("callFlip")
    }

    @ViewBuilder private var speakerSlot: some View {
        #if os(iOS)
        if route.external {
            // Android CallOutputSheet: with a headset or Bluetooth audio present, the system's audio output picker.
            AudioOutputControl(label: route.label).accessibilityIdentifier("callSpeaker")
        } else {
            RoundControl(icon: call.speaker ? "speaker.wave.2.fill" : "speaker.wave.1.fill", label: call.speaker ? "Speaker" : "Earpiece",
                         fill: call.speaker ? .white : Palette.callControl, foreground: call.speaker ? .black : .white, size: 64) {
                call.toggleSpeaker(); lastInteraction = Date()
            }
            .accessibilityHint(call.speaker ? "Sound plays from the speaker. Tap to use the earpiece." : "Sound plays from the earpiece. Tap to use the speaker.")
            .accessibilityIdentifier("callSpeaker")
        }
        #else
        RoundControl(icon: "speaker.wave.2.fill", label: "Sound", fill: call.speaker ? .white : Palette.callControl,
                     foreground: call.speaker ? .black : .white, size: 64) { call.toggleSpeaker(); lastInteraction = Date() }
            .accessibilityIdentifier("callSpeaker")
        #endif
    }

    /// One row of five equal columns; at accessibility text sizes three lines with End alone in the middle line.
    private var activeRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                muteSlot.frame(maxWidth: .infinity)
                cameraSlot.frame(maxWidth: .infinity)
                endSlot.frame(maxWidth: .infinity)
                flipSlot.frame(maxWidth: .infinity)
                speakerSlot.frame(maxWidth: .infinity)
            }
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 28) { muteSlot; cameraSlot }
                endSlot
                HStack(alignment: .top, spacing: 28) { flipSlot; speakerSlot }
            }
        }
    }

    @ViewBuilder private var bottomControls: some View {
        VStack(spacing: 22) {
            if call.ended != nil {
                EmptyView()
            } else if call.phase == .incomingRinging {
                Text(call.offeredType == .voice ? "Voice call" : "Video call").font(Typo.secondary).foregroundStyle(Palette.dimInk)
                // So the two of you can match up: the name the caller sees for this device nearby.
                if let line = model.ownNearbyLine { OwnNearbyNameLine(text: line) }
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 20)) : AnyLayout(HStackLayout(spacing: 56))
                layout {
                    RoundControl(icon: "phone.down.fill", label: "Decline", fill: Palette.callEnd, foreground: .white, size: 72) { model.declineFromScreen(call) }
                    // Apple only (product decision): answer a video call with voice.
                    if call.offeredType == .video {
                        RoundControl(icon: "phone.fill", label: "Voice", size: 72) { call.accept(as: .voice) }
                    }
                    RoundControl(icon: call.offeredType == .video ? "video.fill" : "phone.fill", label: "Accept", fill: Palette.callAccept, foreground: .black, size: 72) {
                        call.accept(as: call.offeredType)
                    }
                }
                // Android: only for a caller that showed its real key (a one-time ID cannot be blocked one by one).
                if call.fingerprint != nil {
                    HStack(spacing: 32) {
                        // Android TextButton: a 48 dp touch target around the text, same look.
                        Button("Decline and block") { model.declineAndBlock(call) }
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                            .accessibilityIdentifier("declineAndBlock")
                        Button("Report") { model.declineAndReport(call) }
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                            .accessibilityIdentifier("declineAndReport")
                    }
                    .font(Typo.secondary.weight(.semibold)).foregroundStyle(.white).buttonStyle(.plain)
                }
            } else if call.phase == .active || call.phase == .negotiatingMedia {
                if showHoldHint {
                    Text("Tip: hold Mute to talk").font(Typo.secondary).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Palette.callControl, in: Capsule())
                        .transition(.opacity)
                }
                activeRow
                #if os(macOS)
                // The Mac's camera picker stays (gap audit); Flip also moves to the next camera.
                if call.cameraOn { DesktopCameraPicker().frame(maxWidth: 220) }
                #endif
            } else {
                // Calling or ringing (Android cancelCallButton): Cancel alone, in the middle.
                RoundControl(icon: "phone.down.fill", label: "Cancel", fill: Palette.callEnd, size: 72) { call.end() }
                    .accessibilityIdentifier("callEnd")
            }
        }
        .padding(.horizontal, 12).padding(.top, 28).padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(showsVideo ? AnyView(LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()) : AnyView(Color.clear))
    }
}

enum TimelineFormatter {
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Call info: encryption, route, verification and the safety code (the only place with security detail).
struct CallInfoSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var call: CallController
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    private var securityTitle: String {
        if let count = call.relayCount, count > 0 {
            return count == 1 ? "Encrypted, through 1 other phone" : "Encrypted, through \(count) other phones"
        }
        return call.relayed ? "Encrypted, through other phones" : "Encrypted, direct"
    }
    var body: some View {
        List {
            Section {
                InfoLine(icon: AppIcon.lock, tint: Palette.connected, title: securityTitle,
                         detail: call.relayed ? "Your call passes through other phones near you. They cannot hear or see it." : "Directly between your two phones.")
                switch call.verification {
                case .verified:
                    InfoLine(icon: "checkmark.shield.fill", tint: Palette.connected, title: "Verified", detail: "You checked this person's code in person.")
                case .mismatch:
                    InfoLine(icon: "exclamationmark.octagon.fill", tint: Palette.ink, title: "This contact's ID has changed",
                             detail: "This phone no longer matches the ID saved for this contact. End the call and check with them in person before sharing anything private.")
                case .unverified:
                    InfoLine(icon: "questionmark.circle", tint: Palette.dimInk, title: "Not verified yet", detail: "Compare the safety code below to be sure who you are talking to.")
                }
            }
            if let code = call.safetyCode {
                Section {
                    Text("Read this code aloud. Their screen must show exactly the same numbers.").font(Typo.secondary)
                    Text(formatCode(code)).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                    if call.verification != .verified {
                        Button("Codes match: mark as verified") {
                            guard let fp = call.fingerprint else { return }
                            let claim = call.claimedName.flatMap { c in model.contacts.contains { NameReading.same(c, $0.displayName) } ? nil : c }
                            do { try model.markVerified(sessionPeer: fp, name: call.label?.contactName ?? claim ?? call.label?.handle ?? call.peerName); call.verification = .verified; message = "Saved as verified." }
                            catch { message = "Could not save: \(error)" }
                        }
                        .tint(Palette.accent)
                    }
                    if let message { Text(message).font(Typo.caption).foregroundStyle(Palette.dimInk) }
                } header: { Text("Safety code with \(call.label?.title ?? call.peerName)") }
            }
            // Android Link health, for every call: the connection; for a video call what was asked for, what the link allows
            // now and why it is lower (Settings › Manual video: never changed silently); the sound bitrate once active.
            Section {
                Text("Connection: Bluetooth \(call.transport.label)").accessibilityIdentifier("callConnection")
                if call.callType == .video {
                    Text("Your video: \(call.requestedVideo.width)\u{00D7}\(call.requestedVideo.height), \(call.requestedVideo.fps) fps, \(call.requestedVideo.kbps) kbps requested")
                        .accessibilityIdentifier("callVideoRequested")
                    if let allows = call.videoAllowsKbps {
                        Text("Link currently allows about \(allows) kbps").accessibilityIdentifier("callVideoSending")
                    }
                    ForEach(call.videoNotes, id: \.self) { note in
                        Text(note).font(Typo.caption).foregroundStyle(Palette.dimInk)
                    }
                }
                if call.phase == .active {
                    Text("Sound: \(CallController.audioBitrate / 1_000) kbps").accessibilityIdentifier("callSound")
                }
            } header: { Text("Link health") }
            Section {
                if let label = call.label { LabeledContent("ID", value: label.handle).font(.body.monospaced()) }
                Text(call.stats).font(Typo.caption).foregroundStyle(Palette.dimInk)
                // Android Link health "Copy diagnostics": the export plus this call's encryption, route, verification
                // state and link counters. Never the ID, the name or the safety code.
                Button("Copy diagnostics") {
                    let verification: String
                    switch call.verification {
                    case .verified: verification = "Verified"
                    case .mismatch: verification = "ID changed"
                    case .unverified: verification = "Not verified yet"
                    }
                    let rows = ["Encrypted end to end", call.relayed ? "Through other phones" : "Direct", verification, call.stats]
                    DiagnosticsSheet.copy(DiagnosticsReport.withCall(DiagnosticsExport.text(), rows: rows))
                    message = "Copied"
                }
                .accessibilityIdentifier("copyCallDiagnostics")
                if let message, call.safetyCode == nil { Text(message).font(Typo.caption).foregroundStyle(Palette.dimInk) }
            } header: { Text("Link details") } footer: {
                FooterText("The camera is in use by your call. Compare the safety code above instead, or scan their code from Contacts \u{203A} Add contact right after the call.")
            }
        }
        .monoList()
        .navigationTitle(call.label?.title ?? "Call info").mobileNavigationTitle(inline: true)
        .toolbar { Button("Done") { dismiss() } }
    }
}

func formatCode(_ code: String) -> String {
    let groups = code.split(separator: " ")
    return stride(from: 0, to: groups.count, by: 4).map { groups[$0..<min($0 + 4, groups.count)].joined(separator: " ") }.joined(separator: "\n")
}


/// Mute: a tap toggles; while muted, press and hold to talk (release = muted again).
struct MuteControl: View {
    @ObservedObject var call: CallController
    /// Android RoundControl: 64 in the call row.
    var size: CGFloat = 64
    var interacted: () -> Void
    @State private var pressStart: Date?
    @State private var holdWork: DispatchWorkItem?
    @ScaledMetric(relativeTo: .caption) private var scale: CGFloat = 1

    var body: some View {
        let active = call.muted && !call.talking
        let side = size * min(scale, 1.4)
        VStack(spacing: 6) {
            Image(systemName: call.talking ? "mic.fill" : (call.muted ? "mic.slash.fill" : "mic.fill"))
                .font(.system(size: side * 0.36, weight: .semibold))
                .frame(width: side, height: side)
                .background(call.talking ? Palette.connected : (active ? .white : Palette.callControl), in: Circle())
                .foregroundStyle(call.talking ? .white : (active ? .black : .white))
                .scaleEffect(call.talking ? 1.08 : 1)
            Text(call.talking ? "Talking\u{2026}" : (call.muted ? "Unmute" : "Mute")).font(Typo.caption).foregroundStyle(.white)
                .lineLimit(1).fixedSize()
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard pressStart == nil else { return }
                pressStart = Date()
                guard call.muted else { return }
                let work = DispatchWorkItem { call.holdToTalk(true) }
                holdWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
            .onEnded { _ in
                holdWork?.cancel(); holdWork = nil
                if call.talking { call.holdToTalk(false) } else { call.toggleMute() }
                pressStart = nil
                interacted()
            })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(call.muted ? "Unmute" : "Mute")
        .accessibilityHint(call.muted ? "Unmute your microphone. Touch and hold to talk while you hold." : "Double-tap to mute.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { call.toggleMute(); interacted() }
    }
}

#if os(iOS)
/// The current audio output (Android PrivateCallAudioSession labels: Speaker, Earpiece, Headset, Bluetooth) and whether a
/// headset or Bluetooth output is present, in the route or among the available inputs.
final class AudioRouteWatcher: ObservableObject {
    @Published private(set) var external = false
    @Published private(set) var label = "Speaker"
    private let queue = DispatchQueue(label: "io.github.meshlive.app.audio.route", qos: .utility)
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// The session is read on a utility queue; only `external` and `label` are published, on the main queue. The
    /// notification arrives on whatever thread posts it, so only the main-side publish is marked for the stall tracer.
    private func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let session = AVAudioSession.sharedInstance()
            let outputs = session.currentRoute.outputs.map(\.portType)
            let headset: [AVAudioSession.Port] = [.headphones, .usbAudio]
            let bluetooth: [AVAudioSession.Port] = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
            let inputs = (session.availableInputs ?? []).map(\.portType)
            let external = outputs.contains { headset.contains($0) || bluetooth.contains($0) }
                || inputs.contains { $0 == .headsetMic || $0 == .bluetoothHFP || $0 == .usbAudio }
            let label = outputs.contains { bluetooth.contains($0) } ? "Bluetooth"
                : outputs.contains { headset.contains($0) } ? "Headset"
                : outputs.contains(.builtInReceiver) ? "Earpiece" : "Speaker"
            DispatchQueue.main.async {
                MainStall.run("AudioRouteWatcher.publish") {
                    if self.external != external { self.external = external }
                    if self.label != label { self.label = label }
                }
            }
        }
    }
}

/// The Speaker slot with a headset or Bluetooth present: Apple's audio output picker in the round control's disc,
/// labelled with the current output (Android CallOutputSheet: Phone speaker, Earpiece, the device by name).
struct AudioOutputControl: View {
    let label: String
    @ScaledMetric(relativeTo: .caption) private var scale: CGFloat = 1
    var body: some View {
        let side = 64 * min(scale, 1.4)
        VStack(spacing: 6) {
            RoutePicker()
                .frame(width: side * 0.6, height: side * 0.6)
                .frame(width: side, height: side)
                .background(Palette.callControl, in: Circle())
                .accessibilityLabel("Audio output: \(label)")
                .accessibilityHint("Tap to choose the audio output.")
            Text(label).font(Typo.caption).foregroundStyle(.white).lineLimit(1).fixedSize().accessibilityHidden(true)
        }
    }
}

private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .white
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif
