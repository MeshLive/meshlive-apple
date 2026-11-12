import SwiftUI
import CoreBluetooth
import NearbyCore

#if os(iOS)
@main
struct MeshLivePhoneApp: App {
    @StateObject private var model = AppModel()
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage("termsAcceptedVersion") private var termsAcceptedVersion = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onAppear {
                    if !RootView.onboardingShows(onboardingComplete: onboardingComplete, termsAccepted: termsAcceptedVersion, dismissed: false) {
                        model.start()
                    }
                    model.configureCallAlerts()
                    #if DEBUG
                    if let fixture = RootView.debugArgument("-NearbyFixture") { model.applyDebugFixture(fixture) }
                    if let screen = RootView.debugScreenName, screen.hasPrefix("call") { model.showDebugCall(screen) }
                    if let screen = RootView.debugScreenName, screen.hasPrefix("broadcast") { model.showDebugBroadcast(screen) }
                    #endif
                }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        if !RootView.onboardingShows(onboardingComplete: onboardingComplete, termsAccepted: termsAcceptedVersion, dismissed: false) {
                            model.enterForeground()
                        }
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
    @AppStorage("termsAcceptedVersion") private var termsAcceptedVersion = 0
    @State private var onboardingDismissed = false
    /// DEBUG screenshot aid: `simctl launch <device> <bundle> -NearbyScreen live|people|contacts|verify|settings|privacy|experiments|connection|about`.
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
        return debugScreenName != "onboarding" && debugScreenName != "terms"
            && ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-Nearby") }
        #else
        return false
        #endif
    }
    /// The pages this run shows, from the values the root already reads (its `@AppStorage`, which on the Mac preview is
    /// the preview store). DEBUG screenshot screens force their page set.
    static func onboardingPages(onboardingComplete: Bool, termsAccepted: Int) -> [OnboardingPage] {
        #if DEBUG
        if debugScreenName == "onboarding" { return [.welcome, .capabilities, .terms, .permissions, .ready] }
        if debugScreenName == "terms" { return [.terms] }
        #endif
        return OnboardingFlow.pages(onboardingComplete: onboardingComplete, termsAccepted: termsAccepted)
    }
    /// Whether the first-run flow (or, for an existing user, the terms page) covers the app. One rule for the iPhone
    /// and the Mac roots; `dismissed` is the in-run completion flag.
    static func onboardingShows(onboardingComplete: Bool, termsAccepted: Int, dismissed: Bool) -> Bool {
        if dismissed { return false }
        #if DEBUG
        if debugScreenName == "onboarding" || debugScreenName == "terms" { return true }
        #endif
        if bypassesOnboarding { return false }
        return !onboardingPages(onboardingComplete: onboardingComplete, termsAccepted: termsAccepted).isEmpty
    }
    /// The tab a DEBUG `-NearbyScreen` value opens (pages inside a tab are pushed by that tab's `debugPush`).
    private var initialTab: MainTab {
        switch RootView.debugScreenName {
        case "settings", "privacy", "experiments", "connection", "about", "help", "video", "manual", "terms", "licences": return .settings
        case "people", "calls": return .calls
        case "contacts", "verify": return .contacts
        default: return .live
        }
    }
    var body: some View {
        rootContent.crashReportPrompt(suppressed: RootView.onboardingShows(
            onboardingComplete: onboardingComplete,
            termsAccepted: termsAcceptedVersion,
            dismissed: onboardingDismissed))
    }
    @ViewBuilder private var rootContent: some View {
        #if os(macOS)
        DesktopRootView()
        #else
        Group {
            if model.wiped {
                WipedView()
            } else if let error = model.identityError {
                EmptyState(icon: "key.slash", title: "Identity unavailable", message: error)
            } else if RootView.onboardingShows(onboardingComplete: onboardingComplete, termsAccepted: termsAcceptedVersion, dismissed: onboardingDismissed) {
                OnboardingView(pages: RootView.onboardingPages(onboardingComplete: onboardingComplete, termsAccepted: termsAcceptedVersion)) {
                    onboardingComplete = true; onboardingDismissed = true
                    model.start()
                }
            } else {
                MainTabs(initial: initialTab)
                    .fullScreenCover(item: Binding(get: { model.call.flatMap { $0.presentable ? $0 : nil } }, set: { _ in })) { call in CallView(call: call) }
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

/// The first-run flow, shared by the iPhone and the Mac: Welcome, What you can do, the terms, one permissions page
/// and You're all set. The terms come before any system prompt. Skip on the two pages before the terms jumps to the
/// terms and never out of onboarding; an install from before the terms existed sees only the terms, once.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("termsAcceptedVersion") private var termsAcceptedVersion = 0
    let finish: () -> Void
    private let pages: [OnboardingPage]
    @State private var position = 0
    @State private var microphone = MediaPermissions.microphone
    @State private var camera = MediaPermissions.camera
    @State private var permissionRunning = false
    @State private var timedOut: Set<Permission> = []
    @State private var sequenceID = 0
    @State private var promptStarted = Date()

    init(pages: [OnboardingPage], finish: @escaping () -> Void) {
        self.pages = pages
        self.finish = finish
    }

    /// The page to show, or nil when there is none: the caller finishes onboarding instead of indexing an empty list.
    private var currentPage: OnboardingPage? { OnboardingFlow.page(in: pages, at: position) }
    private var page: OnboardingPage { currentPage ?? .terms }

    var body: some View {
        Group {
            if currentPage == nil {
                // Past the terms there is no page to show: finish instead of indexing an empty list.
                Color.clear.onAppear { finish() }
            } else {
                content
            }
        }
    }

    private var content: some View {
        VStack(spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch page {
                    case .welcome: welcome
                    case .capabilities: capabilities
                    case .terms: terms
                    case .permissions: permissions
                    case .ready: ready
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true).padding(.vertical, 24)
            }
            .id(position)
            HStack(spacing: 8) {
                ForEach(0..<pages.count, id: \.self) { index in
                    Circle().fill(index == position ? Color.white : Palette.chip).frame(width: 8, height: 8)
                }
            }
            .accessibilityElement(children: .ignore).accessibilityLabel("Step \(position + 1) of \(pages.count)")
            primaryButton
            HStack {
                if position > 0 { Button("Back") { goBack() }.frame(minWidth: 44, minHeight: 44) }
                Spacer()
                if let target = OnboardingFlow.skipTarget(from: page, in: pages) {
                    Button("Skip") { position = target }.frame(minWidth: 44, minHeight: 44)
                }
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

    @ViewBuilder private var primaryButton: some View {
        switch page {
        case .welcome, .capabilities:
            CapsuleButton(title: "Next") { advance() }
        case .terms:
            CapsuleButton(title: "Agree and continue") { agree() }
                .accessibilityIdentifier("terms-agree")
        case .permissions:
            CapsuleButton(title: "Continue") { continueFromPermissions() }
                .disabled(permissionRunning)
                .accessibilityIdentifier("permissions-continue")
        case .ready:
            CapsuleButton(title: "Start") { finish() }
        }
    }

    @ViewBuilder private var welcome: some View {
        Image(systemName: "dot.radiowaves.forward").font(.system(size: 64)).accessibilityHidden(true)
        heading("Call and watch live video with people nearby")
        Text("Calls and live video over Bluetooth. No internet or account needed.")
            .font(.body).foregroundStyle(Palette.dimInk)
    }

    @ViewBuilder private var capabilities: some View {
        heading("What you can do")
        point("phone", "Call people nearby", "Voice or video, encrypted end to end.")
        point("dot.radiowaves.left.and.right", "Watch live", "See or hear what people nearby are broadcasting.")
        point("lock", "No account", "Nothing goes through a server.")
        CardNote(AppPlatform.isMac ? "Keep MeshLive running to find people and be found. In Settings, choose whether it keeps running with its windows closed. Quitting stops calls and streams." : "Keep MeshLive open to find phones and be found. A closed iPhone app cannot receive calls.")
    }

    @ViewBuilder private var terms: some View {
        heading("Before you start")
        TermsContent()
    }

    @ViewBuilder private var permissions: some View {
        heading("Allow access")
        Text(AppPlatform.isMac
             ? "When you click Continue, macOS asks for these one at a time. You can change your answers later in System Settings > Privacy & Security."
             : "When you tap Continue, iOS asks for these one at a time. You can change your answers later in iPhone Settings.")
            .font(.body).foregroundStyle(Palette.dimInk)
        point("dot.radiowaves.left.and.right", "Bluetooth", "MeshLive uses Bluetooth to find and connect to people nearby.")
        // Android call readiness permissions: the camera is asked at the first video use; the control arm keeps the row.
        if !AppSettings.callReadinessPermissions {
            point("video", "Camera", "For video calls.")
        }
        point("mic", "Microphone", "For calls.")
        point("bell", "Notifications", AppPlatform.isMac ? "So your Mac rings when someone calls." : "So your phone rings when someone calls.")
        CardNote("If you say no to one, MeshLive still opens. That feature just will not work until you allow it in Settings.")
        #if os(macOS)
        if DesktopPreview.enabled { CardNote("Preview cannot request permissions. These screens do not test Bluetooth, camera or microphone access.") }
        #endif
        #if targetEnvironment(simulator)
        CardNote("Bluetooth and a real camera are unavailable in Simulator. Permission status does not prove either works.")
        #endif
    }

    @ViewBuilder private var ready: some View {
        heading("You're all set")
        Text(AppPlatform.isMac ? "To call: both open MeshLive, stay within about 20 m, and click them in Calls." : "To call: both open MeshLive, stay within about 20 m, and tap them in Calls.")
            .font(.body).foregroundStyle(Palette.dimInk)
        Text("Add people you trust in Contacts by scanning each other's QR code.").font(.body).foregroundStyle(Palette.dimInk)
        CardNote("Stand together: show your code and scan theirs (no call is needed first). Once you have both scanned, Contacts can call them when they are nearby.")
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.largeTitle.weight(.bold)).accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("onboarding-title-\(OnboardingPage.allCases.firstIndex(of: page) ?? 0)")
    }
    private func point(_ icon: String, _ title: String, _ detail: String = "") -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).font(.system(size: 22)).frame(width: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                if !detail.isEmpty { Text(detail).font(.body).foregroundStyle(Palette.dimInk) }
            }
        }
    }

    private func advance() {
        if position + 1 < pages.count { position += 1 } else { finish() }
    }
    private func goBack() {
        sequenceID += 1
        permissionRunning = false
        if position > 0 { position -= 1 }
    }
    private func agree() {
        termsAcceptedVersion = StoreTerms.currentVersion
        advance()
    }

    // MARK: One system prompt at a time

    private var permissionOrder: [Permission] { PermissionSequence.order(cameraRow: !AppSettings.callReadinessPermissions) }

    /// The preview cannot request permissions, and a simulator DEBUG run has no real Bluetooth radio: both advance
    /// without prompting (the preview note above says so).
    private var cannotPrompt: Bool {
        if DesktopPreview.enabled { return true }
        #if targetEnvironment(simulator)
        return RootView.debugScreenName == "onboarding"
        #else
        return false
        #endif
    }

    private func status(of permission: Permission) -> PermissionStatus {
        if timedOut.contains(permission) { return .decided }
        switch permission {
        case .bluetooth:
            return CBManager.authorization == .notDetermined ? .notDetermined : .decided
        case .camera:
            return camera == "undetermined" ? .notDetermined : .decided
        case .microphone:
            return microphone == "undetermined" ? .notDetermined : .decided
        case .notifications:
            return model.callAlerts == .notDetermined ? .notDetermined : .decided
        }
    }

    private func continueFromPermissions() {
        guard !permissionRunning else { return }
        if cannotPrompt { advance(); return }
        permissionRunning = true
        runNextPermission()
    }

    private func runNextPermission() {
        sequenceID += 1
        let id = sequenceID
        let statuses = Dictionary(uniqueKeysWithValues: permissionOrder.map { ($0, status(of: $0)) })
        guard let next = PermissionSequence.next(order: permissionOrder, statuses: statuses) else {
            permissionRunning = false
            advance()
            return
        }
        promptStarted = Date()
        switch next {
        case .bluetooth:
            model.radio.start()
            poll(next, id: id)
        case .camera:
            MediaPermissions.requestCamera { _ in permissionAnswered(next, id: id) }
            guardAfterSixtySeconds(next, id: id)
        case .microphone:
            MediaPermissions.requestMicrophone { _ in permissionAnswered(next, id: id) }
            guardAfterSixtySeconds(next, id: id)
        case .notifications:
            CallNotifier.shared.requestIfAppropriate(.settingsButton)
            poll(next, id: id)
        }
    }

    private func permissionAnswered(_ permission: Permission, id: Int) {
        DispatchQueue.main.async {
            self.refreshMedia()
            guard self.permissionRunning, self.sequenceID == id else { return }
            self.runNextPermission()
        }
    }

    /// Polls a prompt that has no completion, every 0.3 s for at most 60 s; a prompt that never answers moves on.
    private func poll(_ permission: Permission, id: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard self.permissionRunning, self.sequenceID == id else { return }
            if self.status(of: permission) != .notDetermined {
                self.runNextPermission()
            } else if Date().timeIntervalSince(self.promptStarted) >= 60 {
                self.timedOut.insert(permission)
                self.runNextPermission()
            } else {
                self.poll(permission, id: id)
            }
        }
    }

    private func guardAfterSixtySeconds(_ permission: Permission, id: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard self.permissionRunning, self.sequenceID == id else { return }
            self.timedOut.insert(permission)
            self.runNextPermission()
        }
    }

    private func refreshMedia() { microphone = MediaPermissions.microphone; camera = MediaPermissions.camera }
}
