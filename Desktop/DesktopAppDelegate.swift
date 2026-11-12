import AppKit
import SwiftUI

final class DesktopAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !DesktopPreview.preferences.bool(forKey: "desktopKeepRunningWithWindowClosed")
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        model?.configureCallAlerts()
        model?.appActivityChanged()
    }
    func applicationDidResignActive(_ notification: Notification) { model?.appActivityChanged() }
    func applicationWillTerminate(_ notification: Notification) { model?.stopForDesktopExit() }
}

/// Settings › Desktop (Mac only, between the Privacy card and Advanced), in Android's row style: keep running, menu
/// bar, login, keep awake, camera and content size. The experimental Desktop rows are on Experiments.
struct DesktopLifecycleSettings: View {
    @AppStorage("desktopKeepRunningWithWindowClosed") private var keepRunning = false
    var body: some View {
        SectionLabel("Desktop")
        Card {
            SettingsToggleRow(icon: "macwindow", title: "Keep running with windows closed",
                              info: "Off by default. When on, MeshLive keeps Bluetooth, calls and live streams running with all windows closed while this Mac is awake. Use Window > Show MeshLive to return, or MeshLive > Quit to stop. Sleep can interrupt connections.",
                              identifier: "desktop-keep-running", isOn: $keepRunning)
            CardDivider()
            DesktopReachabilitySettingsRows()
            CardDivider()
            SettingsPickerRow(icon: "video", title: "Camera") { DesktopCameraPicker() }
            CardDivider()
            SettingsPickerRow(icon: "textformat.size", title: "Content size") { DesktopContentSizePicker() }
        }
        DesktopLoginItemNotes()
        CardNote("Camera: Automatic uses a built-in camera first, then a connected camera. Microphone and sound use the devices selected in macOS Sound settings; in a call, Sound turns local playback on or off. Content size enlarges text, controls and spacing in MeshLive; scroll to reach content that no longer fits.")
    }
}

/// Holds the app's existing main window so navigation shortcuts do not create duplicate windows.
struct DesktopWindowReference: NSViewRepresentable {
    let found: (NSWindow) -> Void
    final class WindowView: NSView {
        var found: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                window.standardWindowButton(.closeButton)?.setAccessibilityLabel("Close window")
                window.standardWindowButton(.miniaturizeButton)?.setAccessibilityLabel("Minimize window")
                window.standardWindowButton(.zoomButton)?.setAccessibilityLabel("Zoom window")
                found?(window)
            }
        }
    }
    func makeNSView(context: Context) -> WindowView { let view = WindowView(); view.found = found; return view }
    func updateNSView(_ view: WindowView, context: Context) { view.found = found }
}
