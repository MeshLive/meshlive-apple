import SwiftUI
import NearbyCore

/// List wording (Android 2026-10-17): the advertised title plainly, else "Live from <name>"; the route in words.
extension StreamRow {
    var listTitle: String { advertisedTitle ?? "Live from \(label.title)" }
    var listDetail: String {
        var text = announcement.routeCost == 0 ? "Nearby" : "Through \(announcement.routeCost) other phone\(announcement.routeCost == 1 ? "" : "s")"
        if audioOnly { text = "Audio only, " + text }
        if paused { text += ", paused" } else if full { text += ", full right now" }
        return text
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

/// The viewer screen: the picture, a Live tag, and only two controls: the lock (stream info) and Leave.
private struct WatchPlayer: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var watch: WatchController
    @ObservedObject var sink: VideoSink
    let title: String
    var leave: (() -> Void)? = nil
    @State private var showInfo = false
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurfaceView(sink: sink).ignoresSafeArea()
            VStack {
                HStack(alignment: .top) {
                    if watch.sourceFingerprint != nil && watch.ended == nil { LiveTag(text: watch.paused ? "Paused" : "Live", blinking: !watch.paused) }
                    Spacer()
                    if watch.sourceFingerprint != nil {
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
                    Label("Sharing with a phone near you", systemImage: "arrow.triangle.branch").font(Typo.caption).foregroundStyle(.white.opacity(0.85))
                }
                RoundControl(icon: "xmark", label: "Leave") { watch.stop(); if let leave { leave() } else { dismiss() } }
                    .padding(.top, 12)
            }
            .padding(16)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showInfo) { NavigationStack { StreamInfoSheet(watch: watch, title: title) }.desktopReadingSize() }
    }
}

/// Listening to an audio-only stream: black, the radio glyph, the title, "Audio only", the state and Leave.
/// It keeps playing with the screen locked or MeshLive in the background.
private struct RadioPlayer: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var watch: WatchController
    let title: String
    var leave: (() -> Void)? = nil
    @State private var showInfo = false
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if typeSize.isAccessibilitySize {
                ScrollView { playerContent }
            } else { playerContent }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showInfo) { NavigationStack { StreamInfoSheet(watch: watch, title: title) }.desktopReadingSize() }
    }
    private var playerContent: some View {
        VStack(spacing: 18) {
                HStack(alignment: .top) {
                    if watch.sourceFingerprint != nil && watch.ended == nil { LiveTag(text: watch.paused ? "Paused" : "Live", blinking: !watch.paused) }
                    Spacer()
                    if watch.sourceFingerprint != nil {
                        Button { showInfo = true } label: {
                            Image(systemName: AppIcon.lock).font(.title3).frame(width: 44, height: 44).foregroundStyle(.white)
                        }
                        .accessibilityLabel("Stream info: encryption and source")
                    }
                }
                Spacer()
                IconDisc(icon: "radio", size: 120)
                Text(title).font(.title2.weight(.semibold)).foregroundStyle(.white).multilineTextAlignment(.center).lineLimit(typeSize.isAccessibilitySize ? nil : 3)
                Text(subtitle).font(.subheadline).foregroundStyle(Palette.dimInk)
                if !watch.state.isEmpty {
                    Text(watch.state).font(.body).foregroundStyle(.white).multilineTextAlignment(.center)
                }
                Spacer()
                Text(AppPlatform.isMac ? "Keeps playing with the display off while this Mac is awake." : "Keeps playing with the screen off.").font(.footnote).foregroundStyle(Palette.dimInk)
                RoundControl(icon: "xmark", label: "Leave") { watch.stop(); if let leave { leave() } else { dismiss() } }
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

/// Stream info behind the lock: encryption, the source and the route (the only place with these details).
struct StreamInfoSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var watch: WatchController
    let title: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section {
                InfoLine(icon: AppIcon.lock, tint: Palette.connected, title: "Encrypted end to end", detail: "Only phones that join this stream can see it.")
                if let fp = watch.sourceFingerprint {
                    let verified = model.verificationState(of: fp) == .verified
                    InfoLine(icon: verified ? AppIcon.verified : AppIcon.unverified, tint: verified ? Palette.connected : Palette.dimInk,
                             title: verified ? "Verified source" : "Source not verified", detail: verified ? "You checked this person's code in person." : "Verify them in person to be sure who is broadcasting.")
                }
                InfoLine(icon: "point.3.connected.trianglepath.dotted", tint: Palette.dimInk, title: watch.route == "direct" ? "Directly from the broadcaster" : "Through other phones near you",
                         detail: watch.route == "direct" ? "No other phone passes it on." : "Phones in between pass it on; they cannot change it.")
            }
            Section("Link details") { Text(watch.stats).font(Typo.caption).foregroundStyle(Palette.dimInk) }
        }
        .monoList()
        .navigationTitle(title).mobileNavigationTitle(inline: true)
        .toolbar { Button("Done") { dismiss() } }
    }
}

/// The broadcaster screen, with a scrolling control column at accessibility text sizes.
struct LivePanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var live: LiveController
    @Environment(\.dynamicTypeSize) private var typeSize
    private var radioSubtitle: String {
        let quality = live.preset == AudioLive.presetLowData ? "Low data" : live.preset == AudioLive.presetMusic ? "Music" : "Voice"
        return "Audio only · \(quality) · keeps going with the screen off"
    }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let camera = live.camera { CameraPreviewView(session: camera.session).ignoresSafeArea() }
            if typeSize.isAccessibilitySize {
                ScrollView {
                    VStack(spacing: 24) {
                        status
                        if live.audioOnly { radioContent }
                        controls
                    }
                    .padding(20)
                }
            } else {
                if live.audioOnly { radioContent.padding(20) }
                VStack {
                    status
                    if let health = model.healthMessage {
                        Label(health, systemImage: "thermometer.medium").font(Typo.caption).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.5), in: Capsule())
                    }
                    Spacer()
                    controls
                        .padding(.vertical, 20).frame(maxWidth: .infinity)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
                }
                .padding(.horizontal, 16)
            }
        }
        .preferredColorScheme(.dark)
    }
    private var status: some View {
        VStack(spacing: 12) {
            HStack {
                if !live.state.isEmpty {
                    Text(live.state).font(Typo.secondary).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.black.opacity(0.5), in: Capsule())
                }
                Spacer()
                LiveTag(text: live.paused ? "Paused" : "Live  \(live.viewers.count)", blinking: !live.paused)
                    .accessibilityLabel(live.paused ? "Paused" : "Live, \(live.viewers.count) \(live.audioOnly ? "listeners" : "viewers")")
            }
            if typeSize.isAccessibilitySize, let health = model.healthMessage {
                Label(health, systemImage: "thermometer.medium").font(Typo.caption).foregroundStyle(.white)
            }
        }
    }
    private var radioContent: some View {
        VStack(spacing: 16) {
            IconDisc(icon: "radio", size: 120)
            Text(live.title ?? "Audio only").font(.title2.weight(.semibold)).foregroundStyle(.white).multilineTextAlignment(.center)
            Text(radioSubtitle).font(.subheadline).foregroundStyle(Palette.dimInk).multilineTextAlignment(.center)
        }
    }
    private var controls: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 16)) : AnyLayout(HStackLayout(spacing: 40))
        return layout {
            if live.audioOnly {
                RoundControl(icon: live.muted ? "mic.slash.fill" : "mic.fill", label: live.muted ? "Unmute" : "Mute",
                             fill: live.muted ? .white : Palette.callControl, foreground: live.muted ? .black : .white) { live.toggleMute() }
            }
            RoundControl(icon: live.paused ? "play.fill" : "pause.fill", label: live.paused ? "Resume" : "Pause") { live.togglePause() }
            RoundControl(icon: "stop.fill", label: "End", fill: Palette.liveEnd, size: 68) { live.stop() }
        }
    }
}
