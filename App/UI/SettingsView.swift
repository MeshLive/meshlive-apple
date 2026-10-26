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
                    let unnamed = model.displayName.trimmingCharacters(in: .whitespaces).isEmpty
                    SettingsLinkRow(icon: "person", title: "Your name", value: unnamed ? "Not set" : model.displayName,
                                    subtitle: unnamed ? model.ownNearbyLine : nil) { NameView() }
                    CardDivider()
                    SettingsLinkRow(icon: AppIcon.identity, title: "Your ID", value: model.handle) { VerifyView() }
                }
                Card {
                    SettingsToggleRow(icon: "phone", title: "Allow calls",
                                      info: AppPlatform.isMac ? "Nearby phones and Macs can call while MeshLive is running. Enable Keep running with windows closed to stay available without a window. Quitting stops calls." : "Phones nearby can call you while MeshLive is open. A closed app cannot ring: MeshLive uses no internet push.",
                                      isOn: $model.availableForCalls)
                    CardDivider()
                    CallAlertsRow()
                    CardDivider()
                    SettingsToggleRow(icon: "point.3.connected.trianglepath.dotted", title: "Relay live streams",
                                      info: AppPlatform.isMac ? "Experimental. While you watch or listen, this Mac can pass the stream on to one nearby device. Keep MeshLive running to accept a listener." : "Experimental. While you watch or listen, this phone can pass the stream on to one phone near you. Keep the app open to accept a listener.",
                                      isOn: $model.relayForOthers)
                    CardDivider()
                    SettingsLinkRow(icon: "lock", title: "Privacy") { PrivacyView() }
                }
                #if os(macOS)
                DesktopMediaSettings()
                DesktopLifecycleSettings()
                DesktopReadingSettings()
                #endif
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
        .mobileRootNavigation()
        .debugPush("privacy") { PrivacyView() }
        .debugPush("advanced-privacy") { AdvancedPrivacyView() }
        .debugPush("experiments") { ExperimentsView() }
        .debugPush("connection") { ConnectionView() }
        .debugPush("about") { AboutView() }
        .alert("Erase everything?", isPresented: $showWipe) {
            TextField("Type WIPE", text: $wipeText)
            Button("Erase now", role: .destructive) { if wipeText == "WIPE" { model.emergencyWipe() }; wipeText = "" }
                .disabled(wipeText != "WIPE")
            Button("Cancel", role: .cancel) { wipeText = "" }
        } message: { Text(AppPlatform.isMac ? "Type WIPE to delete this Mac's identity, verified contacts and settings." : "Type WIPE to delete this phone's identity, verified contacts and settings.") }
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
        .mobileNavigationTitle(inline: false)
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
                                  info: "Experimental. Sends your name, encrypted and signed with your ID, to the people you call or answer, and shows your live titles to phones nearby. Only phones that also turned this on see them.",
                                  isOn: $model.peerLabelsEnabled)
                CardDivider()
                SettingsToggleRow(icon: "person.crop.circle", title: "Generated nearby names",
                                  info: AppPlatform.isMac ? "Shows the same changing two-word names as Android for rotating nearby IDs. These names help pick a device; they do not verify its identity. Turn on Rotating discovery IDs in Advanced privacy for this Mac to appear by a changing name too." : "Shows the same changing two-word names as Android for rotating nearby IDs. These names help pick a phone; they do not verify its identity. Turn on Rotating discovery IDs in Advanced privacy for this iPhone to appear by a changing name too.",
                                  identifier: "desktop-generated-names", isOn: $model.desktopGeneratedNames)
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
                                  info: AppPlatform.isMac ? "Experimental. Changes your nearby Bluetooth ID every 15 minutes to make this Mac harder to recognise. This doesn't make you anonymous. Contacts you allow can still recognise you, and older app versions may not connect. On a Mac this does not hide the Mac's Bluetooth address, which macOS keeps fixed. macOS may show this Mac's name to devices that connect; use a neutral computer name if yours is personal." : "Experimental. Changes your nearby Bluetooth ID every 15 minutes to make your phone harder to recognise. This doesn't make you anonymous. Contacts you allow can still recognise you, and older app versions may not connect. The name in Settings > General > About > Name can still identify this iPhone to phones that connect.",
                                  isOn: $model.rotatingIds)
                if model.rotatingIds {
                    CardDivider()
                    Button { model.startVisibleByHandle() } label: {
                        SettingsRowLabel(icon: "eye", title: "Visible by your ID for 10 to 25 minutes", chevron: false)
                    }.buttonStyle(.plain)
                    CardDivider()
                    Button { confirmPresenceReset = true } label: {
                        SettingsRowLabel(icon: "key", title: "Reset nearby recognition", chevron: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("resetPresenceKey")
                    .accessibilityHint("Contacts stop recognising this phone nearby until your next call with each of them")
                }
            }
            if model.rotatingIds {
                CardNote(AppPlatform.isMac ? "macOS may expose this Mac's system Bluetooth name to connected devices. A neutral computer name reduces that separate identifying clue." : "While rotating, the name in Settings > General > About > Name can still identify this iPhone to phones that connect. Use a neutral name if it is personal.")
            }
            Card {
                SettingsToggleRow(icon: "eye.slash", title: "Hidden identities",
                                  info: "Experimental. Adds privacy protection when connecting to other phones, and is needed to call Android phones with their default settings. Older versions or phones with this protection turned off may not connect. Accepting a call can still let the other person recognise your phone.",
                                  isOn: $model.hiddenIdentities)
                if model.hiddenIdentities {
                    CardDivider()
                    SettingsToggleRow(icon: "theatermasks", title: "Pseudonymous toward strangers",
                                      info: "Experimental. Needs rotating discovery IDs. Uses a temporary ID with people you haven't verified. Verified contacts, and people whose calls you accept or whom you call, receive your usual ID. Both phones need compatible settings.",
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
        .alert("Reset nearby recognition?", isPresented: $confirmPresenceReset) {
            Button("Reset") { model.resetPresenceKey() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Contacts will need to reconnect with you to recognise your phone nearby again. Your saved contacts and call verification stay the same.") }
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
            CardNote(AppPlatform.isMac ? "Connection type for calls and streams this Mac offers. Standard works with every supported device." : "Connection type for calls and streams this phone offers. Standard works with every phone.")
        }
    }
}

/// Every experiment that has a switch on the iPhone.
struct ExperimentsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        SettingsPage(title: "Experiments") {
            #if os(macOS)
            Card {
                SettingsToggleRow(icon: "antenna.radiowaves.left.and.right", title: "Android compatibility",
                                  info: "Experimental. Finds Android devices that use changing nearby IDs and calls them with a one-time identity. Advanced privacy controls how this Mac appears nearby.",
                                  identifier: "desktop-android-compatibility", isOn: $model.desktopAndroidCompatibility)
                CardDivider()
                SettingsToggleRow(icon: "speedometer", title: "Adapt call video to delivery",
                                  info: "Experimental. Uses the other device's delivery reports to reduce queued video and keep calls responsive. Older devices keep the existing adaptation.",
                                  identifier: "desktop-call-delivery-feedback", isOn: $model.desktopCallDeliveryFeedback)
                CardDivider()
                SettingsToggleRow(icon: "antenna.radiowaves.left.and.right.slash", title: "Pause discovery during calls",
                                  info: "Experimental. Pauses nearby discovery once a call connects, giving Bluetooth more time for the call. Discovery resumes when the call ends.",
                                  identifier: "desktop-pause-call-discovery", isOn: $model.desktopPauseCallDiscovery)
            }
            #endif
            Card {
                SettingsToggleRow(icon: "waveform", title: "Call audio error correction",
                                  info: "Experimental. Adds Opus in-band error correction to call audio, so a lost packet can be rebuilt from the next one.",
                                  isOn: Binding(get: { AppSettings.callAudioFec }, set: { AppSettings.callAudioFec = $0; model.objectWillChange.send() }))
                CardDivider()
                SettingsToggleRow(icon: "forward.end", title: "Relay: slow viewers skip to keyframes",
                                  info: "Used when Relay live streams is on. A phone you pass a stream to that cannot keep up skips stale video to the next keyframe and keeps the sound, instead of being dropped.",
                                  isOn: Binding(get: { AppSettings.relayChildMediaAge }, set: { AppSettings.relayChildMediaAge = $0; model.objectWillChange.send() }))
            }
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Experimental, off").font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                    Text("Standalone iPhone-to-iPhone protocol (v1, Noise). Call video fragments. Neither is used in this app; see the switch register in the project's docs.")
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
                infoRow("Build", Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-")
                CardDivider(inset: 16)
                infoRow("Video decode", decodeText)
                CardDivider(inset: 16)
                infoRow("Video encode", VP9Encoder.isAvailable ? "VP9, software" : "Unavailable")
                CardDivider(inset: 16)
                infoRow("Voice", CallAudio.opusAvailable ? "Opus 48 kHz" : "Unavailable")
            }
            SectionLabel("Calls")
            CardNote(AppPlatform.isMac ? "Calls reach you while MeshLive is running. Call alerts require notification permission. Keep running with windows closed is optional; quitting stops Bluetooth and media. Sleep can interrupt connections. While muted, hold Mute to talk." : "Calls reach you while MeshLive is open. A call that starts ringing just as you leave the app shows an alert. A closed app cannot ring: MeshLive uses no internet push. A call keeps going if you lock the phone. While muted, hold Mute to talk.")
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
    private var decodeText: String {
        var parts: [String] = []
        if VideoDecoderSupport.videoToolboxVP9 { parts.append("VP9, hardware") } else if VP9Encoder.isAvailable { parts.append("VP9, software") }
        if VideoDecoderSupport.videoToolboxAV1 { parts.append("AV1, hardware") }
        return parts.isEmpty ? "Unavailable" : parts.joined(separator: "; ")
    }
}
