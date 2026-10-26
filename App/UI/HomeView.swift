import SwiftUI
#if os(iOS)
import UIKit
#endif
import NearbyCore

/// The four tabs of the Android app (2026-10-17 redesign): Live, Calls, Contacts and Settings. Each tab root draws
/// its own large title with the status dot (as Android); pushed pages use the system navigation bar.
enum MainTab: Hashable { case live, calls, contacts, settings }

struct MainTabs: View {
    @EnvironmentObject var model: AppModel
    @State private var tab: MainTab
    @State private var callsShowRecent = false

    init(initial: MainTab = .live) {
        _tab = State(initialValue: initial)
        #if os(iOS)
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .black
        appearance.shadowColor = UIColor(white: 1, alpha: 0.08)
        for item in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            item.normal.iconColor = UIColor(white: 0.62, alpha: 1)
            item.normal.titleTextAttributes = [.foregroundColor: UIColor(white: 0.62, alpha: 1)]
            item.selected.iconColor = .white
            item.selected.titleTextAttributes = [.foregroundColor: UIColor.white]
        }
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        #endif
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { LiveTab() }
                .tabItem { Label("Live", systemImage: "dot.radiowaves.left.and.right") }.tag(MainTab.live)
            NavigationStack { CallsTab(showRecent: $callsShowRecent) }
                .tabItem { Label("Calls", systemImage: "phone") }.tag(MainTab.calls)
            NavigationStack { ContactsTab { callsShowRecent = false; tab = .calls } }
                .tabItem { Label("Contacts", systemImage: "person.2") }.tag(MainTab.contacts)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(MainTab.settings)
        }
        .tint(.white)
        .alert("Erase everything now?", isPresented: $model.askQuickWipe) {
            Button("Erase now", role: .destructive) { model.emergencyWipe() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This deletes your identity keys, verified contacts and settings. It cannot be undone.") }
    }
}

/// DEBUG screenshot aid: pushes `destination` once when `-NearbyScreen <screen>` names it.
struct DebugPush<Destination: View>: ViewModifier {
    let screen: String
    @ViewBuilder let destination: () -> Destination
    @State private var shown = false
    @State private var done = false
    func body(content: Content) -> some View {
        content
            .navigationDestination(isPresented: $shown, destination: destination)
            .onAppear { if !done { done = true; shown = RootView.debugScreenName == screen } }
    }
}
extension View {
    func debugPush<D: View>(_ screen: String, @ViewBuilder _ destination: @escaping () -> D) -> some View {
        modifier(DebugPush(screen: screen, destination: destination))
    }
}

/// A tab root page: black ground, scrolling content with the screen gutter, no navigation bar.
struct TabPage<Content: View, Bottom: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let bottom: Bottom
    @ViewBuilder var body: some View {
        let page = ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .background(Palette.ground.ignoresSafeArea())
        .mobileRootNavigation()
        // No bottom bar for an EmptyView: a padded empty view with a Color background grows to fill the inset
        // and squeezed the page to nothing.
        if Bottom.self == EmptyView.self {
            page
        } else {
            page.safeAreaInset(edge: .bottom) {
                bottom.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 10).background(Palette.ground)
            }
        }
    }
}
extension TabPage where Bottom == EmptyView {
    init(@ViewBuilder content: () -> Content) { self.content = content(); self.bottom = EmptyView() }
}

/// A dismissible notice card ("Couldn't reach ..."), optionally with one action ("Call again").
struct NoticeCard: View {
    let text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: AppIcon.problem).foregroundStyle(Palette.dimInk).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text(text).font(.subheadline).foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(action: action) {
                        Text(actionTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 14).padding(.vertical, 8).background(Color.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("notice-action")
                }
            }
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(Palette.dimInk)
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(14).background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .padding(.vertical, 6)
    }
}

/// The last call problem with "Call again" when it was a call this device placed (Calls and Contacts).
struct CallNoticeCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let notice = model.callNotice {
            NoticeCard(text: notice, actionTitle: model.callRetry == nil ? nil : "Call again",
                       action: model.callRetry == nil ? nil : { model.callAgain() }) { model.callNotice = nil }
        }
    }
}

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
            Text("Live nearby").font(.title3.weight(.semibold)).foregroundStyle(Palette.dimInk)
                .padding(.top, 10).padding(.bottom, 4).accessibilityAddTraits(.isHeader)
            if model.streams.isEmpty {
                PlainEmptyState(icon: "dot.radiowaves.left.and.right", title: "No one is live nearby", message: "Looking\u{2026}")
                    .padding(.top, 110)
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
                        .disabled(model.watch != nil || model.live != nil)
                }
            }
        } bottom: {
            CapsuleButton(title: "Go live", systemImage: "dot.radiowaves.left.and.right", kind: .whiteLive) { showGoLive = true }
            .disabled(model.call != nil || model.watch != nil || model.live != nil)
            .accessibilityHint("Choose video and audio, or audio only, for phones nearby")
        }
        .meshFullScreenCover(item: $watching) { WatchView(row: $0) }
        .onAppear {
            // DEBUG screenshot aids: the Go live sheet and the radio player (fixture row).
            switch RootView.debugScreenName {
            case "golive": showGoLive = true
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
                    if let choice = startAfterSheet { startAfterSheet = nil; model.goLive(audioOnly: choice.audioOnly, preset: choice.preset) }
                }) {
                    GoLiveSheet { audioOnly, preset in startAfterSheet = (audioOnly, preset); showGoLive = false }
                }
                .meshFullScreenCover(item: Binding(get: { model.live }, set: { _ in })) { LivePanel(live: $0) }
        )
    }
}

/// Shown on Live when the radio is not ready, with the one fix (Android's status line).
struct StatusCard: View {
    let status: RadioStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: AppIcon.problem).foregroundStyle(Palette.ink).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title).font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text(status.detail).font(.subheadline).foregroundStyle(Palette.dimInk)
                }
            }
            if let action = status.action {
                CapsuleButton(title: action, kind: .dark) {
                    if status.opensBluetooth { AppPlatform.openBluetoothSettings() } else { AppPlatform.openSettings() }
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.vertical, 8)
    }
}

/// One stream row: a consistent leading camera or radio icon, title and route.
struct StreamRowView: View {
    let row: StreamRow
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        HStack(spacing: 16) {
            IconDisc(icon: row.audioOnly ? "radio" : "video", size: 48)
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

/// "Go live" sheet (Android live2): Video and audio, or Audio only (radio) with its quality, and the optional
/// signed title when names and titles are on.
struct GoLiveSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let start: (_ audioOnly: Bool, _ preset: UInt8) -> Void
    @AppStorage("audioLivePreset") private var preset = Int(AudioLive.presetVoice)
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
            if model.peerLabelsEnabled {
                TextField("Title (optional)", text: $model.liveTitle)
                    .padding(.horizontal, 16).frame(minHeight: 52)
                    .background(Palette.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            #if os(macOS)
            DesktopCameraPicker()
            #endif
            CapsuleButton(title: "Video and audio", systemImage: "video", kind: .white) { start(false, AudioLive.presetVoice) }
            // Audio-only live streams follow their switch (Android audio_live).
            if AppSettings.audioLive {
                CapsuleButton(title: "Audio only", systemImage: "radio", kind: .dark) { start(true, UInt8(preset)) }
                let qualityLayout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
                qualityLayout {
                    Chip(title: "Voice", selected: preset == Int(AudioLive.presetVoice)) { preset = Int(AudioLive.presetVoice) }
                    Chip(title: "Low data", selected: preset == Int(AudioLive.presetLowData)) { preset = Int(AudioLive.presetLowData) }
                    Chip(title: "Music", selected: preset == Int(AudioLive.presetMusic)) { preset = Int(AudioLive.presetMusic) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Audio only quality")
                Text(AppPlatform.isMac ? "Audio only uses less Bluetooth capacity and keeps playing with the display off while this Mac is awake. Listeners learn your ID." : "Audio only uses less Bluetooth capacity and keeps playing with the screen off. Listeners learn your ID.")
                    .font(.subheadline).foregroundStyle(Palette.dimInk)
            }
          }
          .padding(.horizontal, 20).padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.card.ignoresSafeArea())
        .meshPresentation(height: model.peerLabelsEnabled ? 470 : 400, largeOnly: typeSize.isAccessibilitySize)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Calls

/// Calls tab: Nearby (the people you can call; a check mark only for your verified contacts) and Recent.
/// A row opens "Call <name>" with Voice call and Video call.
struct CallsTab: View {
    @EnvironmentObject var model: AppModel
    @Binding var showRecent: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var picked: PersonRow?

    var body: some View {
        TabPage {
            TabHeader(title: "Calls")
            if !showRecent, let line = model.ownNearbyLine { OwnNearbyNameLine(text: line) }
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
            layout {
                Chip(title: "Nearby", selected: !showRecent) { showRecent = false }
                Chip(title: "Recent", selected: showRecent) { showRecent = true }
            }
            .padding(.vertical, 8)
            if !showRecent, model.bluetoothRestartNeeded { StatusCard(status: RadioStatus(model: model)) }
            CallNoticeCard()
            if showRecent { recent } else { nearby }
        }
        .debugPush("recent-none") { EmptyView() }
        .background(
            Color.clear.confirmationDialog(picked.map { "Call \($0.label.title)" } ?? "Call",
                                isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } }),
                                titleVisibility: .visible, presenting: picked) { person in
                Button("Voice call") { model.startCall(to: person, type: .voice) }.desktopCallShortcut("a")
                Button("Video call") { model.startCall(to: person, type: .video) }.desktopCallShortcut("v")
                Button("Cancel", role: .cancel) {}
            }
        )
    }

    @ViewBuilder private var nearby: some View {
        if model.people.isEmpty {
            PlainEmptyState(icon: AppIcon.people, title: "No one found yet",
                            message: "Ask the other person to open MeshLive. Stay within about 10 to 30 metres. The list updates by itself.")
                .padding(.top, 80)
        } else {
            ForEach(Array(model.people.enumerated()), id: \.element.id) { index, person in
                if index > 0 { ListDivider() }
                Button { picked = person } label: { PersonRowView(person: person) }
                    .buttonStyle(.plain)
                    .disabled(model.call != nil)
            }
        }
    }

    @ViewBuilder private var recent: some View {
        if model.recentCalls.isEmpty {
            PlainEmptyState(icon: "clock", title: "No recent calls").padding(.top, 80)
        } else {
            ForEach(Array(model.recentCalls.enumerated()), id: \.element.id) { index, record in
                if index > 0 { ListDivider(inset: 38) }
                RecentCallRow(record: record)
            }
        }
    }
}

/// One person nearby: name (check mark only for a verified contact), where they are, chevron.
struct PersonRowView: View {
    let person: PersonRow
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(person.label.title).font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.leading)
                    if person.label.contactName != nil {
                        Image(systemName: "checkmark").font(.subheadline.weight(.bold)).foregroundStyle(Palette.ink)
                            .accessibilityLabel("Verified contact")
                    }
                }
                Text(person.routeText).font(.subheadline).foregroundStyle(Palette.dimInk)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.body.weight(.semibold)).foregroundStyle(Palette.dimInk).accessibilityHidden(true)
        }
        .padding(.vertical, 12).frame(minHeight: 72)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("person-\(person.prefixHex)")
        .accessibilityHint("Shows voice and video call")
    }
}

/// One recent call: direction, who, what and when; the round button calls back (if they are nearby now).
struct RecentCallRow: View {
    @EnvironmentObject var model: AppModel
    let record: CallRecord
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let label = PeerLabel(prefix: Data(hex: record.prefixHex) ?? Data(count: 6), contactName: model.contactName(prefixHex: record.prefixHex))
        let title = record.callable ? label.title : (record.name ?? "Someone nearby")
        let text = VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.body.weight(.medium)).foregroundStyle(Palette.ink)
            Text(detail).font(.subheadline).foregroundStyle(Palette.dimInk)
        }
        let callBack = Button { model.callBack(record) } label: {
            Image(systemName: record.video ? "video" : "phone").font(.title3).foregroundStyle(Palette.ink)
                .frame(width: 48, height: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Call \(title) back")
        .opacity(record.callable ? 1 : 0)
        .disabled(!record.callable)
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { text; callBack }
            } else {
                HStack(spacing: 14) {
                    Image(systemName: icon).foregroundStyle(Palette.dimInk).frame(width: 24).accessibilityHidden(true)
                    text
                    Spacer()
                    callBack
                }
            }
        }
        .padding(.vertical, 10)
        .disabled(model.call != nil)
        .accessibilityElement(children: .combine)
    }
    private var icon: String {
        switch record.direction {
        case .outgoing: return "phone.arrow.up.right"
        case .incoming: return "phone.arrow.down.left"
        case .missed: return "phone.down"
        }
    }
    private var detail: String {
        let kind = record.video ? "video" : "voice"
        let what: String
        switch record.direction {
        case .outgoing: what = "Outgoing \(kind)"
        case .incoming: what = "Incoming \(kind)"
        case .missed: what = "Missed \(kind) call"
        }
        let when = RelativeDateTimeFormatter().localizedString(for: record.at, relativeTo: Date())
        return record.seconds > 0 ? "\(what) \u{00B7} \(TimelineFormatter.duration(TimeInterval(record.seconds))) \u{00B7} \(when)" : "\(what) \u{00B7} \(when)"
    }
}

// MARK: - Contacts

/// Contacts tab (Android r4): name, "Nearby now" when in range, then video call, voice call and info.
struct ContactsTab: View {
    @EnvironmentObject var model: AppModel
    #if os(macOS)
    @EnvironmentObject private var desktopNavigation: DesktopNavigation
    #endif
    let openNearby: () -> Void
    @State private var info: VerifiedContact?
    @State private var addContact = false

    var body: some View {
        TabPage {
            TabHeader(title: "Contacts")
            CallNoticeCard()
            if let unreadable = model.contactsUnreadable {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Contacts unavailable").font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text("The saved list could not be opened (\(unreadable)). Everyone counts as unverified until you reset it.")
                        .font(.subheadline).foregroundStyle(Palette.dimInk)
                    CapsuleButton(title: "Reset contacts", kind: .dark) { model.resetContacts() }
                }
                .padding(16).background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).padding(.vertical, 8)
            }
            if model.contacts.isEmpty {
                PlainEmptyState(icon: AppIcon.people, title: "No contacts yet",
                                message: "Meet in person and scan each other's code to add a contact.")
                    .padding(.top, 100)
            } else {
                ForEach(Array(model.contacts.enumerated()), id: \.element.id) { index, contact in
                    if index > 0 { ListDivider() }
                    ContactRow(contact: contact, openNearby: openNearby) { info = contact }
                }
            }
        } bottom: {
            CapsuleButton(title: "Add contact", systemImage: "person.badge.plus", kind: .white) {
                #if os(macOS)
                desktopNavigation.detailPath.append(DesktopDetailRoute { VerifyView() })
                #else
                addContact = true
                #endif
            }
            }
        #if !os(macOS)
        .navigationDestination(isPresented: $addContact) { VerifyView() }
        #endif
        .debugPush("verify") { VerifyView() }
        .sheet(item: $info) { ContactInfoSheet(contact: $0) }
    }
}

struct ContactRow: View {
    @EnvironmentObject var model: AppModel
    let contact: VerifiedContact
    let openNearby: () -> Void
    let showInfo: () -> Void
    @State private var notFound = false
    @Environment(\.dynamicTypeSize) private var typeSize
    private var nearbyPerson: PersonRow? { model.nearbyPerson(for: contact) }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { names; HStack(spacing: 8) { buttons } }
            } else {
                HStack(spacing: 4) { names; Spacer(minLength: 8); buttons }
            }
        }
        .padding(.vertical, 14)
        .alert("\(contact.displayName) is not found nearby yet", isPresented: $notFound) {
            Button("Open Nearby", action: openNearby)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("If you have not talked since adding them, call them once from the Nearby list. After that, Contacts can call them directly.")
        }
    }
    private var names: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(contact.displayName).font(.body.weight(.medium)).foregroundStyle(Palette.ink)
            if nearbyPerson != nil { Text("Nearby now").font(.subheadline).foregroundStyle(Palette.dimInk) }
        }
        .accessibilityElement(children: .combine)
    }
    @ViewBuilder private var buttons: some View {
        iconButton("video", "Video call \(contact.displayName)") { call(.video) }.disabled(model.call != nil)
        iconButton("phone", "Voice call \(contact.displayName)") { call(.voice) }.disabled(model.call != nil)
        iconButton("info.circle", "Contact info \(contact.displayName)", action: showInfo)
    }
    private func iconButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(Palette.ink).frame(width: 48, height: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
    private func call(_ type: CallType) {
        if let person = nearbyPerson { model.startCall(to: person, type: type) }
        else { notFound = true }
    }
}

/// Contact info (Android's sheet): name, how and when verified, short and full ID, presence (rotating IDs), Forget.
/// Rename and Block are Android-only: the iPhone contact book has no rename or block yet.
struct ContactInfoSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let contact: VerifiedContact
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(contact.displayName).font(.title.weight(.bold)).foregroundStyle(Palette.ink)
                        Text("Verified by \(contact.method == "qr" ? "QR code" : "safety code"), \(contact.verifiedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.subheadline).foregroundStyle(Palette.dimInk)
                    }
                    .padding(.horizontal, 6).padding(.top, 8)
                    Card {
                        HStack {
                            Text("ID").font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                            Spacer()
                            Text(IdentityHandle.handle(prefix: Data(hex: contact.nodePrefixHex) ?? Data()) ?? "").font(Typo.code).foregroundStyle(Palette.dimInk)
                        }
                        .padding(.horizontal, 16).frame(minHeight: 56)
                        .accessibilityElement(children: .combine)
                        CardDivider(inset: 16)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Full ID").font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                            Text(grouped(contact.fingerprintHex)).font(.footnote.monospaced()).foregroundStyle(Palette.dimInk).textSelection(.enabled)
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if model.rotatingIds {
                        Card {
                            // Android verify_visible_nearby: default on; off after a delivery starts a new key.
                            SettingsToggleRow(icon: "eye", title: "Can see when I'm nearby",
                                              info: "This contact's phone may recognise yours when it is nearby (shown as unconfirmed, never as verified). Turning it off after they received a key makes this phone start a new key.",
                                              identifier: "canSeeMe-\(contact.displayName)",
                                              isOn: Binding(get: { model.canSeeMe(contact) }, set: { model.setCanSeeMe(contact, $0) }))
                        }
                    }
                    CapsuleButton(title: "Forget", systemImage: "trash", kind: .dark) { confirmForget = true }
                        .padding(.top, 8)
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
            .background(Palette.ground.ignoresSafeArea())
            .mobileNavigationTitle(inline: true)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Forget \(contact.displayName)?", isPresented: $confirmForget) {
                Button("Forget", role: .destructive) { model.forget(contact); dismiss() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("They become unverified on this phone. You can verify them again in person.") }
        }
        .preferredColorScheme(.dark)
    }
    private func grouped(_ hex: String) -> String {
        let chars = Array(hex.uppercased())
        return stride(from: 0, to: chars.count, by: 4).map { String(chars[$0..<min($0 + 4, chars.count)]) }.joined(separator: " ")
    }
}
