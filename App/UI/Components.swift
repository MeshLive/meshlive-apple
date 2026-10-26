import SwiftUI
import NearbyCore

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
    /// Row background for flat lists.
    func monoRow() -> some View { listRowBackground(Palette.ground).listRowSeparatorTint(Palette.outline) }
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

/// The one status line: state and what it means; an action only when something is wrong.
struct StatusRow: View {
    let title: String, detail: String
    var ok: Bool
    var action: (title: String, perform: () -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RowLabel(title: title, subtitle: detail, icon: ok ? AppIcon.ready : AppIcon.problem, tint: ok ? Palette.connected : Palette.ink)
            if let action { SecondaryButton(title: action.title, action: action.perform) }
        }
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Primary action: amber, prominent, large (one per screen).
struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
            }
            .font(Typo.heading).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).controlSize(.large).tint(Palette.accent).foregroundStyle(Palette.onAccent)
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

/// Destructive action: white outline, never red (red is reserved for live).
struct DestructiveButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void
    var body: some View {
        Button(role: .destructive, action: action) {
            Group {
                if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
            }
            .font(Typo.heading).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).controlSize(.large).tint(Palette.ink)
    }
}

/// A dismissible notice row (for example "Couldn't reach ...").
struct NoticeRow: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        Button(action: dismiss) {
            Label { Text(text).font(Typo.secondary).foregroundStyle(Palette.ink).multilineTextAlignment(.leading) }
                icon: { Image(systemName: AppIcon.problem).fontWeight(.light).foregroundStyle(Palette.dimInk) }
        }
        .accessibilityHint("Dismiss")
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
                if typeSize.isAccessibilitySize { stacked } else { ViewThatFits(in: .horizontal) { inline; stacked } }
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
    private var titleText: some View {
        Text(title).font(.body.weight(.medium)).foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
    }
    private var inline: some View {
        HStack(spacing: 8) {
            titleText.lineLimit(1)
            Spacer(minLength: 8)
            if let value { Text(value).font(.body).foregroundStyle(Palette.dimInk).lineLimit(1) }
        }
    }
    private var stacked: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleText.fixedSize(horizontal: false, vertical: true)
            if let value { Text(value).font(.body).foregroundStyle(Palette.dimInk).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// Tab root header: large bold title and the status dot (green when the radio is ready). Three quick taps on the
/// header ask to erase when the opt-in quick wipe is on (Android panic_wipe_gesture).
struct TabHeader: View {
    @EnvironmentObject var model: AppModel
    let title: String
    var showsLogo = false
    var body: some View {
        let status = RadioStatus(model: model)
        HStack(spacing: 12) {
            if showsLogo {
                Image(systemName: "dot.radiowaves.forward").font(.title.weight(.semibold)).foregroundStyle(Palette.ink).accessibilityHidden(true)
            }
            Text(title).font(.largeTitle.weight(.bold)).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
            Spacer()
            Text("\u{25CF}").font(.system(size: 14)).foregroundStyle(status.ok ? Palette.connected : Palette.dimInk)
                .frame(width: 44, height: 44)
                .accessibilityLabel(status.title)
                .accessibilityValue(status.detail)
        }
        .padding(.top, 8).padding(.bottom, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 3) { if model.quickWipeGesture { model.askQuickWipe = true } }
    }
}

/// Android's readiness states and wording (the header dot and, when something is wrong, a card on Live).
struct RadioStatus {
    let title: String, detail: String, ok: Bool, action: String?
    /// The action opens Bluetooth settings (Mac) rather than the app's settings.
    var opensBluetooth = false
    init(model: AppModel) {
        if DesktopPreview.enabled {
            (title, detail, ok, action) = ("Preview", "Sample people and streams. Bluetooth and media are off.", false, nil)
            return
        }
        if model.bluetoothRestartNeeded {
            // iOS has no public link to Bluetooth settings; the Mac opens its Bluetooth pane.
            (title, detail, ok, action) = (BluetoothGuidance.restartTitle, BluetoothGuidance.restartText(mac: AppPlatform.isMac), false,
                                           AppPlatform.isMac ? "Open Bluetooth settings" : nil)
            opensBluetooth = true
            return
        }
        switch model.radio.central?.state {
        case .poweredOff?: (title, detail, ok, action) = ("Bluetooth off", "Turn it on to call, talk or go live", false, "Open Settings"); return
        case .unauthorized?: (title, detail, ok, action) = ("Access needed", "Bluetooth, camera and microphone", false, "Open app settings"); return
        case .unsupported?: (title, detail, ok, action) = ("No Bluetooth", "This phone cannot reach other phones", false, nil); return
        default: break
        }
        if let problem = model.bluetoothProblem { (title, detail, ok, action) = ("Bluetooth problem", problem, false, nil); return }
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
