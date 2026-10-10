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
                    #if DEBUG
                    if RootView.debugScreenName == "call" { model.showDebugCall() }
                    #endif
                }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active: model.enterForeground()
                    case .background: model.enterBackground()
                    default: break
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var debugScreenShown = false
    /// DEBUG screenshot aid: `simctl launch <device> <bundle> -NearbyScreen verify|settings|watch|live|people`.
    static var debugScreenName: String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-NearbyScreen"), i + 1 < args.count { return args[i + 1] }
        #endif
        return nil
    }
    @ViewBuilder private var debugScreen: some View {
        switch RootView.debugScreenName {
        case "verify": VerifyView()
        case "settings": SettingsView()
        case "watch": WatchListView()
        case "live": LiveView()
        default: PeopleView()
        }
    }
    var body: some View {
        Group {
            if model.wiped {
                WipedView()
            } else if let error = model.identityError {
                EmptyState(icon: "key.slash", title: "Identity unavailable", message: error)
            } else {
                NavigationStack {
                    HomeView()
                        .navigationDestination(isPresented: $debugScreenShown) { debugScreen }
                }
                .onAppear { debugScreenShown = RootView.debugScreenName != nil && RootView.debugScreenName != "call" }
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
