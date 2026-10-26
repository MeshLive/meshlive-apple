import AppKit
import Combine
import CoreBluetooth
import ServiceManagement
import SwiftUI

/// Keeps this Mac reachable while another app is in front: drives the menu bar item, the ProcessInfo activity
/// (DesktopReachabilityPolicy) and the incoming-call window from AppModel's live state. Main thread only.
final class DesktopReachabilityMonitor: ObservableObject {
    @Published private(set) var state: DesktopReachabilityState = .notReachable
    @Published private(set) var detail = ""
    /// Brings the main window forward (set by the app scene).
    var openMain: () -> Void = {}

    private weak var model: AppModel?
    private var modelObserver: AnyCancellable?
    private var childObservers: [AnyCancellable] = []
    private var observedChildren: [ObjectIdentifier] = []
    private var notificationObservers: [NSObjectProtocol] = []
    private var fallback: Timer?
    private var scheduled = false
    private let activity = DesktopActivityHolder()
    private let ringPanel = DesktopRingPanel()

    func attach(_ model: AppModel) {
        guard self.model !== model else { return }
        self.model = model
        modelObserver = model.objectWillChange.sink { [weak self] _ in self?.schedule() }
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     UserDefaults.didChangeNotification] {
            notificationObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.schedule() })
        }
        // Bluetooth power changes reach AppModel through the radio callbacks; this slow re-check covers a state that
        // changes without a published model property.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        fallback = timer
        refresh()
    }

    /// objectWillChange fires before the new value is stored: evaluate on the next main-queue turn, coalesced.
    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in self?.scheduled = false; self?.refresh() }
    }

    func refresh() {
        guard let model else { return }
        observeChildren(of: model)
        let presence = Self.presence(of: model)
        let settings = DesktopReachabilitySettings(defaults: DesktopPreview.preferences)
        let newState = DesktopReachabilityPolicy.state(presence)
        if newState != state {
            state = newState
            AppLog.event("desktop_reachability", ["state": newState.rawValue])
        }
        let newDetail = Self.detail(model: model, presence: presence, state: newState)
        if newDetail != detail { detail = newDetail }
        if activity.apply(DesktopReachabilityPolicy.activity(presence, settings)) {
            AppLog.event("desktop_activity", ["options": "\(activity.current?.options.rawValue ?? 0)", "reason": activity.current?.reason ?? "none"])
        }
        if DesktopReachabilityPolicy.showsRingWindow(presence, settings), let call = model.call {
            ringPanel.show(call: call) { [weak self] in self?.openMain(); NSApp.activate() }
        } else {
            ringPanel.close()
        }
    }

    private func observeChildren(of model: AppModel) {
        let children: [AnyObject?] = [model.call, model.watch, model.live, model.callRelay]
        let ids = children.compactMap { $0.map(ObjectIdentifier.init) }
        guard ids != observedChildren else { return }
        observedChildren = ids
        childObservers = [
            model.call?.objectWillChange.sink { [weak self] _ in self?.schedule() },
            model.watch?.objectWillChange.sink { [weak self] _ in self?.schedule() },
            model.live?.objectWillChange.sink { [weak self] _ in self?.schedule() },
            model.callRelay?.objectWillChange.sink { [weak self] _ in self?.schedule() },
        ].compactMap { $0 }
    }

    static func presence(of model: AppModel) -> DesktopPresence {
        var p = DesktopPresence()
        // The hardware-free preview has no radio; treat it as ready so the menu and settings can be exercised.
        p.radioReady = DesktopPreview.enabled || (model.radio.central?.state == .poweredOn && model.bluetoothProblem == nil)
        p.allowCalls = model.availableForCalls
        if let call = model.call, call.ended == nil, let phase = call.phase, phase != .ended {
            p.call = phase == .incomingRinging ? .incomingRinging : .other
            p.callVideo = call.callType == .video || call.cameraOn
        }
        if let live = model.live, live.running { p.liveSource = true; p.liveVideo = !live.audioOnly }
        if let watch = model.watch, watch.ended == nil { p.watching = true; p.watchVideo = !watch.isRadio }
        p.relayingCall = model.callRelay != nil
        p.appActive = NSApp.isActive
        return p
    }

    private static func detail(model: AppModel, presence p: DesktopPresence, state: DesktopReachabilityState) -> String {
        switch state {
        case .live:
            if let live = model.live, live.running { return live.audioOnly ? "You are live (audio only)" : "You are live" }
            return model.watch?.isRadio == true ? "Listening to a live stream" : "Watching a live stream"
        case .inCall:
            let name = model.call?.label?.title ?? model.call?.peerName ?? "someone"
            return p.call == .incomingRinging ? "Incoming call from \(name)" : "Call with \(name)"
        case .reachable:
            return "Nearby phones and Macs can call this Mac"
        case .notReachable:
            if !p.allowCalls { return "Allow calls is off" }
            return model.bluetoothProblem ?? "Bluetooth is off or not ready"
        }
    }
}

// MARK: Menu bar

/// The menu bar icon: system template (black or white with the menu bar) except Live, which is red as on Android.
struct DesktopMenuBarLabel: View {
    let state: DesktopReachabilityState
    var body: some View {
        Image(nsImage: Self.image(for: state))
            .accessibilityLabel("MeshLive, \(state.title)")
    }

    static func image(for state: DesktopReachabilityState) -> NSImage {
        let symbol: String
        switch state {
        case .reachable: symbol = "antenna.radiowaves.left.and.right"
        case .notReachable: symbol = "antenna.radiowaves.left.and.right.slash"
        case .inCall: symbol = "phone.fill"
        case .live: symbol = "dot.radiowaves.left.and.right"
        }
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "MeshLive, \(state.title)") ?? NSImage()
        guard state == .live else { base.isTemplate = true; return base }
        let red = NSImage.SymbolConfiguration(paletteColors: [NSColor(Palette.liveRed)])
        let image = base.withSymbolConfiguration(red) ?? base
        image.isTemplate = false
        return image
    }
}

struct DesktopMenuBarMenu: View {
    @ObservedObject var monitor: DesktopReachabilityMonitor
    @EnvironmentObject private var model: AppModel
    let navigation: DesktopNavigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(monitor.state.title)
        if !monitor.detail.isEmpty { Text(monitor.detail) }
        Divider()
        Button("Open MeshLive") {
            if let open = navigation.openMain { open() } else { openWindow(id: "main") }
            NSApp.activate()
        }
        Toggle("Reachable for calls", isOn: $model.availableForCalls)
        Divider()
        Button("Quit MeshLive") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

// MARK: Settings

/// Settings › Desktop rows for staying reachable behind other apps. Every switch except the menu bar item is off by
/// default (README: Experimental, alternative and optional behaviour).
struct DesktopReachabilitySettingsRows: View {
    @AppStorage(DesktopReachabilitySettings.menuBarKey) private var menuBar = true
    @AppStorage(DesktopReachabilitySettings.ringWindowKey) private var ringWindow = false
    @AppStorage(DesktopReachabilitySettings.activityDuringMediaKey) private var activityDuringMedia = false
    @AppStorage(DesktopReachabilitySettings.noAppNapWhileReachableKey) private var noAppNap = false
    @AppStorage(DesktopReachabilitySettings.keepAwakeWhileReachableKey) private var keepAwake = false
    @ObservedObject private var login = DesktopLoginItems.shared

    var body: some View {
        Card {
            SettingsToggleRow(icon: "menubar.rectangle", title: "Show in menu bar",
                              info: "On by default. The menu bar shows whether this Mac is reachable, in a call or live, with Open MeshLive, a Reachable for calls switch and Quit.",
                              identifier: "desktop-menu-bar", isOn: $menuBar)
            CardDivider()
            SettingsToggleRow(icon: "power", title: "Start at login",
                              info: "Off by default. Opens MeshLive when you log in to this Mac. macOS may ask you to allow it in System Settings › General › Login Items.",
                              identifier: "desktop-start-at-login",
                              isOn: Binding(get: { login.item.state.on }, set: { login.item.set($0) }))
            CardDivider()
            SettingsToggleRow(icon: "bell.badge", title: "Ring window in the background (experimental)",
                              info: "Off by default. When a call rings while another app is in front, a small window with Accept and Decline appears above other windows. The notification and ring sound are unchanged.",
                              identifier: "desktop-ring-window-setting", isOn: $ringWindow)
            CardDivider()
            SettingsToggleRow(icon: "waveform", title: "Stay active during calls and live (experimental)",
                              info: "Off by default. During a call, a live stream or live audio, MeshLive asks macOS not to nap the app or idle-sleep this Mac; while video is on screen the display stays on too. It ends when the call or stream stops.",
                              identifier: "desktop-activity-media", isOn: $activityDuringMedia)
            CardDivider()
            SettingsToggleRow(icon: "timer", title: "Avoid App Nap while reachable (experimental)",
                              info: "Off by default. While reachable for calls, keeps MeshLive's Bluetooth timers at full rate when other apps are in front. The Mac can still sleep, which stops Bluetooth.",
                              identifier: "desktop-no-app-nap", isOn: $noAppNap)
            CardDivider()
            SettingsToggleRow(icon: "sun.max", title: "Keep Mac awake while reachable",
                              info: "Off by default. Prevents idle sleep while MeshLive is reachable for calls, so nearby phones can still reach this Mac. Uses more battery. Closing the lid still puts the Mac to sleep.",
                              identifier: "desktop-keep-awake", isOn: $keepAwake)
        }
        if login.item.state.needsApproval {
            CardNote("Start at login is waiting for your approval in System Settings › General › Login Items.")
            Button("Open Login Items") { login.openSystemSettings() }
                .buttonStyle(.plain).foregroundStyle(Palette.ink).padding(.horizontal, 16)
                .accessibilityIdentifier("desktop-open-login-items")
        }
        if let problem = login.item.state.problem { CardNote(problem) }
    }
}

/// The app's single login-item model: the real SMAppService, or isolated preview preferences under -NearbyPreview.
final class DesktopLoginItems: ObservableObject {
    static let shared = DesktopLoginItems()
    let item: DesktopLoginItem
    private var forward: AnyCancellable?
    private var activeObserver: NSObjectProtocol?

    private init() {
        item = DesktopLoginItem(service: DesktopPreview.enabled ? PreviewLoginService() : SMAppService.mainApp)
        forward = item.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // The user may approve or remove the item in System Settings while MeshLive runs.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.item.refresh()
        }
    }

    func openSystemSettings() {
        guard !DesktopPreview.enabled else { return }
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Preview-only stand-in: records the switch in the isolated preview preferences, never in Login Items.
    private final class PreviewLoginService: DesktopLoginService {
        private let key = "desktopPreviewStartAtLogin"
        var status: SMAppService.Status { DesktopPreview.preferences.bool(forKey: key) ? .enabled : .notRegistered }
        func register() throws { DesktopPreview.preferences.set(true, forKey: key) }
        func unregister() throws { DesktopPreview.preferences.set(false, forKey: key) }
    }
}
