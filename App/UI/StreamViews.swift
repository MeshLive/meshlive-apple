import SwiftUI
import NearbyCore

struct WatchListView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List {
            if !model.streams.isEmpty {
                Section {
                    ForEach(model.streams) { row in
                        NavigationLink { WatchView(row: row) } label: {
                            HStack(spacing: 12) {
                                MonogramView(label: row.label, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title).font(Typo.rowTitle)
                                    Text(row.detail).font(Typo.secondary).foregroundStyle(Palette.dimInk)
                                }
                            }
                        }
                        .disabled(model.watch != nil || model.live != nil)
                    }
                }
            }
        }
        .monoList()
        .overlay {
            if model.streams.isEmpty { EmptyState(icon: AppIcon.watch, title: "No one is live nearby yet", message: "Streams appear here automatically.") }
        }
        .navigationTitle("Watch")
    }
}

struct WatchView: View {
    @EnvironmentObject var model: AppModel
    let row: StreamRow
    var body: some View {
        Group {
            if let watch = model.watch { WatchPlayer(watch: watch, sink: watch.remote.sink, title: watch.signedTitle ?? row.label.title) }
            else { Color.black.ignoresSafeArea() }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { if model.watch == nil { model.startWatching(row) } }
        .onDisappear { model.watch?.stop() }
    }
}

/// The viewer screen: the picture, a Live tag, and only two controls: the lock (stream info) and Leave.
private struct WatchPlayer: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var watch: WatchController
    @ObservedObject var sink: VideoSink
    let title: String
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
                RoundControl(icon: "xmark", label: "Leave") { watch.stop(); dismiss() }
                    .padding(.top, 12)
            }
            .padding(16)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showInfo) { NavigationStack { StreamInfoSheet(watch: watch, title: title) } }
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
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Done") { dismiss() } }
    }
}

struct LiveView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Group {
            if let live = model.live { LivePanel(live: live) }
            else {
                List {
                    Section {
                        Text("Share your camera and voice with phones nearby. Each viewer connects to you directly, and the video is encrypted end to end.")
                            .font(Typo.body)
                    } footer: { FooterText("Anyone nearby who opens Watch can see it.") }
                    if model.peerLabelsEnabled {
                        Section {
                            TextField("Title (optional)", text: $model.liveTitle)
                        } footer: { FooterText("Experimental. Signed with your ID; people nearby see it before they join.") }
                    }
                }
                .monoList()
                .safeAreaInset(edge: .bottom) {
                    PrimaryButton(title: "Go live", systemImage: AppIcon.goLive) { model.goLive() }
                        .disabled(model.call != nil || model.watch != nil)
                        .padding(.horizontal, 20).padding(.vertical, 8).background(.bar)
                }
            }
        }
        .navigationTitle("Go live")
    }
}

private struct LivePanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var live: LiveController
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let camera = live.camera { CameraPreviewView(session: camera.session).ignoresSafeArea() }
            VStack {
                HStack {
                    if !live.state.isEmpty {
                        Text(live.state).font(Typo.secondary).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.black.opacity(0.5), in: Capsule())
                    }
                    Spacer()
                    LiveTag(text: live.paused ? "Paused" : "Live  \(live.viewers.count)", blinking: !live.paused)
                }
                if let health = model.healthMessage {
                    Label(health, systemImage: "thermometer.medium").font(Typo.caption).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.5), in: Capsule())
                }
                Spacer()
                HStack(spacing: 40) {
                    RoundControl(icon: live.paused ? "play.fill" : "pause.fill", label: live.paused ? "Resume" : "Pause") { live.togglePause() }
                    RoundControl(icon: "stop.fill", label: "End", fill: Palette.callEnd, size: 68) { live.stop() }
                }
                .padding(.vertical, 20).frame(maxWidth: .infinity)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            }
            .padding(.horizontal, 16)
        }
        .preferredColorScheme(.dark)
    }
}
