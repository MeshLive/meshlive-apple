import SwiftUI
import CoreBluetooth

#if os(iOS)
@main
struct MeshLivePhoneApp: App {
    @StateObject private var model = AppModel()
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onAppear {
                    if RootView.debugScreenName != "onboarding", onboardingComplete || RootView.bypassesOnboarding { model.start() }
                    model.configureCallAlerts()
                    #if DEBUG
                    if let fixture = RootView.debugArgument("-NearbyFixture") { model.applyDebugFixture(fixture) }
                    if let screen = RootView.debugScreenName, screen.hasPrefix("call") { model.showDebugCall(screen) }
                    if RootView.debugScreenName == "broadcast-radio" { model.showDebugBroadcast() }
                    #endif
                }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        if RootView.debugScreenName != "onboarding", onboardingComplete || RootView.bypassesOnboarding { model.enterForeground() }
                    case .background: model.enterBackground()
                    default: break
                    }
                    model.appActivityChanged()
                }
        }
    }
}

#endif

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @State private var onboardingDismissed = false
    /// DEBUG screenshot aid: `simctl launch <device> <bundle> -NearbyScreen live|people|contacts|verify|settings|privacy|advanced-privacy|experiments|connection|about`.
    static var debugScreenName: String? { debugArgument("-NearbyScreen") }
    /// DEBUG-only launch argument value (`-NearbyScreen`, `-NearbyFixture`); always nil in release builds.
    static func debugArgument(_ name: String) -> String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
        #endif
        return nil
    }
    /// Existing DEBUG scenarios, including no-tap media automation, launch directly.
    static var bypassesOnboarding: Bool {
        #if DEBUG
        return debugScreenName != "onboarding" && ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-Nearby") }
        #else
        return false
        #endif
    }
    /// The tab a DEBUG `-NearbyScreen` value opens (pages inside a tab are pushed by that tab's `debugPush`).
    private var initialTab: MainTab {
        switch RootView.debugScreenName {
        case "settings", "privacy", "advanced-privacy", "experiments", "connection", "about": return .settings
        case "people", "calls": return .calls
        case "contacts", "verify": return .contacts
        default: return .live
        }
    }
    var body: some View {
        #if os(macOS)
        DesktopRootView()
        #else
        Group {
            if model.wiped {
                WipedView()
            } else if let error = model.identityError {
                EmptyState(icon: "key.slash", title: "Identity unavailable", message: error)
            } else if !onboardingDismissed && (RootView.debugScreenName == "onboarding" || (!onboardingComplete && !RootView.bypassesOnboarding)) {
                OnboardingView {
                    onboardingComplete = true; onboardingDismissed = true
                    model.start()
                }
            } else {
                MainTabs(initial: initialTab)
                    .fullScreenCover(item: Binding(get: { model.call }, set: { _ in })) { call in CallView(call: call) }
            }
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
        #endif
    }
}

struct WipedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield").font(.system(size: 56)).foregroundStyle(Palette.connected)
            Text("Everything was erased").font(Typo.title).foregroundStyle(Palette.ink)
            Text("Keys, verified contacts and settings are gone. Close the app. Next time it starts with a new ID.")
                .font(Typo.body).multilineTextAlignment(.center).foregroundStyle(Palette.dimInk)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.ground.ignoresSafeArea())
    }
}

/// Android's first-run pages, adapted to iOS permissions and foreground discovery.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let finish: () -> Void
    @State private var page = 0
    @State private var microphone = MediaPermissions.microphone
    @State private var camera = MediaPermissions.camera

    var body: some View {
        VStack(spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if page == 0 {
                        Image(systemName: "dot.radiowaves.forward").font(.system(size: 64)).accessibilityHidden(true)
                        heading("Calls and live video, no internet needed")
                        Text(AppPlatform.isMac ? "MeshLive connects this Mac to nearby phones and Macs over Bluetooth. It works without Wi-Fi or internet." : "MeshLive connects phones directly over Bluetooth. It works with no signal, no Wi-Fi, and where the internet is blocked.")
                            .font(.body).foregroundStyle(Palette.dimInk)
                    } else if page == 1 {
                        heading("What you can do")
                        point("phone", "Call people nearby", AppPlatform.isMac ? "Voice or video, encrypted from device to device." : "Voice or video, encrypted from phone to phone.")
                        point("radio", "Go live", "Share video, or audio only like a radio, with everyone nearby.")
                        point("point.3.connected.trianglepath.dotted", AppPlatform.isMac ? "Devices pass it along" : "Phones pass it along", AppPlatform.isMac ? "Nearby devices can carry a call or a stream further. Range depends on the Bluetooth hardware and surroundings." : "Each phone reaches about 10 to 30 metres. Phones in between can carry a call or a stream further.")
                        point("lock", "No account, no servers", AppPlatform.isMac ? "Nothing goes to the internet. A random ID identifies you nearby." : "Nothing goes to the internet. Strangers see a random name, not who you are.")
                        CardNote(AppPlatform.isMac ? "Keep MeshLive running to find people and be found. In Settings, choose whether it keeps running with its windows closed. Quitting stops calls and streams." : "Keep MeshLive open to find phones and be found. A closed iPhone app cannot receive calls.")
                    } else if page == 2 {
                        heading("Allow what the app needs")
                        Text(AppPlatform.isMac ? "macOS asks you for each one. You can change them later in System Settings > Privacy & Security. Notifications has its own Settings page." : "iOS asks you for each one. You can change them later in iPhone Settings.").font(.body).foregroundStyle(Palette.dimInk)
                        permission("Bluetooth", "To find and connect to phones around you.", icon: "dot.radiowaves.left.and.right",
                                   granted: CBManager.authorization == .allowedAlways,
                                   denied: CBManager.authorization == .denied || CBManager.authorization == .restricted) { model.radio.start() }
                        permission("Camera", "For video calls and going live.", icon: "video",
                                   granted: camera == "granted", denied: camera == "denied" || camera == "restricted") {
                            MediaPermissions.requestCamera { _ in refreshMedia() }
                        }
                        permission("Microphone", "For calls and live audio.", icon: "mic",
                                   granted: microphone == "granted", denied: microphone == "denied" || microphone == "restricted") {
                            MediaPermissions.requestMicrophone { _ in refreshMedia() }
                        }
                        permission("Notifications", "For alerts when a call starts ringing. Keep MeshLive open to be reached.", icon: "bell",
                                   granted: model.callAlerts == .authorized, denied: model.callAlerts == .denied) {
                            CallNotifier.shared.requestIfAppropriate(.settingsButton)
                        }
                        #if os(macOS)
                        if DesktopPreview.enabled { CardNote("Preview cannot request permissions. These screens do not test Bluetooth, camera or microphone access.") }
                        #endif
                        #if targetEnvironment(simulator)
                        CardNote("Bluetooth and a real camera are unavailable in Simulator. Permission status does not prove either works.")
                        #endif
                    } else {
                        heading("You are ready")
                        Text("Add people you trust in Contacts by scanning each other's QR code.").font(.body).foregroundStyle(Palette.dimInk)
                        CardNote(AppPlatform.isMac ? "Connect with a call or stream before scanning. After adding each other, answer a call from Nearby so Contacts can recognise the device." : "On iPhone, connect with a call or stream before scanning. After adding each other, answer a call from Nearby so Contacts can recognise their phone.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true).padding(.vertical, 24)
            }
            .id(page)
            HStack(spacing: 8) {
                ForEach(0..<4) { index in Circle().fill(index == page ? Color.white : Palette.chip).frame(width: 8, height: 8) }
            }
            .accessibilityElement(children: .ignore).accessibilityLabel("Step \(page + 1) of 4")
            CapsuleButton(title: page == 3 ? "Start" : "Next") { if page == 3 { finish() } else { page += 1 } }
            HStack {
                if page > 0 { Button("Back") { page -= 1 }.frame(minWidth: 44, minHeight: 44) }
                Spacer()
                if page < 3 { Button(page == 2 ? "Not now" : "Skip", action: finish).frame(minWidth: 44, minHeight: 44) }
            }
            .font(.body.weight(.medium)).foregroundStyle(Palette.ink)
        }
        .padding(.horizontal, 20).padding(.bottom, 12)
        .background(Palette.ground.ignoresSafeArea()).foregroundStyle(Palette.ink)
        #if os(macOS)
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshMedia(); CallNotifier.shared.refreshAuthorization() } }
        #else
        .onChange(of: scenePhase) { if $0 == .active { refreshMedia(); CallNotifier.shared.refreshAuthorization() } }
        #endif
    }
    private func heading(_ title: String) -> some View {
        Text(title).font(.largeTitle.weight(.bold)).accessibilityAddTraits(.isHeader)
    }
    private func point(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).font(.system(size: 22)).frame(width: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.body).foregroundStyle(Palette.dimInk)
            }
        }
    }
    private func permission(_ title: String, _ reason: String, icon: String, granted: Bool, denied: Bool,
                            request: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            point(icon, title, reason)
            if granted {
                Label("Allowed", systemImage: "checkmark").font(.subheadline).accessibilityLabel("\(title): Allowed")
            } else {
                Button(denied ? "Open Settings" : "Allow") {
                    if denied { AppPlatform.openSettings() }
                    else { request() }
                }
                .font(.body.weight(.semibold)).padding(.horizontal, 18).frame(minHeight: 44)
                .background(Palette.chip, in: Capsule())
                .accessibilityLabel(denied ? "Open Settings for \(title)" : "Allow \(title)")
                .accessibilityIdentifier("permission-" + title.lowercased())
                .disabled(DesktopPreview.enabled)
            }
        }
    }
    private func refreshMedia() { microphone = MediaPermissions.microphone; camera = MediaPermissions.camera }
}
