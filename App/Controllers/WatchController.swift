import Foundation
import SwiftUI
import NearbyCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif
#if canImport(NearbyMedia)
import NearbyMedia
#endif

// MARK: - Watching (viewer: we advertise a request; the Android source connects to us)

final class WatchController: ObservableObject {
    weak var model: AppModel?
    /// The route being watched; recovery after an unexpected loss may move to another route of the same stream.
    private(set) var offer: DiscoveryAnnouncement
    let name: String
    /// "direct" / "via 2 phones".
    private(set) var route: String
    private(set) var transport: MeshTransport
    @Published var state = "Joining…"
    @Published var awaitingSource = true
    @Published var paused = false
    @Published var ended: String?
    @Published var stats = ""
    @Published var sourceFingerprint: IdentityFingerprint?
    @Published var signedTitle: String?
    /// The radio source's identity from its signed header (Android listenSourceFingerprint): Block and Report use it.
    @Published var radioSourceFingerprint: IdentityFingerprint?
    /// The source's stream header arrived: the join worked (StreamJoinRetry).
    private(set) var joined = false
    /// The user left (not a failed join).
    private(set) var stoppedByUser = false
    /// Experimental audio-only live: the selected offer is a radio stream (no video; screen-off playback).
    let isRadio: Bool
    private var routeKey: StreamRoutePenalties.Route
    private var audioInboundGuard: AudioLiveRelayInboundGuard?
    /// The verified BTL1 preset once the header arrived (1 Low data, 2 Voice, 3 Music).
    @Published var radioPreset: UInt8?
    /// Sound level of the playout, 0...1 (Android radio listener meter); 0 while muted.
    @Published private(set) var level: Double = 0
    /// Listener Mute: local playout is silent; the link and the stream stay.
    @Published private(set) var playbackMuted = false
    /// When the stream started playing here (the listener's timer).
    @Published private(set) var liveSince: Date?
    /// Warn when video freezes (Experimental): how long the picture has not changed, nil while it is fine.
    @Published private(set) var stalledMs: Int?
    /// The broadcaster resumed (the frozen-picture clock restarts) and whether it turned its camera off.
    private var resumedAtMs: Int?
    private var cameraOffNotice = false
    private var pictureFps = 15

    func togglePlaybackMute() {
        playbackMuted.toggle()
        audio?.setPlaybackMuted(playbackMuted)
        if playbackMuted { level = 0 }
    }

    private func attachMeter(_ audio: CallAudio) {
        audio.onPlaybackLevel = { [weak self] value in
            guard let self else { return }
            self.level = self.playbackMuted ? 0 : value
        }
        if playbackMuted { audio.setPlaybackMuted(true) }
    }
    let remote = RemoteVideo()
    // MARK: D1 join keys (begin): identity
    /// The identity every stream hop of this watch presents: the session's join key J when `joinKeys` is set.
    private let identity: SigningIdentity
    /// D1 (`ReleaseGates.streamJoinKeys`): this watch session's join keys, kept across rejoin, recovery and epoch
    /// boundaries and closed when the watch finishes; nil presents this device's identity, as before.
    let joinKeys: StreamJoinKeys?
    // MARK: D1 join keys (end)
    private var engine: StreamViewerEngine?
    private var driver: ConnectionDriver?
    /// AW2 (Experimental, off): this stream hop's Wi-Fi Direct guest, while the engine asked for one.
    private var wifiGuest: WifiDirectGuest?
    private var audio: CallAudio?
    private var timeout: Timer?
    private var statsTimer: Timer?

    // EXPERIMENTAL forwarding (Settings > Advanced, off by default): pass this stream on to one child.
    let forwardingEnabled: Bool
    @Published var sharing = false
    private(set) var forwardOffer: DiscoveryAnnouncement?
    private var adjacentNodeId: NodeId?
    private var core: StreamForwardingCore?
    private var forwarder: (engine: StreamForwarderEngine, driver: ConnectionDriver, row: UUID)?
    private var connectingChild: UUID?
    private var downstreamToken: UInt32 = 0
    private var health = RelayChildHealthPolicy()
    private var healthTimer: Timer?
    private var lastUpstreamKeyRequest: TimeInterval = 0
    private var childSince: TimeInterval?
    private var bytesAtChildStart: (in: UInt64, out: UInt64) = (0, 0)

    init(model: AppModel, identity: SigningIdentity, joinKeys: StreamJoinKeys? = nil, offer: DiscoveryAnnouncement, name: String, route: String, transport: MeshTransport, routeKey: StreamRoutePenalties.Route) {
        self.model = model; self.identity = identity; self.offer = offer; self.name = name; self.route = route; self.transport = transport
        self.joinKeys = joinKeys   // D1
        self.routeKey = routeKey
        isRadio = offer.isAudioOnlyOffer
        // Android effectiveForwarding: decided when the join starts; paused below 20 % unplugged or in Low Power Mode.
        forwardingEnabled = model.relayForOthers && offer.streamToken != 0 && !model.relayBatteryPaused
        if model.relayForOthers && model.relayBatteryPaused { AppLog.event("relay_battery_pause", ["event": "not_forwarding"]) }
        // DEBUG -NearbyWatchTimeout N shortens the wait for UI tests of a failed join.
        let wait = RootView.debugArgument("-NearbyWatchTimeout").flatMap(Double.init) ?? 45
        joinDeadline = ProcessInfo.processInfo.systemUptime + wait
        armJoinTimeout(after: wait)
        remote.onNeedKeyFrame = { [weak self] in self?.engine?.requestKeyFrame(); self?.driver?.pump() }
    }

    // MARK: D1 join keys (begin): session end
    /// The watch session ends: J stops signing and Ks is zeroed now, and the request leaves the air at once, not after
    /// the 2 s hand-back to the model. Called by `finish` while `recovering` still tells a lost stream (`.lost`).
    private func closeJoinKeys() {
        guard let joinKeys else { return }
        let reason = StreamJoinSessions.endReason(sourceEnded: upstreamEnded, recovering: recovering, stoppedByUser: stoppedByUser)
        if let model { model.endJoinKeys(joinKeys, reason: reason) } else { joinKeys.close() }
        model?.refreshAdvertising()
    }

    /// S3: a join-key watch ends 60 s after the stream was first lost. Track C1's lost-stream search bound
    /// (`noteSearchLoss`, below) is the one 60 s timer: it is always on for a join-key watch (the key's lifetime bound,
    /// whatever the `streamSearchBound` lab switch says) and ends the watch through `finish`, so J closes as `.lost`.
    // MARK: D1 join keys (end)

    /// When the join gives up waiting for the source (a link already in setup at that moment runs on).
    private var joinDeadline: TimeInterval = 0
    /// The current link finished its hop handshake (As Android). The viewer engine refuses a hop whose authenticated
    /// prefix is not the advertised fixed one, so this also proves the route's fixed ID ("Hide this livestream", AB3).
    private(set) var hopAuthenticated = false
    /// The radio address of the route being watched (a run-only "Hide this livestream", AB3).
    var routeAddress: String { routeKey.address }
    /// The source ended the stream (its terminal record may still be on the way to a child).
    private var upstreamEnded = false
    /// Android viewer recovery (`-viewerRecovery NO`): an active stream lost without the source's end looks for the same
    /// stream again on any route; the last picture stays.
    @Published private(set) var recovering = false
    private var rejoinTimer: Timer?
    /// The parent withdrew this route (Android `onRouteWithdrawn`): recovery applies even before the stream's header, and
    /// the model holds that route back 30 s. Cleared when recovery asks the next route.
    private(set) var routeWithdrawn = false
    /// Android relayed-child parent-link watch (5 s silence, trickle under 1/8 of the bitrate).
    private var parentWatch: RelayParentWatch?
    private var parentWatchTimer: Timer?
    /// The source authenticated on this link itself (Android `activeStreamSourceAuthenticated`), not only named by a
    /// forwarder: video Block and Report need it.
    @Published private(set) var sourceDirect = false
    /// The end-to-end source of this stream (first authentication); a recovery rejoin must reach the same one.
    private var streamSource: NodeId?
    // MARK: RV-C forwarder claims (begin)
    /// Routes this watch no longer tries: a forwarder on them named a blocked or reported source (`BlockedSourceClaim`).
    private(set) var droppedRoutes = WatchRouteExclusions()
    /// The current route was dropped for such a claim: recovery applies even before the header, as for a withdrawal.
    private var claimDropped = false
    /// The drop runs outside the engine's callback; the engine's later events on that route are ignored meanwhile.
    private var droppingRoute = false
    // MARK: RV-C forwarder claims (end)
    /// The current route for the recovery back-off.
    var recoveryRouteKey: String { ViewerRecovery.routeKey(routeKey) }
    /// Block and Report have an identity to act on: a source that authenticated itself, or a radio header's certified key.
    var canModerate: Bool { (sourceDirect && sourceFingerprint != nil) || radioSourceFingerprint != nil }

    private func armJoinTimeout(after seconds: TimeInterval) {
        timeout?.invalidate()
        timeout = Timer.scheduledTimer(withTimeInterval: max(0, seconds), repeats: false) { [weak self] _ in
            guard let self, self.awaitingSource else { return }
            #if DEBUG
            if RootView.debugArgument("-NearbyFixtureStreamLost") == "1" {
                self.searchGaveUp = true
                self.finish(StreamSearchBound.lostNotice)
                return
            }
            #endif
            self.finish("Couldn't start watching. Try again.")
        }
    }

    /// As Android: a connection that failed before its hop handshake (a stranger, a stale dial, noise) no longer
    /// ends the join: it is dropped and the viewer waits again within the same deadline. `-watchKeepWaiting NO` is the
    /// control arm.
    private func linkFinished(_ reason: String) {
        if recoveryApplies { lost(reason); return }
        let keepWaiting = AppSettings.labSwitch("watchKeepWaiting", shipped: true)
        let left = joinDeadline - ProcessInfo.processInfo.systemUptime
        if StreamJoinWait.keepWaiting(enabled: keepWaiting, hopAuthenticated: hopAuthenticated, joined: joined, stoppedByUser: stoppedByUser,
                                      ended: ended != nil, secondsLeft: left) {
            AppLog.event("watch_link", ["event": "dropped", "reason": reason, "waitLeftMs": "\(Int(left * 1000))"])
            wifiGuest?.leave(); wifiGuest = nil
            engine = nil; driver = nil; statsTimer?.invalidate(); statsTimer = nil
            awaitingSource = true
            state = "Waiting for the broadcaster…"
            armJoinTimeout(after: left)
            model?.refreshAdvertising()
            return
        }
        finish(reason)
    }

    func attach(_ link: MeshLink) {
        AppLog.event("watch_link", ["transport": link.transport.rawValue, "expected": transport.rawValue])
        guard awaitingSource, link.transport == transport else { link.close(); return }
        awaitingSource = false
        hopAuthenticated = false
        state = "Authenticating…"
        // Phase 1b item 7: the role-2 entries this listener may open are evaluated when the connection is accepted
        // (now, before any record is read): the request on air, or one that left the air less than 60 s ago.
        var openingEntries: [OpeningEntry] = []
        if let model, offer.rotating,
           RotatingStreamPolicy.viewerRequest(offer: offer, rotatingIds: model.rotatingIds, privateViewer: model.rotatingViewer) == .rotating {
            openingEntries = model.rotating.viewerRequest.acceptedEntries(elapsedMs: RotatingDiscoveryRuntime.elapsedMs)
        }
        // Signing maxChildren 1 makes the source send BMV1 envelopes this phone can pass on (exactly 1: more is BGK1).
        let engine = StreamViewerEngine(transport: transport, identity: identity, decodeMask: VideoDecoderSupport.decodeMask,
                                        expectedAdjacentPrefix: offer.nodeIdPrefix,
                                        // A recovery rejoin keeps the screen's name and title: only the source that
                                        // authenticated before the loss may continue it (any other ends this route).
                                        expectedMediaSource: recovering ? streamSource : nil,
                                        maxChildren: forwardingEnabled ? 1 : 0,
                                        labels: model?.peerLabelsEnabled ?? false,
                                        rotatingOffer: offer.rotating ? offer : nil, openingEntries: openingEntries, expectAudioOnly: isRadio,
                                        allowAudioOnly: AppSettings.audioLive,
                                        // AW2 (Experimental, off): nil keeps every byte of the hop as before. D1: never with
                                        // join keys (no build tag in a join-key stream hello; Design SI.6).
                                        wifi: joinKeys == nil && AppSettings.wifiWire && (model?.wifiCarrier == true || model?.wifiDirect == true)
                                            ? WifiCallAgent.Config(directClient: model?.wifiDirectClientPossible ?? false) : nil)
        engine.onTimeReports = AppSettings.onTimeReports
        engine.measuredReports = AppSettings.viewerLinkReports
        engine.onAccessUnitRejected = { codec, rule, nalType, bytes in
            AppLog.event("au_reject", ["codec": codec.label, "rule": "\(rule)", "type": "\(nalType)", "bytes": "\(bytes)"])
        }
        engine.onAudioLivePayload = { [weak self] bytes in
            self?.audioInboundGuard?.onBytes(bytes, now: ConnectionDriver.now)
        }
        let routeKey = self.routeKey
        engine.isParentBlocked = { [weak model = self.model] _ in
            // The route only, as Android: no node is ever penalised, even one seen over an authenticated link.
            model?.streamRoutePenalties.isPenalized(routeKey, authenticatedNode: nil, now: ConnectionDriver.now) ?? false
        }
        if offer.rotating && openingEntries.isEmpty {
            // A rotating offer answered without a role-2 opening: only a DEBUG run with rotating IDs off (its request
            // carried the fixed prefix), or a request that left the air more than 60 s ago (the source's check fails).
            AppLog.event("rotating_ids", ["event": "no_opening", "role": "viewer", "rotatingIds": "\(model?.rotatingIds ?? false)"])
        }
        engine.identityGate = model?.book
        engine.onEvent = { [weak self] in self?.handle($0) }
        engine.onWifiRequest = { [weak self] in self?.handleWifi($0) }
        engine.onWifiLog = { event, fields in AppLog.event(event, fields) }
        #if os(iOS)
        engine.wifiForeground = { UIApplication.shared.applicationState == .active }
        #endif
        self.engine = engine
        let driver = ConnectionDriver(engine: engine, link: link)
        driver.onFinished = { [weak self] reason in self?.linkFinished(reason) }
        startParentWatch()
        self.driver = driver
        driver.start()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let engine = self.engine else { return }
            if self.isRadio {
                let verified = engine.audioLiveGuard?.verifiedRecords ?? 0
                self.stats = "\(self.transport.label) · audio only · \(verified) signed records verified · \(engine.audioPackets) Opus frames"
            } else {
                self.stats = "\(self.transport.label) · \(engine.videoPackets) video / \(engine.audioPackets) audio packets · \(self.remote.decoderName)"
                self.updateFreeze()
                self.applyHeatStop()
            }
        }
    }

    /// Android ViewerFrameAge on Apple: the last decoded picture or the last resume, whichever is later; never for radio.
    private func updateFreeze() {
        guard model?.viewerFreezeWarning == true, !isRadio else { if stalledMs != nil { stalledMs = nil }; return }
        let picture = remote.sink.lastPictureAt.map { Int($0 * 1000) }
        let since = picture.map { max($0, resumedAtMs ?? 0) }
        let next = ViewerFreeze.stalledMs(nowMs: Int(ProcessInfo.processInfo.systemUptime * 1000), sinceMs: since, fps: pictureFps,
                                          quiet: paused || cameraOffNotice || ended != nil)
        if next != stalledMs { stalledMs = next }
    }

    /// Android critical heat stops watching video (audio only keeps playing). Not a failed join: no automatic retry.
    private func applyHeatStop() {
        guard !isRadio, ended == nil, model?.videoBlockedByHeat == true else { return }
        AppLog.event("watch_thermal", ["event": "stopped_critical"])
        stoppedByUser = true
        driver?.cancel()
        finish(AppModel.stoppedHotText)
    }

    private func handle(_ event: StreamViewerEngine.Event) {
        guard !droppingRoute else { return }   // RV-C: this route is being dropped
        switch event {
        case .sourceAuthenticated(let adjacent, let source, _):
            // D1 (S2): a forwarding parent may present a join key: never logged.
            AppLog.event("watch_auth", ["adjacent": adjacent == source ? adjacent.shortLabel : "hidden", "source": source.shortLabel])
        case .header(let h): pictureFps = max(1, h.fps); AppLog.event("watch_header", ["codec": "\(h.codecId)", "size": "\(h.width)x\(h.height)", "fps": "\(h.fps)", "audio": "\(h.hasAudio)"])
        case .audioLiveHeader(let h): AppLog.event("watch_header", ["kind": "audio_only", "preset": "\(h.preset)"])
        case .state(let s): AppLog.event("watch_state", ["state": "\(s)"])
        case .ended(let r, let e): AppLog.event("watch_end", ["reason": r, "error": "\(e)", "video": "\(engine?.videoPackets ?? 0)", "audio": "\(engine?.audioPackets ?? 0)", "decoded": "\(remote.decodedFrames)",
                                                       "measuredReports": "\(engine?.measuredReportsSent ?? 0)", "lastKbps": "\(engine?.lastMeasuredKbps ?? 0)",
                                                       "onTimeReports": "\(engine?.onTimeReportsSent ?? 0)"])
        case .title: AppLog.event("watch_title", ["title": "set"])
        default: break
        }
        switch event {
        case .linkAuthenticated: hopAuthenticated = true
        case .sourceAuthenticated(let adjacent, let source, let fp):
            // Call blocking (Android review 2026-10-27 finding 4): a blocked person's stream is left as soon as its
            // source is known. Only a direct (authenticated) source ends the watch and hides the offer; a forwarder's
            // bare BFG1 claim only drops its own route and the watch looks for the stream elsewhere (RV-C, as Windows
            // WP5F), so a lying forwarder can neither hide a genuine source's stream nor end a watch that went through it.
            if model?.hidesStreams(of: source) == true {
                switch BlockedSourceClaim.action(adjacent: adjacent, source: source) {
                case .leaveAndHide:
                    model?.hideStreamRoute(offer)
                    AppLog.event("call_blocking", ["event": "stream_left", "kind": isRadio ? "audio" : "video", "reason": "blocked_person"])
                    finish("You blocked the person sharing this.")
                    // Android: the viewer leaves and the Live page says why (not a black player with only Leave).
                    model?.liveNotice = LiveNotice(text: "You blocked the person sharing this.", offersRescan: false, closesWatch: true)
                case .dropRoute:
                    dropClaimedRoute()
                }
                return
            }
            adjacentNodeId = adjacent
            if streamSource == nil { streamSource = source }
            sourceDirect = adjacent == source
            // D1 (S5): only a direct source's key is remembered; a forwarder's key may be a join key (Design SI.3).
            sourceFingerprint = fp; if adjacent == source { model?.noteAuthenticated(fp) }
            state = isRadio ? "Waiting for sound…" : "Waiting for video…"
        case .header(let h):
            joined = true
            if recovering { recovered() }
            if liveSince == nil { liveSince = Date() }
            remote.configure(header: h)
            if h.hasAudio {
                let audio = CallAudio(bitrate: 24_000, route: .speaker)
                audio.playbackPath = "stream"
                attachMeter(audio)
                audio.start(capture: false); self.audio = audio
            }
            state = ""
            if forwardingEnabled { considerForwarding(header: h) }
        case .audioLiveHeader(let h):
            // The header's identity key is certified by the source over this stream: it names the source even through a
            // forwarder. A blocked or reported person's radio is left at once and its offer stays hidden.
            let source = IdentityFingerprint(publicKey: h.identitySpki)
            if model?.hidesStreams(of: source.nodeId) == true {
                model?.hideStreamRoute(offer)
                AppLog.event("call_blocking", ["event": "stream_left", "kind": "audio", "reason": "blocked_person"])
                finish("You blocked the person sharing this.")
                return
            }
            radioSourceFingerprint = source
            joined = true
            if recovering { recovered() }
            radioPreset = h.preset
            audioInboundGuard = AudioLiveRelayInboundGuard(nominalKbps: Double(AudioLive.presetKbps(h.preset)))
            if forwardingEnabled { considerForwarding(header: nil, audioPreset: h.preset) }
            let audio = CallAudio(bitrate: AudioLive.presetKbps(h.preset) * 1_000, route: .speaker)
            audio.playbackPath = "stream"
            attachMeter(audio)
            audio.start(capture: false); self.audio = audio
            if liveSince == nil { liveSince = Date() }
            state = ""
        case .audioConfig: break
        case .audio(let p): audio?.receive(presentationTimeUs: p.presentationTimeUs, opus: p.payload)
        case .video(let p): remote.decode(p)
        case .rotation(let d): remote.sink.rotation = d
        case .state(let s):
            let wasPaused = paused
            paused = s == .paused
            cameraOffNotice = s == .liveCameraOff || s == .liveMutedCameraOff
            if wasPaused && !paused { resumedAtMs = Int(ProcessInfo.processInfo.systemUptime * 1000) }
            audioInboundGuard?.onPausedChanged(paused, now: ConnectionDriver.now)
            switch s {
            case .paused: state = "Paused by broadcaster"
            case .ended: state = "The broadcast ended"; upstreamEnded = true
            case .liveMuted: state = "Muted"
            case .liveCameraOff: state = "Camera off"
            case .liveMutedCameraOff: state = "Camera off, muted"
            case .live: state = ""
            }
            // An audio-only receiver never asks for a keyframe (protocol: no type 5 on a radio stream).
            if !isRadio, s == .live || (s.isLive && wasPaused) { remote.requestKeyFrame() }
        case .envelope(let e): relay(e)
        case .title(let t): signedTitle = t
        case .routeWithdrawn:
            routeWithdrawn = true
            state = isRadio ? ViewerRecovery.listenerReconnectingText : ViewerRecovery.withdrawalNotice(routeCost: offer.routeCost)
        case .ended(let reason, _):
            if engine?.audioMarkerMismatch != nil {
                model?.penalizeStreamRoute(routeKey)
            }
            // Before the hop handshake the link's own finish decides whether the join keeps waiting.
            if hopAuthenticated || joined { if recoveryApplies { lost(reason) } else { finish(reason) } }
        }
    }

    // MARK: Recovery after an unexpected loss (Android viewer recovery)

    /// An active stream (its header arrived here) ended without the source's end record, the user's Leave, a block or the
    /// heat stop: look for it again. Control arm `-viewerRecovery NO` (the viewer ends, as before).
    private var recoveryApplies: Bool {
        ViewerRecovery.recovers(enabled: AppSettings.viewerRecovery, joined: joined, sourceEnded: upstreamEnded,
                                stoppedByUser: stoppedByUser, ended: ended != nil, routeWithdrawn: routeWithdrawn || claimDropped)
    }

    // MARK: RV-C forwarder claims (begin)
    /// A forwarder named a blocked or reported source: this route is dropped for the rest of the watch and recovery looks
    /// for the stream on any other route; with none, the lost-stream search bound ends the watch. With recovery off
    /// (`-viewerRecovery NO`) the watch ends, as before.
    private func dropClaimedRoute() {
        AppLog.event("call_blocking", ["event": "route_dropped", "kind": isRadio ? "audio" : "video", "reason": "forwarder_named_blocked_source"])
        guard AppSettings.viewerRecovery else { finish("You blocked the person sharing this."); return }
        droppedRoutes.drop(recoveryRouteKey)
        claimDropped = true
        droppingRoute = true
        // Outside the engine's own event callback: the link closes and recovery takes over.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.droppingRoute else { return }
            self.droppingRoute = false
            self.lost("A forwarder named a blocked source")
        }
    }
    // MARK: RV-C forwarder claims (end)

    /// The link of an active stream (or of a rejoin) is gone: keep the last picture, close what hangs off it and let the
    /// model look for any route of the same stream (Android's rule; decision 2026-11-06). One call per link.
    private func lost(_ reason: String) {
        guard ended == nil, engine != nil || driver != nil else { return }
        AppLog.event("viewer_recovery", ["event": recovering ? "rejoin_failed" : "lost", "reason": reason, "route": route,
                                         "transport": transport.rawValue, "withdrawn": "\(routeWithdrawn)"])
        let old = driver
        engine = nil; driver = nil
        old?.cancel()
        wifiGuest?.leave(); wifiGuest = nil
        // As finish after an upstream loss: nothing more will come for the child, so its link closes at once.
        if let f = forwarder { f.driver.cancel() }
        forwardOffer = nil; core = nil; adjacentNodeId = nil
        sourceDirect = false; sourceFingerprint = nil; radioSourceFingerprint = nil
        healthTimer?.invalidate(); healthTimer = nil
        timeout?.invalidate(); statsTimer?.invalidate(); statsTimer = nil
        parentWatchTimer?.invalidate(); parentWatchTimer = nil; parentWatch = nil
        rejoinTimer?.invalidate(); rejoinTimer = nil
        audio?.stop(); audio = nil; level = 0
        stalledMs = nil
        recovering = true; awaitingSource = false; hopAuthenticated = false
        state = isRadio ? ViewerRecovery.listenerReconnectingText
            : routeWithdrawn ? ViewerRecovery.withdrawalNotice(routeCost: offer.routeCost) : ViewerRecovery.lostText
        model?.viewerLost(self)
    }

    /// Recovery found a route of the same stream: ask it for the stream as at the start (the source or relay connects and
    /// authenticates as usual; nothing is reused). That route fails after `ViewerRecovery.rejoinTimeout` without a header.
    func rejoin(offer next: DiscoveryAnnouncement, route nextRoute: String, routeKey nextKey: StreamRoutePenalties.Route) {
        guard recovering, ended == nil, engine == nil, !awaitingSource else { return }
        // D1: recovery keeps the session's join keys; a closed session never rejoins (and never gets a fresh key).
        if let joinKeys {
            guard model?.joinSessions.resume(joinKeys) != nil else { return }
            model?.noteJoinKeysPresented(joinKeys, reason: .recovery)
        }
        offer = next; route = nextRoute; transport = next.transport ?? .gatt; routeKey = nextKey; routeWithdrawn = false
        claimDropped = false   // RV-C
        awaitingSource = true; hopAuthenticated = false
        state = isRadio ? ViewerRecovery.listenerReconnectingText : ViewerRecovery.rejoiningText
        AppLog.event("viewer_recovery", ["event": "rejoin", "route": nextRoute, "transport": transport.rawValue])
        rejoinTimer = Timer.scheduledTimer(withTimeInterval: ViewerRecovery.rejoinTimeout, repeats: false) { [weak self] _ in
            guard let self, self.recovering, self.awaitingSource, self.ended == nil else { return }
            AppLog.event("viewer_recovery", ["event": "rejoin_timeout", "route": self.route])
            self.awaitingSource = false
            self.state = self.isRadio ? ViewerRecovery.listenerReconnectingText : ViewerRecovery.lostText
            self.model?.viewerLost(self)
        }
    }

    /// The stream's header arrived again: recovery is over.
    private func recovered() {
        recovering = false
        rejoinTimer?.invalidate(); rejoinTimer = nil
        endSearch()
        AppLog.event("viewer_recovery", ["event": "recovered", "route": route])
        model?.viewerRecovered(self)
    }

    /// Android relayed-child parent-link watch: on a relayed route (cost above 0) a link that delivers nothing for 5 s, or
    /// under 1/8 of the stream's bitrate over a whole 5 s window once media started, is closed so recovery reconnects.
    /// Never while paused. Control arms `-relayParentWatch NO`, `-relayParentTrickle NO`. A direct link keeps the
    /// engine's own silence close (`StreamViewerEngine.silentTimeout`).
    private func startParentWatch() {
        parentWatchTimer?.invalidate(); parentWatchTimer = nil; parentWatch = nil
        guard offer.routeCost > 0, AppSettings.relayParentWatch else { return }
        parentWatch = RelayParentWatch(streamKbps: Int(offer.streamBitrateKbps), now: ProcessInfo.processInfo.systemUptime)
        parentWatchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tickParentWatch() }
    }

    private func tickParentWatch() {
        guard let engine, var current = parentWatch else { return }
        let armed = engine.header != nil || engine.audioLiveHeader != nil
        let verdict = current.tick(now: ProcessInfo.processInfo.systemUptime, bytes: engine.receivedBytes, paused: paused, armed: armed,
                                   trickle: AppSettings.relayParentTrickle)
        parentWatch = current
        guard verdict != .fine else { return }
        var fields = ["action": "close", "route": route, "streamKbps": "\(offer.streamBitrateKbps)"]
        if case .trickle(let kbps) = verdict { fields["reason"] = "trickle"; fields["kbps"] = "\(kbps)" } else { fields["reason"] = "silent" }
        AppLog.event("relay_parent_silence", fields)
        parentWatchTimer?.invalidate(); parentWatchTimer = nil
        driver?.cancel()
    }

    func stop() { stoppedByUser = true; driver?.cancel(); finish("Stopped watching") }

    /// AW2: the platform half of this stream hop's Wi-Fi Direct guest (the same WifiDirectGuest as calls).
    private func handleWifi(_ request: WifiCallAgent.Request) {
        switch request {
        case .join(let ssid, let passphrase, _, let ticket):
            guard let engine else { return }
            let guest = WifiDirectGuest(engine: engine, pumpBluetooth: { [weak self] in self?.driver?.pump() })
            wifiGuest = guest
            guest.join(ssid: ssid, passphrase: passphrase, ticket: ticket)
        case .connect(let host, let port, let local, _):
            wifiGuest?.connect(host: host, port: port, local: local)
        case .closeSocket:
            wifiGuest?.closeSocket()
        case .leave:
            wifiGuest?.leave(); wifiGuest = nil
        case .keyFrame:
            break   // a viewer has no encoder; the engine asks its parent for a keyframe itself
        }
        driver?.pump()
    }

    // MARK: Experimental forwarding

    /// Admission after the header (Android: skipped when the offer's bitrate is unknown), then the offer onward.
    private func considerForwarding(header: StreamHeader?, audioPreset: UInt8? = nil) {
        guard model?.sourceGate.allowsForwarding == true else { return }
        guard let model, forwardOffer == nil, let engine, engine.meshStreamId != nil, engine.mediaOpenKey != nil else {
            AppLog.event("relay_admission", ["started": "false", "reason": "no mesh stream (source sent direct records)"]); return
        }
        if isRadio, model.audioRelayMemory.blockedFor(transport, now: ConnectionDriver.now) > 0 { return }
        guard RotatingStreamPolicy.mayForward(offer: offer, rotatingIds: model.rotatingIds) else {
            AppLog.event("relay_admission", ["started": "false", "reason": "rotating offer: a fixed-prefix forwarder offer would show this phone's ID"]); return
        }
        let learned = AppSettings.relayLearned
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let decision = RelayAdmission.evaluate(learned: learned, advertisedKbps: Int(offer.streamBitrateKbps), fps: header?.fps ?? 0, nowMs: nowMs, audioPreset: audioPreset)
        AppLog.event("relay_admission", ["cold_start": "\(decision.coldStart)", "needKbps": String(format: "%.0f", decision.needKbps),
                                         "budgetKbps": String(format: "%.0f", decision.budgetKbps), "measuredKbps": String(format: "%.0f", decision.measuredKbps),
                                         "fits": "\(decision.fits)", "proven": "\(learned.provenKbps)", "ceiling": "\(learned.ceilingKbps.map(String.init) ?? "none")"])
        // D1: a join-key watch forwards as nodeId(J) (the same J toward its children).
        guard decision.fits, let own = joinKeys?.versionTwoPrefix ?? model.identityPrefix else { return }
        // AB5: a compact offer cannot carry HEVC or H.264 while owner question Q-HC2 is open, so such a stream is not offered onward.
        guard audioPreset != nil || !VideoCodecMap.isInBandParameterSetCodec(header?.codecId ?? 0) else {
            AppLog.event("relay_offer", ["skipped": "codec", "codec": VideoCodecMap.label(codecId: header?.codecId ?? 0)])
            return
        }
        downstreamToken = StreamRouteToken.downstream(upstreamRouteToken: offer.streamToken, parentPrefix: offer.nodeIdPrefix, ownPrefix: own)
        var flags = DiscoveryAnnouncement.flagStreamAvailable | DiscoveryAnnouncement.flagRelayCapable
        if transport == .gatt { flags |= DiscoveryAnnouncement.flagGattTransport }
        forwardOffer = DiscoveryAnnouncement(nodeIdPrefix: own, flags: flags, capabilitySummary: audioPreset != nil ? 0x40 : VideoCodecMap.summaryBit(codecId: header!.codecId),
                                             streamToken: downstreamToken, routeCost: min(offer.routeCost + 1, 15),
                                             streamWidth: UInt16(header?.displayWidth ?? 0), streamHeight: UInt16(header?.displayHeight ?? 0),
                                             streamFps: UInt8(header?.fps ?? 0), streamBitrateKbps: audioPreset.map { UInt16(AudioLive.presetKbps($0)) } ?? offer.streamBitrateKbps)
        // D1 (S1): the downstream token is derived from the join key's prefix: never logged.
        AppLog.event("relay_offer", ["token": joinKeys == nil ? String(format: "%08x", downstreamToken) : "hidden", "routeCost": "\(min(offer.routeCost + 1, 15))", "transport": transport.rawValue])
        if let joinKeys { model.noteJoinKeysPresented(joinKeys, reason: .watch, role: .forwarder) }   // D1
        if healthTimer == nil {
            healthTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkChildHealth() }
        }
        model.refreshAdvertising()
    }

    private func relay(_ envelope: MeshEnvelope) {
        guard forwardingEnabled else { return }
        if core == nil, let adjacent = adjacentNodeId {
            core = StreamForwardingCore(localNodeId: identity.nodeId, upstreamPeerNodeId: adjacent, streamId: envelope.streamId, sourceNodeId: envelope.sourceNodeId, audioOnly: isRadio)
        }
        guard let core else { return }
        do {
            switch try core.receive(envelope) {
            case .forward(let copy, _):
                // Relay-child media age: a slow child skips to a keyframe; its paced recovery request goes upstream.
                if forwarder?.engine.forward(copy, now: ConnectionDriver.now) == .shedWaitingForKeyFrame { requestUpstreamKeyFrame(force: true) }
                forwarder?.driver.pump()
            case .waitingForJoinKeyFrame: requestUpstreamKeyFrame()
            case .rejected: break
            }
        } catch {
            AppLog.event("relay_error", ["stage": "core", "error": "\(error)"])
        }
    }

    private func requestUpstreamKeyFrame(force: Bool = false) {
        guard !isRadio else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastUpstreamKeyRequest > 1 else { return }
        lastUpstreamKeyRequest = now
        engine?.requestKeyFrame(); driver?.pump()
    }

    /// Children advertise a viewer request carrying this phone's downstream token; connect as central.
    func viewerRequestsChanged(_ peers: [DiscoveredPeer]) {
        guard forwardOffer != nil, forwarder == nil, connectingChild == nil, ended == nil, let model, let identity = Optional(identity) else { return }
        // A rotating (compact v2) request answers a rotating offer, which this forwarder does not send: never selected.
        guard let peer = peers.first(where: { !$0.announcement.rotating && $0.announcement.isViewerRequest(routeToken: downstreamToken)
                                              && $0.announcement.transport == transport }),
              let engine, let source = engine.mediaSourceNodeId, let streamId = engine.meshStreamId, let key = engine.mediaOpenKey, engine.header != nil || engine.audioLiveHeader != nil else { return }
        if isRadio, model.audioRelayMemory.blockedFor(transport, now: ConnectionDriver.now) > 0 { return }
        connectingChild = peer.id
        AppLog.event("relay_child", ["stage": "connect", "prefix": peer.announcement.loggablePrefix(debugBuild: LabSwitch.isDebugBuild), "transport": transport.rawValue])   // D1 (S2)
        let grant = ForwardedStreamGrant(sourceNodeId: source, streamId: streamId, key: key)
        model.radio.connect(to: peer.id, transport: transport) { [weak self] result in
            guard let self else { return }
            self.connectingChild = nil
            guard case .success(let link) = result, self.ended == nil, self.forwarder == nil else {
                if case .success(let l) = result { l.close() }
                AppLog.event("relay_child", ["stage": "connect_failed"]); return
            }
            let labels = self.engine?.labelInbox.verifiedEncoded().isEmpty == false ? try? SignedLabelCodec.encodeContainer(self.engine!.labelInbox.verifiedEncoded()) : nil
            let child = StreamForwarderEngine(transport: self.transport, identity: identity, grant: grant, codecId: self.engine?.header?.codecId ?? 0,
                                              expectedChildPrefix: peer.announcement.nodeIdPrefix, labelsContainer: labels, audioOnly: self.isRadio)
            child.linkPacing = AppSettings.linkPacing; child.onTimeSeedRaise = AppSettings.onTimeSeedRaise
            child.mediaAge = AppSettings.relayChildMediaAge
            // D1: a parent never checks a child's throwaway key against its contacts (Design SI.3 parent rules).
            child.identityGate = self.joinKeys == nil ? model.book : nil
            let driver = ConnectionDriver(engine: child, link: link)
            child.onEvent = { [weak self] in self?.handleChild($0) }
            driver.onFinished = { [weak self] reason in self?.removeChild(reason) }
            self.forwarder = (child, driver, peer.id)
            self.engine?.holdEndAck = true
            driver.start()
            model.refreshAdvertising()   // presence stops while a child is connected
        }
    }

    private func handleChild(_ event: StreamForwarderEngine.Event) {
        guard let forwarder else { return }
        switch event {
        case .childAuthenticated(let id, _):
            AppLog.event("relay_child", ["stage": "authenticated", "child": "hidden"])   // D1 (S2): a child's key may be a join key
            // Call blocking (Android security review item 14): a blocked person is not sent this stream.
            if model?.isBlockedNode(id) == true {
                AppLog.event("call_blocking", ["event": "child_refused", "reason": "blocked_person"])
                forwarder.driver.cancel()
                return
            }
            do {
                for e in try core?.addChild(id) ?? [] { forwarder.engine.forward(e) }
                forwarder.driver.pump()
                requestUpstreamKeyFrame(force: true)      // a join needs a fresh keyframe
                health = RelayChildHealthPolicy(sheddingActive: forwarder.engine.mediaAge)
                childSince = ProcessInfo.processInfo.systemUptime
                bytesAtChildStart = (engine?.receivedMediaBytes ?? 0, 0)
                sharing = true
                audioInboundGuard?.onChildCount(1, now: ConnectionDriver.now)
            } catch { AppLog.event("relay_error", ["stage": "add_child", "error": "\(error)"]); forwarder.driver.cancel() }
        case .keyFrameRequested: requestUpstreamKeyFrame(force: true)
        case .endAcknowledged: engine?.releaseEndAck(); driver?.pump()
        case .routeWithdrawalAcknowledged, .report: break
        case .ended(let reason, let error): AppLog.event("relay_child", ["stage": "ended", "reason": reason, "error": "\(error)"])
        }
    }

    private func removeChild(_ reason: String) {
        guard let f = forwarder else { return }
        if let child = f.engine.endpoint?.peerNodeId { core?.removeChild(child) }
        learnFromChild(engine: f.engine, withdrawn: f.engine.isWithdrawing)
        forwarder = nil; sharing = false; childSince = nil
        audioInboundGuard?.onChildCount(0, now: ConnectionDriver.now)
        AppLog.event("relay_child", ["stage": "removed", "reason": reason, "forwarded": "\(f.engine.forwardedEnvelopes)"])
        if let engine, engine.holdEndAck { engine.holdEndAck = false; engine.releaseEndAck() }
        if ended == nil { model?.refreshAdvertising() }   // offer again
    }

    /// Withdraw a child whose link stays behind live (hop-local; it can reroute).
    private func checkChildHealth() {
        if isRadio, forwardOffer == nil, let preset = radioPreset,
           model?.audioRelayMemory.blockedFor(transport, now: ConnectionDriver.now) == 0 {
            considerForwarding(header: nil, audioPreset: preset)
        }
        guard let f = forwarder, f.engine.ready else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if isRadio {
            if audioInboundGuard?.shouldDropChild(now: now) == true {
                model?.audioRelayMemory.onDropped(transport, now: now)
                forwardOffer = nil; model?.refreshAdvertising()
                audioInboundGuard?.onChildCount(0, now: now)
                state = "Forwarding stopped to keep your sound playing"
                f.engine.withdrawRoute(); f.driver.pump()
            } else if audioInboundGuard?.childCarriedHealthily(now: now) == true {
                model?.audioRelayMemory.onHealthy(transport)
            }
            return
        }
        let backlog = f.engine.backlog(now: now)
        if health.shouldWithdraw(backlog: backlog, now: now) {
            AppLog.event("relay_withdraw", ["backlogMs": "\(Int(backlog * 1000))", "queued": "\(f.engine.queuedEnvelopes)"])
            learnFromChild(engine: f.engine, withdrawn: true)
            f.engine.withdrawRoute(); f.driver.pump()
        }
    }

    /// Proven after a clean relay of at least 10 s (two 5 s windows); a withdrawal records a ceiling.
    private func learnFromChild(engine child: StreamForwarderEngine, withdrawn: Bool) {
        guard let since = childSince, let viewer = engine else { return }
        let seconds = ProcessInfo.processInfo.systemUptime - since
        guard seconds >= 2 else { return }
        let kbps = Int(Double((viewer.receivedMediaBytes - bytesAtChildStart.in) + child.forwardedBytes) * 8 / seconds / 1000)
        var learned = AppSettings.relayLearned
        if withdrawn {
            learned.ceilingKbps = kbps; learned.ceilingMeasuredAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        } else if seconds >= 10 {
            learned.provenKbps = max(learned.provenKbps, kbps)
        } else { return }
        AppSettings.relayLearned = learned
        AppLog.event("relay_learned", ["kbps": "\(kbps)", "withdrawn": "\(withdrawn)", "proven": "\(learned.provenKbps)", "ceiling": "\(learned.ceilingKbps.map(String.init) ?? "none")"])
        childSince = nil
    }

    private func finish(_ reason: String) {
        guard ended == nil else { return }
        healthTimer?.invalidate(); forwardOffer = nil
        if let f = forwarder {
            // As Android: after an upstream loss nothing more will come, so the child link closes at once; after the
            // source ended the stream, the child first gets the forwarded terminal record (the link driver closes once it
            // drained, at most 2.5 s later). `-forwarderGracefulEnd NO` closes at once in both cases (the earlier rule).
            let graceful = upstreamEnded && AppSettings.labSwitch("forwarderGracefulEnd", shipped: true)
            if graceful { f.engine.finish("The broadcast ended", error: false); f.driver.pump() } else { f.driver.cancel() }
        }
        ended = reason; state = reason; awaitingSource = false
        closeJoinKeys()   // D1 (before `recovering` is cleared)
        timeout?.invalidate(); statsTimer?.invalidate(); rejoinTimer?.invalidate(); parentWatchTimer?.invalidate()
        searchTimer?.invalidate(); searchTimer = nil
        recovering = false
        audio?.stop(); audio = nil; remote.stop()
        wifiGuest?.leave(); wifiGuest = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.model?.watchFinished(self)
        }
    }

    // MARK: Lost-stream search bound (C1)

    /// Always bounded for a join-key watch (D1: the throwaway key must not outlive a lost stream by more than 60 s).
    private lazy var search = StreamSearchBound(enabled: { [weak self] in
        self?.joinKeys != nil || AppSettings.labSwitch("streamSearchBound", shipped: true)
    })
    private var searchTimer: Timer?
    private(set) var searchGaveUp = false

    /// A lost stream: the first loss starts a 60 s clock, a failed attempt inside the search does not restart it.
    /// Returns true when the search has ended (the watch screen closes through `watchFinished`).
    func noteSearchLoss() -> Bool {
        search.begin(now: ConnectionDriver.now)
        if searchTimer == nil, let left = search.remaining(now: ConnectionDriver.now) {
            searchTimer = Timer.scheduledTimer(withTimeInterval: left, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.searchTimer = nil
                // An attempt running at the mark ends the search through its own failure (`viewerLost`).
                // A join-key watch also ends while a rejoin attempt is running (D1: the key must not outlive the bound).
                if self.recovering && (!self.awaitingSource || self.joinKeys != nil) { self.giveUpSearch() }
            }
        }
        if search.expired(now: ConnectionDriver.now) { giveUpSearch(); return true }
        return false
    }

    private func endSearch() {
        search.end()
        searchTimer?.invalidate(); searchTimer = nil
    }

    private func giveUpSearch() {
        guard ended == nil else { return }
        AppLog.event("stream_search", ["event": "gave_up", "boundMs": "60000"])
        searchGaveUp = true
        finish(StreamSearchBound.lostNotice)
        if joinKeys != nil { driver?.cancel() }   // D1: stop a running rejoin attempt, as the removed D1 timer did
    }
}
