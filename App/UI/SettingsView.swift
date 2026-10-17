import SwiftUI
import NearbyCore
#if canImport(NearbyMedia)
import NearbyMedia
#endif

/// Settings as Android's 2026-10-17 redesign: grouped dark cards, small grey leading icons, values and chevrons,
/// everyday privacy on Privacy and the protocol/identity choices on Advanced privacy, and the red Wipe everything
/// capsule at the bottom. Every iPhone setting from the earlier list is here; Android rows without an iPhone
/// counterpart (Video quality, Manual video, Playback, Help and feedback, update switches) are left out.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var wipeText = ""
    @State private var showWipe = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TabHeader(title: "Settings")
                Card {
                    SettingsLinkRow(icon: "person", title: "Your name",
                                    value: model.displayName.trimmingCharacters(in: .whitespaces).isEmpty ? "Not set" : model.displayName) { NameView() }
                    CardDivider()
                    SettingsLinkRow(icon: AppIcon.identity, title: "Your ID", value: model.handle) { VerifyView() }
                }
                Card {
                    SettingsToggleRow(icon: "phone", title: "Allow calls",
                                      info: "Phones nearby can call you while MeshLive is open. A closed app cannot ring: MeshLive uses no internet push.",
                                      isOn: $model.availableForCalls)
                    CardDivider()
                    CallAlertsRow()
                    CardDivider()
                    SettingsToggleRow(icon: "point.3.connected.trianglepath.dotted", title: "Relay video for others",
                                      info: "Experimental. While you watch, this phone can pass the stream on to one phone near you. It only works with the app open.",
                                      isOn: $model.relayForOthers)
                    CardDivider()
                    SettingsLinkRow(icon: "lock", title: "Privacy") { PrivacyView() }
                }
                SectionLabel("Advanced")
                Card {
                    SettingsLinkRow(icon: "dot.radiowaves.left.and.right", title: "Connection",
                                    value: model.transport == .gatt ? "Standard" : "Faster") { ConnectionView() }
                    CardDivider()
                    SettingsLinkRow(icon: "flask", title: "Experiments") { ExperimentsView() }
                }
                SectionLabel("About and updates")
                Card {
                    SettingsLinkRow(icon: "info.circle", title: "About this app") { AboutView() }
                }
                CapsuleButton(title: "Wipe everything", systemImage: AppIcon.wipe, kind: .red) { showWipe = true }
                    .padding(.top, 20)
                    .accessibilityHint("Deletes your identity keys, verified contacts and settings, after you confirm")
                CardNote("Deletes your identity keys first, then verified contacts and settings. Copies on other phones and earlier backups are not affected.")
            }
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .debugPush("privacy") { PrivacyView() }
        .debugPush("advanced-privacy") { AdvancedPrivacyView() }
        .debugPush("experiments") { ExperimentsView() }
        .debugPush("connection") { ConnectionView() }
        .debugPush("about") { AboutView() }
        .alert("Erase everything?", isPresented: $showWipe) {
            TextField("Type WIPE", text: $wipeText)
            Button("Erase now", role: .destructive) { if wipeText == "WIPE" { model.emergencyWipe() }; wipeText = "" }
            Button("Cancel", role: .cancel) { wipeText = "" }
        } message: { Text("Type WIPE to delete this phone's identity, verified contacts and settings.") }
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
                    smallButton("Open iPhone Settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
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

/// A pushed settings page: black ground, cards with the gutter, large title.
struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
        }
        .background(Palette.ground.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
    }
}

struct NameView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        SettingsPage(title: "Your name") {
            Card {
                TextField("Optional. Only people you call see it", text: $model.displayName)
                    .padding(.horizontal, 16).frame(minHeight: 56)
            }
            CardNote("Your name is never broadcast. With Names and titles on (Privacy), it is sent, encrypted, only to the people you call or answer. It is also in your QR code. Without a name they see your ID instead.")
        }
    }
}

/// Everyday privacy (Android Privacy page), then Advanced privacy.
struct PrivacyView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        SettingsPage(title: "Privacy") {
            Card {
                SettingsToggleRow(icon: "hand.tap", title: "Quick wipe",
                                  info: "Three quick taps on the title at the top of a tab ask to erase your identity keys, verified contacts and settings. Copies on other phones and earlier backups are not affected.",
                                  identifier: "quickWipeToggle", isOn: $model.quickWipeGesture)
                CardDivider()
                SettingsToggleRow(icon: "textformat", title: "Names and titles",
                                  info: "Experimental. Sends your name and call subjects, encrypted and signed with your ID, to the people you call or answer, and shows your live titles to phones nearby. Only phones that also turned this on see them.",
                                  isOn: $model.peerLabelsEnabled)
            }
            Card {
                SettingsLinkRow(icon: "lock.shield", title: "Advanced privacy") { AdvancedPrivacyView() }
            }
            .padding(.top, 8)
        }
    }
}

/// Protocol and identity choices (Android Advanced privacy).
struct AdvancedPrivacyView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmPresenceReset = false
    var body: some View {
        SettingsPage(title: "Advanced privacy") {
            Card {
                SettingsToggleRow(icon: "arrow.triangle.2.circlepath", title: "Rotating discovery IDs",
                                  info: "Experimental. Phones nearby see a new ID every 15 minutes instead of your fixed one; contacts still recognise you after connecting. While rotating, the name in Settings > General > About > Name can still identify this iPhone to phones that connect.",
                                  isOn: $model.rotatingIds)
                if model.rotatingIds {
                    CardDivider()
                    Button { model.startVisibleByHandle() } label: {
                        SettingsRowLabel(icon: "eye", title: "Visible by your ID for 10 to 25 minutes", chevron: false)
                    }.buttonStyle(.plain)
                    CardDivider()
                    Button { confirmPresenceReset = true } label: {
                        SettingsRowLabel(icon: "key", title: "Reset presence key", chevron: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("resetPresenceKey")
                    .accessibilityHint("Contacts stop recognising this phone nearby until your next call with each of them")
                }
            }
            if model.rotatingIds {
                CardNote("While rotating, the name in Settings > General > About > Name can still identify this iPhone to phones that connect. Use a neutral name if it is personal.")
            }
            Card {
                SettingsToggleRow(icon: "eye.slash", title: "Hidden identities",
                                  info: "Experimental. Calls use the BMH3 handshake, so a radio listener cannot read who is calling whom. Needed to call Android phones with their default settings.",
                                  isOn: $model.hiddenIdentities)
                if model.hiddenIdentities {
                    CardDivider()
                    SettingsToggleRow(icon: "theatermasks", title: "Pseudonymous toward strangers",
                                      info: "Experimental. Needs rotating discovery IDs. Strangers meet a one-time key; your real ID is shown only to someone whose call you answer or whom you call. Phones without hidden identities can then not call you.",
                                      isOn: $model.bmh3Pseudonyms)
                }
            }
            .padding(.top, 8)
            Card {
                SettingsToggleRow(icon: "exclamationmark.shield", title: "Warn instead of refusing an identity mismatch",
                                  info: "When a contact's phone shows a different identity from the one you verified, MeshLive refuses the call. With this on, it warns you instead.",
                                  isOn: Binding(get: { AppSettings.mismatchPolicyWarnOnly },
                                                set: { AppSettings.mismatchPolicyWarnOnly = $0; model.book.policy = $0 ? .warn : .refuse; model.objectWillChange.send() }))
            }
            .padding(.top, 8)
        }
        .alert("Reset presence key?", isPresented: $confirmPresenceReset) {
            Button("Reset") { model.resetPresenceKey() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Contacts who could see when you are nearby stop recognising this phone until your next call with each of them.") }
    }
}

/// Connection type (Android Connection page).
struct ConnectionView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        SettingsPage(title: "Connection") {
            Card {
                ForEach(Array(MeshTransport.allCases.enumerated()), id: \.element) { index, transport in
                    if index > 0 { CardDivider(inset: 16) }
                    Button { model.transport = transport } label: {
                        HStack {
                            Text(transport == .gatt ? "Standard (GATT)" : "Faster channel (L2CAP)").font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                            Spacer()
                            if model.transport == transport { Image(systemName: "checkmark").foregroundStyle(Palette.ink).accessibilityHidden(true) }
                        }
                        .padding(.horizontal, 16).frame(minHeight: 56).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.transport == transport ? [.isSelected] : [])
                }
            }
            CardNote("Connection type for calls and streams this phone offers. Standard works with every phone.")
        }
    }
}

/// Every experiment that has a switch on the iPhone.
struct ExperimentsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        SettingsPage(title: "Experiments") {
            Card {
                SettingsToggleRow(icon: "waveform", title: "Call audio error correction",
                                  info: "Experimental. Adds Opus in-band error correction to call audio, so a lost packet can be rebuilt from the next one.",
                                  isOn: Binding(get: { AppSettings.callAudioFec }, set: { AppSettings.callAudioFec = $0; model.objectWillChange.send() }))
                CardDivider()
                SettingsToggleRow(icon: "forward.end", title: "Relay: slow viewers skip to keyframes",
                                  info: "Used when Relay video for others is on. A phone you pass a stream to that cannot keep up skips stale video to the next keyframe and keeps the sound, instead of being dropped.",
                                  isOn: Binding(get: { AppSettings.relayChildMediaAge }, set: { AppSettings.relayChildMediaAge = $0; model.objectWillChange.send() }))
            }
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Experimental, off").font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                    Text("Standalone iPhone-to-iPhone protocol (v1, Noise). Call video fragments. Neither is used in this app; see the README register.")
                        .font(.footnote).foregroundStyle(Palette.dimInk)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 8)
        }
    }
}

/// About this app: codecs, how calls reach you, and what the iPhone cannot do.
struct AboutView: View {
    var body: some View {
        SettingsPage(title: "About this app") {
            Card {
                infoRow("Version", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
                CardDivider(inset: 16)
                infoRow("Video decode", decodeText)
                CardDivider(inset: 16)
                infoRow("Video encode", VP9Encoder.isAvailable ? "VP9, software" : "Unavailable")
                CardDivider(inset: 16)
                infoRow("Voice", CallAudio.opusAvailable ? "Opus 48 kHz" : "Unavailable")
            }
            SectionLabel("Calls")
            CardNote("Calls reach you while MeshLive is open. A call that starts ringing just as you leave the app shows an alert. A closed app cannot ring: MeshLive uses no internet push. A call keeps going if you lock the phone. While muted, hold Mute to talk.")
            SectionLabel("Not possible on iPhone")
            CardNote("Bluetooth Classic links, being found while the app is in the background, and incoming calls while the app is closed.")
        }
    }
    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.body.weight(.medium)).foregroundStyle(Palette.ink)
            Spacer(minLength: 12)
            Text(value).font(.body).foregroundStyle(Palette.dimInk).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
    private var decodeText: String {
        var parts: [String] = []
        if VideoDecoderSupport.videoToolboxVP9 { parts.append("VP9, hardware") } else if VP9Encoder.isAvailable { parts.append("VP9, software") }
        if VideoDecoderSupport.videoToolboxAV1 { parts.append("AV1, hardware") }
        return parts.isEmpty ? "Unavailable" : parts.joined(separator: "; ")
    }
}
