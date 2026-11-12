import SwiftUI
#if os(iOS)
import UIKit
#endif
import NearbyCore

// MARK: - Live

/// Live tab: the streams nearby (Android list: title on up to two lines, grey route line, chevron) and the red
/// "Go live" capsule. The iPhone broadcasts video and audio only (no audio-only stream in NearbyCore), so
/// Go live starts the camera broadcast directly; with names and titles on, a sheet asks for the optional title first.
struct LiveTab: View {
    @EnvironmentObject var model: AppModel
    #if os(macOS)
    @EnvironmentObject private var desktop: DesktopNavigation
    #endif
    @State private var watching: StreamRow?
    @State private var showGoLive = false
    @State private var startAfterSheet: (audioOnly: Bool, preset: UInt8)?

    var body: some View {
        let status = RadioStatus(model: model)
        TabPage {
            TabHeader(title: "MeshLive", showsLogo: true)
            if !status.ok { StatusCard(status: status) }
            if let notice = model.liveNotice {
                NoticeCard(text: notice.text, actionTitle: notice.offersRescan ? "Try again" : nil,
                           action: notice.offersRescan ? { model.rescanStreams() } : nil) { model.dismissLiveNotice() }
            }
            Text("Live nearby").font(.title3.weight(.semibold)).foregroundStyle(Palette.dimInk)
                .padding(.top, 10).padding(.bottom, 4).accessibilityAddTraits(.isHeader)
            if model.streams.isEmpty {
                PlainEmptyState(icon: "dot.radiowaves.left.and.right", title: "No one is live nearby", message: "Livestreams from people nearby show up here.")
                    .padding(.top, 110)
                if status.ok {
                    Text("Looking for livestreams nearby\u{2026}").font(Typo.secondary).foregroundStyle(Palette.dimInk)
                        .frame(maxWidth: .infinity).padding(.top, 12)
                        .accessibilityIdentifier("liveScanning")
                }
            } else {
                ForEach(Array(model.streams.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { ListDivider(inset: 64) }
                    Button {
                        #if os(macOS)
                        desktop.watching = row
                        #else
                        watching = row
                        #endif
                    } label: { StreamRowView(row: row) }
                        .buttonStyle(.plain)
                        .disabled(model.watch != nil || model.live != nil || !row.joinable)
                        .opacity(row.joinable ? 1 : 0.6)
                }
            }
        } bottom: {
            if model.sourceGate.showsSourceControls {
                CapsuleButton(title: "Go live", systemImage: "dot.radiowaves.left.and.right", kind: .whiteLive) { showGoLive = true }
                .disabled(model.call != nil || model.watch != nil || model.live != nil)
                .accessibilityHint("Choose video and audio, or audio only, for phones nearby")
            } else {
                Text(StreamSourceGate.laterNotice).font(Typo.secondary).foregroundStyle(Palette.dimInk)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    .accessibilityIdentifier("liveSourceLater")
            }
        }
        .meshFullScreenCover(item: $watching) { WatchView(row: $0) }
        #if DEBUG && os(iOS)
        // The automation hooks open the player as a tap does (WatchView joins only if the hook has not already).
        .onReceive(model.$debugOpenStream.compactMap { $0 }) { row in watching = row; model.debugOpenStream = nil }
        #endif
        .onChange(of: model.liveNotice) { notice in
            // The lost-stream end closes the watch screen; the list underneath shows the notice and Try again.
            if notice?.closesWatch == true { watching = nil }
        }
        .onAppear {
            // DEBUG screenshot aids: the Go live sheet and the radio player (fixture row).
            switch RootView.debugScreenName {
            case "golive": if model.sourceGate.showsSourceControls { showGoLive = true }
            case "radio":
                #if os(iOS)
                watching = model.streams.first(where: \.audioOnly)
                #endif
            default: break
            }
        }
        .background(
            Color.clear
                .sheet(isPresented: $showGoLive, onDismiss: {
                    if let choice = startAfterSheet { startAfterSheet = nil; model.goLive(audioOnly: choice.audioOnly, preset: choice.preset, setup: choice.audioOnly) }
                }) {
                    GoLiveSheet { audioOnly, preset in startAfterSheet = (audioOnly, preset); showGoLive = false }
                }
                .meshFullScreenCover(item: Binding(get: { model.live }, set: { _ in })) { LivePanel(live: $0) }
        )
    }
}

/// One stream row: a consistent leading camera or radio icon (plain, as Android), title and route.
struct StreamRowView: View {
    let row: StreamRow
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: row.audioOnly ? "radio" : "video").font(.system(size: 24)).foregroundStyle(Palette.ink)
                .frame(width: 48, height: 48).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.listTitle).font(.body.weight(.medium)).foregroundStyle(Palette.ink).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .multilineTextAlignment(.leading)
                Text(row.listDetail).font(.subheadline).foregroundStyle(Palette.dimInk)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.body.weight(.semibold)).foregroundStyle(Palette.dimInk).accessibilityHidden(true)
        }
        .padding(.vertical, 10).frame(minHeight: 64)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.audioOnly ? "Audio only stream" : "Video stream")
        .accessibilityIdentifier("stream-\(row.id)")
        .accessibilityHint("Opens the stream")
    }
}

/// "Go live" sheet (Android live2): the optional title (always offered, as Android), Video
/// and audio, or Audio only (radio; its own screen picks the quality and starts).
struct GoLiveSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let start: (_ audioOnly: Bool, _ preset: UInt8) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Go live").font(.title2.weight(.bold)).foregroundStyle(Palette.ink)
                #if os(macOS)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                #endif
            }
            .padding(.top, 24)
            // Android always offers the title (names and titles are always on); it is public to anyone who joins.
            TextField("Stream title (optional)", text: $model.liveTitle)
                .padding(.horizontal, 16).frame(minHeight: 52)
                .background(Palette.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("Public: anyone nearby can read it").font(.footnote).foregroundStyle(Palette.dimInk)
            #if os(macOS)
            DesktopCameraPicker()
            #endif
            // Android: the last choice is drawn white. Audio only opens its own screen (title, quality, Start).
            let audioLast = AppSettings.audioLive && AppSettings.audioLiveLastChoice
            CapsuleButton(title: "Video and audio", systemImage: "video", kind: audioLast ? .dark : .white) { start(false, AudioLive.presetVoice) }
            // Audio-only live streams follow their switch (Android audio_live).
            if AppSettings.audioLive {
                CapsuleButton(title: "Audio only", systemImage: "radio", kind: audioLast ? .white : .dark) { start(true, AudioLive.presetVoice) }
                Text(AppPlatform.isMac ? "Audio only uses less Bluetooth capacity and keeps playing with the display off while this Mac is awake." : "Audio only uses less Bluetooth capacity and keeps playing with the screen off.")
                    .font(.subheadline).foregroundStyle(Palette.dimInk)
            }
          }
          .padding(.horizontal, 20).padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.card.ignoresSafeArea())
        .meshPresentation(height: 490, largeOnly: typeSize.isAccessibilitySize)
        .preferredColorScheme(.dark)
    }
}
