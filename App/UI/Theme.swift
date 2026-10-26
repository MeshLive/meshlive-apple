import SwiftUI
#if os(iOS)
import UIKit
#endif
import NearbyCore

/// One product, native on each platform: Android and iOS share the screens, flow, features, wording and the
/// monochrome dark theme (Design/design-tokens.json -> DesignTokens.swift). Dark always: true black ground, white
/// primary text, grey secondary, hairline dividers and flat surfaces; white is the accent (the primary button is
/// white with black text); red only for live (on air, recording, ending a broadcast); a muted green only for "connected".
/// Problems, destructive actions, identity warnings and ending a call are white or grey, never red.
/// SF Pro with Dynamic Type and thin SF Symbols.
struct TokenColor {
    let dark: UInt32, light: UInt32
    var color: Color {
        #if os(macOS)
        return Color(.sRGB, red: Double((dark >> 16) & 255) / 255, green: Double((dark >> 8) & 255) / 255,
                     blue: Double(dark & 255) / 255, opacity: Double((dark >> 24) & 255) / 255)
        #else
        return Color(UIColor { $0.userInterfaceStyle == .light ? UIColor(argb: light) : UIColor(argb: dark) })
        #endif
    }
}

/// Android type tokens are kept for reference (generated code); iOS uses Dynamic Type text styles.
struct TokenType {
    let size: CGFloat, weight: Font.Weight, condensed: Bool, tabular: Bool
}

enum Palette {
    typealias C = DesignTokens.Colors
    // Monochrome dark (Android v8 direction): white accent, red only for live/recording/destructive,
    // a muted green only for "connected".
    static let accent = C.accent.color          // primary action: white, with black text
    static let onAccent = C.onAccent.color
    #if os(macOS)
    static let connected = Color.white
    #else
    static let connected = C.connected.color
    #endif
    static let recordRed = C.recordRed.color
    static let liveRed = C.liveRed.color
    static let callAccept = C.callAccept.color
    /// Ending or declining a call: red, as Android's call_end (2026-10-17 redesign: red only for end and live).
    static let callEnd = C.callEnd.color
    /// Ending a live broadcast is part of being live: red.
    static let liveEnd = C.liveRed.color
    static let ink = C.ink.color
    static let dimInk = C.dimInk.color
    static let ground = C.ground.color
    static let panel = C.panel.color
    static let outline = C.outline.color
    /// Call and live screens: true black.
    static let callGround = LinearGradient(colors: [C.callGroundTop.color, C.callGroundBottom.color], startPoint: .top, endPoint: .bottom)
    static let callControl = Color.white.opacity(0.16)
    /// Avatars: a neutral disc (no per-person colours).
    static let avatar = C.panelVariant.color
    /// Grouped settings cards and sheets (Android 2026-10-17 redesign: #121212 on black).
    static let card = Color(meshRGB: 0x121212)
    /// Secondary capsules, chips and icon discs.
    static let chip = Color(meshRGB: 0x262626)
    /// Inset separators in lists and between card rows (Android card outline grey).
    static let separator = Color(meshRGB: 0x262626)
}

#if os(iOS)
extension UIColor {
    convenience init(rgb: UInt32) { self.init(argb: 0xFF00_0000 | rgb) }
    convenience init(argb: UInt32) {
        self.init(red: CGFloat((argb >> 16) & 0xff) / 255, green: CGFloat((argb >> 8) & 0xff) / 255, blue: CGFloat(argb & 0xff) / 255,
                  alpha: CGFloat((argb >> 24) & 0xff) / 255)
    }
}

#endif

/// Dynamic Type text styles (SF), one role each, used by every screen.
enum Typo {
    static let display = Font.largeTitle.weight(.bold)
    static let title = Font.title2.weight(.semibold)        // call name, empty-state titles
    static let heading = Font.headline                      // row titles that lead a group, buttons
    static let rowTitle = Font.body                         // list row titles
    static let body = Font.body
    static let secondary = Font.subheadline                 // row subtitles, explanations
    static let section = Font.footnote
    static let caption = Font.caption
    static let timer = Font.subheadline.monospacedDigit()
    static let code = Font.body.monospaced()                // identity codes only
}

/// What the UI shows for a peer. The naming design (handles, signed display names, titles) is under
/// review; every screen reads names through this type so the reviewed format drops in at one place.
/// Never shows raw hex: the handle is Crockford Base32 of the 48-bit prefix (display only).
struct PeerLabel: Equatable {
    /// Main line (R5): your verified contact's own label, else a verified self-chosen name in quotes, else
    /// the full handle. Advertised device names are never used.
    let title: String
    /// The peer's signed self-chosen name (experimental labels), shown quoted and marked self-named.
    let selfName: String?
    let contactName: String?
    /// Full handle `XXXXX-XXXXX` (authenticated to 48 bits only after connecting).
    let handle: String
    let shortHandle: String
    /// True only for a contact verified by QR / safety code whose full fingerprint matched this session.
    let verified: Bool
    /// Colour chip derived from the prefix (a visual aid, never a security cue).
    let color: Color
    var monogram: String { ((contactName ?? selfName)?.first.map { String($0) } ?? (shortHandle.isEmpty ? "?" : String(shortHandle.prefix(1)))).uppercased() }

    /// A rotating-ID advert (experimental): no handle and no contact match before the handshake (RV3).
    static func nearbyPhone(seed: Data) -> PeerLabel {
        PeerLabel(title: "Nearby phone", handle: "", hue: Double(seed.last ?? 0) / 255)
    }
    static func generated(_ name: String, seed: Data) -> PeerLabel {
        PeerLabel(title: name, handle: "", hue: Double(seed.last ?? 0) / 255)
    }
    /// A rotating advert recognised through a contact's presence lease: their own label, "seen nearby, unconfirmed".
    static func recognized(contactName: String, seed: Data) -> PeerLabel {
        PeerLabel(title: "\(contactName), seen nearby, unconfirmed", handle: "", hue: Double(seed.last ?? 0) / 255)
    }
    private init(title: String, handle: String, hue: Double) {
        self.title = title; self.handle = handle; shortHandle = ""; selfName = nil; contactName = nil; verified = false
        color = Color(hue: hue, saturation: 0.25, brightness: 0.6)
    }

    init(prefix: Data, contactName: String? = nil, selfName: String? = nil, verified: Bool = false) {
        let handle = IdentityHandle.handle(prefix: prefix) ?? "?????-?????"
        let short = String(handle.prefix(5))
        self.handle = handle; shortHandle = short; self.verified = verified
        self.contactName = contactName; self.selfName = selfName
        title = contactName ?? selfName.map { "\u{201C}\($0)\u{201D}" } ?? handle
        let hue = Double(prefix.last ?? 0) / 255
        color = Color(hue: hue, saturation: 0.45, brightness: 0.75)
    }
}

struct MonogramView: View {
    let label: PeerLabel
    var size: CGFloat = 44
    /// Follows Dynamic Type (the disc grows with the text, up to 1.6x, so rows stay aligned at accessibility sizes).
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    var body: some View {
        let side = size * min(scale, 1.6)
        Text(label.monogram)
            .font(.system(size: side * 0.42, weight: .semibold, design: .rounded))
            .foregroundStyle(Palette.ink)
            .frame(width: side, height: side)
            .background(Palette.avatar, in: Circle())
            .accessibilityHidden(true)
    }
}

