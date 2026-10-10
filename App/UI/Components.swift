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
            RowLabel(title: title, subtitle: detail, icon: ok ? AppIcon.ready : AppIcon.problem, tint: ok ? Palette.connected : Palette.red)
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

/// Destructive action: red, prominent.
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
        .buttonStyle(.borderedProminent).controlSize(.large).tint(Palette.red)
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
        if #available(iOS 17.0, *) {
            ContentUnavailableView(title, systemImage: icon, description: Text(message))
        } else {
            VStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 44)).foregroundStyle(Palette.dimInk)
                Text(title).font(Typo.title).foregroundStyle(Palette.ink)
                Text(message).font(Typo.secondary).foregroundStyle(Palette.dimInk).multilineTextAlignment(.center)
            }
            .padding(32).frame(maxWidth: .infinity)
        }
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
        .background(Palette.liveRed, in: Capsule()).foregroundStyle(.white)
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
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: size * 0.36, weight: .semibold))
                    .frame(width: size, height: size).background(fill, in: Circle()).foregroundStyle(foreground)
                Text(label).font(Typo.caption).foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
