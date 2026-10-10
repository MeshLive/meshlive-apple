import SwiftUI
import NearbyCore

/// Home: the same screen and flow as Android (status line, "Your ID", Watch, Go live, and one primary
/// "Call someone" at the bottom where the thumb rests), rendered the iOS way: a large navigation title with
/// Settings in the toolbar, an inset grouped list, and a prominent bottom button. There is no push-to-talk
/// mode: a call has Mute, and while muted, holding Mute talks (user decision, 2026-10-10).
struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmPanic = false
    @State private var showPeople = false

    var body: some View {
        List {
            Section {
                StatusRow(title: state.title, detail: state.detail, ok: state.ok, action: state.action.map { title in
                    (title, { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } })
                })
                .contentShape(Rectangle())
                .onTapGesture(count: 3) { confirmPanic = true }
                NavigationLink { VerifyView() } label: {
                    RowLabel(title: "Your ID \(model.handle)", subtitle: "Show your code or verify someone", icon: AppIcon.identity, tint: Palette.dimInk)
                }
            }
            if !model.recentCalls.isEmpty {
                Section("Recent calls") {
                    ForEach(model.recentCalls.prefix(3)) { RecentCallRow(record: $0) }
                }
            }
            Section {
                NavigationLink { WatchListView() } label: {
                    RowLabel(title: "Watch", subtitle: "Live video from phones nearby", icon: AppIcon.watch, tint: Palette.ink)
                }
                NavigationLink { LiveView() } label: {
                    RowLabel(title: "Go live", subtitle: "Broadcast your camera to phones nearby", icon: AppIcon.goLive, tint: Palette.recordRed)
                }
            }
            if let notice = model.callNotice {
                Section { NoticeRow(text: notice) { model.callNotice = nil } }
            }
        }
        .monoList()
        .navigationTitle("MeshLive")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SettingsView() } label: { Image(systemName: AppIcon.settings) }.accessibilityLabel("Settings")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Text("Encrypted voice and video calls with people nearby").font(Typo.secondary).foregroundStyle(Palette.dimInk)
                    .multilineTextAlignment(.center)
                PrimaryButton(title: "Call someone", systemImage: AppIcon.call) { showPeople = true }
                    .accessibilityHint("Shows the people you can reach")
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 8)
            .background(.bar)
        }
        .navigationDestination(isPresented: $showPeople) { PeopleView() }
        .alert("Erase everything now?", isPresented: $confirmPanic) {
            Button("Erase now", role: .destructive) { model.emergencyWipe() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This deletes your identity keys, verified contacts and settings. It cannot be undone.") }
    }

    /// Android's readiness states and wording.
    private var state: (title: String, detail: String, ok: Bool, action: String?) {
        switch model.radio.central?.state {
        case .poweredOff?: return ("Bluetooth off", "Turn it on to call, talk or go live", false, "Open Settings")
        case .unauthorized?: return ("Access needed", "Bluetooth, camera and microphone", false, "Open app settings")
        case .unsupported?: return ("No Bluetooth", "This phone cannot reach other phones", false, nil)
        default: break
        }
        if let problem = model.bluetoothProblem { return ("Bluetooth problem", problem, false, nil) }
        return model.availableForCalls ? ("Bluetooth on \u{00B7} Reachable for calls", "Keep MeshLive open to be reached", true, nil)
            : ("Bluetooth on \u{00B7} Not reachable for calls", "Turn on Reachable for calls in Settings", true, nil)
    }
}

struct PersonRowView: View {
    @EnvironmentObject var model: AppModel
    let person: PersonRow
    var body: some View {
        HStack(spacing: 12) {
            MonogramView(label: person.label, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.label.title).font(Typo.rowTitle)
                Text(person.routeText).font(Typo.secondary).foregroundStyle(Palette.dimInk)
            }
            Spacer()
            Button { model.startCall(to: person, type: .voice) } label: { Image(systemName: AppIcon.call) }
                .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(Palette.ink)
                .accessibilityLabel("Voice call \(person.label.title)")
            Button { model.startCall(to: person, type: .video) } label: { Image(systemName: AppIcon.video) }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Palette.accent).foregroundStyle(Palette.onAccent)
                .accessibilityLabel("Video call \(person.label.title)")
        }
        .disabled(model.call != nil)
    }
}

/// "People nearby": the people you can call, the same list and wording as Android.
struct PeopleView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List {
            if let notice = model.callNotice {
                Section { NoticeRow(text: notice) { model.callNotice = nil } }
            }
            if model.peerLabelsEnabled && !model.people.isEmpty {
                Section {
                    TextField("Subject (optional)", text: $model.pendingCallSubject)
                } footer: { FooterText("Experimental. Sent with your next call, signed with your ID.") }
            }
            if !model.people.isEmpty {
                Section { ForEach(model.people) { PersonRowView(person: $0) } }
            }
        }
        .monoList()
        .overlay {
            if model.people.isEmpty {
                EmptyState(icon: AppIcon.people, title: "No one found yet",
                           message: "Ask the other person to open Call on their phone. Stay within about 10 to 30 metres. The list updates by itself.")
            }
        }
        .navigationTitle("People nearby")
    }
}


/// One recent call: who, what and when; one tap calls back (if they are nearby now).
struct RecentCallRow: View {
    @EnvironmentObject var model: AppModel
    let record: CallRecord
    var body: some View {
        let label = PeerLabel(prefix: Data(hex: record.prefixHex) ?? Data(count: 6), contactName: model.contactName(prefixHex: record.prefixHex))
        HStack(spacing: 12) {
            Image(systemName: icon).fontWeight(.light).foregroundStyle(Palette.dimInk).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label.title).font(Typo.rowTitle).foregroundStyle(Palette.ink)
                Text(detail).font(Typo.secondary).foregroundStyle(Palette.dimInk)
            }
            Spacer()
            Button { model.callBack(record) } label: { Image(systemName: record.video ? AppIcon.video : AppIcon.call) }
                .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(Palette.ink)
                .accessibilityLabel("Call \(label.title) back")
        }
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
