# Testing: verification and remaining checks

Environment: macOS 26.6.2 (arm64), Xcode 27.0, iOS 27 SDK, deployment target iOS 16. Android vectors were generated with Android Studio's kotlinc and Temurin 21 from the meshlive-android tree of 2026-10-10.

## Evidence (offline)

| Check | Command | Result |
| --- | --- | --- |
| Android byte compatibility | `bash Scripts/test.sh --filter AndroidVectorTests` | Pass. Swift derives Android's exact link/endpoint keys from recorded ephemerals and verifies Android signatures in the right domain only. It reproduces Android's BMS1 stream and BME1 records byte for byte and decodes every signal, header, packet, batch, heartbeat, envelope and grant. Fingerprints, safety codes (including Android's fixed release vector), QR, announcements, route tokens and fragments all match |
| Reverse check | `NEARBY_TRANSCRIPT_OUT=... bash Scripts/test.sh --filter testSwiftTranscript`, then `java -jar android-vectors.jar verify` ([how](../../Interop/android-vectors/README.md)) | Pass: Android's classes verified Swift-made hellos (both domains, cross-domain rejected), BMS1, BME1, BMC2, BTV3 and audio packets |
| Compact announcement (addendum A + review) | `--filter CompactAnnouncementTests` | Pass: the 4 shared vectors and the review's extra reject/quantization cases |
| Engines | `--filter EngineTests` | Pass. Loopback over CoC byte streams and GATT chunks covers: voice/video setup, push-to-talk mute signals, fragments, rotation, keyframe requests, camera signals, decline/cancel/ring and silence timeouts, codec mismatch, wrong prefix, transport mismatch, verified-contact mismatch, stream direct/mesh, pause/end/acks, route withdrawal and video shedding |
| Handle (display only, naming design draft) | `--filter IdentityHandleTests` | Pass: the 4 draft vectors, read-aloud parsing |
| Peer labels (naming phase 1) | `--filter "LabelTextTests\|SignedLabelTests\|TitlePageTests\|AndroidLabelVectorTests\|LabelEngineTests"` | Pass. Ports of Android LabelTextTest, SignedLabelTest, TitlePageTest and handle parsing; the R11 vector; Android-signed labels verify in Swift and Swift-signed labels verify with Android's classes (`java -jar labels.jar verify`); Swift equals Android LabelText on 49 strings; engines with labels on/off/mixed |
| Discovery rows | `--filter DiscoveryTableTests` | Pass: an address change replaces the row, 8 s expiry, stable row IDs, role switch on one address |
| Capture pipeline and Android audio | `--filter "AudioCapturePipelineTests\|AndroidAudioPathTests"` | Pass: 48/44.1/16/24 kHz microphones resample to 960-sample frames with 20 ms timestamps (1 kHz tone kept); Android's BTA1/BTA2 vector bytes play in order, also when reordered before playback |
| Resolution ladder | `--filter CallResolutionLadderTests` | Port of Android CallResolutionLadderTest (WebRTC limits, rungs, holds, hysteresis, no oscillation) plus the iPhone portrait rungs |
| Rotating discovery IDs | `--filter RotatingDiscovery` | The reviewed shared vectors (salts, RDIs, lease keys, the owner's own ID, compact v2, Android version 5, BDO1), opening and selection rules, pins, the RV4 clock (backward, stuck, reboot, forward-pin recovery), tarpit, the Visible-by-handle window, and BDO1 over real call engines (open and ring, impostor and old callee refused, one-sided bit) |
| Relaying (experimental) | `--filter "RelayAdmissionTests\|RelayChildHealthPolicyTests\|StreamForwardingCoreTests\|StreamForwardingLoopbackTests\|ForwarderRouteTokenTests\|CallRelayTests"` | Ports of Android RelayColdStartTest, RelayChildHealthPolicyTest, the BFG1 vector and PrivateCallRelayChainTest rules. Loopbacks: source -> iPhone relay -> child (original source authenticated, join keyframe, hop-by-hop keyframe request and end ack, withdrawal) and caller -> 1 or 2 iPhone relays -> callee (end-to-end identity, audio both ways, heartbeats replaced, hang-up, wrong child, parent wait) |
| Video rate control | `--filter VideoRateControllerTests` | Pass: replays the measured GATT case (bounded backlog), recovers to the requested maximum |
| Audio playout | `--filter AudioPlayoutTests` | Pass: target buffering, PLC on gaps, late packets, Android BTA2 batches with timestamp jitter, sender restart, bounded overflow |
| Video codecs | `--filter NearbyMediaTests` | Pass. libvpx 1.15.2 encode/decode round trip with a forced keyframe at 300 kbps; libvpx decodes an ffmpeg libvpx-vp9 clip; VideoToolbox (macOS) decodes that clip with our generated `vpcC`; the AV1 sequence header and `av1C` parse from a libaom clip. AV1 VideoToolbox decode is skipped: no AV1 hardware on this Mac |
| Builds | `bash Scripts/build.sh iphoneos` / `iphonesimulator` | Pass with Opus and libvpx, no compiler warnings. The experimental v1 app also builds (`project.py --v1-experiment`) |
| Simulator | `bash Scripts/screenshots.sh` (DEBUG `-NearbyScreen`) | Home, people, watch, call, settings and verify in dark and light mode, checked by screenshot. The simulator reports no Bluetooth LE |
| Design tokens | `python3 Scripts/tokens.py --check` | Up to date with `Design/design-tokens.json` |
| v1 experiment | `bash Scripts/fixtures.sh`, `bash Scripts/interop.sh`, `bash Scripts/diagnose-video.sh` | Pass: unchanged fixture, 4 Swift↔Java v1 sessions, H.264 pattern check |

None of this shows radio, microphone, speaker, camera or battery behaviour.

## Scripted device runs (an iPhone connected to a Mac)

1. **Install:** `bash Scripts/gui-run.sh install`. This builds, signs (team and bundle in `device-gui.command`), installs and launches through the logged-in GUI session; SSH sessions cannot open the login keychain. Output goes to `.build/device-logs/<stamp>-install/`.
2. **Before a run:** the iPhone must be unlocked with the screen on and Auto-Lock off; a locked phone refuses the launch. Microphone and camera permission must already be granted. `app_start` logs both, and `-NearbyRequestPermissions 1` asks once at launch.
3. **Run:** `bash Scripts/run-scenario.sh call ABCDE-FGHIJ voice 30` (iPhone calls; video works the same), or `bash Scripts/run-scenario.sh answer voice 180` (the iPhone auto-answers). It prints the BENCHMARK summary and the pulled log path. `Scripts/pull-logs.sh` copies all logs.
4. **Measured on 2026-10-10 (M31, GATT):** voice after the microphone fix: 1476/1476 and 1492/1481 packets each way. Video (before rate control): both directions decoded; iPhone -> M31 was limited to about 125-135 kbps, so the iPhone's video queued. Rerun with `VideoRateController`.

## Physical checks (when an iPhone and Android phones are available)

Use a signed build on the iPhone and the current Android build. For directions marked "flag", Android needs `test_ios_compact_discovery` (Advanced › "Experimental: find iPhones"). Record transports, models, OS versions, and each direction separately. Keep both apps in the foreground. Start with 30-60 s runs.

1. **iPhone calls Android, GATT then CoC (no flag needed).** Android: allow calls on GATT. iPhone: the Android phone appears under Calls > Nearby; place a voice call, then a video call. Check: Ringing, Accept, audio both ways; mute and hold Mute to talk change the Android "muted" indicator; video both ways with VP9; hang-up from each side. Repeat with Android on CoC. GATT voice and video from the iPhone side are measured (above).
2. **Android calls iPhone (flag).** The iPhone must appear in Android's call list (compact UUID). Accept as voice, then as video. Check the incoming voice offer (Invite + Camera off) and decline/busy.
3. **iPhone watches Android (flag on the source).** Android goes live. The iPhone lists it under Watch; open it. The Android source must connect to the iPhone viewer request. Check video, audio, pause/resume and end (terminal ack).
4. **Android watches iPhone (flag on the viewer).** iPhone › Go live; Android viewers connect as centrals. Check that the keyframe on join and audio play on Android.
5. **Verification.** Compare the call safety code on both screens and mark verified on both; scan each other's QR after a call; confirm the verified badge.
6. **Emergency wipe.** Triple-tap the status line on Home. Confirm the ID changes on next launch and Android shows a new (unverified) ID.
7. **Lifecycle.** Background the iPhone during a call (ends cleanly; Android sees hang-up/link loss), Bluetooth off/on, out of range.

Measure on hardware before tuning:
- the iPhone's VP9 CPU and thermal cost at 240×426/15 fps;
- VideoToolbox VP9 availability on the test iPhone's iOS version (Settings › This iPhone shows "hardware" or "software");
- GATT notification throughput from the iPhone peripheral.

## Remaining work

- **CallKit (planned):** report incoming and outgoing calls to CallKit so the system ringer, Focus, the lock screen and audio interruptions behave like a phone call. Today the in-app ringer follows the Ring/Silent switch, and an audio interruption puts the call on hold (the microphone is muted, so the peer sees it).
- **Store-and-forward messages:** not on iPhone yet. Android has an experimental store-and-forward node and auto sync; the iPhone needs the protocol (BMS1 type 11) first, after its design review.

- Physical checks above; the video rerun with rate control; Android calling the iPhone; L2CAP.
- XCUITest on the iPhone: `bash Scripts/gui-run.sh uitest call <handle> voice 30` (or `uitest people`). It needs one Apple ID sign-in in Xcode Settings › Accounts, so Xcode can create the `io.github.meshlive.app.uitests.xctrunner` profile. On the simulator, `testPeopleList` passes.
- Physical validation of stream and private-call relaying on an iPhone. Signed audio-only forwarding, unchanged envelopes, admission and overload behavior are covered offline; actual radio behavior is unverified.
- AV1 hardware decode on A17 Pro/M3 devices.
- Link reports with measured arrival rate for Android's rate control.
- Signing and distribution.

## Simulator parity (2026-10-18)

An audit of the iPhone UI against the Android layouts, English strings and screenshots found these
simulator-testable gaps: consistent video/radio row icons and inset separators; outgoing call subjects; contact
lookup through rotating IDs and its not-nearby dialog; first-run onboarding; the About build number; and
accessibility at large text sizes. Existing call setup choices, received subjects, contact verification and
privacy settings remain supported.

Live rows, immediate call choices, recognized contact calling, onboarding, the Settings build number, the typed
wipe confirmation and signed audio-only forwarding are implemented and simulator-tested. Audio-only relay
forwarding, route-local marker mismatch penalties and encrypted hop-record caps have focused engine regressions
against the existing Android rules. No QR presence-lease exchange or wire change is part of this work.

Accessibility layouts wrap or scroll at accessibility text sizes, keep VoiceOver call controls, provide 44 pt
switch targets and keep decorative glyphs inside fixed icon columns. Each onboarding page starts at the top. The
hardware-free broadcast fixture starts no microphone, camera or media engine. The focused UI check requires
complete controls to fit inside the window.

Verification: the iPhone 17 simulator build, the package tests (187 core, 6 media, 20 retained v1) and all 15
simulator UI tests passed, also at AccessibilityXXXL; the largest-text control test passed on iPhone SE (3rd
generation). The accessibility audit reported only contrast warnings for content beneath the translucent tab-bar
fade. Physical Bluetooth/media interoperability and a real VoiceOver user check remain unverified.

## Native macOS app (experimental)

### Scope and isolation

The desktop app reuses the shared screens, controllers, media path and the CoreBluetooth central/peripheral
transport (the same files as the MeshPeer test peer). NearbyCore wire and security rules are unchanged, and no
QR presence-lease exchange is included. The generated MeshLive scheme builds a native macOS 14+ sandboxed app for
Apple Silicon only (the Mac VP9 library is arm64). Local builds use ad-hoc signing with no team identity and
exactly five entitlements: app sandbox, Bluetooth, camera, audio input and user-selected read-only files. The
Release app has no debugger-access entitlement and passes strict code-signature verification.

The DEBUG-only `-NearbyPreview` argument uses an ephemeral identity and isolated preferences, keeps radio and
media off, and skips both the legacy presence-key cleanup and current Keychain reads and writes. It is never
enabled by the other automation arguments and is absent from Release builds. It is a screenshot and navigation
aid, not an interoperability test. Three behavioral tests inject a fake Keychain: preview keeps both legacy and
current items, normal startup removes only the legacy namespace, and preview rejects any deletion.

Native UI tests use preview mode, never grant or reset permissions, and keep screenshots as XCTest attachments
exported from the result bundle (`bash Scripts/run-macos-uitest.sh`). They need an unlocked desktop and the
macOS UI-testing (automation) permission. Coverage: launch and window, sidebar and menu navigation, close and
reopen, close-to-quit, first-run pages, call choices, legacy incoming subjects, Contacts fallback/cancel/Open
Nearby, radio Leave, version/build/linked codecs, each experiment switch across relaunch, and generated
nearby-name rows with call selection.

### Media, lifecycle and navigation

`Scripts/prepare-opus-macos.sh` builds pinned Opus 1.6.1 for macOS arm64 in its own build directory, leaving
the iOS XCFramework untouched. `Scripts/check-macos-media.sh` exercises the real C bridge offline with ASan/UBSan
(100 mono 48 kHz packets, 20 ms, 20 kbps CBR; frequency/power, concealment and reset checks); it does not test
audio hardware. Camera preferences accept built-in and external Mac cameras; Continuity Camera is excluded. A
disconnected explicit camera selection never silently falls back.

macOS keeps discovery and media running when the app is deactivated; it does not use the iOS background path.
Keep running with windows closed is optional and off by default. Quit ends local media and closes links. An
app-local, non-persistent `NSTreatUnknownArgumentsAsOpen` default stops automation arguments being opened as
documents. Onboarding uses desktop wording, one reason per permission, the real authorization status and
explicit request actions; restricted microphone access opens System Settings instead of asking again.

The main detail navigation path is owned by `DesktopNavigation`, so changing the sidebar section while a
Settings subpage is open no longer leaves that subpage visible; the separate Settings window has its own path. A
UI regression opens Experiments and About and leaves them through the sidebar and keyboard shortcuts.

`DesktopVideoLayout` converts BTV3's clockwise display angle to AppKit's upward-positive coordinates (the Mac
previously used UIKit's sign, which turned a quarter-turn picture the wrong way). Tests rotate asymmetric
markers at 0/90/180/270 degrees and check that resized viewports keep extent and centre without mirroring. The
iPhone renderer and wire angles are unchanged.

### Connection driver

Heartbeat scheduling: the native connection driver's repeating timer used only the default run-loop mode, so a
menu, mouse-tracking loop or modal panel could pause heartbeats while media callbacks kept running (Apple's
[run-loop mode behavior](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/RunLoopManagement/RunLoopManagement.html)).
`DesktopConnectionTimer` now runs in the common modes at the existing 100 ms interval. `DesktopConnectionTimerTests`
connects two real call engines, mutes both and runs the Mac timer in default, event-tracking and modal-panel
modes: before the change the remote endpoint timed out in both interaction modes; afterwards all modes stay
active beyond the silence deadline, unmuting restores audio and hang-up works. Heartbeat format, the 1 s interval
and the 8 s silence deadline are unchanged. The iPhone link timer now also runs in the common modes, with the
old default-mode timer kept as a control (`-NearbyDefaultModeLinkTimer 1`); the iPhone scroll stall is inferred
from the same run-loop rules and has not been measured on a phone.

Failed-link release: a `ConnectionDriver` regression over an in-memory pipe reproduced a leak where a secure
hello stayed in a transport that never drained, the engine failed, and the driver neither closed the pipe nor
told its owner. Fatal engine closure now releases the transport regardless of queued bytes; finished drivers
detach their callbacks and cannot recreate their timer; releasing a driver closes an abandoned graceful drain.
Normal closure keeps the final-record drain and 1.5 s grace. Tests cover hang-up delivery before release,
synchronous send failure with late callbacks, and owner release during a blocked drain. No wire or security
rule changes.

Diagnostics: Mac call statistics record transport backlog, time since incoming/outgoing engine bytes, the
driver's tick age and largest tick gap, timestamped local mute actions, desired and actual scan state, delivery
report counters and incoming compressed-video payload bytes. For GATT they add raw input counts, the expected
next sequence, raw-input idle time, write batches and requests entering the Core Bluetooth delegate, accepted
writes, each rejected-routing reason, notification errors and tracked link counts. `connect_details` separates
service discovery, characteristic discovery, subscription and the setup stage at a timeout. None of these
fields contain addresses, peer IDs or media content, and none change retry, heartbeat or timeout rules.

### Experiments (all off by default)

**Android compatibility** (`experimentalDesktopAndroidCompatibility`): the Mac accepts version-5 and compact-v2
offers while its own Rotating IDs setting stays off. A selected rotating call uses the existing BMH3 per-attempt
pseudonym, discovery-opening exchange and selected-offer authentication; BMH3 responder parsing is enabled, and
Advanced privacy still controls the Mac's own identity presentation. Turning off both this and Rotating IDs hides
cached rotating offers and refuses a previously selected rotating call. `bash Scripts/test.sh --filter
DesktopCallCompatibilityTests` covers both announcement formats, setup against rotating real-key and pseudonymous
responders, selected-offer impersonation rejection, audio both ways and hang-up, legacy BMH2 calls and the
privacy settings, as engine loopbacks without Bluetooth or audio hardware.

**Rotating advertising scheduler**: with the existing Rotating discovery IDs experiment on, `DesktopDiscoveryAdvertising`
rotates idle call presence only; live, viewer-request and forwarding offers are not blanked by an old call epoch.
Call-ID changes and Visible-by-ID windows use the existing 1-8 s break-before-make silence; opening pins leave the
air with the offer, and delayed callbacks cannot restore an old offer after a media-role change, quit or wipe.
`DesktopDiscoveryAdvertisingTests` runs the production scheduler with an injected clock, queue and radio sink.
Whether macOS changes its on-air Bluetooth address has not been checked.

**Generated nearby names** (`experimentalDesktopGeneratedNames`, Privacy): the Mac reads Android's frozen names-v2
lists and pair blocklist (hash-checked), derives the same words from public rotating adverts and applies the same
collision suffixes. Rows keep their own discovery identity; equal names never merge devices. An incoming caller is
named from its throwaway ID only while the call engine reports it as pseudonymous; after a reveal the
authenticated contact/ID path takes over. Calls and Settings show the Mac's current advertised name while it
advertises a rotating ID. Tests cover the published Android vectors, blocked-pair rehash, suffixes, order
independence, malformed input and edited catalogues.

**Adapt call video to delivery** (`experimentalDesktopCallDeliveryFeedback`): the Mac otherwise adapts from its
own unsent queue, which does not show how much video the peer has received. This feeds the existing video-rate
controller with peer delay and video goodput from the negotiated version-3 delivery counters, following Android's
`PeerDeliveryEstimate` (byte offsets mapped to local submission times, a rolling two-minute minimum in ten-second
buckets, a bounded twenty-second write history), with no clock synchronisation or wire change. Video is separated
from audio delivered in the same prefix. Missing, legacy, stale or impossible reports fall back to local
adaptation; relayed calls do not use it. Nine tests cover hidden backlog, audio removal, duplicates, invalid input,
counter wrap, pruned history, sparse reports and real encrypted call accounting with and without fragments.

**Pause discovery during calls** (`experimentalDesktopPauseCallDiscovery`): stops the Mac's discovery scan after the
selected call's link attaches, keeps scanning for an outgoing attempt's address-refresh retry, and restores it on
termination, failure or transport closure. Quit and wipe stop the coordinator first so late callbacks cannot
restart scanning. Streams, viewer requests, advertising and the iOS runtime are unchanged. Six coordinator tests
cover these flows.

### Reachability behind other apps

The native app has a `MenuBarExtra` (Reachable, Not reachable, In call or Live, with Open MeshLive, a Reachable
for calls switch and Quit), Start at login through `SMAppService.mainApp`, ProcessInfo activities for calls,
live streams and reachability, and a ring window for calls that ring while another app is in front. Only the
menu bar item is on by default; the other switches are off and listed in [switches](switches.md).
Incoming-call notifications use the Time Sensitive level only when the signed app carries Apple's entitlement;
ad-hoc builds keep Active.

`DesktopReachabilityTests` checks the menu state (Live wins over a call, Allow calls and Bluetooth readiness
decide Reachable), that the default settings hold no activity, the activity options for ringing, voice and
video calls, live and live audio, watching and listening and relayed calls (never `.latencyCritical`; display
sleep blocked only with video on screen), App Nap prevention without idle-sleep prevention while reachable
unless Keep Mac awake is on, the holder's begin-before-end swap and release on stop, and that the ring window
appears only when enabled, ringing and not frontmost. `DesktopLoginItemTests` uses an injected service: never
registers on its own, no repeated register/unregister calls, approval pending stays on and is reported,
failures leave the switch off with the reason.

Native UI checks with DEBUG `-NearbyPreview` (preview preferences, no radio, media, Login Items or real
calls): every reachability switch flips, persists across relaunch and is restored; the status item's menu
offers Open MeshLive (reopens a closed window), Reachable for calls (the status title follows it) and Quit;
the ring window is absent while MeshLive is frontmost, appears with Decline and Accept while Finder is
frontmost, and disappears when MeshLive returns.

Not verified: a real incoming call ringing behind another app, the notification permission prompt and Time
Sensitive delivery, Start at login across a real logout/login with the ad-hoc build (macOS may require
approval in Login Items), and whether the activities change call or reachability survival behind other apps,
during idle sleep or on battery. These need a person at the Mac and a nearby phone.

### Hardware results (Release app, Mac with Android phones over GATT)

These are short manual checks on one Mac, not a scored test suite.

- **Discovery and voice:** with Android compatibility on, the Mac listed nearby Android offers. Outgoing GATT voice
  calls to two Android phones and an incoming voice call from a phone connected, ringing about 2.3 s after setup
  began; audio packets flowed both ways with zero codec errors, muting stopped outgoing audio, and the phone was
  heard on the Mac. One other offer stalled at service discovery on both attempts (no callback before the
  timeout), so the stall is not universal and is not yet explained. Acoustic quality was not measured.
- **Generated names:** with generated names and Rotating IDs on, nearby rotating offers showed different two-word
  names, the Mac's own name changed at the 15-minute boundary, and a voice call placed from the Android phone by
  selecting that name connected and ran for about 80 s.
- **Pairing prompt:** the first GATT connection to one phone produced numeric pairing dialogs on both devices. The
  macOS Bluetooth log associates the prompt with the system's own GAP device-name read returning insufficient
  authentication, before the app's filtered service discovery; the app's characteristics use ordinary
  permissions and its CoC is published without link encryption. Core Bluetooth offers no identified control for
  that read ([connection options](https://developer.apple.com/documentation/corebluetooth/peripheral-connection-options)).
  Later connections to the paired phone did not prompt; a prompt-free first connection is not established.
- **Video calls fail** (most runs with a Samsung Galaxy S24, MeshLive 0.3.1-beta, Android 16). Video decodes both
  ways and is upright after the orientation fix, but every video call so far ended with "Call peer stopped responding" after
  between 17 s and about 5.5 min. In each failure all incoming GATT values stopped for about 8 s while the Mac's
  driver kept ticking (largest gap at most about 1.2 s) and its write queue was empty. It happened with and
  without either side muted, with the Mac camera off, with delivery adaptation on or off, and with discovery
  paused. A Bluetooth-daemon trace showed incoming indications stopping below the app while outgoing writes were
  still accepted; the disconnect was initiated locally after the timeout. In an instrumented run all 16,516 write
  requests were accepted and routed, with no rejected writes. The cause is not identified, and no timeout or
  protocol rule was changed to hide it. Received video fell from about 230-260 kbps to 35-40 kbps when the phone
  muted; that is unexplained and confounded by scene and audio changes.
- **Faster channel (LE L2CAP CoC):** the Android phone did not list the Mac's CoC offer. Android's Calls scanner
  filters offers by the effective connection type, so a matched L2CAP comparison with both sides on the faster
  channel is the next check; it passes only with an actual CoC link in the logs.

Not tested: live streams to or from the Mac, relays, sleep and wake, other Android models, and Mac-to-iPhone
calls. The native app is an experimental interoperability build, not a working video-call release.

Current package suite on macOS: 299 tests (218 core, 11 media, 20 retained v1, 46 desktop policy, 4 native
transport), plus the native Release build and the native UI tests.
