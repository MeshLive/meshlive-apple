import SwiftUI
import NearbyCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The shared iOS component set. Every screen builds from these (no one-off styling): SF Symbols mapped from
/// Android's icons, list rows, the status line, primary/secondary/destructive buttons, notices and the empty
/// state. Native HIG controls underneath (inset grouped lists, bordered buttons, Labels, Dynamic Type).
enum AppIcon {
    static let call = "phone.fill"                 // Android ic_call
    static let video = "video.fill"                // ic_videocam
    static let watch = "eye"                       // ic_visibility
    static let goLive = "record.circle"            // ic_record (red)
    static let settings = "gearshape"              // ic_settings
    static let identity = "checkmark.shield"       // ic_verified_user
    static let ready = "dot.radiowaves.left.and.right" // ic_bluetooth (no Bluetooth glyph in SF Symbols)
    static let problem = "exclamationmark.triangle.fill"
    static let people = "person.2"
    static let scan = "qrcode.viewfinder"
    static let lock = "lock.fill"
    static let verified = "checkmark.shield.fill"
    static let mismatch = "exclamationmark.octagon.fill"
    static let unverified = "questionmark.circle"
    static let wipe = "trash"
}

/// Flat list: black ground, hairline dividers, no cards (monochrome dark).
struct MonoList: ViewModifier {
    func body(content: Content) -> some View {
        content.listStyle(.plain).scrollContentBackground(.hidden).background(Palette.ground.ignoresSafeArea())
            .listRowSeparatorTint(Palette.outline)
    }
}
extension View {
    func monoList() -> some View { modifier(MonoList()) }
}

/// Section footer text for flat lists (footnote, grey): plain lists do not style footers.
struct FooterText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(Typo.section).foregroundStyle(Palette.dimInk) }
}

/// A list row: thin SF Symbol (white or grey), title and an optional subtitle (Android two-line list item).
struct RowLabel: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    var tint: Color = Palette.dimInk
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.rowTitle).foregroundStyle(Palette.ink)
                if let subtitle { Text(subtitle).font(Typo.secondary).foregroundStyle(Palette.dimInk) }
            }
        } icon: {
            Image(systemName: icon).fontWeight(.light).foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Secondary action: bordered, white text.
struct SecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).controlSize(.large).tint(Palette.ink)
    }
}

/// Empty state: the native ContentUnavailableView where available.
struct EmptyState: View {
    let icon: String, title: String, message: String
    var body: some View {
        #if os(macOS)
        ContentUnavailableView(title, systemImage: icon, description: Text(message))
        #else
        if #available(iOS 17.0, *) {
            ContentUnavailableView(title, systemImage: icon, description: Text(message))
        } else {
            VStack(spacing: 12) {
                Image(systemName: icon).font(.largeTitle).imageScale(.large).foregroundStyle(Palette.dimInk)
                Text(title).font(Typo.title).foregroundStyle(Palette.ink)
                Text(message).font(Typo.secondary).foregroundStyle(Palette.dimInk).multilineTextAlignment(.center)
            }
            .padding(32).frame(maxWidth: .infinity)
        }
        #endif
    }
}

/// Security/explanation line in sheets (icon, title, explanation).
struct InfoLine: View {
    let icon: String, tint: Color, title: String, detail: String
    var body: some View { RowLabel(title: title, subtitle: detail, icon: icon, tint: tint) }
}

/// "LIVE" tag with a blinking dot (the one allowed animation: being on air matters).
struct LiveTag: View {
    let text: String
    var blinking = true
    @State private var on = true
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(.white).frame(width: 8, height: 8).opacity(on || !blinking ? 1 : 0.2)
            Text(text).font(Typo.secondary.weight(.semibold).monospacedDigit())
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        // Red only while on air; a paused stream is grey.
        .background(blinking ? Palette.liveRed : Palette.avatar, in: Capsule()).foregroundStyle(.white)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in if blinking { on.toggle() } }
        .accessibilityLabel(text)
    }
}

/// Round call control (FaceTime-style): 60 pt, Accept/Decline 76 pt, label below.
struct RoundControl: View {
    let icon: String, label: String
    var fill: Color = Palette.callControl
    var foreground: Color = .white
    var size: CGFloat = 60
    let action: () -> Void
    /// The disc and glyph follow Dynamic Type up to 1.4x; the caption wraps instead of being clipped.
    @ScaledMetric(relativeTo: .caption) private var scale: CGFloat = 1
    var body: some View {
        let side = size * min(scale, 1.4)
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: side * 0.36, weight: .semibold))
                    .frame(width: side, height: side).background(fill, in: Circle()).foregroundStyle(foreground)
                // Never broken inside a word: when the row cannot fit, the call screen switches to a grid.
                Text(label).font(Typo.caption).foregroundStyle(.white).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - 2026-10-17 redesign (Android parity): grouped cards, capsule buttons, tab headers

/// Dark rounded card (Android #121212 on black, 16 pt radius) holding rows separated by hairlines.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Small grey label above a card ("Advanced", "About and updates").
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.subheadline).foregroundStyle(Palette.dimInk)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6).padding(.top, 14).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Grey explanation under a card or row.
struct CardNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(Palette.dimInk).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
    }
}

/// "You appear as ..." (OwnNearbyName) with a small info glyph; tapping it explains the changing name.
struct OwnNearbyNameLine: View {
    let text: String
    @State private var showInfo = false
    var body: some View {
        Button { showInfo = true } label: {
            (Text(text).foregroundColor(Palette.dimInk) + Text("  ") + Text(Image(systemName: "info.circle")).foregroundColor(Palette.dimInk))
                .font(Typo.secondary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .accessibilityHint("Explains this name")
        .accessibilityIdentifier("own-nearby-name")
        .alert(OwnNearbyName.infoTitle, isPresented: $showInfo) { Button("OK", role: .cancel) {} } message: { Text(OwnNearbyName.info) }
    }
}

/// Leading icon + label (+ optional grey value) + chevron: the content of a navigation row in a card.
struct SettingsRowLabel: View {
    let icon: String, title: String
    var value: String? = nil
    /// A grey line under the title (for example "You appear as ..." under Your name).
    var subtitle: String? = nil
    var chevron = true
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(Palette.dimInk).frame(width: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                // Android (2026-10-21): the value sits at the right when title and value fit on one line, and wraps
                // under the title otherwise, instead of squeezing both into narrow columns.
                TitleValueLayout(alwaysStacked: typeSize.isAccessibilitySize) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
                    if let value { Text(value).font(.body).foregroundStyle(Palette.dimInk).multilineTextAlignment(.leading) }
                }
                if let subtitle {
                    Text(subtitle).font(.footnote).foregroundStyle(Palette.dimInk).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if chevron { Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.dimInk).accessibilityHidden(true) }
        }
        .padding(.horizontal, 16).padding(.vertical, 15).frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Title and value on one line (value at the trailing edge) when both fit, else the value under the title, as
/// Android's 2026-10-21 settings rows. One copy of each text, so VoiceOver and the accessibility audit see one row.
struct TitleValueLayout: Layout {
    var alwaysStacked = false
    var spacing: CGFloat = 8, lineSpacing: CGFloat = 4

    private func inline(_ width: CGFloat?, _ subviews: Subviews) -> Bool {
        guard !alwaysStacked, subviews.count == 2 else { return subviews.count < 2 }
        guard let width else { return true }
        return subviews[0].sizeThatFits(.unspecified).width + spacing + subviews[1].sizeThatFits(.unspecified).width <= width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let first = subviews.first else { return .zero }
        let column = ProposedViewSize(width: proposal.width, height: nil)
        if subviews.count == 1 { return first.sizeThatFits(column) }
        if inline(proposal.width, subviews) {
            let a = subviews[0].sizeThatFits(.unspecified), b = subviews[1].sizeThatFits(.unspecified)
            return CGSize(width: proposal.width ?? a.width + spacing + b.width, height: max(a.height, b.height))
        }
        let a = subviews[0].sizeThatFits(column), b = subviews[1].sizeThatFits(column)
        return CGSize(width: proposal.width ?? max(a.width, b.width), height: a.height + lineSpacing + b.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first else { return }
        let column = ProposedViewSize(width: bounds.width, height: nil)
        if subviews.count == 1 { first.place(at: bounds.origin, proposal: column); return }
        if inline(bounds.width, subviews) {
            let a = subviews[0].sizeThatFits(.unspecified), b = subviews[1].sizeThatFits(.unspecified)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(a))
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(b))
        } else {
            let height = subviews[0].sizeThatFits(column).height
            subviews[0].place(at: bounds.origin, proposal: column)
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + height + lineSpacing), proposal: column)
        }
    }
}

/// A row in a card that pushes a page.
struct SettingsLinkRow<Destination: View>: View {
    let icon: String, title: String
    var value: String? = nil
    var subtitle: String? = nil
    @ViewBuilder let destination: () -> Destination
    #if os(macOS)
    @State private var desktopRouteID = UUID()
    #endif
    var body: some View {
        #if os(macOS)
        NavigationLink(value: DesktopDetailRoute(id: desktopRouteID) { destination() }) {
            SettingsRowLabel(icon: icon, title: title, value: value, subtitle: subtitle)
        }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings-link-" + title)
        #else
        NavigationLink { destination() } label: { SettingsRowLabel(icon: icon, title: title, value: value, subtitle: subtitle) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings-link-" + title)
        #endif
    }
}

/// A switch row in a card (system Toggle, so it stays a VoiceOver/XCUI switch).
struct SettingsToggleRow: View {
    let icon: String?, title: String
    /// The explanation: a small grey info glyph follows the label, and tapping the label shows it (Android parity).
    var info: String? = nil
    /// XCUI / automation identifier of the switch itself.
    var identifier: String? = nil
    @Binding var isOn: Bool
    @State private var showInfo = false
    var body: some View {
        HStack(spacing: 14) {
            if let icon { Image(systemName: icon).font(.system(size: 17)).foregroundStyle(Palette.dimInk).frame(width: 26).accessibilityHidden(true) }
            if let info {
                Button { showInfo = true } label: {
                    (Text(title).font(.body.weight(.medium)).foregroundColor(Palette.ink)
                     + Text("  ") + Text(Image(systemName: "info.circle")).font(.footnote).foregroundColor(Palette.dimInk))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About \(title)")
                .alert(title, isPresented: $showInfo) { Button("OK", role: .cancel) {} } message: { Text(info) }
            } else {
                Text(title).font(.body.weight(.medium)).foregroundStyle(Palette.ink).accessibilityHidden(true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(MeshSwitchStyle())
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier ?? title)
        }
        .padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 56)
    }
}

/// A row whose value is a menu (Mac Camera, Content size): Android's row style, the menu at the end.
struct SettingsPickerRow<Value: View>: View {
    let icon: String, title: String
    @ViewBuilder let value: Value
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(Palette.dimInk).frame(width: 26).accessibilityHidden(true)
            Text(title).font(.body.weight(.medium)).foregroundStyle(Palette.ink)
            Spacer(minLength: 12)
            value.labelsHidden().fixedSize()
        }
        .padding(.horizontal, 16).frame(minHeight: 56)
    }
}

/// Android's switch: on = white track with a black thumb, off = dark grey track with a grey thumb. VoiceOver and
/// XCUI still see a system switch (accessibilityRepresentation).
struct MeshSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Color.white : Color(meshRGB: 0x3A3A3C)).frame(width: 52, height: 32)
                Circle().fill(configuration.isOn ? Color.black : Color(meshRGB: 0x9A9A9F)).frame(width: 24, height: 24).padding(4)
            }
            .frame(width: 52, height: 44)
            .animation(.easeOut(duration: 0.15), value: configuration.isOn)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// Thin inset separator between flat list rows (starts where the row text starts).
struct ListDivider: View {
    var inset: CGFloat = 0
    var body: some View { Rectangle().fill(Palette.separator).frame(height: 0.5).padding(.leading, inset).accessibilityHidden(true) }
}

/// Hairline between rows inside a card.
struct CardDivider: View {
    var inset: CGFloat = 56
    var body: some View { Rectangle().fill(Palette.separator).frame(height: 0.5).padding(.leading, inset).accessibilityHidden(true) }
}

/// Full-width capsule button (Android's big pill): white (primary), red (live / wipe) or dark (secondary).
struct CapsuleButton: View {
    /// white: primary; whiteLive: white with a red broadcast icon (Go live); red: Wipe everything; dark: secondary.
    enum Kind { case white, whiteLive, red, dark }
    let title: String
    var systemImage: String? = nil
    var kind: Kind = .white
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage).font(.title3.weight(.semibold))
                        .foregroundStyle(kind == .whiteLive ? Palette.liveRed : (kind == .white ? Color.black : Color.white))
                        .accessibilityHidden(true)
                }
                Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .frame(maxWidth: .infinity).frame(minHeight: 60)
            .foregroundStyle(kind == .white || kind == .whiteLive ? Color.black : Color.white)
            .background(background, in: Capsule())
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
    private var background: Color {
        switch kind { case .white, .whiteLive: return .white; case .red: return Palette.liveRed; case .dark: return Palette.chip }
    }
}

/// Tab root title row (Android `activity_main.xml` tab rows): one row, at least 56 high, 8 from the top. Live shows the
/// app mark and "MeshLive" at Android's Readout 22; the other tabs their name at Android's Headline 28. The status chip
/// is the last item and never cuts the title (it drops its word first). Three quick taps on the title ask to erase
/// when the opt-in quick wipe is on (Android panic_wipe_gesture).
struct TabHeader: View {
    @EnvironmentObject var model: AppModel
    let title: String
    var showsLogo = false
    var body: some View {
        HStack(spacing: 10) {
            if showsLogo {
                Image(systemName: "dot.radiowaves.forward").font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.ink)
                    .frame(width: 28, height: 28).accessibilityHidden(true)
            }
            Text(title).font(TitleFont.tab(app: showsLogo)).foregroundStyle(Palette.ink)
                .lineLimit(1).layoutPriority(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("tabTitle")
                .onTapGesture(count: 3) { if model.quickWipeGesture { model.askQuickWipe = true } }
            Spacer(minLength: 8)
            StatusChip()
        }
        .frame(minHeight: 56)
        .padding(.top, 8)
    }
}

/// Title sizes of Android's title rows. iPhone: text styles that are Android's sizes at the default text size
/// (`.title` 28, `.title2` 22) and still follow Dynamic Type. Mac: macOS text styles are smaller, so fixed sizes; the
/// Mac's Content size setting scales the window.
enum TitleFont {
    static func tab(app: Bool) -> Font {
        #if os(macOS)
        return .system(size: app ? 22 : 28, weight: .bold)
        #else
        return app ? Font.title2.weight(.bold) : Font.title.weight(.bold)
        #endif
    }
    static var page: Font { tab(app: false) }
}

/// Mac pushed page title row (Android `settingsTitle` row): the page title and the status chip; the system back button
/// stays in the window toolbar. The iPhone uses the inline navigation bar instead (`pageTitle`).
struct PageHeader: View {
    let title: String
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(TitleFont.page).foregroundStyle(Palette.ink)
                .lineLimit(1).layoutPriority(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            StatusChip()
        }
        .frame(minHeight: 56)
    }
}

/// The status indicator at the end of every title row (Android `view_status_chip.xml`): an 8-point dot and, for a
/// problem, one short word when it fits (`ViewThatFits` offers dot and word, then the dot alone). A tap always opens
/// the status sheet (Android 2026-10-21). `compact` (the iPhone navigation bar, which cannot measure the title): the
/// word only when it is short.
struct StatusChip: View {
    @EnvironmentObject var model: AppModel
    var compact = false
    @State private var showSheet = false
    var body: some View {
        let kind = StatusKind(model: model)
        let word = kind.word(mac: AppPlatform.isMac).flatMap { compact && $0.count > 14 ? nil : $0 }
        Button { showSheet = true } label: {
            ViewThatFits(in: .horizontal) {
                if let word { chip(kind, word: word) }
                chip(kind, word: nil)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.word(mac: AppPlatform.isMac) ?? "Status: ready")
        .accessibilityHint("Shows what is on and what needs you")
        .accessibilityIdentifier("statusChip-" + kind.rawValue)
        .sheet(isPresented: $showSheet) {
            StatusSheet().environmentObject(model).meshPresentation(height: 560, largeOnly: false)
        }
    }

    private func chip(_ kind: StatusKind, word: String?) -> some View {
        HStack(spacing: 8) {
            Circle().fill(kind.problem ? Palette.ink : Palette.connected).frame(width: 8, height: 8)
            if let word {
                Text(word).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink).lineLimit(1).fixedSize()
            }
        }
        .padding(.leading, 8).padding(.trailing, 4)
        .frame(minWidth: 48, minHeight: 48)
        .contentShape(Rectangle())
    }
}

extension StatusKind {
    /// This device's status now (Android `updateStatusIndicators` inputs): Bluetooth readiness as `RadioStatus` judges
    /// it, the screen that owns the radio, Allow calls, Relay video for others paused by the battery, and heat.
    init(model: AppModel) {
        let thermal = ProcessInfo.processInfo.thermalState
        self = StatusKind.of(readiness: RadioStatus(model: model).readiness, hidden: !model.availableForCalls,
                             relayPaused: model.relayForOthers && model.relayBatteryPaused, hot: thermal == .serious || thermal == .critical,
                             screen: model.live != nil ? .live : model.watch != nil ? .watching : .home,
                             callsUnavailable: model.callsUnavailable != nil)
    }
}

/// The status sheet behind the chip (Android `sheet_status.xml`, `showStatusSheet`): what is on and what needs you,
/// and the one fix when there is one. Your code and ID are not here (Add contact has them).
struct StatusSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let status = RadioStatus(model: model)
        let kind = StatusKind(model: model)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Status").font(.title3.weight(.bold)).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
                    Spacer()
                    #if os(macOS)
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                    #endif
                }
                .padding(.bottom, 4)
                row("Bluetooth", Self.bluetooth(status.readiness), id: "bluetooth")
                row("Access", Self.access, id: "access")
                row("Allow calls", calls(kind), id: "calls")
                row("Private Bluetooth ID", model.rotatingIds ? "On" : "Off", id: "ids")
                if model.sourceGate.showsSourceControls {
                    row("Relay video for others", model.relayForOthers ? (model.relayBatteryPaused ? "Paused to save battery" : "On") : "Off", id: "relay")
                }
                row("Battery and temperature", Self.health, id: "battery")
                if model.callAlerts != .authorized {
                    Text("Notifications off: you won't see calls").font(.subheadline).foregroundStyle(Palette.ink)
                        .padding(.vertical, 10).accessibilityIdentifier("status-notifications-off")
                }
                if let nameplate { row("Nearby you appear as", nameplate, id: "nameplate") }
                if status.readiness != .ready, let action = status.action {
                    CapsuleButton(title: action, kind: .white) {
                        dismiss()
                        if status.opensBluetooth { AppPlatform.openBluetoothSettings() } else { AppPlatform.openSettings() }
                    }
                    .padding(.top, 8)
                    .accessibilityIdentifier("status-action")
                }
                // Android "Calls unavailable": Bluetooth settings (apps cannot turn Bluetooth off and on). The Mac opens its
                // Bluetooth pane; iOS has no public link to it, so the iPhone shows only the text.
                if kind == .callsUnavailable, AppPlatform.isMac {
                    CapsuleButton(title: "Bluetooth settings", kind: .white) {
                        dismiss()
                        AppPlatform.openBluetoothSettings()
                    }
                    .padding(.top, 8)
                    .accessibilityIdentifier("status-bluetooth-settings")
                }
            }
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 24)
        }
        .background(Palette.card.ignoresSafeArea())
    }

    private func row(_ label: String, _ value: String, id: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
            Spacer(minLength: 12)
            Text(value).font(.subheadline).foregroundStyle(Palette.dimInk).multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("status-row-" + id)
    }

    private static func bluetooth(_ readiness: StatusReadiness) -> String {
        switch readiness {
        case .ready: return "On"
        case .bluetoothOff: return "Off"
        case .permissionsNeeded: return "Needs permission"
        case .unsupported: return "Not available"
        case .bluetoothProblem: return "Needs attention"
        }
    }

    /// "All allowed", or which of Bluetooth and the microphone (and, in the call readiness control arm, the camera) are not
    /// allowed (never prompts). Android readiness: the camera is asked at the first video use, so it is not part of it.
    private static var access: String {
        let needed = AppSettings.callReadinessPermissions
            ? [("Bluetooth", MediaPermissions.bluetooth), ("microphone", MediaPermissions.microphone)]
            : [("Bluetooth", MediaPermissions.bluetooth), ("camera", MediaPermissions.camera), ("microphone", MediaPermissions.microphone)]
        let missing = needed
            .filter { $0.1 != "granted" }.map(\.0)
        guard !missing.isEmpty else { return "All allowed" }
        let list = ListFormatter.localizedString(byJoining: missing)
        return list.prefix(1).uppercased() + list.dropFirst() + " needed"
    }

    private func calls(_ kind: StatusKind) -> String {
        switch kind {
        case .watching, .live: return kind.word(mac: AppPlatform.isMac) ?? ""
        case .callsUnavailable: return model.callsUnavailable?.statusValue(mac: AppPlatform.isMac) ?? ""
        default: return model.availableForCalls ? "On" : "Not available for nearby calls"
        }
    }

    /// iPhone: charge and heat; Mac: heat (the app reads no Mac battery).
    static var health: String {
        let heat: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: heat = "normal"
        case .fair: heat = "warm"
        case .serious: heat = "hot"
        case .critical: heat = "too hot"
        @unknown default: heat = "unknown"
        }
        #if os(iOS)
        let level = UIDevice.current.batteryLevel
        if level >= 0 {
            let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full ? " charging" : ""
            return "\(Int((level * 100).rounded()))%\(charging) \u{00B7} heat \(heat)"
        }
        #endif
        return "Heat \(heat)"
    }

    /// Android `ownGeneratedNameLine`: the generated name of this device's current rotating call ID and when it changes.
    private var nameplate: String? {
        guard model.rotatingIds, model.availableForCalls, let name = model.desktopAdvertisedName else { return nil }
        let next = Date(timeIntervalSince1970: TimeInterval((model.rotating.currentEpoch() + 1) * RotatingDiscoveryIds.epochSeconds))
        return "\(GeneratedNameText.display(name)) until \(next.formatted(date: .omitted, time: .shortened))"
    }
}

/// Android's readiness states and wording (the status chip's readiness and, when something is wrong, a card on Live).
struct RadioStatus {
    let title: String, detail: String, ok: Bool, action: String?
    /// The action opens Bluetooth settings (Mac) rather than the app's settings.
    var opensBluetooth = false
    /// What the title-bar status makes of it (`StatusKind.of`).
    var readiness: StatusReadiness = .ready
    init(model: AppModel) {
        #if DEBUG
        // README fixture first, so README screenshots taken under -NearbyPreview show the ordinary ready state. Store
        // screenshots pass -NearbyReadyStatus 1.
        if model.debugReadme || RootView.debugArgument("-NearbyReadyStatus") == "1" { (title, detail, ok, action) = ("Bluetooth on \u{00B7} Reachable for calls", "Keep MeshLive open to be reached", true, nil); return }
        #endif
        if DesktopPreview.enabled {
            // The preview has no radio; the status chip treats it as ready.
            (title, detail, ok, action) = ("Preview", "Sample people and streams. Bluetooth and media are off.", false, nil)
            return
        }
        if model.bluetoothRestartNeeded {
            // iOS has no public link to Bluetooth settings; the Mac opens its Bluetooth pane.
            (title, detail, ok, action) = (BluetoothGuidance.restartTitle, BluetoothGuidance.restartText(mac: AppPlatform.isMac), false,
                                           AppPlatform.isMac ? "Open Bluetooth settings" : nil)
            opensBluetooth = true
            readiness = .bluetoothProblem
            return
        }
        switch model.radio.central?.state {
        case .poweredOff?: (title, detail, ok, action) = ("Bluetooth off", "Turn it on to call, talk or go live", false, "Open Settings"); readiness = .bluetoothOff; return
        case .unauthorized?: (title, detail, ok, action) = ("Access needed", "Bluetooth, camera and microphone", false, "Open app settings"); readiness = .permissionsNeeded; return
        case .unsupported?: (title, detail, ok, action) = ("No Bluetooth", "This phone cannot reach other phones", false, nil); readiness = .unsupported; return
        default: break
        }
        if let problem = model.bluetoothProblem { (title, detail, ok, action) = ("Bluetooth problem", problem, false, nil); readiness = .bluetoothProblem; return }
        if let reason = model.callsUnavailable {
            // Android "Calls unavailable" on Home: why, and Bluetooth settings on the Mac (iOS has no public link to it).
            (title, detail, ok, action) = ("Calls unavailable", reason.statusValue(mac: AppPlatform.isMac), false,
                                           AppPlatform.isMac ? "Bluetooth settings" : nil)
            opensBluetooth = true
            return
        }
        (title, detail, ok, action) = model.availableForCalls
            ? ("Bluetooth on \u{00B7} Reachable for calls", "Keep MeshLive open to be reached", true, nil)
            : ("Bluetooth on \u{00B7} Not reachable for calls", "Turn on Allow calls in Settings", true, nil)
    }
}

/// Selectable chip (Calls: Nearby / Recent).
struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.body.weight(.medium))
                .padding(.horizontal, 18).padding(.vertical, 9)
                .foregroundStyle(selected ? Color.black : Palette.ink)
                .background(selected ? Color.white : Palette.chip, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Round dark circle with an icon (audio-only stream rows).
struct IconDisc: View {
    let icon: String
    var size: CGFloat = 48
    var body: some View {
        Image(systemName: icon).font(.system(size: size * 0.42)).foregroundStyle(Palette.ink)
            .frame(width: size, height: size).background(Palette.chip, in: Circle()).accessibilityHidden(true)
    }
}

/// Centered empty state in the Android wording.
struct PlainEmptyState: View {
    let icon: String, title: String
    var message: String? = nil
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(Palette.dimInk).accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(Palette.ink.opacity(0.85)).multilineTextAlignment(.center)
            if let message { Text(message).font(.subheadline).foregroundStyle(Palette.dimInk).multilineTextAlignment(.center) }
        }
        .padding(32).frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// What a Block confirmation is about: the person's full fingerprint, what screens call them, and the stream route that
/// was playing (for a report).
struct BlockTarget: Identifiable, Equatable {
    let fingerprint: IdentityFingerprint
    let name: String
    var streamRoute: String? = nil
    var id: String { fingerprint.hex }
}

/// Android `CallBlockingUi.confirmBlock`: "Block <name>?" with Block, Report and Cancel. `onDone` runs after Block or Report.
private struct BlockConfirmation: ViewModifier {
    @EnvironmentObject var model: AppModel
    @Binding var target: BlockTarget?
    var onBlocked: ((BlockTarget) -> Void)? = nil
    let onDone: () -> Void
    func body(content: Content) -> some View {
        content.alert(target.map { "Block \($0.name)?" } ?? "Block?", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                      presenting: target) { t in
            Button("Block", role: .destructive) { model.blockAndSay(t.fingerprint); onBlocked?(t); onDone() }
            Button("Report") { model.report(t.fingerprint, streamRoute: t.streamRoute); onDone() }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Their livestreams will be hidden. Calls will be blocked when MeshLive can recognise their phone. Calls using a temporary ID may still ring; turn on Block unknown callers to stop those too. They won't be notified.")
        }
    }
}

/// Android's report confirmation: "Blocked and hidden on this phone." with Tell MeshLive (a mail draft with subject
/// "MeshLive: report a concern" and body "What happened:", no identifiers) and Close; the address with Copy when no mail
/// app takes the draft. Shown at the root (the screen that reported has closed).
private struct ReportDoneAlert: ViewModifier {
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    @State private var showAddress = false
    static let address = "meshlive.dev@gmail.com"
    func body(content: Content) -> some View {
        content
            .alert(AppPlatform.isMac ? "Blocked and hidden on this Mac." : "Blocked and hidden on this phone.", isPresented: $model.reportDone) {
                Button("Tell MeshLive") {
                    guard let url = URL(string: "mailto:\(Self.address)?subject=MeshLive%3A%20report%20a%20concern&body=What%20happened%3A") else {
                        showAddress = true; return
                    }
                    openURL(url) { accepted in if !accepted { showAddress = true } }
                }
                Button("Close", role: .cancel) {}
            }
            .alert("Contact us", isPresented: $showAddress) {
                Button("Copy") {
                    #if os(iOS)
                    UIPasteboard.general.string = Self.address
                    #else
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.address, forType: .string)
                    #endif
                }
                Button("Close", role: .cancel) {}
            } message: { Text(Self.address) }
    }
}

/// Android offerBlockUnknownAfterDecline, once until "Not now".
private struct BlockUnknownOffer: ViewModifier {
    @EnvironmentObject var model: AppModel
    func body(content: Content) -> some View {
        content.alert("Declined. Block all unknown callers?", isPresented: $model.askBlockUnknown) {
            Button("Block all unknown callers") { model.blockUnknownCallers = true; model.callNotice = "Block unknown callers is on" }
            Button("Not now", role: .cancel) { AppSettings.blockUnknownOfferDismissed = true }
        }
    }
}

/// Android `showBlockListUnreadable` (decision 2026-11-06): a Block that could not be saved because the saved list
/// is damaged says so and offers Reset (this alert is the confirmation). Shown at the root, like the report alert.
private struct BlockListUnreadableAlert: ViewModifier {
    @EnvironmentObject var model: AppModel
    func body(content: Content) -> some View {
        content.alert("Block list can't be read", isPresented: $model.blockListUnreadableAlert) {
            Button("Reset") { model.resetBlockList() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This block wasn't saved because the block list can't be read, so calls aren't blocked. Reset unblocks everyone; then you can block people again.")
        }
    }
}

extension View {
    func blockConfirmation(_ target: Binding<BlockTarget?>, onBlocked: ((BlockTarget) -> Void)? = nil,
                           onDone: @escaping () -> Void = {}) -> some View {
        modifier(BlockConfirmation(target: target, onBlocked: onBlocked, onDone: onDone))
    }
    /// The root-level blocking alerts: the report confirmation, the Block unknown callers offer and the unreadable list.
    func blockingAlerts() -> some View { modifier(ReportDoneAlert()).modifier(BlockUnknownOffer()).modifier(BlockListUnreadableAlert()) }
}
