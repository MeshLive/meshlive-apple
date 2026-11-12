import SwiftUI
import NearbyCore

/// List wording (Android stream rows): the advertised title plainly, else who is live by route and name; the detail
/// lists Audio only, the route, Paused, Full and "This phone can't play it", joined by commas.
extension StreamRow {
    var listTitle: String {
        if let advertisedTitle { return advertisedTitle }
        // No route of this row comes from the source itself: a relay's identity is not the broadcaster's.
        if announcement.routeCost > 0 { return audioOnly ? "Radio from further away" : "Live from a phone further away" }
        if label.title == OwnNearbyName.someoneNearby { return audioOnly ? "Radio nearby" : "Live from a nearby phone" }
        // A changing ID recognised as a contact ("<name> · seen nearby · unconfirmed", Android stream_row_live_from_seen).
        if announcement.rotating && !label.isGenerated { return audioOnly ? "Radio from \(label.title)" : "Live from \(label.title)" }
        if label.contactName == nil && label.selfName == nil && !label.isGenerated {
            return audioOnly ? "Someone nearby is on the radio" : "Someone nearby is live"
        }
        return audioOnly ? "Radio from \(label.title)" : "\(label.title) is live"
    }
    var listDetail: String {
        var parts: [String] = []
        if audioOnly { parts.append("Audio only") }
        let relays = Int(announcement.routeCost)
        parts.append(relays == 0 ? "Nearby" : relays == 1 ? "Via 1 phone" : "Via \(relays) phones")
        if paused { parts.append("Paused") }
        if full { parts.append("Full, can't take more viewers") }
        if !playable { parts.append("This phone can't play it") }
        return parts.joined(separator: ", ")
    }
}

extension LiveController: Identifiable {}

struct WatchView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let row: StreamRow
    var onLeave: (() -> Void)? = nil
    var stopOnDisappear = true
    var body: some View {
        Group {
            if let watch = model.watch, watch.isRadio { RadioPlayer(watch: watch, title: watch.signedTitle ?? row.listTitle, leave: onLeave) }
            else if let watch = model.watch { WatchPlayer(watch: watch, sink: watch.remote.sink, title: watch.signedTitle ?? row.listTitle, leave: onLeave) }
            else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack {
                        Spacer()
                        if let notice = model.streamNotice {
                            Text(notice).font(.body).foregroundStyle(Palette.ink).multilineTextAlignment(.center).padding(20)
                        }
                        if model.streamRetryTarget != nil {
                            CapsuleButton(title: "Try again", kind: .white) { model.streamTryAgain() }
                                .frame(maxWidth: 260).padding(.bottom, 16)
                        }
                        RoundControl(icon: "xmark", label: "Leave") { if let onLeave { onLeave() } else { dismiss() } }.padding(.bottom, 16)
                    }
                }
            }
        }
        .mobileRootNavigation()
        .onAppear { model.watchScreenOpen = true; if model.watch == nil { model.startWatching(row) } }
        .onDisappear { model.watchScreenOpen = false; if stopOnDisappear { model.watch?.stop() } }
    }
}

/// The viewer screen (Android's shared top bar): title, route, the LIVE badge and the lock (stream info); the picture;
/// Block this person, Leave (in the middle) and Report once the source authenticated (P6 deferred these here).
private struct WatchPlayer: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var watch: WatchController
    @ObservedObject var sink: VideoSink
    let title: String
    var leave: (() -> Void)? = nil
    @State private var showInfo = false
    @State private var blockTarget: BlockTarget?
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurfaceView(sink: sink, fill: model.videoFill).ignoresSafeArea()
            // Warn when video freezes (Experimental): dim the frozen picture and say how long ago it last changed.
            if let stalled = watch.stalledMs, watch.ended == nil {
                Color.black.opacity(0.5).ignoresSafeArea().allowsHitTesting(false)
                VStack(spacing: 6) {
                    Text(ViewerFreeze.stalledTitle).font(.headline).foregroundStyle(.white)
                    Text(ViewerFreeze.lastPicture(stalled)).font(Typo.secondary).foregroundStyle(.white.opacity(0.8))
                }
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("viewerStalled")
                .allowsHitTesting(false)
            }
            // Android ViewerFrameAge "Signal lost" (Warn when video freezes on): the last picture stays, dimmed, while
            // recovery looks for the stream.
            if watch.recovering, model.viewerFreezeWarning, sink.hasVideo {
                Color.black.opacity(0.5).ignoresSafeArea().allowsHitTesting(false)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(spacing: 6) {
                        Text(ViewerRecovery.signalLostTitle).font(.headline).foregroundStyle(.white)
                        if let at = sink.lastPictureAt {
                            Text(ViewerFreeze.lastPicture(Int((ProcessInfo.processInfo.systemUptime - at) * 1000)))
                                .font(Typo.secondary).foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .multilineTextAlignment(.center)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("viewerSignalLost")
                .allowsHitTesting(false)
            }
            VStack {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline).foregroundStyle(.white).lineLimit(1)
                        Text(routeText(watch.route)).font(Typo.secondary).foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer(minLength: 8)
                    if watch.sourceFingerprint != nil && watch.ended == nil { LiveTag(text: watch.paused ? "PAUSED" : "LIVE", blinking: !watch.paused) }
                    if watch.ended == nil || watch.sourceFingerprint != nil {
                        Button { showInfo = true } label: {
                            Image(systemName: AppIcon.lock).font(.title3).frame(width: 44, height: 44).foregroundStyle(.white)
                        }
                        .accessibilityLabel("Stream info: encryption and source")
                    }
                }
                Spacer()
                if !watch.state.isEmpty {
                    Text(watch.state).font(Typo.body).foregroundStyle(.white).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity).padding().background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if watch.sharing {
                    Label(model.relaySharingText, systemImage: "arrow.triangle.branch").font(Typo.caption).foregroundStyle(.white.opacity(0.85))
                }
                HStack(alignment: .top, spacing: 0) {
                    Group {
                        if let source = watch.sourceFingerprint, watch.sourceDirect {
                            RoundControl(icon: "hand.raised", label: "Block this person", size: 64) {
                                blockTarget = BlockTarget(fingerprint: source, name: model.blockName(for: source), streamRoute: BlockedStreams.routeKey(watch.offer))
                            }
                        } else { Color.clear.frame(width: 64, height: 64) }
                    }
                    .frame(maxWidth: .infinity)
                    RoundControl(icon: "xmark", label: "Leave", size: 72) { leaveNow() }
                        .frame(maxWidth: .infinity)
                    Group {
                        if let source = watch.sourceFingerprint, watch.sourceDirect {
                            RoundControl(icon: "flag", label: "Report", size: 64) {
                                model.report(source, streamRoute: BlockedStreams.routeKey(watch.offer))
                                leaveNow()
                            }
                        } else { Color.clear.frame(width: 64, height: 64) }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.top, 12)
            }
            .padding(16)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showInfo) { NavigationStack { StreamInfoSheet(watch: watch, title: title, onHide: { leaveNow() }) }.desktopReadingSize() }
        .blockConfirmation($blockTarget) { leaveNow() }
    }
    private func leaveNow() { watch.stop(); if let leave { leave() } else { dismiss() } }
}

/// Android audio_live_route_*: "Direct", "Via 1 phone", "Via N phones" (the watch route is "direct" or "via N phones").
private func routeText(_ route: String) -> String {
    route == "direct" ? "Direct" : route.prefix(1).uppercased() + route.dropFirst()
}

/// Android Audio broadcast stopped dialog (and the heat stop or refusal of a video live), at the root.
private struct LiveStoppedAlert: ViewModifier {
    @EnvironmentObject var model: AppModel
    func body(content: Content) -> some View {
        content.alert(model.liveStoppedTitle, isPresented: Binding(get: { model.liveStoppedNotice != nil }, set: { if !$0 { model.liveStoppedNotice = nil } })) {
            Button("OK", role: .cancel) { model.liveStoppedNotice = nil }
        } message: { Text(model.liveStoppedNotice ?? "") }
    }
}

extension View {
    func liveStoppedAlert() -> some View { modifier(LiveStoppedAlert()) }
}

/// Listening to an audio-only stream: black, the radio glyph, the title, "Audio only", the state and Leave.
/// It keeps playing with the screen locked or MeshLive in the background.
private struct RadioPlayer: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var watch: WatchController
    let title: String
    var leave: (() -> Void)? = nil
    @State private var showInfo = false
    @State private var blockTarget: BlockTarget?
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if typeSize.isAccessibilitySize {
                ScrollView { playerContent }
            } else { playerContent }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showInfo) {
            NavigationStack { StreamInfoSheet(watch: watch, title: title, onHide: { watch.stop(); if let leave { leave() } else { dismiss() } }) }
                .desktopReadingSize()
        }
        .blockConfirmation($blockTarget, onBlocked: { _ in
            // Block is offered only once the direct source authenticated, so this route is that person's: it stays hidden
            // for this run (BlockedStreams rule 1), as a later join of a blocked source does (device test 2026-11-12:
            // the row came back after Block until the stream was opened again).
            model.hideStreamRoute(watch.offer)
            // Android audio_live_listen_blocked: the listener has left; the Live page says what happened until dismissed.
            model.liveNotice = LiveNotice(text: "Blocked. Their broadcasts are hidden.", offersRescan: false, closesWatch: false)
        }) { watch.stop(); if let leave { leave() } else { dismiss() } }
    }
    /// Android screen_audio_listen: "Radio", the LIVE badge and timer; the title, the route, the sound meter, the state,
    /// the info; Mute and Stop; Block this person and Report once the signed header named the source.
    private var playerContent: some View {
        VStack(spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                Text("Radio").font(.headline).foregroundStyle(.white)
                Spacer(minLength: 8)
                if watch.sourceFingerprint != nil && watch.ended == nil && !watch.paused { LiveTag(text: "LIVE") }
                if let since = watch.liveSince, watch.ended == nil {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(TimelineFormatter.duration(Date().timeIntervalSince(since))).font(Typo.timer).foregroundStyle(.white.opacity(0.9))
                    }
                }
                if watch.ended == nil || watch.sourceFingerprint != nil {
                    Button { showInfo = true } label: {
                        Image(systemName: AppIcon.lock).font(.title3).frame(width: 44, height: 44).foregroundStyle(.white)
                    }
                    .accessibilityLabel("Stream info: encryption and source")
                }
            }
            Spacer()
            IconDisc(icon: "radio", size: 120)
            Text(title.isEmpty ? "Radio nearby" : title).font(.title2.weight(.semibold)).foregroundStyle(.white).multilineTextAlignment(.center).lineLimit(typeSize.isAccessibilitySize ? nil : 3)
            Text(subtitle).font(.subheadline).foregroundStyle(Palette.dimInk)
            Text(routeText(watch.route)).font(.subheadline).foregroundStyle(Palette.dimInk)
            ProgressView(value: watch.level).progressViewStyle(.linear).tint(.white).frame(maxWidth: 280)
                .accessibilityLabel("Sound level")
            // Android listener states: the engine's state, else "Live" or "Live. Muted" while playing.
            let listen = !watch.state.isEmpty ? watch.state
                : (watch.liveSince != nil && watch.ended == nil ? (watch.playbackMuted ? "Live. Muted" : "Live") : "")
            if !listen.isEmpty {
                Text(listen).font(.body).foregroundStyle(.white).multilineTextAlignment(.center)
                    .accessibilityIdentifier("radioListenState")
            }
            Spacer()
            Text("Anyone nearby with MeshLive can listen, including phones that pass it on. Titles from people you have not verified are unconfirmed. Volume is your \(AppPlatform.isMac ? "Mac's" : "phone's") media volume.")
                .font(.footnote).foregroundStyle(Palette.dimInk).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text(AppPlatform.isMac ? "Keeps playing with the display off while this Mac is awake." : "Keeps playing with the screen off.").font(.footnote).foregroundStyle(Palette.dimInk)
            HStack(alignment: .top, spacing: 40) {
                RoundControl(icon: watch.playbackMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: watch.playbackMuted ? "Unmute" : "Mute",
                             fill: watch.playbackMuted ? .white : Palette.callControl, foreground: watch.playbackMuted ? .black : .white, size: 64) { watch.togglePlaybackMute() }
                    .accessibilityIdentifier("radioMute")
                RoundControl(icon: "stop.fill", label: "Stop", fill: Palette.liveEnd, size: 64) { watch.stop(); if let leave { leave() } else { dismiss() } }
                    .accessibilityIdentifier("radioStop")
            }
            // Android listener: Block this person and Report, once the signed header named the source.
            if let source = watch.radioSourceFingerprint {
                HStack(spacing: 40) {
                    RoundControl(icon: "hand.raised", label: "Block this person") {
                        blockTarget = BlockTarget(fingerprint: source, name: model.blockName(for: source), streamRoute: BlockedStreams.routeKey(watch.offer))
                    }
                    RoundControl(icon: "flag", label: "Report") {
                        model.report(source, streamRoute: BlockedStreams.routeKey(watch.offer))
                        watch.stop(); if let leave { leave() } else { dismiss() }
                    }
                }
            }
        }
        .padding(20)
    }
    private var subtitle: String {
        switch watch.radioPreset {
        case AudioLive.presetLowData?: return "Audio only \u{00B7} Low data"
        case AudioLive.presetMusic?: return "Audio only \u{00B7} Music"
        case AudioLive.presetVoice?: return "Audio only \u{00B7} Voice"
        default: return "Audio only"
        }
    }
}

/// Android stream info ("About this stream"): who can watch, that it is encrypted on the way, from whom; the source's
/// verification and the route. A source that did not authenticate itself (named only by a relay, or not yet known) cannot
/// be blocked or reported: Android offers "Hide this livestream" instead (this route, kept with the block list).
struct StreamInfoSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var watch: WatchController
    /// The player's title (the sheet uses Android's title; kept for the call sites).
    let title: String
    /// Leaves the player after Hide this livestream.
    var onHide: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section {
                Text("Anyone nearby with MeshLive can watch, including phones that pass the video on. It is encrypted on the way, so phones that are not watching cannot see it.")
                    .font(Typo.secondary).foregroundStyle(Palette.ink)
                Text("From: \(watch.name)").font(Typo.secondary).foregroundStyle(Palette.dimInk)
                if let fp = watch.sourceFingerprint, watch.sourceDirect {
                    let verified = model.verificationState(of: fp) == .verified
                    InfoLine(icon: verified ? AppIcon.verified : AppIcon.unverified, tint: verified ? Palette.connected : Palette.dimInk,
                             title: verified ? "Verified source" : "Source not verified", detail: verified ? "You checked this person's code in person." : "Verify them in person to be sure who is broadcasting.")
                }
                InfoLine(icon: "point.3.connected.trianglepath.dotted", tint: Palette.dimInk, title: watch.route == "direct" ? "Directly from the broadcaster" : "Through other phones near you",
                         detail: watch.route == "direct" ? "No other phone passes it on." : "Phones in between pass it on; they cannot change it.")
            }
            if !watch.canModerate {
                Section {
                    Button("Hide this livestream") {
                        model.hideLivestream(watch.offer, address: watch.routeAddress, hopAuthenticated: watch.hopAuthenticated)
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onHide?() }
                    }
                    .accessibilityIdentifier("hideLivestream")
                }
            }
            Section("Link details") { Text(watch.stats).font(Typo.caption).foregroundStyle(Palette.dimInk) }
        }
        .monoList()
        .navigationTitle("About this stream").mobileNavigationTitle(inline: true)
        .toolbar { Button("Done") { dismiss() } }
    }
}

/// The broadcaster screen (Android liveTopBar, LiveControls, screen_audio_broadcast): the top bar (title, the red LIVE
/// badge, the timer); a video live shows the picture and Mute, Camera, End, Flip, Pause with End in the middle; audio
/// only shows the setup (title, quality, Start) and, on air, the level meter, the status, Mute, End, Pause and Switch to
/// video. The first audio-only broadcast warns first; the reminder asks while MeshLive is frontmost.
struct LivePanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var live: LiveController
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("audioLivePreset") private var preset = Int(AudioLive.presetVoice)
    @State private var showDisclosure = false
    @State private var confirmEnd = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if !live.audioOnly {
                if let camera = live.camera { CameraPreviewView(session: camera.session).ignoresSafeArea() }
                if live.cameraOff { Text("Camera off").font(Typo.title).foregroundStyle(.white) }
            }
            if live.audioOnly {
                ScrollView { audioColumn.padding(20) }
            } else if typeSize.isAccessibilitySize {
                ScrollView { VStack(spacing: 24) { topBar; notices; videoControls }.padding(20) }
            } else {
                VStack {
                    topBar
                    notices
                    Spacer()
                    videoControls
                        .padding(.vertical, 20).frame(maxWidth: .infinity)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
                }
                .padding(.horizontal, 16)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if live.audioOnly, !live.running, !AppSettings.audioLiveDisclosed { showDisclosure = true } }
        .alert("Going live", isPresented: $showDisclosure) {
            Button("Go live with audio") { AppSettings.audioLiveDisclosed = true }
            Button("Cancel", role: .cancel) { live.stop() }
        } message: {
            Text("Your livestream is public. Anyone nearby with MeshLive can listen, and it can be passed on to people further away.")
        }
        .alert("Still broadcasting", isPresented: Binding(get: { live.reminderShown && live.running }, set: { if !$0 { live.reminderShown = false } })) {
            Button("Keep going") { live.userPresent() }
            Button("End", role: .destructive) { live.stop() }
        } message: {
            Text("Your audio broadcast is still on. Nobody answered for a while, so it stops by itself soon unless you keep going.")
        }
        .alert(LiveEndConfirm.title(viewers: live.viewers.count), isPresented: $confirmEnd) {
            Button("End live") { live.stop() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Top bar (Android liveTopBar)

    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            if live.audioOnly && !live.running {
                Button { live.stop() } label: {
                    Image(systemName: "chevron.backward").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).foregroundStyle(.white).accessibilityLabel("Back")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(barTitle).font(.headline).foregroundStyle(.white).lineLimit(1)
                if let subtitle = barSubtitle {
                    Text(subtitle).font(Typo.secondary).foregroundStyle(.white.opacity(0.8)).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                }
            }
            Spacer(minLength: 8)
            if live.running {
                LiveTag(text: live.paused ? "PAUSED" : "LIVE", blinking: !live.paused)
                if let since = live.liveSince {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(TimelineFormatter.duration(Date().timeIntervalSince(since))).font(Typo.timer).foregroundStyle(.white.opacity(0.9))
                    }
                    .accessibilityIdentifier("liveTimer")
                }
            }
        }
    }

    private var barTitle: String {
        if live.audioOnly { return "Audio only" }
        return live.running ? "You are live" : "Ready to go live"
    }

    private var barSubtitle: String? {
        guard !live.audioOnly else { return nil }
        let watching = live.paused ? "Paused, \(live.viewers.count) watching" : "\(live.viewers.count) watching"
        return [live.title, watching].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder private var notices: some View {
        if let health = model.healthMessage {
            Label(health, systemImage: "thermometer.medium").font(Typo.caption).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.5), in: Capsule())
        }
        if model.showTemperature {
            Label(StatusSheet.health, systemImage: "thermometer.medium").font(Typo.caption).foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.5), in: Capsule())
                .accessibilityIdentifier("deviceTemperature")
        }
        if !live.audioOnly, let line = LiveStatusLine.video(running: live.running, paused: live.paused, viewers: live.viewers.count,
                                                            bluetoothOff: RadioStatus(model: model).readiness == .bluetoothOff) {
            Text(line).font(Typo.secondary).foregroundStyle(.white).multilineTextAlignment(.center)
                .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("liveStatusLine")
        }
        if !live.state.isEmpty {
            Text(live.state).font(Typo.secondary).foregroundStyle(.white).multilineTextAlignment(.center)
                .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: Video live (Android LiveControls: Mute, Camera, End, Flip, Pause)

    private var muteButton: some View {
        RoundControl(icon: live.muted ? "mic.slash.fill" : "mic.fill", label: live.muted ? "Unmute" : "Mute",
                     fill: live.muted ? .white : Palette.callControl, foreground: live.muted ? .black : .white, size: 64) { live.toggleMute() }
            .disabled(live.paused).opacity(live.paused ? 0.5 : 1)
            .accessibilityHint(live.audioOnly ? "Sends silence; the microphone stays on" : (live.muted ? "Unmute your microphone" : "Mute your microphone. The video goes on."))
    }

    private var cameraButton: some View {
        RoundControl(icon: live.cameraOff ? "video.slash.fill" : "video.fill", label: live.cameraOff ? "Camera on" : "Camera off",
                     fill: live.cameraOff ? .white : Palette.callControl, foreground: live.cameraOff ? .black : .white, size: 64) { live.toggleCamera() }
            .disabled(live.paused).opacity(live.paused ? 0.5 : 1)
            .accessibilityHint(live.cameraOff ? "Turn your camera on" : "Turn your camera off. The sound goes on.")
            .accessibilityIdentifier("liveCamera")
    }

    /// Android End live: with someone watching or listening, ask first ("End live for 1 viewer?").
    private var endButton: some View {
        RoundControl(icon: "stop.fill", label: "End", fill: Palette.liveEnd, size: 72) {
            if LiveEndConfirm.asks(viewers: live.viewers.count, enabled: AppSettings.liveEndConfirm) { confirmEnd = true } else { live.stop() }
        }
        .accessibilityIdentifier("liveEnd")
    }

    /// iPhone: two lenses. Mac: two or more cameras. The slot stays when there is nothing to flip to.
    private var hasSecondCamera: Bool {
        #if os(macOS)
        return DesktopCameraDevices.available.count > 1
        #else
        return true
        #endif
    }

    private var flipButton: some View {
        let enabled = hasSecondCamera && !live.paused && !live.cameraOff
        return RoundControl(icon: "camera.rotate.fill", label: "Flip", size: 64) { live.flipCamera() }
            .disabled(!enabled)
            .opacity(hasSecondCamera ? (enabled ? 1 : 0.5) : 0)
            .accessibilityHidden(!hasSecondCamera)
            .accessibilityIdentifier("liveFlip")
    }

    private var pauseButton: some View {
        RoundControl(icon: live.paused ? "play.fill" : "pause.fill", label: live.paused ? "Resume" : "Pause", size: 64) { live.togglePause() }
            .accessibilityHint(live.paused ? "Resume broadcast" : "Pause broadcast")
    }

    private var videoControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                muteButton.frame(maxWidth: .infinity)
                cameraButton.frame(maxWidth: .infinity)
                endButton.frame(maxWidth: .infinity)
                flipButton.frame(maxWidth: .infinity)
                pauseButton.frame(maxWidth: .infinity)
            }
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 28) { muteButton; cameraButton }
                endButton
                HStack(alignment: .top, spacing: 28) { flipButton; pauseButton }
            }
        }
    }

    // MARK: Audio only (Android screen_audio_broadcast)

    private var audioColumn: some View {
        VStack(spacing: 18) {
            topBar
            IconDisc(icon: "radio", size: 120).padding(.top, 12)
            if live.running { onAir } else { setup }
        }
    }

    private var qualityName: String {
        preset == Int(AudioLive.presetLowData) ? "Low data" : preset == Int(AudioLive.presetMusic) ? "Music" : "Voice"
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Title").font(Typo.secondary).foregroundStyle(Palette.dimInk)
            TextField("Optional. Anyone nearby can read it", text: $model.liveTitle)
                .padding(.horizontal, 16).frame(minHeight: 52)
                .background(Palette.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityIdentifier("radioTitle")
            Text("Quality").font(Typo.secondary).foregroundStyle(Palette.dimInk)
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                Chip(title: "Voice", selected: preset == Int(AudioLive.presetVoice)) { preset = Int(AudioLive.presetVoice) }
                Chip(title: "Low data", selected: preset == Int(AudioLive.presetLowData)) { preset = Int(AudioLive.presetLowData) }
                Chip(title: "Music", selected: preset == Int(AudioLive.presetMusic)) { preset = Int(AudioLive.presetMusic) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Audio only quality")
            Text("\(qualityName): about \(AudioLive.presetKbps(UInt8(preset))) kbps over the air").font(.footnote).foregroundStyle(Palette.dimInk)
            Text(micNote).font(.footnote).foregroundStyle(Palette.dimInk).fixedSize(horizontal: false, vertical: true)
            Text("Ready. Nobody is listening yet").font(.body).foregroundStyle(.white).accessibilityIdentifier("radioSetupStatus")
            CapsuleButton(title: "Start", kind: .white) { model.startRadio(preset: UInt8(preset)) }
                .accessibilityIdentifier("radioStart")
            if !live.state.isEmpty {
                Text(live.state).font(.body).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Android audio_live_mic_note. The Mac turns the microphone off on Pause as Android; the iPhone keeps it on so iOS
    /// does not suspend a broadcast running with the screen off (`AppSettings.radioPauseMicOff`).
    private var micNote: String {
        AppPlatform.isMac && AppSettings.radioPauseMicOff
            ? "Mute sends silence, but the microphone stays on. Pause turns the microphone off. Audio already sent may still play for listeners."
            : "Mute sends silence. Pause stops sending; the microphone stays on so the broadcast can continue with the screen off. Audio already sent may still play for listeners."
    }

    /// Android audioStatusText, in its order (paused, muted, no listener, listeners).
    private var radioStatus: String {
        if live.paused { return AppPlatform.isMac && AppSettings.radioPauseMicOff ? "Paused. The microphone is off" : "Paused. Nothing is being sent" }
        if live.muted { return "Muted. Sending silence" }
        return live.viewers.isEmpty ? "Live. Waiting for listeners" : "Live. \(live.viewers.count) listening"
    }

    private var onAir: some View {
        VStack(spacing: 18) {
            Text(live.title ?? "Audio only").font(.title2.weight(.semibold)).foregroundStyle(.white).multilineTextAlignment(.center)
            ProgressView(value: live.level).progressViewStyle(.linear).tint(.white).frame(maxWidth: 280)
                .accessibilityLabel("Microphone level")
            Text(radioStatus).font(.body).foregroundStyle(.white).multilineTextAlignment(.center)
                .accessibilityIdentifier("radioStatus")
            notices
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
            layout {
                muteButton.frame(maxWidth: typeSize.isAccessibilitySize ? nil : .infinity)
                endButton.frame(maxWidth: typeSize.isAccessibilitySize ? nil : .infinity)
                pauseButton.frame(maxWidth: typeSize.isAccessibilitySize ? nil : .infinity)
            }
            .frame(maxWidth: 360)
            Button("Switch to video") { model.switchRadioToVideo() }
                .font(Typo.secondary.weight(.semibold)).foregroundStyle(.white).buttonStyle(.plain)
                .accessibilityIdentifier("switchToVideo")
            Text(micNote).font(.footnote).foregroundStyle(Palette.dimInk).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}
