import SwiftUI

@main
struct NearbyIntercomApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onAppear {
                    model.start()
                    model.configureCallAlerts()
                    #if DEBUG
                    if let fixture = RootView.debugArgument("-NearbyFixture") { model.applyDebugFixture(fixture) }
                    if let screen = RootView.debugScreenName, screen.hasPrefix("call") { model.showDebugCall(screen) }
                    #endif
                }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active: model.enterForeground()
                    case .background: model.enterBackground()
                    default: break
                    }
                    model.appActivityChanged()
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
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
        Group {
            if model.wiped {
                WipedView()
            } else if let error = model.identityError {
                EmptyState(icon: "key.slash", title: "Identity unavailable", message: error)
            } else {
                MainTabs(initial: initialTab)
                    .fullScreenCover(item: Binding(get: { model.call }, set: { _ in })) { call in CallView(call: call) }
            }
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
    }
}

struct WipedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield").font(.system(size: 56)).foregroundStyle(Palette.connected)
            Text("Everything was erased").font(Typo.title).foregroundStyle(Palette.ink)
            Text("Keys, verified contacts and settings are gone. Close the app. Next time it starts with a new ID.")
                .font(Typo.body).multilineTextAlignment(.center).foregroundStyle(Palette.dimInk)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(UIColor.systemBackground).ignoresSafeArea())
    }
}
