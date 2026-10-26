import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum AppPlatform {
    static var isMac: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }
    static var device: String { isMac ? "Mac" : "iPhone" }
    static var active: Bool {
        #if os(macOS)
        return NSApp.isActive
        #else
        return UIApplication.shared.applicationState == .active
        #endif
    }
    static func openSettings(notifications: Bool = false) {
        #if os(macOS)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        #else
        let text = notifications ? UIApplication.openNotificationSettingsURLString : UIApplication.openSettingsURLString
        if let url = URL(string: text) { UIApplication.shared.open(url) }
        #endif
    }
}

/// Explicit, hardware-free desktop screenshots/tests. Never enabled in release or by ordinary automation args.
enum DesktopPreview {
    static var enabled: Bool {
        #if os(macOS) && DEBUG
        return ProcessInfo.processInfo.arguments.contains("-NearbyPreview")
        #else
        return false
        #endif
    }
}

extension Color {
    init(meshRGB: UInt32) {
        self.init(.sRGB, red: Double((meshRGB >> 16) & 255) / 255,
                  green: Double((meshRGB >> 8) & 255) / 255, blue: Double(meshRGB & 255) / 255, opacity: 1)
    }
}

extension View {
    @ViewBuilder func desktopCallShortcut(_ key: KeyEquivalent) -> some View {
        #if os(macOS)
        keyboardShortcut(key, modifiers: [.command, .shift])
        #else
        self
        #endif
    }
    @ViewBuilder func desktopReadingSize() -> some View {
        #if os(macOS)
        modifier(DesktopReadingSize())
        #else
        self
        #endif
    }
    @ViewBuilder func mobileRootNavigation() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
    @ViewBuilder func mobileNavigationTitle(inline: Bool) -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(inline ? .inline : .large)
        #else
        self
        #endif
    }
    @ViewBuilder func meshFullScreenCover<Item: Identifiable, Content: View>(item: Binding<Item?>,
                                                       @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(item: item, content: content)
        #else
        sheet(item: item) { value in content(value).frame(minWidth: 700, minHeight: 520) }
        #endif
    }
    @ViewBuilder func meshPresentation(height: CGFloat, largeOnly: Bool) -> some View {
        #if os(iOS)
        presentationDetents(largeOnly ? [.large] : [.height(height), .large]).presentationDragIndicator(.visible)
        #else
        desktopReadingSize().frame(minWidth: 500, minHeight: 500)
        #endif
    }
}

extension DesktopPreview {
    #if os(macOS) && DEBUG
    private static let fixturePreferences = UserDefaults(suiteName: "io.github.meshlive.app.preview")!
    #endif
    static var preferences: UserDefaults {
        #if os(macOS) && DEBUG
        if enabled { return fixturePreferences }
        #endif
        return .standard
    }
}
