import SwiftUI
import NearbyCore

/// The Terms of use and Privacy policy pages, linked from the terms page and from About.
enum LegalLinks {
    static let privacyPolicyURL = URL(string: "https://meshlive.github.io/privacy/")!
    static let termsURL = URL(string: "https://meshlive.github.io/terms/")!
}

/// The About row that opens the Privacy policy in the system browser.
struct PrivacyPolicyLink: View {
    var body: some View {
        Link(destination: LegalLinks.privacyPolicyURL) {
            SettingsRowLabel(icon: "hand.raised", title: "Privacy policy")
        }
        .buttonStyle(.plain)
    }
}

/// The About row that opens the Terms of use in the system browser (used as the secondary link on the in-app terms page).
struct TermsLink: View {
    var title = "Terms of use"
    var body: some View {
        Link(destination: LegalLinks.termsURL) {
            SettingsRowLabel(icon: "safari", title: title)
        }
        .buttonStyle(.plain)
    }
}

/// The terms text, in one place: the onboarding terms step and About's in-app Terms page show the same words.
struct TermsContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("MeshLive connects you with people near you. What you say, show or send is your responsibility.")
                .font(.body).foregroundStyle(Palette.dimInk)
            row("person.fill", "You must be 18 or older.")
            row("exclamationmark.shield", "No abuse", "Harassment, hate, threats, sexual content involving minors and anything illegal are not allowed. We have zero tolerance for abuse.")
            row("hand.raised", "Block or report anyone",
                AppPlatform.isMac
                ? "From an incoming call, a livestream, Recent, a contact or the list of people nearby. Block hides them on this Mac. Report also blocks them and offers to email the MeshLive team."
                : "From an incoming call, a livestream, Recent, a contact or the list of people nearby. Block hides them on this phone. Report also blocks them and offers to email the MeshLive team.")
            row("dot.radiowaves.left.and.right", "Livestreams are public", "Anyone nearby can join a livestream. Calls are end-to-end encrypted between the two devices.")
            row("cross.case", "Not for emergencies", "MeshLive does not replace calling emergency services.")
            VStack(alignment: .leading, spacing: 6) {
                Text("By continuing you agree to the")
                HStack(spacing: 4) {
                    Link("Terms of use", destination: LegalLinks.termsURL).accessibilityIdentifier("terms-link-terms")
                    Text("and the")
                    Link("Privacy policy", destination: LegalLinks.privacyPolicyURL).accessibilityIdentifier("terms-link-privacy")
                    Text(".")
                }
            }
            .font(.body).foregroundStyle(Palette.dimInk)
            Text("If you do not agree, close the app.").font(.footnote).foregroundStyle(Palette.dimInk)
        }
    }

    private func row(_ icon: String, _ title: String, _ detail: String = "") -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).font(.system(size: 22)).frame(width: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                if !detail.isEmpty { Text(detail).font(.body).foregroundStyle(Palette.dimInk) }
            }
        }
    }
}

/// About's Terms row: the same terms as the first run, readable offline, with the published page as a secondary link.
struct TermsPageView: View {
    var body: some View {
        SettingsPage(title: "Terms of use") {
            Text("Before you start").font(.largeTitle.weight(.bold)).foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            TermsContent()
            Card {
                TermsLink(title: "Terms of use on the web")
                    .accessibilityIdentifier("terms-web-link")
            }
            .padding(.top, 8)
        }
    }
}

/// Settings > About this app > Open-source licences: the components linked into the apps, each with the licence text
/// bundled at the app bundle root from the same repository files that THIRD_PARTY_NOTICES.md links to.
struct LicencesView: View {
    var body: some View {
        SettingsPage(title: "Open-source licences") {
            CardNote("MeshLive is free software under the GNU General Public License, version 3 or later. It includes these components.")
            Card {
                ForEach(Array(OpenSourceNotices.entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { CardDivider() }
                    SettingsLinkRow(icon: "doc.text", title: entry.title,
                                    value: [entry.version, entry.licence].filter { !$0.isEmpty }.joined(separator: " · ")) {
                        LicenceTextView(entry: entry)
                    }
                }
            }
        }
    }
}

/// One component's licence text, selectable and monospaced, inside the page's scroll view. A missing file shows the
/// plan's sentence and logs nothing.
private struct LicenceTextView: View {
    let entry: OpenSourceNotice

    var body: some View {
        SettingsPage(title: entry.title) {
            CardNote([entry.version, entry.licence].filter { !$0.isEmpty }.joined(separator: " · "))
            Text(licenceText)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var licenceText: String {
        entry.resources.map { name in
            let path = name as NSString
            let ext = path.pathExtension
            let base = ext.isEmpty ? name : path.deletingPathExtension
            guard let url = Bundle.main.url(forResource: base, withExtension: ext.isEmpty ? nil : ext),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                return "\(name)\nThis licence text is missing from the app."
            }
            return "\(name)\n\(text)"
        }
        .joined(separator: "\n\n")
    }
}
