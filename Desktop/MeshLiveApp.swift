import SwiftUI
import AppKit

final class DesktopNavigation: ObservableObject {
    @Published var selection: MainTab? = .live { didSet { detailPath = [] } }
    @Published var detailPath: [DesktopDetailRoute] = []
    @Published var goLive = false
    @Published var watching: StreamRow?
    var openMain: (() -> Void)?
    weak var mainWindow: NSWindow?
    var prepared = false
}

/// Explicit native detail destinations let sidebar/menu navigation clear a pushed page.
struct DesktopDetailRoute: Hashable {
    let id: UUID
    let content: AnyView
    init<Content: View>(id: UUID = UUID(), @ViewBuilder content: () -> Content) {
        self.id = id; self.content = AnyView(content())
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@main
struct MeshLiveDesktopApp: App {
    @NSApplicationDelegateAdaptor(DesktopAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var navigation = DesktopNavigation()
    @State private var settingsPath: [DesktopDetailRoute] = []

    init() {
        // This app has no document-opening command line. Keep DEBUG argument values out of AppKit file-open handling.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": false])
    }
    var body: some Scene {
        WindowGroup("MeshLive", id: "main") {
            RootView()
                .desktopReadingSize()
                .environmentObject(model)
                .environmentObject(navigation)
                .defaultAppStorage(DesktopPreview.preferences)
                .frame(minWidth: 800, minHeight: 560)
                .preferredColorScheme(.dark)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1000, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Go live") { navigation.openMain?(); navigation.selection = .live; navigation.goLive = true }
                    .keyboardShortcut("g")
                    .disabled(model.call != nil || model.watch != nil || model.live != nil)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Show MeshLive") { navigation.openMain?() }.keyboardShortcut("0")
            }
            CommandMenu("Navigate") {
                Button("Live") { navigation.openMain?(); navigation.selection = .live }.keyboardShortcut("1")
                Button("Calls") { navigation.openMain?(); navigation.selection = .calls }.keyboardShortcut("2")
                Button("Contacts") { navigation.openMain?(); navigation.selection = .contacts }.keyboardShortcut("3")
                Button("Settings") { navigation.openMain?(); navigation.selection = .settings }.keyboardShortcut("4")
            }
        }
        Settings {
            NavigationStack(path: $settingsPath) {
                SettingsView().navigationDestination(for: DesktopDetailRoute.self) { $0.content }
            }
                .background(DesktopWindowReference { _ in })
                .desktopReadingSize()
                .environmentObject(model)
                .defaultAppStorage(DesktopPreview.preferences)
                .frame(minWidth: 600, idealWidth: 680, minHeight: 550, idealHeight: 700)
                .preferredColorScheme(.dark)
        }
    }
}

struct DesktopRootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var navigation: DesktopNavigation
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @State private var onboardingDismissed = false
    @Environment(\.openWindow) private var openWindow
    @AppStorage("desktopKeepRunningWithWindowClosed") private var keepRunning = false
    @State private var recent = false
    @State private var goLiveChoice: (audioOnly: Bool, preset: UInt8)?

    private func sidebarItem(_ title: String, icon: String, tab: MainTab, id: String) -> some View {
        Button { navigation.selection = tab } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Palette.ink)
        .listRowBackground(navigation.selection == tab ? Palette.chip : Palette.ground)
        .accessibilityLabel(title)
        .accessibilityValue(navigation.selection == tab ? "Selected" : "")
        .accessibilityIdentifier("desktop-tab-" + id)
    }

    var body: some View {
        Group {
            if model.wiped {
                WipedView()
            } else if let error = model.identityError {
                EmptyState(icon: "key.slash", title: "Identity unavailable", message: error)
            } else if !onboardingDismissed && (RootView.debugScreenName == "onboarding" || (!onboardingComplete && !RootView.bypassesOnboarding)) {
                OnboardingView {
                    onboardingComplete = true
                    onboardingDismissed = true
                    model.start()
                }
                .frame(maxWidth: 680).padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NavigationSplitView {
                    List {
                        sidebarItem("Live", icon: "dot.radiowaves.left.and.right", tab: .live, id: "live")
                        sidebarItem("Calls", icon: "phone", tab: .calls, id: "calls")
                        sidebarItem("Contacts", icon: "person.2", tab: .contacts, id: "contacts")
                        sidebarItem("Settings", icon: "gearshape", tab: .settings, id: "settings")
                    }
                    .listStyle(.sidebar).scrollContentBackground(.hidden)
                    .tint(Palette.chip)
                    .background(Palette.ground)
                    .safeAreaInset(edge: .bottom) {
                        if DesktopPreview.enabled {
                            Text("Preview · Bluetooth and media are off")
                                .font(.caption).foregroundStyle(Palette.dimInk)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(12).frame(maxWidth: .infinity)
                                .background(Palette.ground)
                        }
                    }
                    .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
                } detail: {
                    Group {
                        if let call = model.call { CallView(call: call) }
                        else if let live = model.live { LivePanel(live: live) }
                        else if let row = navigation.watching { WatchView(row: row, onLeave: { navigation.watching = nil }, stopOnDisappear: !keepRunning) }
                        else {
                            NavigationStack(path: $navigation.detailPath) {
                                Group {
                                    switch navigation.selection ?? .live {
                                    case .live: LiveTab()
                                    case .calls: CallsTab(showRecent: $recent)
                                    case .contacts: ContactsTab { recent = false; navigation.selection = .calls }
                                    case .settings: SettingsView()
                                    }
                                }
                                .navigationDestination(for: DesktopDetailRoute.self) { $0.content }
                            }
                            .frame(maxWidth: 800)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .background(Palette.ground)
                }
                .navigationTitle("MeshLive")
            }
        }
        .background(Palette.ground)
        .background(DesktopWindowReference { navigation.mainWindow = $0 })
        .tint(.white)
        .sheet(isPresented: $navigation.goLive, onDismiss: {
            if let choice = goLiveChoice {
                goLiveChoice = nil
                model.goLive(audioOnly: choice.audioOnly, preset: choice.preset)
            }
        }) {
            GoLiveSheet { audioOnly, preset in
                goLiveChoice = (audioOnly, preset)
                navigation.goLive = false
            }
            .environmentObject(model)
        }
        .alert("Erase everything now?", isPresented: $model.askQuickWipe) {
            Button("Erase now", role: .destructive) { model.emergencyWipe() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes your identity keys, verified contacts and settings. It cannot be undone.")
        }
        .onAppear {
            navigation.openMain = {
                if let window = navigation.mainWindow { window.makeKeyAndOrderFront(nil) }
                else { openWindow(id: "main") }
            }
            guard !navigation.prepared else { return }
            navigation.prepared = true
            switch RootView.debugScreenName {
            case "people": navigation.selection = .calls
            case "contacts", "verify": navigation.selection = .contacts
            case "settings", "privacy", "advanced-privacy", "experiments", "connection", "about": navigation.selection = .settings
            default: break
            }
            model.configureCallAlerts()
            #if DEBUG
            if let fixture = RootView.debugArgument("-NearbyFixture") { model.applyDebugFixture(fixture) }
            if let screen = RootView.debugScreenName, screen.hasPrefix("call") { model.showDebugCall(screen) }
            if RootView.debugScreenName == "broadcast-radio" { model.showDebugBroadcast() }
            if RootView.debugScreenName == "radio" { navigation.watching = model.streams.first(where: \.audioOnly) }
            #endif
            if onboardingComplete || RootView.bypassesOnboarding { model.start() }
        }
    }
}
