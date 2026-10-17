import SwiftUI
import NearbyCore

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

    init(call: CallController) { self.call = call; _sink = ObservedObject(wrappedValue: call.remote.sink) }

    private var showsVideo: Bool { sink.hasVideo && call.remoteCameraOn && call.phase == .active }

    var body: some View {
        ZStack {
            Palette.callGround.ignoresSafeArea()
            if showsVideo {
                VideoSurfaceView(sink: sink).ignoresSafeArea()
                    .onTapGesture { controlsVisible.toggle(); lastInteraction = Date() }
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
            VStack(spacing: 0) {
                if controlsVisible || !showsVideo { topBar.transition(.opacity) }
                if model.mismatchWarning != nil || call.verification == .mismatch { mismatchBanner }
                Spacer()
                if let camera = call.camera, call.cameraOn, call.phase == .active {
                    HStack { Spacer(); CameraPreviewView(session: camera.session).frame(width: 104, height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 6)).padding(.trailing, 16).padding(.bottom, 12) }
                }
                if controlsVisible || !showsVideo { bottomControls.transition(.opacity) }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .sheet(isPresented: $showInfo) { NavigationStack { CallInfoSheet(call: call) } }
        .preferredColorScheme(.dark)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
            // Controls fade out after 4 s during video and come back on a tap.
            if showsVideo, controlsVisible, !call.talking, !showHoldHint, now.timeIntervalSince(lastInteraction) > 4 { controlsVisible = false }
            if !showsVideo { controlsVisible = true }
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
        if call.talking { return "Talking" }
        if call.phase == .active, let since = call.activeSince {
            return TimelineFormatter.duration(Date().timeIntervalSince(since))
        }
        return call.phaseText.isEmpty ? "Connecting…" : call.phaseText
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(call.label?.title ?? call.peerName).font(Typo.title).foregroundStyle(.white).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(stateLine).font(Typo.timer).foregroundStyle(.white.opacity(0.75))
                }
                if call.remoteMuted && call.phase == .active {
                    Label("Their microphone is off", systemImage: "mic.slash.fill").font(Typo.caption).foregroundStyle(Palette.dimInk)
                }
                if let health = model.healthMessage, call.ended == nil {
                    Label(health, systemImage: "thermometer.medium").font(Typo.caption).foregroundStyle(Palette.accent)
                }
                if let subject = call.subject {
                    Text(subject).font(Typo.secondary).foregroundStyle(.white.opacity(0.9)).lineLimit(2)
                }
                if let problem = call.mediaProblem, call.ended == nil {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").font(Typo.caption).foregroundStyle(Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if call.fingerprint != nil {
                Button { showInfo = true; lastInteraction = Date() } label: {
                    Image(systemName: call.verification == .verified ? "lock.shield.fill" : "lock.fill")
                        .font(.title3).frame(width: 48, height: 48)
                        .foregroundStyle(call.verification == .verified ? Palette.connected : Palette.ink)
                }
                .accessibilityLabel("Call info: encryption and verification")
            }
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
        .background(showsVideo ? AnyView(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea()) : AnyView(Color.clear))
    }

    private var mismatchBanner: some View {
        Button { showInfo = true } label: {
            Label("Identity does not match. Someone may be pretending to be this person. Tap for details.", systemImage: "exclamationmark.octagon.fill")
                .font(Typo.secondary.weight(.semibold)).foregroundStyle(.black).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Inverted (white on black screen) instead of red: red is reserved for live.
                .background(Palette.ink, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var callControls: some View {
        MuteControl(call: call) { lastInteraction = Date(); maybeShowHoldHint() }
        RoundControl(icon: call.cameraOn ? "video.fill" : "video.slash.fill",
                     label: call.cameraOn ? "Video off" : (call.callType == .voice ? "Add video" : "Video on")) { call.toggleCamera(); lastInteraction = Date() }
        if call.cameraOn { RoundControl(icon: "camera.rotate.fill", label: "Flip") { call.flipCamera(); lastInteraction = Date() } }
        RoundControl(icon: "speaker.wave.2.fill", label: "Speaker", fill: call.speaker ? .white : Palette.callControl,
                     foreground: call.speaker ? .black : .white) { call.toggleSpeaker(); lastInteraction = Date() }
    }

    @ViewBuilder private var bottomControls: some View {
        VStack(spacing: 22) {
            if call.ended != nil {
                EmptyView()
            } else if call.phase == .incomingRinging {
                Text(call.offeredType == .voice ? "Voice call" : "Video call").font(Typo.secondary).foregroundStyle(Palette.dimInk)
                HStack(spacing: 56) {
                    RoundControl(icon: "phone.down.fill", label: "Decline", fill: Palette.callEnd, foreground: .white, size: 76) { call.decline() }
                    if call.offeredType == .video {
                        RoundControl(icon: "phone.fill", label: "Voice", size: 76) { call.accept(as: .voice) }
                    }
                    RoundControl(icon: call.offeredType == .video ? "video.fill" : "phone.fill", label: "Accept", fill: Palette.callAccept, foreground: .black, size: 76) {
                        call.accept(as: call.offeredType)
                    }
                }
            } else {
                if call.phase == .active || call.phase == .negotiatingMedia {
                    if showHoldHint {
                        Text("Hold Mute to talk").font(Typo.secondary).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Palette.callControl, in: Capsule())
                            .transition(.opacity)
                    }
                    // One row; at large Dynamic Type sizes the controls wrap into a grid instead of being clipped.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 18) { callControls }
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) { callControls }
                    }
                }
                RoundControl(icon: "phone.down.fill", label: call.phase == .active ? "End" : "Cancel", fill: Palette.callEnd, size: 68) { call.end() }
            }
        }
        .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 24)
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
    var body: some View {
        List {
            Section {
                InfoLine(icon: AppIcon.lock, tint: Palette.connected, title: "Encrypted end to end",
                         detail: call.relayed ? "Your call passes through other phones near you. They cannot hear or see it." : "Directly between your two phones.")
                switch call.verification {
                case .verified:
                    InfoLine(icon: "checkmark.shield.fill", tint: Palette.connected, title: "Verified", detail: "You checked this person's code in person.")
                case .mismatch:
                    InfoLine(icon: "exclamationmark.octagon.fill", tint: Palette.ink, title: "Identity does not match",
                             detail: "This phone's identity differs from the one you verified for this person. Do not share anything sensitive. End the call and check in person.")
                case .unverified:
                    InfoLine(icon: "questionmark.circle", tint: Palette.dimInk, title: "Not verified yet", detail: "Compare the safety code below to be sure who you are talking to.")
                }
            }
            if let code = call.safetyCode {
                Section {
                    Text("Read this code aloud. Their screen must show exactly the same numbers.").font(Typo.secondary)
                    Text(formatCode(code)).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                    if call.verification != .verified {
                        Button("The codes match") {
                            guard let fp = call.fingerprint else { return }
                            do { try model.markVerified(sessionPeer: fp, name: call.label?.title ?? call.peerName); call.verification = .verified; message = "Saved as verified." }
                            catch { message = "Could not save: \(error)" }
                        }
                        .tint(Palette.accent)
                    }
                    if let message { Text(message).font(Typo.caption).foregroundStyle(Palette.dimInk) }
                } header: { Text("Safety code") }
            }
            Section {
                if let label = call.label { LabeledContent("ID", value: label.handle).font(.body.monospaced()) }
                Text(call.stats).font(Typo.caption).foregroundStyle(Palette.dimInk)
            } header: { Text("Link details") } footer: {
                FooterText("Scanning their code needs the camera, which your call is using. Compare the safety code now, or scan from Your identity after the call.")
            }
        }
        .monoList()
        .navigationTitle(call.label?.title ?? "Call info").navigationBarTitleDisplayMode(.inline)
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
    var interacted: () -> Void
    @State private var pressStart: Date?
    @State private var holdWork: DispatchWorkItem?
    @ScaledMetric(relativeTo: .caption) private var scale: CGFloat = 1

    var body: some View {
        let active = call.muted && !call.talking
        let side = 60 * min(scale, 1.4)
        VStack(spacing: 6) {
            Image(systemName: call.talking ? "mic.fill" : (call.muted ? "mic.slash.fill" : "mic.fill"))
                .font(.system(size: side * 0.36, weight: .semibold))
                .frame(width: side, height: side)
                .background(call.talking ? Palette.connected : (active ? .white : Palette.callControl), in: Circle())
                .foregroundStyle(call.talking ? .white : (active ? .black : .white))
                .scaleEffect(call.talking ? 1.08 : 1)
            Text(call.talking ? "Talking" : (call.muted ? "Unmute" : "Mute")).font(Typo.caption).foregroundStyle(.white)
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
        .accessibilityHint(call.muted ? "Double-tap to unmute. Touch and hold to talk while muted." : "Double-tap to mute.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { call.toggleMute(); interacted() }
    }
}
