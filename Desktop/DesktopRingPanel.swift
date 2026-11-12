import AppKit
import Security
import SwiftUI
import UserNotifications

/// Experimental (Settings › Desktop › Ring window in the background, off by default): while a call rings and another
/// app is in front, a small floating panel offers Decline and Accept above other apps' windows, on every Space. It does
/// not take focus from the frontmost app; Accept brings MeshLive forward because media starts in its window. The
/// local notification and the app's ringer (App/Media/Ringer.swift, its existing level) run unchanged.
final class DesktopRingPanel {
    private var panel: NSPanel?
    private weak var call: CallController?

    func show(call: CallController, model: AppModel, openMain: @escaping () -> Void) {
        if let panel, self.call === call {
            if !panel.isVisible { panel.orderFrontRegardless() }
            return
        }
        close()
        self.call = call
        let view = DesktopRingView(call: call, decline: { [weak model] in model?.declineFromScreen(call) },
                                   declineAndBlock: { [weak model] in model?.declineAndBlock(call) },
                                   declineAndReport: { [weak model] in model?.declineAndReport(call) }, openMain: openMain)
            .environment(\.colorScheme, .dark)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 340),
                            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Incoming call"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .black
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = NSHostingView(rootView: view)
        panel.setAccessibilityIdentifier("desktop-ring-window")
        if let screen = NSScreen.main?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 24))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        AppLog.event("desktop_ring_window", ["state": "shown"])
    }

    func close() {
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
        call = nil
        AppLog.event("desktop_ring_window", ["state": "closed"])
    }
}

/// Android's incoming-call controls (same as CallView): Decline, Voice for a video call, Accept and, for a caller that
/// showed its real key, Decline and block and Report under the row; the two P14 ring lines too.
private struct DesktopRingView: View {
    @ObservedObject var call: CallController
    let decline: () -> Void
    let declineAndBlock: () -> Void
    let declineAndReport: () -> Void
    let openMain: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if let claimed = call.claimedName, call.label?.contactName == nil {
                    Text("~").foregroundColor(Palette.dimInk) + Text(claimed)
                } else {
                    Text(call.label?.title ?? call.peerName)
                }
            }
            .font(.title2.weight(.semibold)).foregroundStyle(Palette.ink)
            .lineLimit(2).multilineTextAlignment(.center)
            .accessibilityLabel(call.claimedNote.map { call.imitates == nil ? "calls itself \(call.claimedName ?? ""), not verified" : "\($0), calls itself \(call.claimedName ?? "")" } ?? (call.label?.title ?? call.peerName))
            if let note = call.claimedNote {
                Text(note).font(.callout).foregroundStyle(Palette.dimInk).lineLimit(2).multilineTextAlignment(.center)
            }
            if call.claimedNote != nil {
                Text("calls itself, not checked").font(.caption).foregroundStyle(Palette.dimInk).accessibilityHidden(true)
            }
            if call.ringNotice != nil, call.claimedName == nil {
                Text("Not verified. A new call from the same phone shows a new name.").font(.caption).foregroundStyle(Palette.dimInk)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            Text(call.offeredType == .voice ? "Incoming voice call" : "Incoming video call")
                .font(.callout).foregroundStyle(Palette.dimInk)
            HStack(spacing: 32) {
                RoundControl(icon: "phone.down.fill", label: "Decline", fill: Palette.callEnd, foreground: .white, size: 56) { decline() }
                if call.offeredType == .video {
                    RoundControl(icon: "phone.fill", label: "Voice", size: 56) { call.accept(as: .voice); openMain() }
                }
                RoundControl(icon: call.offeredType == .video ? "video.fill" : "phone.fill", label: "Accept",
                             fill: Palette.callAccept, foreground: .black, size: 56) {
                    call.accept(as: call.offeredType); openMain()
                }
            }
            // Android: only for a caller that showed its real key (a one-time ID cannot be blocked one by one).
            if call.fingerprint != nil {
                HStack(spacing: 32) {
                    Button("Decline and block") { declineAndBlock() }
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        .accessibilityIdentifier("declineAndBlock")
                    Button("Report") { declineAndReport() }
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        .accessibilityIdentifier("declineAndReport")
                }
                .font(Typo.secondary.weight(.semibold)).foregroundStyle(.white).buttonStyle(.plain)
            }
        }
        .padding(20).padding(.top, 8)
        .frame(width: 360)
        .background(Palette.ground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop-ring-view")
    }
}

/// Incoming-call notifications are Time Sensitive (they break through Focus when the user allows it) only when the app
/// is signed with Apple's `com.apple.developer.usernotifications.time-sensitive` entitlement, which needs a provisioning
/// profile; ad-hoc builds keep the default Active level.
enum DesktopCallAlertLevel {
    static let entitlement = "com.apple.developer.usernotifications.time-sensitive"
    static let entitled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return (SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) as? Bool) == true
    }()

    static func apply(to content: UNMutableNotificationContent) {
        content.interruptionLevel = entitled ? .timeSensitive : .active
    }
}
