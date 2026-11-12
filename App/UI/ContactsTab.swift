import SwiftUI
#if os(iOS)
import UIKit
#endif
import NearbyCore

// MARK: - Contacts

/// Contacts tab (Android r4): your contacts, named first (A-Z) then the unnamed by ID. A row shows "Nearby now" or what to
/// do while this device cannot recognise them, then video call, voice call and info; tapping the row or info opens the
/// contact sheet.
struct ContactsTab: View {
    @EnvironmentObject var model: AppModel
    #if os(macOS)
    @EnvironmentObject private var desktopNavigation: DesktopNavigation
    #endif
    let openNearby: () -> Void
    @State private var info: VerifiedContact?
    @State private var addContact = false
    @State private var addContactShowsCode = false
    /// Add contact asked for by the sheet; it opens once the sheet has closed (true: on Show my code).
    @State private var pendingAddContact: Bool?

    var body: some View {
        TabPage {
            TabHeader(title: "Contacts")
            CallNoticeCard()
            if let unreadable = model.contactsUnreadable {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Verified contacts couldn't be loaded. The saved list is damaged or its key was lost, so nobody shows as verified. Calls still work, and the list is kept as it is until you reset it.")
                        .font(.subheadline).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                    // Apple keeps the store's own reason (a Keychain or file state Android has no text for).
                    Text(unreadable).font(Typo.caption).foregroundStyle(Palette.dimInk)
                    CapsuleButton(title: "Reset verified contacts", kind: .dark) { model.resetContacts() }
                }
                .padding(16).background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).padding(.vertical, 8)
            }
            if model.contacts.isEmpty {
                PlainEmptyState(icon: AppIcon.people, title: "No contacts yet",
                                message: "Meet someone, tap Add contact and scan each other's code. Then you can give them a name.")
                    .padding(.top, 100)
            } else {
                ForEach(Array(ContactNames.sorted(model.contacts).enumerated()), id: \.element.id) { index, contact in
                    if index > 0 { ListDivider() }
                    ContactRow(contact: contact, openNearby: openNearby, openAddContact: openAddContact) { info = contact }
                }
            }
        } bottom: {
            CapsuleButton(title: "Add contact", systemImage: "person.badge.plus", kind: .white) { openAddContact(false) }
        }
        #if !os(macOS)
        .navigationDestination(isPresented: $addContact) { VerifyView(showCode: addContactShowsCode) }
        #endif
        .debugPush("verify") { VerifyView() }
        .sheet(item: $info, onDismiss: {
            if let showCode = pendingAddContact { pendingAddContact = nil; openAddContact(showCode) }
        }) { contact in
            ContactInfoSheet(contact: contact) { showCode in pendingAddContact = showCode; info = nil }
        }
        // Android F15: a call never opens under the contact sheet.
        .onChange(of: model.call != nil) { inCall in if inCall { info = nil } }
    }

    private func openAddContact(_ showCode: Bool) {
        #if os(macOS)
        desktopNavigation.detailPath.append(DesktopDetailRoute { VerifyView(showCode: showCode) })
        #else
        addContactShowsCode = showCode
        addContact = true
        #endif
    }
}

/// One contact (Android `ContactRowAdapter`): the name and one line under it, then video call, voice call and info. The
/// name area opens the contact sheet, like info.
struct ContactRow: View {
    @EnvironmentObject var model: AppModel
    let contact: VerifiedContact
    let openNearby: () -> Void
    let openAddContact: (Bool) -> Void
    let showInfo: () -> Void
    /// Android `showContactNotFound`: the contact cannot be dialled now; the dialog follows `ContactReach`.
    @State private var notFound: NotFound?
    @Environment(\.dynamicTypeSize) private var typeSize
    private var nearbyPerson: PersonRow? { model.nearbyPerson(for: contact) }

    struct NotFound: Identifiable {
        let hint: ContactReach.Hint
        let type: CallType
        var id: String { hint.rawValue }
    }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { names; HStack(spacing: 8) { buttons } }
            } else {
                HStack(spacing: 4) { names; buttons }
            }
        }
        .padding(.vertical, 14)
        .alert(notFound.map { title($0.hint) } ?? "", isPresented: Binding(get: { notFound != nil }, set: { if !$0 { notFound = nil } }),
               presenting: notFound) { item in
            switch item.hint {
            case .recognisable:
                Button("Open Nearby") { model.waitForContact(contact, type: item.type); openNearby() }
            case .askToScan:
                Button("Show my code") { openAddContact(true) }
                Button("Open Nearby") { browse() }
            case .scanAgain:
                Button("Scan again") { openAddContact(false) }
                Button("Open Nearby") { browse() }
            case .callFromNearby:
                Button("Open Nearby") { browse() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(message(item.hint))
        }
    }

    /// "Nearby now" (or the relayed route), else Android's row hint while this device cannot recognise them.
    private var subtitle: String? {
        if let person = nearbyPerson { return person.relayRoute == nil ? "Nearby now" : person.routeText }
        switch model.contactReach(contact) {
        case .askToScan: return "Ask them to scan your code too"
        case .scanAgain: return "Scan each other's codes again"
        default: return nil
        }
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button(action: showInfo) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(contact.displayName).font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                    if model.contactDialWait?.contact != contact, let subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(Palette.dimInk)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel([contact.displayName + ", verified contact", subtitle].compactMap { $0 }.joined(separator: ". "))
            .accessibilityHint("Shows the contact's details")
            .accessibilityIdentifier("contactRow-\(contact.displayName)")
            if model.contactDialWait?.contact == contact {
                HStack(spacing: 8) {
                    Text("Looking nearby\u{2026}").font(.subheadline).foregroundStyle(Palette.dimInk)
                    Button("Cancel") { model.cancelContactDialWait() }.font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        iconButton("video", "Video call \(contact.displayName)") { call(.video) }.disabled(model.call != nil)
        iconButton("phone", "Voice call \(contact.displayName)") { call(.voice) }.disabled(model.call != nil)
        iconButton("info.circle", "Contact info \(contact.displayName)", action: showInfo)
    }

    private func iconButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(Palette.ink).frame(width: 48, height: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func call(_ type: CallType) {
        if let person = nearbyPerson { model.startCall(to: person, type: type); return }
        let hint = model.contactReach(contact)
        // Only a contact this device can recognise can be found by waiting (Android ContactReach.mayWaitForCallBack).
        if hint == .recognisable, model.relayedCalls { model.waitForContact(contact, type: type) }   // up to 45 s, direct or relayed
        else { notFound = NotFound(hint: hint, type: type) }
    }

    /// Nearby for browsing only: the contact shows there under a made-up name until the devices recognise each other.
    private func browse() {
        model.callNotice = "Looking for \(contact.displayName)? Until your phones recognise each other, they show here under a made-up name."
        openNearby()
    }

    private func title(_ hint: ContactReach.Hint) -> String {
        let name = contact.displayName
        switch hint {
        case .recognisable: return "\(name) is not found nearby yet"
        case .askToScan: return "Ask \(name) to scan your code too"
        case .scanAgain, .callFromNearby: return AppPlatform.isMac ? "This Mac does not recognise \(name) yet" : "Your phone does not recognise \(name) yet"
        }
    }

    private func message(_ hint: ContactReach.Hint) -> String {
        let name = contact.displayName
        switch hint {
        case .recognisable:
            return "Make sure \(name) is close by with MeshLive open. Open Nearby to keep looking: the call starts when their phone appears."
        case .askToScan:
            return "Your phones recognise each other only after you have both scanned each other's code. Open Add contact, tap Show my code and let \(name) scan it. Until then \(name) shows in Nearby under a made-up name."
        case .scanAgain:
            return "You scanned each other, but your phones did not finish learning to recognise each other. Scan each other's codes again with both phones on Add contact."
        case .callFromNearby:
            return "Call \(name) once from Nearby, where they show under a made-up name. After that call, Contacts can find them."
        }
    }
}

/// The contact sheet (Android `sheet_contact.xml`, `ContactActions`): the name, how and when you verified them, what they
/// call themselves, the ID and full ID, then Android's rows: Use it as my label and Ignore (a changed claim), Scan to
/// confirm (or Show my code / Scan again while this device cannot recognise them), Rename, Block or Unblock, Report and
/// Forget; with rotating IDs, "Can see when I'm nearby". Calls start from the row's buttons, as Android.
struct ContactInfoSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let contact: VerifiedContact
    /// Opens Add contact once the sheet has closed (true: on Show my code).
    var openAddContact: (Bool) -> Void = { _ in }
    @State private var confirmForget = false
    @State private var blockTarget: BlockTarget?
    @State private var renaming = false
    @State private var newName = ""
    /// The outcome of Rename, Use it as my label or Unblock (Android's toast), under the rows.
    @State private var message: String?

    /// The saved record now (a rename or a claim answer changes it while the sheet is open).
    private var current: VerifiedContact { model.contacts.first { $0.fingerprintHex == contact.fingerprintHex } ?? contact }
    private var fingerprint: IdentityFingerprint? { try? IdentityFingerprint(hex: contact.fingerprintHex) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    Card {
                        HStack {
                            Text("ID").font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                            Spacer()
                            Text(IdentityHandle.handle(prefix: Data(hex: contact.nodePrefixHex) ?? Data()) ?? "").font(Typo.code).foregroundStyle(Palette.dimInk)
                        }
                        .padding(.horizontal, 16).frame(minHeight: 56)
                        .accessibilityElement(children: .combine)
                        CardDivider(inset: 16)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Full ID").font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                            Text(grouped(contact.fingerprintHex)).font(.footnote.monospaced()).foregroundStyle(Palette.dimInk).textSelection(.enabled)
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    actions
                    if let message { CardNote(message).accessibilityIdentifier("contactSheetMessage") }
                    if model.rotatingIds {
                        Card {
                            // Android verify_visible_nearby. Not yet asked shows (and counts) as off until the user answers (owner
                            // decision 2026-11-06); off after a delivery starts a new key.
                            SettingsToggleRow(icon: "eye", title: "Can see when I'm nearby",
                                              info: "This contact's phone may recognise yours when it is nearby (shown as unconfirmed, never as verified). Turning it off after they received a key makes this phone start a new key.",
                                              identifier: "canSeeMe-\(contact.displayName)",
                                              isOn: Binding(get: { model.canSeeMe(contact) }, set: { on in
                                                  model.setCanSeeMe(contact, on)
                                                  // Android ql_visibility_off_warning (Q-QL2b): off starts a new key for every contact.
                                                  if !on { message = "Contacts will need to call you or scan your code again to find you nearby." }
                                              }))
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
            .background(Palette.ground.ignoresSafeArea())
            .mobileNavigationTitle(inline: true)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Forget \(current.displayName)?", isPresented: $confirmForget) {
                Button("Forget", role: .destructive) { model.forget(current); dismiss() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(AppPlatform.isMac ? "They will no longer show as verified, and their name is removed from this Mac. To trust them again you need to verify them in person." : "They will no longer show as verified, and their name is removed from this phone. To trust them again you need to verify them in person.")
            }
            .alert("Rename contact", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Save") { if let fingerprint { message = model.renameContact(fingerprint, to: newName).message } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Only you see this name.") }
            .blockConfirmation($blockTarget) { dismiss() }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(current.displayName).font(.title.weight(.bold)).foregroundStyle(Palette.ink)
                .accessibilityIdentifier("contactSheetName")
            Text("Verified by \(current.method == "qr" ? "QR code" : "safety code"), \(current.verifiedAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.subheadline).foregroundStyle(Palette.dimInk)
            if current.scannedBothWaysAt != nil {
                Text("You and this person scanned each other.").font(.subheadline).foregroundStyle(Palette.dimInk)
            }
            if let note = reachNote {
                Text(note).font(.subheadline).foregroundStyle(Palette.dimInk)
            }
            if let claim = current.claimedName, !claim.isEmpty {
                Text(current.claimPending ? "\(current.displayName) now calls themselves \(claim). Nothing changes unless you tap Use it." : "They call themselves \(claim)")
                    .font(.subheadline).foregroundStyle(Palette.dimInk).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("contactClaim")
            }
        }
        .padding(.horizontal, 6).padding(.top, 8)
    }

    private var actions: some View {
        Card {
            if current.claimPending, let claim = current.claimedName, let fingerprint {
                row("checkmark.circle", "Use it as my label", id: "contactUseClaim") {
                    model.acknowledgeClaim(current)
                    message = model.renameContact(fingerprint, to: claim).message
                }
                CardDivider()
                row("xmark.circle", "Ignore", id: "contactIgnoreClaim") { model.acknowledgeClaim(current) }
                CardDivider()
            }
            if let scan = scanRow {
                row(AppIcon.scan, scan.title, id: "contactScanConfirm") { openAddContact(scan.showCode) }
                CardDivider()
            }
            row("pencil", "Rename", id: "contactRename") {
                newName = ContactNames.isUnnamed(current) ? "" : current.displayName
                renaming = true
            }
            if let fingerprint {
                CardDivider()
                if model.isBlocked(fingerprint) {
                    row("hand.raised.slash", "Unblock", id: "contactBlock") {
                        if model.unblock(fingerprint) { message = "\(current.displayName) unblocked" }
                    }
                } else {
                    row("hand.raised", "Block", id: "contactBlock") {
                        blockTarget = BlockTarget(fingerprint: fingerprint, name: current.displayName)
                    }
                }
                CardDivider()
                row("flag", "Report", id: "contactReport") { model.report(fingerprint, streamRoute: nil); dismiss() }
            }
            CardDivider()
            row(AppIcon.wipe, "Forget", id: "contactForget") { confirmForget = true }
        }
    }

    private func row(_ icon: String, _ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { SettingsRowLabel(icon: icon, title: title, chevron: false) }
            .buttonStyle(.plain)
            .accessibilityIdentifier(id)
    }

    /// Android's scan row: the recognition hint's action first, else Scan to confirm for a contact only checked by code.
    private var scanRow: (title: String, showCode: Bool)? {
        switch model.contactReach(current) {
        case .askToScan: return ("Show my code", true)
        case .scanAgain: return ("Scan again", false)
        default: break
        }
        return current.method != "qr" && model.meet.available ? ("Scan to confirm", false) : nil
    }

    private var reachNote: String? {
        switch model.contactReach(current) {
        case .askToScan: return "Ask \(current.displayName) to scan your code too"
        case .scanAgain: return AppPlatform.isMac ? "This Mac does not recognise \(current.displayName) yet" : "Your phone does not recognise \(current.displayName) yet"
        default: return nil
        }
    }

    private func grouped(_ hex: String) -> String {
        let chars = Array(hex.uppercased())
        return stride(from: 0, to: chars.count, by: 4).map { String(chars[$0..<min($0 + 4, chars.count)]) }.joined(separator: " ")
    }
}
