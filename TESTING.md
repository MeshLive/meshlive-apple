# Verification and remaining checks

Environment: macOS 26.6.2 (arm64), Xcode 27.0, iOS 27 SDK, deployment target iOS 16. Android vectors were generated with Android Studio's kotlinc and Temurin 21 from the meshlive-android tree of 2026-10-10.

## Evidence (offline)

| Check | Command | Result |
| --- | --- | --- |
| Android byte compatibility | `bash Scripts/test.sh --filter AndroidVectorTests` | Pass. Swift derives Android's exact link/endpoint keys from recorded ephemerals and verifies Android signatures in the right domain only. It reproduces Android's BMS1 stream and BME1 records byte for byte and decodes every signal, header, packet, batch, heartbeat, envelope and grant. Fingerprints, safety codes (including Android's fixed release vector), QR, announcements, route tokens and fragments all match |
| Reverse check | `NEARBY_TRANSCRIPT_OUT=... bash Scripts/test.sh --filter testSwiftTranscript`, then `java -jar android-vectors.jar verify` ([how](Interop/android-vectors/README.md)) | Pass: Android's classes verified Swift-made hellos (both domains, cross-domain rejected), BMS1, BME1, BMC2, BTV3 and audio packets |
| Compact announcement (addendum A + review) | `--filter CompactAnnouncementTests` | Pass: the 4 shared vectors and the review's extra reject/quantization cases |
| Engines | `--filter EngineTests` | Pass. Loopback over CoC byte streams and GATT chunks covers: voice/video setup, push-to-talk mute signals, fragments, rotation, keyframe requests, camera signals, decline/cancel/ring and silence timeouts, codec mismatch, wrong prefix, transport mismatch, verified-contact mismatch, stream direct/mesh, pause/end/acks, route withdrawal and video shedding |
| Handle (display only, naming design draft) | `--filter IdentityHandleTests` | Pass: the 4 draft vectors, read-aloud parsing |
| Peer labels (naming phase 1) | `--filter "LabelTextTests\|SignedLabelTests\|TitlePageTests\|AndroidLabelVectorTests\|LabelEngineTests"` | Pass. Ports of Android LabelTextTest, SignedLabelTest, TitlePageTest and handle parsing; the R11 vector; Android-signed labels verify in Swift and Swift-signed labels verify with Android's classes (`java -jar labels.jar verify`); Swift equals Android LabelText on 49 strings; engines with labels on/off/mixed |
| Discovery rows | `--filter DiscoveryTableTests` | Pass: an address change replaces the row, 8 s expiry, stable row IDs, role switch on one address |
| Capture pipeline and Android audio | `--filter "AudioCapturePipelineTests\|AndroidAudioPathTests"` | Pass: 48/44.1/16/24 kHz microphones resample to 960-sample frames with 20 ms timestamps (1 kHz tone kept); Android's BTA1/BTA2 vector bytes play in order, also when reordered before playback |
| Resolution ladder | `--filter CallResolutionLadderTests` | Port of Android CallResolutionLadderTest (WebRTC limits, rungs, holds, hysteresis, no oscillation) plus the iPhone portrait rungs |
| Rotating discovery IDs | `--filter RotatingDiscovery` | The reviewed shared vectors (salts, RDIs, lease keys, the owner's own ID, compact v2, Android version 5, BDO1), opening and selection rules, pins, the RV4 clock (backward, stuck, reboot, forward-pin recovery), tarpit, the Visible-by-handle window, and BDO1 over real call engines (open and ring, impostor and old callee refused, one-sided bit) |
| Video rate control | `--filter VideoRateControllerTests` | Pass: replays the measured GATT case (bounded backlog), recovers to the requested maximum |
| Audio playout | `--filter AudioPlayoutTests` | Pass: target buffering, PLC on gaps, late packets, Android BTA2 batches with timestamp jitter, sender restart, bounded overflow |
| Video codecs | `--filter NearbyMediaTests` | Pass. libvpx 1.15.2 encode/decode round trip with a forced keyframe at 300 kbps; libvpx decodes an ffmpeg libvpx-vp9 clip; VideoToolbox (macOS) decodes that clip with our generated `vpcC`; the AV1 sequence header and `av1C` parse from a libaom clip. AV1 VideoToolbox decode is skipped: no AV1 hardware on this Mac |
| Builds | `bash Scripts/build.sh iphoneos` / `iphonesimulator` | Pass with Opus and libvpx, no compiler warnings. The experimental v1 app also builds (`project.py --v1-experiment`) |
| Simulator | `bash Scripts/screenshots.sh` (DEBUG `-NearbyScreen`) | Home, people, watch, call, settings and verify in dark and light mode, checked by screenshot. The simulator reports no Bluetooth LE |
| Design tokens | `python3 Scripts/tokens.py --check` | Up to date with `Design/design-tokens.json` |
| v1 experiment | `bash Scripts/fixtures.sh`, `bash Scripts/interop.sh`, `bash Scripts/diagnose-video.sh` | Pass: unchanged fixture, 4 Swift↔Java v1 sessions, H.264 pattern check |

None of this shows radio, microphone, speaker, camera or battery behaviour.

## Remote device runs (iPhone 14 Plus on the Mac, Android phones on Windows)

1. **Install:** `bash Scripts/gui-run.sh install`. This builds, signs (team and bundle in `device-gui.command`), installs and launches through the logged-in GUI session; SSH sessions cannot open the login keychain. Output goes to `.build/device-logs/<stamp>-install/`.
2. **Before a run:** the iPhone must be unlocked with the screen on and Auto-Lock off; a locked phone refuses the launch. Microphone and camera permission must already be granted. `app_start` logs both, and `-NearbyRequestPermissions 1` asks once at launch.
3. **Run:** `bash Scripts/run-scenario.sh call ABCDE-FGHIJ voice 30` (iPhone calls; video works the same), or `bash Scripts/run-scenario.sh answer voice 180` (the iPhone auto-answers). It prints the BENCHMARK summary and the pulled log path. `Scripts/pull-logs.sh` copies all logs.
4. **Measured on 2026-10-10 (M31, GATT):** voice after the microphone fix: 1476/1476 and 1492/1481 packets each way. Video (before rate control): both directions decoded; iPhone -> M31 was limited to about 125-135 kbps, so the iPhone's video queued. Rerun with `VideoRateController`.

## Physical checks (when an iPhone and Android phones are available)

Use a signed build on the iPhone and the current Android build. For directions marked "flag", Android needs `test_ios_compact_discovery` (Advanced › "Experimental: find iPhones"). Record transports, models, OS versions, and each direction separately. Keep both apps in the foreground. Start with 30-60 s runs.

1. **iPhone calls Android, GATT then CoC (no flag needed).** Android: allow calls on GATT. iPhone: the Android phone appears under People nearby; place a voice call, then a video call. Check: Ringing, Accept, audio both ways; mute and hold Mute to talk change the Android "muted" indicator; video both ways with VP9; hang-up from each side. Repeat with Android on CoC. GATT voice and video from the iPhone side are measured (above).
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
- XCUITest on the iPhone: `bash Scripts/gui-run.sh uitest call <handle> voice 30` (or `uitest people`). It needs one Apple ID sign-in in Xcode Settings › Accounts, so Xcode can create the `org.nearbyintercom.ios.uitests.xctrunner` profile. On the simulator, `testPeopleList` passes.
- Passing streams and calls on from an iPhone (viewer-forwarder: advertise an offer at route cost + 1, BFG1 grant, copy envelopes).
- AV1 hardware decode on A17 Pro/M3 devices.
- Link reports with measured arrival rate for Android's rate control.
- Signing and distribution.
