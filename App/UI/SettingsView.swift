import SwiftUI
import NearbyCore
#if canImport(NearbyMedia)
import NearbyMedia
#endif

/// The same sections, in the same order, as Android: Your identity, Calls and video, Safety, then a collapsed
/// Advanced section with the technical choices and every experiment. Native inset grouped list.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var wipeText = ""
    @State private var showWipe = false
    @State private var advanced = false

    var body: some View {
        List {
            Section("Your identity") {
                Label { TextField("Your name (optional)", text: $model.displayName) } icon: { Image(systemName: "person.crop.circle").foregroundStyle(Palette.dimInk) }
                LabeledContent { Text(model.handle).font(Typo.code) } label: { Label("Your ID", systemImage: AppIcon.identity) }
                NavigationLink { VerifyView() } label: { Label("Verify a contact", systemImage: AppIcon.scan) }
            }
            Section {
                Toggle(isOn: $model.availableForCalls) { Label("Reachable for calls", systemImage: AppIcon.call) }.tint(Palette.connected)
            } header: { Text("Calls and video") } footer: { FooterText("Calls reach you while MeshLive is open. A call keeps going if you lock the phone. While muted, hold Mute to talk.") }
            Section {
                Button(role: .destructive) { showWipe = true } label: { Label("Erase now…", systemImage: AppIcon.wipe) }
            } header: { Text("Safety") } footer: {
                FooterText("Deletes your identity keys first, then verified contacts and settings. Three quick taps on the status line at the top of Home also erase. Copies on other phones and earlier backups are not affected.")
            }
            Section {
                DisclosureGroup(isExpanded: $advanced) {
                    Picker("Connection type", selection: $model.transport) {
                        ForEach(MeshTransport.allCases) { Text($0 == .gatt ? "Standard (GATT)" : "Faster channel (L2CAP)").tag($0) }
                    }
                    Toggle("Call audio error correction (experimental)", isOn: Binding(get: { AppSettings.callAudioFec }, set: { AppSettings.callAudioFec = $0 }))
                        .tint(Palette.connected)
                        .accessibilityHint("Adds Opus in-band error correction to call audio, so a lost packet can be rebuilt from the next one")
                    Toggle("Rotating discovery IDs (experimental)", isOn: $model.rotatingIds).tint(Palette.connected)
                        .accessibilityHint("Phones nearby see a new ID every 15 minutes instead of your fixed one; contacts still recognise you after connecting")
                    if model.rotatingIds {
                        Button("Visible by your ID for 10 to 25 minutes") { model.startVisibleByHandle() }
                        Text("While rotating, the name in Settings > General > About > Name can still identify this iPhone to phones that connect. Use a neutral name if it is personal.")
                            .font(Typo.caption).foregroundStyle(Palette.dimInk)
                    }
                    Toggle("Names and titles (experimental)", isOn: $model.peerLabelsEnabled).tint(Palette.connected)
                        .accessibilityHint("Sends your name, call subjects and live titles signed with your ID to phones that also turned this on")
                    Toggle("Warn instead of refusing an identity mismatch", isOn: Binding(get: { AppSettings.mismatchPolicyWarnOnly },
                        set: { AppSettings.mismatchPolicyWarnOnly = $0; model.book.policy = $0 ? .warn : .refuse })).tint(Palette.connected)
                    LabeledContent("Video decode", value: decodeText)
                    LabeledContent("Video encode", value: VP9Encoder.isAvailable ? "VP9, software" : "Unavailable")
                    LabeledContent("Voice", value: CallAudio.opusAvailable ? "Opus 48 kHz" : "Unavailable")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Experimental, off").font(Typo.rowTitle)
                        Text("Standalone iPhone-to-iPhone protocol (v1, Noise). Call video fragments. Neither is used in this app; see the README register.")
                            .font(Typo.caption).foregroundStyle(Palette.dimInk)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Not possible on iPhone").font(Typo.rowTitle)
                        Text("Bluetooth Classic links, being found while the app is in the background, and incoming calls while the app is closed.")
                            .font(Typo.caption).foregroundStyle(Palette.dimInk)
                    }
                } label: { Label("Advanced", systemImage: "gearshape.2") }
            }
        }
        .monoList()
        .navigationTitle("Settings")
        .alert("Erase everything?", isPresented: $showWipe) {
            TextField("Type WIPE", text: $wipeText)
            Button("Erase now", role: .destructive) { if wipeText == "WIPE" { model.emergencyWipe() }; wipeText = "" }
            Button("Cancel", role: .cancel) { wipeText = "" }
        } message: { Text("Type WIPE to delete this phone's identity, verified contacts and settings.") }
    }

    private var decodeText: String {
        var parts: [String] = []
        if VideoDecoderSupport.videoToolboxVP9 { parts.append("VP9, hardware") } else if VP9Encoder.isAvailable { parts.append("VP9, software") }
        if VideoDecoderSupport.videoToolboxAV1 { parts.append("AV1, hardware") }
        return parts.isEmpty ? "Unavailable" : parts.joined(separator: "; ")
    }
}
