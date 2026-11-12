# Architecture

How MeshLive for iPhone and the native Mac app are built. Wire formats are in the [protocol notes](protocol.md) and,
canonically, in the [Android protocol reference](https://github.com/MeshLive/meshlive-android/blob/main/docs/dev/protocol/README.md).
Behaviour switches are in the [switch register](switches.md).

## Where the code is

| Path | Contents |
| --- | --- |
| `Sources/NearbyCore` | Android protocol: BMH2, BMS1/BME1, BMC2, BTV3, BMV1/BFG1, discovery, GATT chunks, identity verification. Also the sans-I/O `CallEngine`, `StreamViewerEngine` and `StreamSourceEngine`, audio playout and VP9/AV1 bitstream parsing; Design HC (AB5): the codec-to-summary table (`VideoCodecMap`), Annex B framing, the HEVC/H.264 access-unit gate and packetiser (`AccessUnitGate`) and the call codec choice (`CallCodecChoice`) |
| `Sources/NearbyMedia`, `Sources/CNearbyVPX` | libvpx VP9 encoder/decoder bridge, VideoToolbox VP9/AV1/HEVC/H.264 decoding, VideoToolbox H.264/HEVC hardware encoding with a per-process setup probe judged by the access-unit gate (`VideoToolboxEncoder`, `HardwareEncoderSupport`, Experimental), pixel conversion |
| `App/` | SwiftUI app shared by iPhone and Mac: `MeshRadio` (Core Bluetooth), links and driver, Opus audio, camera, identity/Keychain/wipe, screens |
| `Desktop/` | native macOS app: app delegate and window lifecycle, camera picker, reading size, entitlements, Info.plist |
| `Desktop/Support` | Mac-only policy compiled into both the app and the `DesktopSupport` package target: Android compatibility, rotating advertising scheduler, generated names (`Names/`), delivery feedback, call scanning, connection timer, video layout, legacy Keychain cleanup |
| `Peer/` | MeshPeer, a macOS command-line test peer built from NearbyCore and the app's radio files ([Peer/README.md](../../Peer/README.md)) |
| `Tests/`, `UITests/`, `MacUITests/` | package tests (core, media, desktop policy, native transport, v1), simulator UI tests and native Mac UI tests |
| `Design/` | `design-tokens.json`, copied from Android and turned into `App/UI/DesignTokens.swift` by `Scripts/tokens.py` |
| `Scripts/` | build, codec preparation, project generation, test and device-run scripts |
| `Vendor/` | licences of the pinned third-party code (the built XCFrameworks are ignored) |
| `Interop/` | reviewed discovery addendum and the Android vector generator (`android-vectors/`); `java/` is the v1 reference |
| `Experimental/` | the default-off standalone v1 app and its protocol |

`Sources/NearbyCore` is sans-I/O: engines take bytes and time and return bytes and events, so the same code runs in
unit tests over in-memory links, in the iPhone app, in the Mac app and in MeshPeer. Only `App/Transport` touches
Core Bluetooth.

`Scripts/project.py` generates `MeshLive.xcodeproj` with two app schemes: **MeshLive-iOS** (the iPhone app, UI tests in
`MeshLive-iOS-UITests`) and **MeshLive** (the native Mac app, UI tests in `MeshLiveUITests`). Both build `MeshLive.app`
with the bundle identifier `io.github.meshlive.app`.

Some internal names keep the project's earlier working name, Nearby Intercom, on purpose:

- the Swift modules `NearbyCore`, `NearbyMedia`, `CNearbyVPX` and `NearbyV1Experimental`, and the `-Nearby...` DEBUG
  launch arguments. They are never shown to users, and renaming them would touch every import for no user benefit;
- the experimental v1 protocol labels (`NearbyIntercom/v1`, `NearbyIntercom SAS v1`), because they are hashed into
  every v1 handshake and test vector, and the v1 Java reference package (`org.nearbyintercom`) that checks them.

Stored identifiers use the app's name: the Keychain services `io.github.meshlive.app.mesh.v2` (identity, contacts
key, presence vault) and `io.github.meshlive.app.identity.v1` (the v1 experiment), the unified-log subsystem
`io.github.meshlive.app`, the queue labels and the MeshPeer bundle identifier `io.github.meshlive.app.meshpeer`.
Earlier builds stored their Keychain items under `org.nearbyintercom.*`. At launch each old item moves once: it is
copied to the new service, read back and compared, and only then deleted. Until that has worked (a locked Keychain,
an error, a crash between copy and delete) the app keeps reading the old item and tries again at the next launch, so
the identity is never lost; anything written since goes to the new service and wins. Deleting an item, the emergency
wipe and its verification cover every old and new service name.

## Platform limits and missing features

**Impossible or restricted on iOS:** Bluetooth Classic; discovery while the app is in the background (iOS hides the
advertisement); incoming calls while the app is closed (that needs internet push); manufacturer data in adverts (hence
the compact UUID); and hardware VP9/AV1 encoding (the iPhone encodes VP9 in software with libvpx).

**Not implemented yet:** store-and-forward messages, group (BGK1) relays, relay re-anchor, sending the route-recovery
hint (a source already lets a viewer that sends one in first), forwarding a stream that uses rotating IDs (stream
phase 1b forwarder; the viewer side is built, `-rotatingViewer NO` is its control arm; the source side is built,
Experimental and off, `-rotatingSource YES`), moving a call to a new link (in-call renewal), hardware video encoding and CallKit. See
[testing](testing.md#remaining-work).

## Relayed calls on Apple (Experimental)

Experimental and off ("Relayed calls"); the wire and rules are Android's (relayed calls and route searches in the
Android project's protocol reference, docs/dev/protocol/), with byte-exact vector tests. None of it has run on a phone yet.

- **Target.** With the switch on the call offer carries the consent bit and every call link hello signs bit 4. A
  relayed call (the Invite says so, or the link peer is not the call peer) rings only with the switch on, a relayed
  stranger call only with relayed stranger calls on, labelled "via a phone nearby"; every ring is capped at 60 s.
- **Caller.** Call offers and reach pages (version 4, and version 6 with rotating IDs) from this device's own scans fill
  two reach tables (`ReachTable`). A saved contact reachable only through helpers is listed "Via N phone(s) · not
  confirmed"; dialling it connects to the first helper, sends `SETUP` after the link handshake and starts the call after
  `READY` (`CallEngine` with `RelayedCallOptions`). The first hop is bound to the chosen helper unless it declared a
  throwaway (a pseudonymous relay edge); failures skip the pair and the next helper is tried (at most 3 within 60 s). A Contacts call
  to someone not listed waits up to 45 s and, with route searches on, starts a search (below).
- **Helper.** With "Help calls nearby" on and the device idle and not paused, the call offer carries the helper flag
  and the listener signs bits 4 and 6. A first record `SETUP` hands the listener's authenticated link to a
  `RelayHelperDuty` (same keys and sequences), which dials the next hop from the device's own table, regenerates
  `SETUP` downstream, answers `READY` or `FAIL` and then copies the endpoints' records without reading them.
- **The reach-page limitation.** CoreBluetooth cannot advertise manufacturer data, so an iPhone or Mac publishes no
  reach pages: callers never learn a route through an Apple helper from pages, and an Apple helper answers `SETUP` only
  for targets it hears itself or learned from Android helpers' pages.
- **Route searches (Experimental) are the Apple path.** With `-relayedOnDemand YES` (and rotating IDs and hidden
  identities) a helping listener signs BMH3 `RELAY_SEEK` and answers `SEEK` from what it scans: the target whose role-0
  ID gives the token, or for two relays a next helper with a regenerated `SEEK`, within search budgets. The Apple caller
  searches the same way for a contact that is not listed (rings 1, 1b near an epoch boundary, and 2 with a skip list;
  give-up at 45 s; the contact's own offer appearing first wins). Searches need no pages, so Apple helpers are found.
- **Admission** (`RelayHelperGate`): the rotating-helper and control-arm refusals, then switches,
  pause (Low Power Mode, heat, battery) and busy, then the SETUP rate limiter keyed by the parent's prefix, or for a
  throwaway parent by CoreBluetooth's per-peer identifier (unknown: only the overall cap); a relay that reached READY
  and satisfied the chain guard refunds its token. Searches are bounded by their own budgets.
- **Consent** is its own sub-switch ("Let phones nearby relay calls to me"): without it the offer carries no consent
  bit and a callee closes, unanswered, on the first end-to-end record from a link peer that signed the relay mark.
- **Not built:** client puzzles for searches and the automatic-retry backoff use (the memory exists).

## Store build

- **Logging rule.** `ReleaseLogPolicy` decides from `LabSwitch.isDebugBuild`. A Release build never creates
  `Documents/logs`, deletes the folder and everything in it at every launch (so logs left by an older build or restored
  from a backup are removed), writes nothing to the unified log and does not start the main-stall and lifecycle
  watchdogs. A DEBUG build keeps the file, the system-log mirror and the watchdogs, and keeps the newest 20 `.log`
  files. Export diagnostics reads typed facts only (`DiagnosticsReport`), never `AppLog`, so it is unchanged in both
  builds; Copy diagnostics in a call reads that call's in-memory counters.
- **Privacy manifest.** `App/PrivacyInfo.xcprivacy` declares no tracking and no collected data, and the three
  required-reason API categories the binary uses: System Boot Time `35F9.1` (timers and elapsed time), User Defaults
  `CA92.1` (the app's own settings and flags) and File Timestamp `C617.1` (file metadata of files in the app's own
  container, for the 7-day crash-report expiry). `Scripts/release-check.sh` checks the file in a built app.
- **Distribution.** `MeshLiveDistribution` comes from `$(MESHLIVE_DISTRIBUTION)` (empty for a source build; the archive
  command sets `appstore`). `StoreDistribution` treats only the exact value `appstore` as an App Store build; nil,
  empty, the unsubstituted build setting and any other text are a source build. About then says "Updates come from the
  App Store." instead of the GitHub sentence. DEBUG `-NearbyDistribution appstore|source` overrides it for screenshots
  and tests; a Release build ignores the argument.
- **Version and terms.** Marketing version 1.0, build 1, `IPHONEOS_DEPLOYMENT_TARGET` 17.0 (iPhone app, core and UI
  tests); `ITSAppUsesNonExemptEncryption` is NO. `StoreTerms.currentVersion` is 1 and the accepted version is stored as
  the integer `termsAcceptedVersion` in the standard defaults; Delete everything removes the defaults domain, so a wiped
  app asks again.
- **First run.** Welcome, What you can do, the terms, one permissions page and You're all set. Skip on the first two
  pages goes to the terms and never out of onboarding; the terms page has only "Agree and continue" (closing the app is
  the decline); the permissions page has one Continue that asks for Bluetooth, then the camera only in the control arm,
  then the microphone, then notifications, one system prompt at a time, and moves on after a denial. An install from
  before the terms existed sees only the terms page, once. `RootView.onboardingShows` is the one rule for the iPhone and
  the Mac roots.

## Calls and media

- **Threading:** the main thread never waits for the audio queue, the audio session or the capture session. `CallAudio`
  publishes the earpiece route (`playsOnEarpiece`) and its counters/playout (`AudioStatsSnapshot`) through `LatestValue`;
  `AudioRouteWatcher` reads `AVAudioSession` on a utility queue and publishes on main; `CallAudio.stop()` sets
  `stopRequested` at once and tears down asynchronously, and encode/playout test that flag. The camera queue is never
  `queue.sync`ed from main. DEBUG builds bracket the lock, route, interruption and protected-data tasks with
  `MainStall.run` and log `main_stall_open` / `main_stall_end` (0.75 s, 2 s, 5 s, 10 s, then every 10 s) naming the
  innermost task; only main-queue work is marked (the audio-route publish, never the notification thread). Release
  builds compile the tracer out.
- **Camera and microphone refusal:** after the system question one `CallMediaAccess.decide` runs at the single
  `CallController.accept(as:)` choke point (ring screen, notification, Mac panel and `-NearbyAutoAccept`), and at
  placement (`AppModel.finishStartCall`) and Camera on (`toggleCamera`). Only the camera refused and a video answer or a
  placed call: the existing camera-off voice answer goes on and says so. Every other refusal does not answer or place
  and names the missing camera/microphone, with Open settings when Settings can change it; a restriction never offers
  Settings. A still-undetermined camera behind "Camera on" is asked for once before the camera starts, so the peer is
  never told Camera on before the grant. The placing notice is a `CallsTab` card; the call/ring notice is a caption on
  `CallView`. The runtime camera failure message stays the fallback after a granted permission.
- **Video decoder recovery:** `VideoDecoderHealth` declares a failure only for a key frame that fails to decode, for
  three errors after a good key frame, or for an invalid session; errors before a good key frame (the decoders'
  "Waiting for a key frame") are ordinary loss and never climb the ladder. An invalid session while the app is
  backgrounded never counts: at foreground one silent rebuild runs and the first key frame resets it.
  `VideoDecoderStallDetector` calls a decoder with max(8, 2*fps) inputs and no output for 1.5 s a stall, checked from the
  1 Hz `refreshStats` and suspended while backgrounded. `VideoDecoderRecovery` rebuilds the same decoder, then tries the
  other (VP9 hardware -> libvpx), then stops video on this phone; 60 pictures forget earlier failures. A retired decoder
  is retired on its own serial queue, behind the in-flight decode (queued key frames see the retired flag), the
  replacement gets a new queue and generation, and old pictures are dropped. After the ladder stops video, a later
  stream header keeps it stopped. The new decoder asks for a key frame once; the call, audio and the other phone's state
  are untouched. The watch path has no recovery object and keeps BASE.
- **Callee label moment:** `CallLabelPolicy.calleeMoment` holds an "Everyone" callee name for a caller that also used a
  throwaway key until the caller's reveal passed the block check (`afterReveal`), when
  `CallLabelOptions.calleeNameAfterReveal` is on (the app sets it from the promoted switch; release builds always on).
  A verified contact caller still gets the name at Ringing and a real-key stranger with Accept. Only the moment the
  existing LABELS container is queued changes; no wire byte changes. A blocked caller never receives it, and a declined
  or unanswered call reveals nothing.

## Screens and design

One product on two platforms. Android's design direction (`DESIGN-DIRECTION.md` in the Android project, "Field radio") is the source for the screens, flow, features, wording and brand colours; each app renders them natively. Android uses Material 3; the iPhone follows Apple's HIG: SF fonts with Dynamic Type, inset grouped lists, iOS navigation and sheets, SF Symbols and native controls.

- **Shared tokens:** `Design/design-tokens.json` copies Android's colours, type scale and dimensions. `python3 Scripts/tokens.py` generates `App/UI/DesignTokens.swift`; `--check` fails when it is stale. The look is functional minimal dark: pure black, white text, and red reserved for live state; `Scripts/design-check.py` (run by `Scripts/test.sh`) fails on any other use of red.
- **Components:** `App/UI/Components.swift` is the one component set every screen uses: SF Symbol counterparts of Android's icons, list rows, the status line, primary/secondary/destructive buttons, notices, the empty state, the Live tag and round call controls.
- **Wording:** the same plain words as Android, with no jargon (transport, codec, relay, mesh) outside Advanced and the call's link details: "Allow calls", "Hold Mute to talk", "Couldn't reach ABCDE-FGHIJ - they may have moved away".

Screens (the same tabs and flow as Android's 2026-10-17 redesign; pure black, white text, red only for live, ending a call and Delete everything):
- **Tabs:** Live, Calls, Contacts and Settings. Each tab and each pushed page has Android's one-row title with the status indicator at its end: a dot (the connected colour when ready, white for a problem; never red) and, for a problem, one word when it fits beside the title (Bluetooth off, No Bluetooth, Permissions needed, Bluetooth problem, Calls paused while you watch / while you're live, Calls unavailable (Allow calls is on but the call service was not hosted within 5 s), Hidden, Phone hot or Mac hot; `StatusKind`, Android's order). A tap opens the Status sheet (Bluetooth, Access, Allow calls, Private Bluetooth ID, relaying, battery and heat, "Nearby you appear as", and the one fix). iPhone pages use the inline navigation bar with the indicator; the Mac draws the page title row itself and does not show the window title. Three quick taps on a tab's title ask to erase when the opt-in quick wipe is on.
- **Live:** "Live nearby" streams (the title, else "Live from <name>", and the route in words; audio-only rows have the radio disc and "Audio only") and the white "Go live" capsule with the red broadcast icon. Go live offers "Video and audio" or "Audio only" (Voice, Low data or Music) and the optional title (public to anyone who joins). Audio-only streams (experimental "radio", interoperable with Android: `0x40` offer marker, `BTL1` header, every record signed by a per-stream key certified by the source identity) keep playing and broadcasting with the screen off. Watching and broadcasting are full screen. A full stream ("Full, can't take more viewers") and one this device cannot decode ("This phone can't play it", `StreamPlayability`) are greyed and cannot be opened.
- **Broadcasting and watching:** one top bar (title, the red LIVE badge, the timer). A video live is Mute (drops the microphone's Opus units; the microphone stays open), Camera (off releases the camera and its encoder; on restarts them keyframe first), End in the middle, Flip, Pause; Mute and Camera wait while paused. Audio only opens its own screen from Go live: the first time a "Going live" warning, then title, quality (Voice, Low data, Music) and Start; on air the level meter, the status (paused, muted, listeners), Mute, End, Pause and Switch to video (ends the radio, then starts a video live with the same title). Pause sends nothing; on the iPhone the microphone stays open while paused, so iOS does not suspend a radio left running with the screen off. The reminder (`AudioLiveReminderPolicy`) asks after 30 minutes without a listener or 2 hours on the air and stops the broadcast 5 minutes after an unanswered reminder. The radio listener shows "Radio", the title, the route, a sound meter, Mute (local) and Stop, plus Block this person and Report; the video viewer has the same top bar and Leave, with Block this person and Report only when the broadcaster authenticated itself on this link; otherwise About this stream offers Hide this livestream (a local, sealed hide of that route). Ending a live while someone watches asks first. After an unexpected loss the viewer keeps the last picture and rejoins the same stream on any listed route with a per-route back-off (`ViewerRecoveryRoutes`); a relayed viewer also closes a parent link that goes silent or trickles (`RelayParentWatch`). A source dials new viewers at a bounded pace (`ViewerAdmissionGate`), and relaying pauses on a low battery or in Low Power Mode.
- **Calls:** Nearby and Recent chips. Nearby rows show a person disc, contacts by their saved name with a check mark, everyone else by their generated name or handle, and Android's two round buttons (Voice call on a dark disc, Video call on a white one); tapping the row also opens "Call <name>" with both. Touch and hold (Control-click) a Nearby row for Android's menu (Call, Add contact, Block, Report); a rotating ID heard from two phones at once is flagged (`CopiedIdTracker` in `DiscoveryTable.swift`, fed by `MeshRadio`) and its calls ask first. Nobody nearby: Search again. Recent rows read "↗ Answered / Video, 5 min ago" (`RecentCallOutcome`); a stranger's row explains how to reach them; an unreadable history offers Clear history. After a stranger's call Calls offers Add contact. The caller hears ringback (`Ringback` in `Ringer.swift`) and the iPhone pauses the outgoing camera at the ear (`CallController`).
- **Contacts:** your verified contacts with video call, voice call and info buttons, and "Add contact": Android's **Scan their code | Show my code** segments. Show my code draws a BVMID2 code that works once and for five minutes on the role-0 ID on air (`MeetController` in `App/Meet.swift`; the sans-I/O rules are `Sources/NearbyCore/Bvmid2.swift` and the verification sessions in `CallEngine`). The iPhone hides and ends the code while the screen is recorded or mirrored (`UIScreen.isCaptured`, `sceneCaptureState`) and draws a new one after a screenshot; the Mac keeps the window out of screen sharing (`NSWindow.sharingType = .none`) while the code shows. Scan their code finds the other device by the code's ID, asks "Is this <name>'s screen?", then offers "Save contact as"; the status line says who scanned whom and whether your phones now recognise each other. Contacts are sorted named first, then by ID (`ContactNames.sorted`). A row shows "Nearby now" or, while this device
cannot recognise the contact (`ContactReach`: no presence lease), "Ask them to scan your code too" or "Scan each
other's codes again"; a call to an absent contact explains the same with Show my code / Scan again / Open Nearby.
Tapping the row or info opens the contact sheet: how and when you verified them, what they call themselves (a
verified contact's last signed name from a call, kept in its sealed record, `claimedName`; a change is offered with
"Use it as my label" or "Ignore" and never applied by itself), the ID and full ID, Scan to confirm (only checked by
code), Rename (person-name rules, no name that reads like another contact's), Block or Unblock, Report (at once) and
Forget, and "Can see when I'm nearby" (rotating IDs). "Save contact as" is prefilled with your name for them or the
name they shared, never an ID.
- **Call:** always dark. The name centred with the state line or timer under it and the lock (call info) at the right; only an identity mismatch shows loudly. Android's control row: Mute, Camera, End, Flip, Speaker in five equal columns with the red End (72) in the middle and the others at 64; a control with nothing to do keeps its slot (Flip is disabled while the camera is off; on the Mac it selects the next camera, and the camera picker stays under the row). Toggled-on controls are solid white with a black glyph (muted, video off, speaker on). Speaker shows the current output (Speaker or Earpiece); on an iPhone with a headset or Bluetooth audio present it is the system audio output picker; on the Mac it is Sound on/off. While muted, press and hold Mute to talk, with a one-time hint. Calling and ringing show only Cancel; an incoming call shows Decline, Voice (Apple only, for a video call) and Accept, and Decline and block / Report for a real-key caller. A short message appears only when the phone is hot or the battery is at 20 % or less.
- **Settings:** Android's tree (2026-11-04): Your code (opens Add contact); Allow calls (the call-alert row only while alerts are not allowed), Relay video for others (Experimental, off; shown only while `ReleaseGates.sourceRoles` is on), Video quality (Fill screen with video, Show temperature, Lower quality
when hot, Experimental Warn when video freezes) and Your name with "Who sees my name" under it while a name is set; Privacy (Show names on lock screen, Triple-tap to delete everything, Block unknown callers, Blocked people, Reset private ID; names and titles, rotating IDs, hidden identities, pseudonyms and generated names always on, an identity mismatch always refused); on the Mac a Desktop card (keep running, menu bar, login, keep awake, camera, content size); Advanced (Connection with Android's transport names and what the next broadcast and the next call will send, Manual video (Manual video settings, resolution, frame rate,
bitrate, decoders), Help and feedback with Export diagnostics, and Experiments: Let older app versions find me, Relay: slow viewers skip to keyframes (only while `ReleaseGates.sourceRoles` is on) and Relayed calls, shown with or without Manual video settings, and the Mac's own experiments in DEBUG builds only); About and updates (About this app with Privacy policy, Terms of use and Open-source licences, Contact us: a mail draft to the project address); and the red Delete everything (type DELETE). Your name edits a draft that Return or leaving the page applies: an empty field clears the name, and a name the label rules reject keeps the current one. The Mac has one Settings: Cmd+, selects it in the sidebar.

Every screen reads names through `PeerLabel`, following the naming review (R5) and Android's Design G precedence: your verified contact's saved name always wins; otherwise a signed self-chosen name with the claim mark "~Name" (the call screen adds "<generated name> - not verified"); otherwise the generated name of a rotating ID or a stranger's throwaway key, title-cased ("Mild Bream"), or "Someone nearby"; otherwise the full handle. Names never come from advertised device names or raw hex, and a claimed name is never stored or put in a notification. The handle is Crockford Base32 of the 48-bit prefix (`M6SC7-N75YR`).

## The native macOS app

The **MeshLive** scheme builds a sandboxed macOS 14+ app for Apple Silicon from the shared `App/` sources plus
`Desktop/`. It shows the same Live, Calls, Contacts and Settings screens in a sidebar with a detail pane, menu
commands and keyboard shortcuts: Cmd-1 to Cmd-4 select Live, Calls, Contacts and Settings, Cmd-G opens Go live,
Cmd-comma opens Settings and Cmd-0 reopens the main window; in the call chooser Cmd-Shift-A picks Voice call and
Cmd-Shift-V picks Video call.

- **Transport:** the same CoreBluetooth central and peripheral code as the iPhone. The Mac's connection driver uses
  `DesktopConnectionTimer` in the common run-loop modes so menus, mouse tracking and modal panels cannot pause
  heartbeats.
- **Lifecycle:** discovery and media keep running when the app is deactivated (there is no iOS-style background
  path). Keep running with windows closed is optional and off by default. A menu bar item (on, can be hidden)
  shows Reachable, Not reachable, In call or Live with Open MeshLive, Reachable for calls and Quit; Start at login,
  App Nap activities and a background ring window are optional and off (see [switches](switches.md)). Quit ends
  local media and closes links;
  sleep can interrupt them.
- **Media:** Opus is built for macOS arm64 separately from the iOS XCFramework; VP9 uses
  `Vendor/VPX-macos.xcframework`. The camera picker accepts built-in and external cameras (not Continuity Camera),
  and a disconnected explicit choice never silently falls back to another camera.
- **Received video:** `DesktopVideoLayout` maps BTV3's clockwise display angle to AppKit coordinates.
- **Sandbox:** five entitlements (app sandbox, Bluetooth, camera, audio input, user-selected read-only files); no
  debugger-access entitlement in Release.
- **Preview:** the DEBUG-only `-NearbyPreview` argument runs the UI with an ephemeral identity, isolated preferences
  and no radio or media, for UI tests and screenshots. It is absent from Release builds.
- **Mac-only experiments** (delivery-based video adaptation, pausing discovery during calls) live in
  `Desktop/Support` and are off by default; Android compatibility there is a DEBUG control arm only; see the [switch register](switches.md).

## Diagnostics and remote testing (DEBUG)

- In a DEBUG build, `AppLog` writes Android-style `BENCHMARK <event>: k=v | ...` lines to the app's Documents/logs: permissions, audio session and route, discovery, connect stages, call phases, authentication and codec, call_stats every 5 s (captured/encoded/sent and received/decoded/played counts), rate changes, and the end reason. They contain no keys, text or media. A Release build keeps no log file and writes nothing to the unified log (see [Store build](#store-build)).
- Startup and the main thread: `app_start` has `processAgeMs` (time from exec to the first line on the Mac),
  `startup` the time of each startup step, and a watchdog logs `main_stall` whenever the main thread was blocked for
  more than 0.75 s. DEBUG builds also run `MainStall`: `main_stall_open` reports while the stall is still running and
  names the task, and `main_stall_end` gives the total and longest marked task. Call audio starts, restarts and stops on its own serial queue (`CallAudio`), because enabling voice
  processing alone takes about a second on a Mac and used to freeze the window each time a call became active.
  `-NearbyAudioSelfTest N` times two back-to-back audio engine runs in loopback at zero volume, without a second device.
- Launch arguments (`App/Diagnostics/Automation.swift`) run a call without touching the phone: `-NearbyAutoCall <handle>`, `-NearbyCallType voice|video`, `-NearbyCallSeconds N`, `-NearbyAutoAccept voice|video` and others.
- `Scripts/gui-run.sh install` builds, signs, installs and launches through the logged-in GUI session (`Scripts/device-gui.command`), because SSH sessions cannot use the login keychain. `Scripts/run-scenario.sh call|answer` runs a scenario over SSH, and `Scripts/pull-logs.sh` copies the logs. `Scripts/screenshots.sh` takes simulator screenshots. `Scripts/gui-run.sh uitest call|people` runs the XCUITest scenarios (`UITests/`), with a screenshot at each step.

**Export diagnostics (users).** `DiagnosticsReport` (NearbyCore) builds Android's export lines from typed facts that
`DiagnosticsExport` (App) reads: the bundle versions, `MeshLiveSourceCommit` (set by `Scripts/build.sh` and
`Scripts/build-macos.sh`), the model identifier (`hw.machine`, `hw.model`), the OS version, the Bluetooth permission
and `CBCentralManager.supports(.extendedScanAndConnect)`, the codecs and the newest crash report. Each value must match
a strict pattern or it becomes `unknown`; nothing from `AppLog`, the contacts, the history, the identity or the radio
is read. Android's documented "Diagnostics block v1" (identity short hash, `conn` lines) is not implemented on Android
yet, so neither is it here.
