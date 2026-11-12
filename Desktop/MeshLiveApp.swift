import SwiftUI
import AppKit
import CoreWLAN
import NearbyCore

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
    @StateObject private var reachability = DesktopReachabilityMonitor()
    /// Settings › Desktop › Show in menu bar (on by default; README explains why this one switch defaults on).
    @AppStorage(DesktopReachabilitySettings.menuBarKey, store: DesktopPreview.preferences) private var showMenuBar = true

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
                .onAppear {
                    appDelegate.model = model
                    reachability.openMain = { navigation.openMain?() }
                    reachability.attach(model)
                }
        }
        .defaultSize(width: 1000, height: 700)
        .windowResizability(.contentMinSize)
        // The tab's own title row is the visible title (gap audit 1.2); the window title stays for the Window menu.
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                if model.sourceGate.showsSourceControls {
                    Button("Go live") { navigation.openMain?(); navigation.selection = .live; navigation.goLive = true }
                        .keyboardShortcut("g")
                        .disabled(model.call != nil || model.watch != nil || model.live != nil)
                }
            }
            CommandGroup(after: .windowArrangement) {
                Button("Show MeshLive") { navigation.openMain?() }.keyboardShortcut("0")
            }
            // One Settings (owner, 2026-11-05): Cmd+, opens Settings in the main window's sidebar, as the other
            // clients have one Settings tab; there is no separate Settings window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings\u{2026}") { navigation.openMain?(); navigation.selection = .settings }
                    .keyboardShortcut(",")
            }
            CommandMenu("Navigate") {
                Button("Live") { navigation.openMain?(); navigation.selection = .live }.keyboardShortcut("1")
                Button("Calls") { navigation.openMain?(); navigation.selection = .calls }.keyboardShortcut("2")
                Button("Contacts") { navigation.openMain?(); navigation.selection = .contacts }.keyboardShortcut("3")
                Button("Settings") { navigation.openMain?(); navigation.selection = .settings }.keyboardShortcut("4")
            }
        }
        MenuBarExtra(isInserted: $showMenuBar) {
            DesktopMenuBarMenu(monitor: reachability, navigation: navigation)
                .environmentObject(model)
        } label: {
            DesktopMenuBarLabel(state: reachability.state)
        }
    }
}

struct DesktopRootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var navigation: DesktopNavigation
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage("termsAcceptedVersion") private var termsAcceptedVersion = 0
    @State private var onboardingDismissed = false
    @Environment(\.openWindow) private var openWindow
    @AppStorage("desktopKeepRunningWithWindowClosed") private var keepRunning = false
    @State private var recent = false
    /// README screenshots (DEBUG `-NearbyFixture readme`) and store screenshots (DEBUG `-NearbyReadyStatus 1`) leave out
    /// the preview footer.
    private var readmeFixture: Bool {
        #if DEBUG
        model.debugReadme || RootView.debugArgument("-NearbyReadyStatus") == "1"
        #else
        false
        #endif
    }
    @State private var goLiveChoice: (audioOnly: Bool, preset: UInt8)?

    /// The window title names the current tab, as the tab's title row does ("MeshLive" on Live).
    private var windowTitle: String {
        switch navigation.selection ?? .live {
        case .live: return "MeshLive"
        case .calls: return "Calls"
        case .contacts: return "Contacts"
        case .settings: return "Settings"
        }
    }

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
            } else if RootView.onboardingShows(onboardingComplete: onboardingComplete, termsAccepted: termsAcceptedVersion, dismissed: onboardingDismissed) {
                OnboardingView(pages: RootView.onboardingPages(onboardingComplete: onboardingComplete, termsAccepted: termsAcceptedVersion)) {
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
                        if DesktopPreview.enabled && !readmeFixture {
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
                        if let call = model.call, call.presentable { CallView(call: call) }
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
                .navigationTitle(windowTitle)
            }
        }
        .background(Palette.ground)
        .background(DesktopWindowReference { navigation.mainWindow = $0 })
        .tint(.white)
        .sheet(isPresented: $navigation.goLive, onDismiss: {
            if let choice = goLiveChoice {
                goLiveChoice = nil
                model.goLive(audioOnly: choice.audioOnly, preset: choice.preset, setup: choice.audioOnly)
            }
        }) {
            GoLiveSheet { audioOnly, preset in
                goLiveChoice = (audioOnly, preset)
                navigation.goLive = false
            }
            .environmentObject(model)
        }
        .alert("Delete everything?", isPresented: $model.askQuickWipe) {
            Button("Delete everything", role: .destructive) { model.emergencyWipe() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes your identity keys, verified contacts and settings. It cannot be undone.")
        }
        .blockingAlerts()
        .liveStoppedAlert()
        .wifiAdviceAlert()
        .onChange(of: model.liveNotice) { _, notice in
            // The lost-stream end closes the Mac's detail-column watch view; LiveTab underneath shows the notice.
            if notice?.closesWatch == true { navigation.watching = nil }
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
            case "settings", "privacy", "experiments", "connection", "about", "help", "video", "manual": navigation.selection = .settings
            default: break
            }
            model.configureCallAlerts()
            #if DEBUG
            if let fixture = RootView.debugArgument("-NearbyFixture") { model.applyDebugFixture(fixture) }
            if let screen = RootView.debugScreenName, screen.hasPrefix("call") { model.showDebugCall(screen) }
            if let screen = RootView.debugScreenName, screen.hasPrefix("broadcast") { model.showDebugBroadcast(screen) }
            if RootView.debugScreenName == "radio" { navigation.watching = model.streams.first(where: \.audioOnly) }
            #endif
            if !RootView.onboardingShows(onboardingComplete: onboardingComplete, termsAccepted: termsAcceptedVersion, dismissed: false) { model.start() }
        }
    }
}

// MARK: - Wi-Fi advice (Android withWifiCheck; gap audit G62, Q4: Mac only, no Location request)

/// The Mac's Wi-Fi band for the advice: CoreWLAN power and the current channel's band only (never the network name or
/// BSSID, never a Location request). Unknown when Wi-Fi is off or not joined, in the preview, or when macOS withholds
/// the channel; the advice then stays silent. DEBUG `-NearbyWifiBand 2.4|5|6|unknown` fakes it.
enum MacWifiBand {
    static func current() -> WifiAdvice.Band {
        #if DEBUG
        if let fake = UserDefaults.standard.string(forKey: "NearbyWifiBand") { return WifiAdvice.Band(rawValue: fake) ?? .unknown }
        #endif
        guard !DesktopPreview.enabled, let interface = CWWiFiClient.shared().interface(), interface.powerOn(),
              let channel = interface.wlanChannel() else { return .unknown }
        switch channel.channelBand {
        case .band2GHz: return .ghz2_4
        case .band5GHz: return .ghz5
        case .band6GHz: return .ghz6
        default: return .unknown
        }
    }
}

extension AppModel {
    /// Android withWifiCheck before a video call, a video live or watching: true when the advice is shown and `action`
    /// waits for the answer. Never before voice or audio only; once a day (`WifiAdvice.shouldAsk`).
    func askWifiAdvice(voice: Bool, _ action: @escaping () -> Void) -> Bool {
        let band = MacWifiBand.current()
        let ask = WifiAdvice.shouldAsk(enabled: AppSettings.wifiAdvice, band: band, voice: voice,
                                       now: Date().timeIntervalSince1970, answeredAt: AppSettings.wifiAdviceAnsweredAt)
        AppLog.event("wifi_advice", ["band": band.rawValue, "voice": "\(voice)", "asked": "\(ask)"])
        guard ask else { return false }
        wifiAdviceAction = action
        wifiAdviceShown = true
        return true
    }

    /// Either answer counts for a day (Android). Continue anyway goes on at once; Open Wi-Fi settings opens System
    /// Settings › Wi-Fi and goes on when MeshLive is active again within 5 minutes (later, nothing starts by itself).
    func answerWifiAdvice(openSettings: Bool) {
        AppSettings.wifiAdviceAnsweredAt = Date().timeIntervalSince1970
        wifiAdviceShown = false
        guard let action = wifiAdviceAction else { return }
        wifiAdviceAction = nil
        AppLog.event("wifi_advice", ["answer": openSettings ? "open_settings" : "continue"])
        guard openSettings else { action(); return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") { NSWorkspace.shared.open(url) }
        if let old = wifiResumeObserver { NotificationCenter.default.removeObserver(old) }
        let openedAt = ProcessInfo.processInfo.systemUptime
        wifiResumeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if let observer = self.wifiResumeObserver { NotificationCenter.default.removeObserver(observer) }
            self.wifiResumeObserver = nil
            guard ProcessInfo.processInfo.systemUptime - openedAt < 300 else { AppLog.event("wifi_advice", ["resume": "expired"]); return }
            action()
        }
    }
}

/// Android's wifi_advice dialog on the Mac: Open Wi-Fi settings, or Continue anyway (the cancel role).
private struct WifiAdviceAlert: ViewModifier {
    @EnvironmentObject var model: AppModel
    func body(content: Content) -> some View {
        content.alert(WifiAdvice.title, isPresented: $model.wifiAdviceShown) {
            Button(WifiAdvice.openSettings) { model.answerWifiAdvice(openSettings: true) }
            Button(WifiAdvice.continueAnyway, role: .cancel) { model.answerWifiAdvice(openSettings: false) }
        } message: { Text(WifiAdvice.message) }
    }
}

extension View {
    func wifiAdviceAlert() -> some View { modifier(WifiAdviceAlert()) }
}
