import SwiftUI
#if os(iOS)
import UIKit
#endif
import NearbyCore

/// The four tabs of the Android app (2026-10-17 redesign): Live, Calls, Contacts and Settings. Each tab root draws
/// Android's title row with the status chip (`TabHeader`); pushed pages use the inline navigation bar with the chip.
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
        .alert("Delete everything?", isPresented: $model.askQuickWipe) {
            Button("Delete everything", role: .destructive) { model.emergencyWipe() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This deletes your identity keys, verified contacts and settings. It cannot be undone.") }
        .blockingAlerts()
        .liveStoppedAlert()
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

/// Android's round call button on a Calls row: voice on a dark disc, video on a white one.
struct RoundCallButton: View {
    let icon: String, label: String, white: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 20, weight: .medium)).foregroundStyle(white ? Color.black : Palette.ink)
                .frame(width: 48, height: 48).background(white ? Color.white : Palette.chip, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
