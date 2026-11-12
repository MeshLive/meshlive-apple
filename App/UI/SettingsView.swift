import SwiftUI
import NearbyCore
#if canImport(NearbyMedia)
import NearbyMedia
#endif
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Settings as Android's tree (2026-11-04): Your code and Your name; Allow calls (with the call-alert row only while
/// alerts are not allowed), Relay video for others, Video quality and Privacy; on the Mac a Desktop card; Advanced (Connection,
/// Manual video, Experiments, Help and feedback); About and updates (About this app, Contact us); the red Delete everything.
/// Android rows without an Apple counterpart (update rows) are left out.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var wipeText = ""
    @State private var showWipe = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TabHeader(title: "Settings")
                Card {
                    SettingsLinkRow(icon: AppIcon.identity, title: "Your code") { VerifyView(showCode: true) }
                    CardDivider()
                    let unnamed = model.displayName.trimmingCharacters(in: .whitespaces).isEmpty
                    SettingsLinkRow(icon: "person", title: "Your name", value: unnamed ? "Not set" : model.displayName) { NameView() }
                    if !unnamed {
                        CardDivider()
                        SettingsLinkRow(icon: "person.2", title: "Who sees my name", value: model.namesAudience.title) { NamesAudienceView() }
                    }
                }
                Card {
                    SettingsToggleRow(icon: "phone", title: "Allow calls",
                                      info: AppPlatform.isMac ? "Nearby phones and Macs can call while MeshLive is running. Enable Keep running with windows closed to stay available without a window. Quitting stops calls." : "Phones nearby can call you while MeshLive is open. A closed app cannot ring: MeshLive uses no internet push.",
                                      isOn: $model.availableForCalls)
                    if model.callAlerts != .authorized {
                        CardDivider()
                        CallAlertsRow()
                    }
                    if ReleaseGates.sourceRoles {
                        CardDivider()
                        SettingsToggleRow(icon: "point.3.connected.trianglepath.dotted", title: "Relay video for others",
                                          info: AppPlatform.isMac ? "Experimental. When you watch or listen, this Mac can pass the stream on to one device that is too far from the person who is live. Like you, they can see it. Keep MeshLive running to accept a listener." : "Experimental. When you watch or listen, this phone can pass the stream on to one phone that is too far from the person who is live. Like you, they can see it. Keep the app open to accept a listener.",
                                          isOn: $model.relayForOthers)
                    }
                    CardDivider()
                    SettingsLinkRow(icon: "video", title: "Video quality", value: model.manualVideo ? "Manual" : "Auto") { VideoQualityView() }
                    CardDivider()
                    SettingsLinkRow(icon: "lock", title: "Privacy") { PrivacyView() }
                }
                #if os(macOS)
                DesktopLifecycleSettings()
                #endif
                SectionLabel("Advanced")
                Card {
                    SettingsLinkRow(icon: "dot.radiowaves.left.and.right", title: "Connection") { ConnectionView() }
                    CardDivider()
                    SettingsLinkRow(icon: "slider.horizontal.3", title: "Manual video") { ManualVideoView() }
                    CardDivider()
                    SettingsLinkRow(icon: "flask", title: "Experiments") { ExperimentsView() }
                    CardDivider()
                    SettingsLinkRow(icon: "questionmark.circle", title: "Help and feedback") { HelpView() }
                }
                SectionLabel("About and updates")
                Card {
                    SettingsLinkRow(icon: "info.circle", title: "About this app") { AboutView() }
                    CardDivider()
                    ContactUsRow()
                }
                CapsuleButton(title: "Delete everything", systemImage: AppIcon.wipe, kind: .red) { showWipe = true }
                    .padding(.top, 20)
                    .accessibilityHint("Deletes your identity keys, verified contacts and settings, after you confirm")
            }
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
        .background(Palette.ground.ignoresSafeArea())
        .mobileRootNavigation()
        .debugPush("privacy") { PrivacyView() }
        .debugPush("blocked") { BlockedPeopleView() }
        .debugPush("experiments") { ExperimentsView() }
        .debugPush("connection") { ConnectionView() }
        .debugPush("about") { AboutView() }
        .debugPush("licences") { LicencesView() }
        .debugPush("help") { HelpView() }
        .debugPush("video") { VideoQualityView() }
        .debugPush("manual") { ManualVideoView() }
        .alert("Delete everything?", isPresented: $showWipe) {
            TextField("Type DELETE to confirm", text: $wipeText)
            Button("Delete everything", role: .destructive) { if wipeText == "DELETE" { model.emergencyWipe() }; wipeText = "" }
                .disabled(wipeText != "DELETE")
            Button("Cancel", role: .cancel) { wipeText = "" }
        } message: { Text(AppPlatform.isMac ? "Your identity, contacts and settings will be deleted from this Mac now. Other people will see you as a new, unverified person. This can't be undone." : "Your identity, contacts and settings will be deleted from this phone now. Other people will see you as a new, unverified person. This can't be undone.") }
    }
}

/// Call alerts: status, and the one action that applies (ask, or open iPhone Settings when denied).
private struct CallAlertsRow: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "bell").font(.body).foregroundStyle(Palette.dimInk).frame(width: 26).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Call alerts").font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                Text(CallAlertPolicy.statusText(model.callAlerts)).font(.footnote).foregroundStyle(Palette.dimInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("callAlertsStatus")
                switch model.callAlerts {
                case .notDetermined:
                    smallButton("Allow call alerts") { CallNotifier.shared.requestIfAppropriate(.settingsButton) }
                        .accessibilityIdentifier("allowCallAlerts")
                case .denied:
                    smallButton(AppPlatform.isMac ? "Open System Settings" : "Open iPhone Settings") {
                        AppPlatform.openSettings(notifications: true)
                    }.accessibilityIdentifier("openNotificationSettings")
                case .authorized: EmptyView()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .accessibilityElement(children: .contain)
    }
    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.black)
                .padding(.horizontal, 14).padding(.vertical, 8).background(Color.white, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }
}

/// About and updates › Contact us (Android `ContactEmail`, `ContactEmailUi`): a mail draft with only the subject
/// "MeshLive" (no app or peer data), or the address with Copy when no mail app takes the draft.
private struct ContactUsRow: View {
    static let address = "meshlive.dev@gmail.com"
    @Environment(\.openURL) private var openURL
    @State private var showAddress = false
    var body: some View {
        Button {
            guard let url = URL(string: "mailto:\(Self.address)?subject=MeshLive") else { showAddress = true; return }
            openURL(url) { accepted in if !accepted { showAddress = true } }
        } label: {
            SettingsRowLabel(icon: "envelope", title: "Contact us", subtitle: "Questions, problems or safety concerns", chevron: false)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("contactUs")
        .alert("Contact us", isPresented: $showAddress) {
            Button("Copy") { Self.copy(Self.address) }
            Button("Close", role: .cancel) {}
        } message: { Text(Self.address) }
    }

    private static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// A pushed settings page: black ground, cards with the gutter, and Android's one-row title with the status chip
/// (iPhone: inline navigation bar; Mac: `PageHeader` at the top of the page).
struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                #if os(macOS)
                PageHeader(title: title)
                #endif
                content
            }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
        }
        .background(Palette.ground.ignoresSafeArea())
        .pageTitle(title)
    }
}

/// Settings › Your name. The field edits a draft; Return or leaving the page (Back, another tab, the sidebar) applies
/// it (Android 2026-11-04): an empty field clears the name, an accepted name is saved, and a name the label rules
/// reject keeps the current name, with the reason shown under the field while it is typed.
struct NameView: View {
    @EnvironmentObject var model: AppModel
    @State private var draft = ""
    @State private var loaded = false
    var body: some View {
        SettingsPage(title: "Your name") {
            Card {
                TextField("Optional. You choose who sees it", text: $draft)
                    .padding(.horizontal, 16).frame(minHeight: 56)
                    .accessibilityIdentifier("yourNameField")
                    .onSubmit(apply)
            }
            if let reason = OwnNameEdit.outcome(typed: draft).rejection {
                CardNote("This name can't be used (\(reason)). Your name stays \(model.displayName.isEmpty ? "not set" : "\u{201C}\(model.displayName)\u{201D}").")
                    .accessibilityIdentifier("yourNameRejected")
            }
            CardNote("Your name is never broadcast. It is sent, encrypted, only to the people you choose under Who sees my name, and your QR code shows it. Without a name, others see a made-up name.")
        }
        .onAppear { if !loaded { draft = model.displayName; loaded = true } }
        .onDisappear(perform: apply)
    }

    private func apply() {
        let name = OwnNameEdit.outcome(typed: draft).resolved(current: model.displayName)
        if name != model.displayName { model.displayName = name }
    }
}

/// Settings › Who sees my name (Android `names_audience_*`, a single choice; shown only while a name is set): who
/// receives your name inside calls. The explanation is the note on Your name, as Android.
struct NamesAudienceView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        SettingsPage(title: "Who sees my name") {
            Card {
                ForEach(Array(NamesAudience.allCases.enumerated()), id: \.element) { index, audience in
                    if index > 0 { CardDivider(inset: 16) }
                    Button { model.namesAudience = audience } label: {
                        HStack {
                            Text(audience.title).font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                            Spacer()
                            if model.namesAudience == audience { Image(systemName: "checkmark").foregroundStyle(Palette.ink).accessibilityHidden(true) }
                        }
                        .padding(.horizontal, 16).frame(minHeight: 56).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("namesAudience-\(audience.rawValue)")
                    .accessibilityAddTraits(model.namesAudience == audience ? [.isSelected] : [])
                }
            }
        }
    }
}

/// Privacy, one page (Android "Fewer switches", 2026-11-04). Rotating discovery IDs, Hidden identities,
/// Pseudonymous toward strangers, Names and titles and Generated nearby names are always on (no switch), and an
/// identity mismatch is always refused; Reset private ID shows while rotating IDs are on (always, except in a DEBUG
/// control run). Block unknown callers (off) and Blocked people as Android, in Android's order (Show names on lock screen first).
struct PrivacyView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmPresenceReset = false
    /// Android `rotating_ids_reset_done`: shown under the card after a reset.
    @State private var presenceResetDone = false
    /// "Reset the block list?" from the unreadable-list row (decision 2026-11-06).
    @State private var confirmBlockListReset = false
    /// Android `block_list_reset_done`: shown under the card after a reset.
    @State private var blockListResetDone = false
    var body: some View {
        SettingsPage(title: "Privacy") {
            Card {
                SettingsToggleRow(icon: "lock.rectangle", title: "Show names on lock screen",
                                  info: AppPlatform.isMac ? "Off: a locked Mac shows only “Incoming call”. Anyone who can see your screen can read a name shown here. macOS shows notification text on a locked Mac only when its previews are set to Always." : "Off: a locked phone shows only “Incoming call”. Anyone who can see your screen can read a name shown here. iOS shows notification text on a locked phone only when its previews are set to Always.",
                                  identifier: "lockScreenNames",
                                  isOn: Binding(get: { AppSettings.lockScreenNames }, set: { AppSettings.lockScreenNames = $0; model.objectWillChange.send() }))
                CardDivider()
                SettingsToggleRow(icon: "hand.tap", title: "Triple-tap to delete everything",
                                  info: "Off by default. Tap the title at the top of a tab three times quickly to delete everything, after you confirm. Copies on other phones and earlier backups are not affected.",
                                  identifier: "quickWipeToggle", isOn: $model.quickWipeGesture)
                CardDivider()
                SettingsToggleRow(icon: "phone.down", title: "Block unknown callers",
                                  info: "Calls not recognised as verified contacts are blocked without ringing and appear in Recent. Some saved contacts may also be blocked if they can't be recognised; you can call them back. If your saved contacts can't be read, calls may still ring.",
                                  identifier: "blockUnknownCallers", isOn: $model.blockUnknownCallers)
                CardDivider()
                SettingsLinkRow(icon: "hand.raised", title: "Blocked people") { BlockedPeopleView() }
                if model.blockListDamaged {
                    // Decision 2026-11-06 (Android blockedPeopleProblemRow): an unreadable list is never silent.
                    CardDivider()
                    BlockListUnreadableRow { confirmBlockListReset = true }
                }
                if model.rotatingIds {
                    CardDivider()
                    Button { confirmPresenceReset = true } label: {
                        SettingsRowLabel(icon: "key", title: "Reset private ID", chevron: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("resetPresenceKey")
                    .accessibilityHint("Contacts stop recognising this phone nearby until your next call with each of them")
                }
            }
            if presenceResetDone {
                CardNote("Private ID reset.").accessibilityIdentifier("privateIdResetDone")
            }
            if blockListResetDone {
                CardNote("Block list reset").accessibilityIdentifier("blockListResetDone")
            }
            if model.rotatingIds {
                CardNote(AppPlatform.isMac ? "macOS may expose this Mac's system Bluetooth name to connected devices. A neutral computer name reduces that separate identifying clue." : "While rotating, the name in Settings > General > About > Name can still identify this iPhone to phones that connect. Use a neutral name if it is personal.")
            }
        }
        .alert("Reset nearby recognition?", isPresented: $confirmPresenceReset) {
            Button("Reset") { model.resetPresenceKey(); presenceResetDone = true }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Contacts will need to reconnect with you to recognise your phone nearby again. Your saved contacts and call verification stay the same.") }
        .alert("Reset the block list?", isPresented: $confirmBlockListReset) {
            Button("Reset") { model.resetBlockList(); blockListResetDone = true }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Everyone is unblocked and you can block people again.") }
        .onAppear { model.reloadBlockListIfNeeded() }
    }
}

/// "Block list can't be read" with Reset (Android `blockedPeopleProblemRow`, and `blockedStoreProblem` with its Reset
/// button): shown on Privacy and on Blocked people while the saved list is damaged. Calls are not blocked until it is
/// reset; `reset` asks "Reset the block list?" first.
struct BlockListUnreadableRow: View {
    var detail: String? = nil
    let reset: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            SettingsRowLabel(icon: "exclamationmark.triangle", title: "Block list can't be read", subtitle: detail, chevron: false)
            Button("Reset", action: reset)
                .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink).buttonStyle(.plain)
                .padding(.trailing, 16)
                .accessibilityIdentifier("blockListReset")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("blockListUnreadable")
    }
}

/// Settings › Privacy › Blocked people (Android BlockedPeopleActivity): who is blocked, Unblock, and the reset of a
/// damaged list. A locked Keychain is not damaged: it shows an explanation and retries on appearance (P6-A2).
struct BlockedPeopleView: View {
    @EnvironmentObject var model: AppModel
    @State private var unblock: BlockedPerson?
    @State private var confirmReset = false
    var body: some View {
        SettingsPage(title: "Blocked people") {
            CardNote(AppPlatform.isMac ? "Blocked calls won't ring, and blocked livestreams are hidden on this Mac. People aren't notified when you block them." : "Blocked calls won't ring, and blocked livestreams are hidden on this phone. People aren't notified when you block them.")
            if let list = model.blockList {
                if list.people.isEmpty {
                    PlainEmptyState(icon: "hand.raised", title: "No one is blocked",
                                    message: AppPlatform.isMac ? "Block someone from Recent (Control-click a row), from a contact, or with Decline and block on an incoming call." : "Block someone from Recent (press and hold a row), from a contact, or with Decline and block on an incoming call.")
                        .padding(.top, 40)
                } else {
                    Card {
                        ForEach(Array(list.people.enumerated()), id: \.element.id) { index, person in
                            if index > 0 { CardDivider(inset: 16) }
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(name(person)).font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                                    Text("Blocked \(person.blockedAt.formatted(date: .abbreviated, time: .omitted))").font(.subheadline).foregroundStyle(Palette.dimInk)
                                }
                                Spacer(minLength: 8)
                                Button("Unblock") { unblock = person }
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink).buttonStyle(.plain)
                                    .accessibilityIdentifier("unblock-\(person.nodePrefixHex)")
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(name(person)), blocked")
                        }
                    }
                }
            } else if BlockListView.of(list: model.blockList, damaged: model.blockListDamaged).showUnreadableNote {
                Card {
                    BlockListUnreadableRow(detail: "Calls aren't blocked until you reset it.") { confirmReset = true }
                }
            } else {
                Card {
                    SettingsRowLabel(icon: "lock", title: "Blocked people unavailable",
                                     subtitle: AppPlatform.isMac ? "The block list cannot be read until you log in. Calls are not blocked until then." : "The block list cannot be read until you unlock this phone. Calls are not blocked until then.",
                                     chevron: false)
                }
                .accessibilityIdentifier("blockedPeopleUnavailable")
            }
        }
        .onAppear { model.reloadBlockListIfNeeded() }
        .alert(unblock.map { "Unblock \(name($0))?" } ?? "Unblock?", isPresented: Binding(get: { unblock != nil }, set: { if !$0 { unblock = nil } }),
               presenting: unblock) { person in
            Button("Unblock") { model.unblock(person) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("Their calls will ring again and their livestreams will show in Live.") }
        .alert("Reset the block list?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.resetBlockList() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Everyone is unblocked and you can block people again.") }
    }
    private func name(_ person: BlockedPerson) -> String {
        model.contactName(prefixHex: person.nodePrefixHex) ?? IdentityHandle.handle(prefix: Data(hex: person.nodePrefixHex) ?? Data()) ?? person.nodePrefixHex
    }
}

/// Connection type, then the next broadcast and call (Android Connection page).
struct ConnectionView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        SettingsPage(title: "Connection") {
            SectionLabel("Bluetooth transport")
            Card {
                ForEach(Array(MeshTransport.allCases.enumerated()), id: \.element) { index, transport in
                    if index > 0 { CardDivider(inset: 16) }
                    Button { model.transport = transport } label: {
                        HStack {
                            Text(transport == .gatt ? "Bluetooth LE (GATT) - Pairing-free default" : "Bluetooth LE (L2CAP CoC) - Experimental").font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                            Spacer()
                            if model.transport == transport { Image(systemName: "checkmark").foregroundStyle(Palette.ink).accessibilityHidden(true) }
                        }
                        .padding(.horizontal, 16).frame(minHeight: 56).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.transport == transport ? [.isSelected] : [])
                }
            }
            CardNote(AppPlatform.isMac ? "The Bluetooth link for calls and streams this Mac offers. GATT works with every supported device; Bluetooth Classic is not available on a Mac." : "The Bluetooth link for calls and streams this phone offers. GATT works with every phone; Bluetooth Classic is not available on iPhone.")
            if AppSettings.wifiWire {
                SectionLabel("Wi-Fi")
                if let notice = model.settingsNotice { CardNote(notice) }
                Card {
                    SettingsToggleRow(icon: "wifi", title: "Use Wi-Fi for faster connections",
                                      info: "Experimental. During a video call with an Android phone that offers it, the call can move to Wi-Fi after Bluetooth has checked both of you. Bluetooth stays connected and takes over if Wi-Fi stops. Turned on during a call, it works from the next one.",
                                      isOn: $model.wifiCarrier)
                    CardDivider()
                    SettingsToggleRow(icon: "wifi.circle", title: "Join Wi-Fi Direct groups",
                                      info: AppPlatform.isMac
                                        ? "Experimental. This Mac joins the other phone's temporary Wi-Fi Direct network and leaves its own Wi-Fi until the call ends. macOS needs Location to find the network; MeshLive never reads your location. Devices nearby can see this Mac on that network, and the other phone can reach other apps on this Mac that accept connections from any network."
                                        : "Experimental. This iPhone joins the other phone's temporary Wi-Fi Direct network and leaves its own Wi-Fi until the call ends. iOS asks before each join. Devices nearby can see this iPhone on that network, and the other phone can reach other apps on this iPhone that accept connections from any network.",
                                      isOn: $model.wifiDirect)
                        .disabled(!model.wifiCarrier)
                }
            }
            // Android Connection page: what the next broadcast and call ask for (Settings › Advanced › Manual video), the
            // call after the transport budget when Manual video settings is on (shown as a cap, never written back).
            let request = model.videoRequest
            let cap = CallTransportCap.cap(transport: model.transport, manual: model.manualVideo, enabled: AppSettings.callTransportCap)
            let callKbps = CallTransportCap.startKbps(requested: request.kbps, cap: cap)
            let device = AppPlatform.isMac ? "The other device" : "The other phone"
            Card {
                SettingsRowLabel(icon: "record.circle", title: "Next broadcast",
                                 value: VideoRequest.line(width: request.width, height: request.height, fps: request.fps, kbps: request.kbps),
                                 subtitle: "Heat can lower it.", chevron: false)
                    .accessibilityIdentifier("videoNextBroadcast")
                CardDivider()
                SettingsRowLabel(icon: "phone", title: "Next call",
                                 value: VideoRequest.line(width: request.width, height: request.height, fps: request.fps, kbps: callKbps),
                                 subtitle: (callKbps < request.kbps ? CallTransportCap.note(cap: callKbps, transport: model.transport) + " " : "")
                                    + "\(device), a route through other phones or heat can lower it; the call info shows what is sent.",
                                 chevron: false)
                    .accessibilityIdentifier("videoNextCall")
            }
            .padding(.top, 8)
        }
    }
}

/// Experiments, in Android's order: the hint, Let older app versions find me, Relay: slow viewers skip to keyframes (only
/// with the relay gate), and Relayed calls with Relay calls for others and Accept relayed calls (shown and honoured with
/// or without Manual video settings since the owner's 2026-11-06 decision, as Android); on the Mac its own experiments
/// only in DEBUG builds. The info-only card about the standalone v1 protocol is gone (the switch register in the docs
/// lists it).
struct ExperimentsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        SettingsPage(title: "Experiments") {
            CardNote("Tests that may not work well yet.")
            if model.rotatingIds {
                Card {
                    Button { model.startVisibleByHandle() } label: {
                        SettingsRowLabel(icon: "eye", title: "Let older app versions find me (10 to 25 minutes)", chevron: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("visibleByHandle")
                }
            }
            if ReleaseGates.sourceRoles {
                Card {
                    SettingsToggleRow(icon: "forward.end", title: "Relay: slow viewers skip to keyframes",
                                      info: "Used when Relay video for others is on. A phone you pass a stream to that cannot keep up skips stale video to the next keyframe and keeps the sound, instead of being dropped.",
                                      isOn: Binding(get: { AppSettings.relayChildMediaAge }, set: { AppSettings.relayChildMediaAge = $0; model.objectWillChange.send() }))
                }
                .padding(.top, 8)
            }
            Card {
                SettingsToggleRow(icon: "arrow.triangle.branch", title: "Relayed calls",
                                  info: "Experimental. Calls that reach you through another phone ring only with this on. A relaying phone cannot hear or see the call, but if you answer an unverified stranger, your identity is revealed to whoever holds the call, which may be a relaying phone.",
                                  identifier: "Relayed calls", isOn: $model.relayedCalls)
                if model.relayedCalls {
                    CardDivider()
                    SettingsToggleRow(icon: "arrow.left.arrow.right", title: "Relay calls for others",
                                      info: "Experimental. While this device is idle, it can pass one call between two people nearby. It cannot hear or see the call. It stops when you use it, and pauses on low battery or in Low Power Mode.",
                                      identifier: "Help calls nearby", isOn: $model.relayedCallsHelp)
                    CardDivider()
                    SettingsToggleRow(icon: "person.wave.2", title: "Accept relayed calls",
                                      info: "Experimental. People out of range can call you through other phones. If you answer someone you have not verified, your identity is revealed to whoever holds the call, which may be a relaying phone.",
                                      identifier: "Let phones nearby relay calls to me", isOn: $model.relayedCallsConsent)
                }
            }
            .padding(.top, 8)
            #if os(macOS)
            if LabSwitch.isDebugBuild {
                Card {
                    SettingsToggleRow(icon: "speedometer", title: "Adapt call video to delivery",
                                      info: "Experimental. Uses the other device's delivery reports to reduce queued video and keep calls responsive. Older devices keep the existing adaptation.",
                                      identifier: "desktop-call-delivery-feedback", isOn: $model.desktopCallDeliveryFeedback)
                    CardDivider()
                    SettingsToggleRow(icon: "antenna.radiowaves.left.and.right.slash", title: "Pause discovery during calls",
                                      info: "Experimental. Pauses nearby discovery once a call connects, giving Bluetooth more time for the call. Discovery resumes when the call ends.",
                                      identifier: "desktop-pause-call-discovery", isOn: $model.desktopPauseCallDiscovery)
                    CardDivider()
                    DesktopExperimentalReachabilityRows()
                }
                .padding(.top, 8)
            }
            #endif
        }
    }
}

/// Settings › Video quality (Android `settingsPageVideo`): Fill screen with video, Show temperature, Lower quality when
/// hot, and the Experimental Warn when video freezes.
struct VideoQualityView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        SettingsPage(title: "Video quality") {
            Card {
                SettingsToggleRow(icon: "arrow.up.left.and.arrow.down.right", title: "Fill screen with video",
                                  info: "On: fills the screen without stretching; excess edges are cropped. Off: shows every edge without stretching; black bars appear when ratios differ.",
                                  identifier: "videoFill", isOn: $model.videoFill)
                CardDivider()
                SettingsToggleRow(icon: "thermometer.medium", title: "Show temperature",
                                  info: AppPlatform.isMac ? "Shows how hot this Mac is on call and live screens. The heat warning stays on when hidden." : "Shows heat and battery level on call and live screens. The heat warning stays on when hidden.",
                                  identifier: "showTemperature", isOn: $model.showTemperature)
                CardDivider()
                SettingsToggleRow(icon: "flame", title: "Lower quality when hot",
                                  info: AppPlatform.isMac ? "Reduces video quality and frame rate as your Mac gets warmer. Video stops if the Mac gets too hot, even with this setting off." : "Reduces video quality and frame rate as your phone gets warmer. Video stops if the phone gets too hot, even with this setting off.",
                                  identifier: "lowerQualityWhenHot", isOn: $model.lowerQualityWhenHot)
            }
            SectionLabel("Experimental")
            Card {
                SettingsToggleRow(icon: "pause.rectangle", title: "Warn when video freezes",
                                  info: "While you watch a stream, dim a frozen picture and say so when it stops updating, instead of leaving it on screen as if it were live. A small label shows how long ago the picture last updated. That time is counted on this device from the last picture it received; it is not the delay from the camera.",
                                  identifier: "viewerFreezeWarning", isOn: $model.viewerFreezeWarning)
            }
        }
    }
}

/// Settings › Advanced › Manual video (Android `settingsPageManual`): Manual video settings, the encoder, resolution, frame
/// rate and bitrate the next call or broadcast asks for, and the decoders (Connection shows the next call and broadcast).
struct ManualVideoView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let request = model.videoRequest
        let maxKbps = VideoRequest.sliderMaxKbps(model.transport, current: request.kbps)
        SettingsPage(title: "Manual video") {
            Card {
                SettingsToggleRow(icon: "slider.horizontal.3", title: "Manual video settings", identifier: "manualVideo", isOn: $model.manualVideo)
            }
            CardNote(model.manualVideo
                     ? "On: every value below is exactly what you choose; nothing adapts automatically. Lower quality when hot still applies."
                     : "Off (recommended): the bitrate and picture size follow what the link carries. You still choose resolution, frame rate and bitrate.")
            SectionLabel("Quality")
            Card {
                SettingsRowLabel(icon: "film", title: "Encoder", value: CodecSummary.encode, chevron: false)
                CardDivider()
                SettingsPickerRow(icon: "aspectratio", title: "Resolution") {
                    Picker("Resolution", selection: Binding(get: { request.lines }, set: { lines in
                        if let next = VideoRequest(lines: lines, fps: request.fps, kbps: request.kbps) { model.videoRequest = next }
                    })) {
                        ForEach(VideoRequest.lineOptions, id: \.self) { Text(VideoRequest.resolutionTitle($0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("videoResolution")
                }
                CardDivider()
                SettingsPickerRow(icon: "speedometer", title: "Frame rate") {
                    Picker("Frame rate", selection: Binding(get: { request.fps }, set: { fps in
                        if let next = VideoRequest(lines: request.lines, fps: fps, kbps: request.kbps) { model.videoRequest = next }
                    })) {
                        ForEach(VideoRequest.fpsOptions, id: \.self) { Text("\($0) FPS").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("videoFrameRate")
                }
                CardDivider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Video bitrate").font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                        Spacer()
                        Text("\(request.kbps) kbps").font(.body).foregroundStyle(Palette.dimInk)
                    }
                    Slider(value: Binding(get: { Double(request.kbps) }, set: { value in
                        let stepped = VideoRequest.minKbps + Int(((value - Double(VideoRequest.minKbps)) / Double(VideoRequest.stepKbps)).rounded()) * VideoRequest.stepKbps
                        if let next = VideoRequest(lines: request.lines, fps: request.fps, kbps: stepped), next != request { model.videoRequest = next }
                    }), in: Double(VideoRequest.minKbps)...Double(maxKbps), step: Double(VideoRequest.stepKbps))
                    .tint(.white)
                    .accessibilityLabel("Video bitrate")
                    .accessibilityValue("\(request.kbps) kbps")
                    .accessibilityIdentifier("videoBitrate")
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            SectionLabel(AppPlatform.isMac ? "Decoders on this Mac" : "Decoders on this phone")
            Card { SettingsRowLabel(icon: "film.stack", title: "Video", value: CodecSummary.decode, chevron: false) }
        }
    }
}

/// Links the support rows use. Android `SupportLinks.ISSUES_URL` is null in this build, so Report a bug is hidden on
/// Android and here until the project sets the bug page.
enum SupportLinks {
    static let issuesURL: URL? = nil
}

/// Settings › Advanced › Help and feedback (Android `settingsPageHelp`): what keeps MeshLive reachable here, Export
/// diagnostics and (when the project has a bug page) Report a bug.
struct HelpView: View {
    @Environment(\.openURL) private var openURL
    @State private var exportText: String?
    var body: some View {
        SettingsPage(title: "Help and feedback") {
            CardNote(AppPlatform.isMac ? "MeshLive is reachable while it runs. Keep running with windows closed keeps it reachable without a window; quitting or sleep stops calls." : "MeshLive is reachable while it is open. iOS stops Bluetooth discovery for apps in the background, and a closed app cannot ring.")
            Card {
                Button { exportText = DiagnosticsExport.text() } label: {
                    SettingsRowLabel(icon: "doc.text", title: "Export diagnostics", chevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("exportDiagnostics")
                if let url = SupportLinks.issuesURL {
                    CardDivider()
                    Button { openURL(url) } label: {
                        SettingsRowLabel(icon: "exclamationmark.bubble", title: "Report a bug", chevron: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("reportBug")
                }
            }
        }
        .sheet(isPresented: Binding(get: { exportText != nil }, set: { if !$0 { exportText = nil } })) {
            if let text = exportText { DiagnosticsSheet(text: text) { exportText = nil } }
        }
    }
}

/// Export diagnostics: the exact text, copied when the sheet opens ("Copied"), Share (the system share sheet, subject
/// "MeshLive diagnostics") and Done. Nothing is sent unless the user sends it.
struct DiagnosticsSheet: View {
    let text: String
    let done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export diagnostics").font(.title2.weight(.bold)).foregroundStyle(Palette.ink)
            Text(AppPlatform.isMac ? "Creates a short technical report (app version, Mac model, Bluetooth support). It contains no video, sound, messages, names or keys. You choose where to send it; it is also copied." : "Creates a short technical report (app version, phone model, Bluetooth support). It contains no video, sound, messages, names or keys. You choose where to send it; it is also copied.")
                .font(.body).foregroundStyle(Palette.dimInk).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(text).font(.footnote.monospaced()).foregroundStyle(Palette.ink).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .frame(maxHeight: 300)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityIdentifier("diagnostics-text")
            Text("Copied").font(.footnote).foregroundStyle(Palette.dimInk)
            ShareLink(item: text, subject: Text(DiagnosticsReport.subject)) {
                Text("Share").font(.body.weight(.semibold)).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).padding(.vertical, 14).background(Color.white, in: Capsule())
            }
            .buttonStyle(.plain)
            CapsuleButton(title: "Done", kind: .dark) { done() }
        }
        .padding(20)
        .frame(minWidth: AppPlatform.isMac ? 480 : nil)
        .background(Palette.ground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { DiagnosticsSheet.copy(text) }
    }

    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// About this app (Android AboutActivity): the version as Android shows it, the commit this copy was built from, the
/// codecs, the offline note, how calls reach you, updates, and what this platform cannot do.
struct AboutView: View {
    @EnvironmentObject var model: AppModel
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    private var versionText: String {
        #if DEBUG
        let type = "debug"
        #else
        let type = "release"
        #endif
        return "\(info["CFBundleShortVersionString"] as? String ?? "-") (build \(info["CFBundleVersion"] as? String ?? "-"), \(type))"
    }
    private var sourceText: String {
        let commit = (info["MeshLiveSourceCommit"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return commit.isEmpty ? "Not recorded" : commit
    }
    var body: some View {
        SettingsPage(title: "About this app") {
            Card {
                infoRow("Version", versionText)
                CardDivider(inset: 16)
                infoRow("Source", sourceText)
                CardDivider(inset: 16)
                infoRow("Video decode", CodecSummary.decode)
                CardDivider(inset: 16)
                infoRow("Video encode", CodecSummary.encode)
                CardDivider(inset: 16)
                infoRow("Voice", CodecSummary.voice)
            }
            Card {
                PrivacyPolicyLink()
                    .accessibilityIdentifier("about-privacy-policy")
                CardDivider()
                #if os(macOS)
                NavigationLink(value: DesktopDetailRoute { TermsPageView() }) {
                    SettingsRowLabel(icon: "doc.text", title: "Terms of use")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("about-terms")
                #else
                NavigationLink { TermsPageView() } label: {
                    SettingsRowLabel(icon: "doc.text", title: "Terms of use")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("about-terms")
                #endif
                CardDivider()
                #if os(macOS)
                NavigationLink(value: DesktopDetailRoute { LicencesView() }) {
                    SettingsRowLabel(icon: "curlybraces", title: "Open-source licences")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("about-licences")
                #else
                NavigationLink { LicencesView() } label: {
                    SettingsRowLabel(icon: "curlybraces", title: "Open-source licences")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("about-licences")
                #endif
            }
            CardNote("Calls and livestreams never use the internet or a server.")
            SectionLabel("Calls")
            CardNote(AppPlatform.isMac ? "Calls reach you while MeshLive is running. Call alerts require notification permission. Keep running with windows closed is optional; quitting stops Bluetooth and media. Sleep can interrupt connections. While muted, hold Mute to talk." : "Calls reach you while MeshLive is open. A call that starts ringing just as you leave the app shows an alert. A closed app cannot ring: MeshLive uses no internet push. A call keeps going if you lock the phone. While muted, hold Mute to talk.")
            SectionLabel("Updates")
            CardNote(model.distribution == .appStore
                     ? "Updates come from the App Store."
                     : "MeshLive does not check for updates. Newer versions are published on the project's GitHub page; build or install them from there. Source is the commit this copy was built from.")
            SectionLabel(AppPlatform.isMac ? "Not available in this Mac app" : "Not possible on iPhone")
            CardNote(AppPlatform.isMac ? "Bluetooth Classic links and incoming calls after quitting. Keep this Mac awake to stay reachable." : "Bluetooth Classic links, being found while the app is in the background, and incoming calls while the app is closed.")
        }
    }
    private func infoRow(_ title: String, _ value: String) -> some View {
        // The value wraps under the title when both do not fit on one line (Android 2026-10-21).
        TitleValueLayout(spacing: 12) {
            Text(title).font(.body.weight(.medium)).foregroundStyle(Palette.ink)
            Text(value).font(.body).foregroundStyle(Palette.dimInk)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + ": " + value)
        .accessibilityIdentifier("about-" + title)
    }
}
