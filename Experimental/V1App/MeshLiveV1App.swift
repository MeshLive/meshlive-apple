import SwiftUI
import NearbyCore

@main struct MeshLiveV1App: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onChange(of: scenePhase) { phase in
                    if phase == .background { model.stop(reason: "App backgrounded", immediate: true) }
                    else if phase == .inactive { model.inactive() }
                    else { model.active() }
                }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var text = ""
    @State private var diagnostics = false
    @State private var held = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(model.state, systemImage: model.ready ? "lock.shield.fill" : "antenna.radiowaves.left.and.right")
                    Text("Keep both phones open in their apps. One hosts; the other joins. For Android testing, host on this iPhone.").font(.footnote).foregroundStyle(.secondary)
                    if !model.running {
                        Picker("Join using", selection: $model.selectedTransport) {
                            Text("LE L2CAP").tag(TransportKind.l2cap)
                            Text("BLE GATT").tag(TransportKind.gatt)
                        }
                        HStack {
                            Button("Host") { model.start(host: true) }.buttonStyle(.borderedProminent)
                            Button("Join") { model.start(host: false) }.buttonStyle(.bordered)
                        }
                    } else { Button("Stop", role: .destructive) { model.stop() } }
                }
                if !model.peers.isEmpty && !model.ready {
                    Section("Nearby hosts") {
                        ForEach(model.peers) { peer in Button { model.connect(peer) } label: { HStack { Text(peer.name); Spacer(); Text("\(peer.rssi) dBm").foregroundStyle(.secondary) } } }
                    }
                }
                if !model.verificationCode.isEmpty && !model.ready && model.running {
                    Section("Verify this session") {
                        Text(model.verificationCode).font(.system(.title, design: .monospaced)).textSelection(.enabled)
                        Text("Compare the full code in person on both phones. A matching device name does not verify identity.").font(.footnote)
                        Text("Peer fingerprint: \(model.fingerprint)").font(.caption.monospaced())
                        Button(model.confirmed ? "Waiting for peer" : "The codes match") { model.verify() }.disabled(model.confirmed)
                        Button("Reject", role: .destructive) { model.reject() }
                    }
                }
                if model.ready {
                    Section("Messages") {
                        Button("Run 30-second data check") { model.startDataCheck() }
                        if !model.diagnosticSummary.isEmpty { Text(model.diagnosticSummary).font(.caption) }
                        ForEach(model.lines) { line in
                            VStack(alignment: .leading, spacing: 4) {
                                Text((line.outgoing ? "You: " : "Peer: ") + line.text)
                                Text(line.status).font(.caption).foregroundStyle(.secondary)
                                if line.outgoing && line.status == "Submitted locally" { Button("Cancel pending message") { model.cancel(line.messageID) }.font(.caption) }
                            }
                        }
                        HStack {
                            TextField("Short message", text: $text)
                            Button("Send") { model.sendText(text); text = "" }.disabled(text.isEmpty || text.utf8.count > 4096)
                        }
                    }
                    Section("Foreground audio") {
                        Text(model.profileDescription).font(.footnote)
                        if !model.opusAvailable { Text("PCM diagnostic: high bandwidth, unverified on devices. Install pinned Opus for the intercom profile.").font(.caption).foregroundStyle(.orange) }
                        Label(model.audioStatus, systemImage: model.microphoneActive ? "mic.fill" : "mic.slash.fill").foregroundStyle(model.microphoneActive ? .red : .secondary)
                        if !model.microphoneActive { Button("Enable microphone and audio") { model.enableAudio() } }
                        else {
                            Text("The microphone stays active locally while audio is enabled. Transmission starts only while holding Talk or enabling duplex.").font(.caption)
                            Text(held ? "Transmitting…" : "Hold to talk")
                                .frame(maxWidth: .infinity, minHeight: 64)
                                .background(held ? Color.red : Color.blue, in: RoundedRectangle(cornerRadius: 14))
                                .foregroundStyle(.white).contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0).onChanged { _ in if !held { held = true; model.talk(true) } }.onEnded { _ in held = false; model.talk(false) })
                                .accessibilityLabel("Push to talk")
                                .accessibilityAction(named: "Start talking") { model.talk(true) }
                                .accessibilityAction(named: "Stop talking") { model.talk(false) }
                                .disabled(model.duplex)
                            Button("Mute and release microphone") { held = false; model.mute() }
                            Toggle("Speaker", isOn: Binding(get: { model.speaker }, set: { model.route($0) }))
                            if model.canDuplex {
                                Toggle("Duplex experiment", isOn: Binding(get: { model.duplex }, set: { model.setDuplex($0) }))
                                Text("Measure echo and each direction before treating duplex as usable.").font(.caption)
                                Toggle("Voice works on both phones", isOn: $model.voiceCheckConfirmed)
                            }
                        }
                    }
                    if model.canVideo {
                        Section("Video experiment · generated pattern") {
                            if model.videoSending { Button("Stop video") { model.stopVideo() } }
                            else { Button("Send live test pattern") { model.startVideo() } }
                            Text("160×120, 5 FPS, requested 32 kbps. Transmission pauses during local speech and waits for a new keyframe after overload.").font(.caption)
                        }
                    }
                }
                if let image = model.videoImage { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180) }
                Section { Button("Diagnostics") { diagnostics = true } }
            }
            .navigationTitle("MeshLive v1 (experimental)")
            .sheet(isPresented: $diagnostics) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(model.metricsText).font(.system(.footnote, design: .monospaced))
                            Text(model.audioMetrics.conversion).font(.footnote)
                            if !model.running {
                                Button("Check microphone and route locally") { model.enableLocalAudioCheck() }
                                if model.microphoneActive {
                                    Text(model.audioStatus).foregroundStyle(.red)
                                    Button(model.isTalking ? "Finish local loopback" : "Start local loopback") { model.talk(!model.isTalking) }
                                    Button("Release microphone") { model.mute() }
                                    Text("Local diagnostic only; no Bluetooth traffic. Use low volume or an earpiece to avoid acoustic feedback.").font(.caption)
                                }
                                Button("Run 6-second H.264 pattern check") { model.startLocalVideoCheck() }.disabled(model.localVideoRunning)
                            }
                            Text("Video: \(model.videoMetrics.effective)\nEncoded/decoded: \(model.videoMetrics.encodedFrames)/\(model.videoMetrics.decodedFrames)\nPeak access unit: \(model.videoMetrics.peakAccessUnit) B · encoded bytes: \(model.videoMetrics.encodedBytes)").font(.caption)
                            Text("Session rate: \(Int(model.audioMetrics.sessionRate)) Hz\nI/O duration: \(model.audioMetrics.ioDuration * 1000, specifier: "%.1f") ms\nRoute: \(model.audioMetrics.route)\nVoice processing: \(model.audioMetrics.voiceProcessing ? "enabled" : "off")").font(.footnote)
                            ShareLink("Export diagnostic JSON", item: model.exportDiagnostics())
                            Text("Export contains session metadata and events, without chat content, recordings, or cryptographic secrets. Bluetooth and physical voice latency require device checks.").font(.caption).foregroundStyle(.secondary)
                        }.padding().frame(maxWidth: .infinity, alignment: .leading)
                    }.navigationTitle("Diagnostics").toolbar { Button("Done") { diagnostics = false } }
                }
            }
            .alert("Attention", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
            .onChange(of: model.microphoneActive) { active in if !active { held = false } }
            .onDisappear { if held { held = false; model.talk(false) } }
        }
    }
}
