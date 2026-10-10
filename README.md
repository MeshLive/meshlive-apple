# MeshLive for iPhone

MeshLive is a Bluetooth app for private voice and video calls, going live and watching live video with phones nearby, with no internet and no servers. This is the native SwiftUI iPhone app. It speaks the same protocol as [MeshLive for Android](https://github.com/MeshLive/meshlive-android): BMH2 authentication, BMS1/BME1 AES-GCM records, BMC2 calls, BTV3 media and BMV1/BFG1 forwarded streams, over Bluetooth LE GATT and LE L2CAP CoC.

**The protocol specification is canonical in [meshlive-android/docs/PROTOCOL.md](https://github.com/MeshLive/meshlive-android/blob/main/docs/PROTOCOL.md).** [PROTOCOL.md](PROTOCOL.md) here lists the iPhone-specific parts (the compact discovery UUID and what iOS can and cannot do). Minimum iOS 16; built with Xcode 26 or later.

## Status

**Early and mostly untested on hardware.** The wire protocol is checked offline against vectors produced by the Android app's own classes, in both directions, and every engine has loopback tests. On hardware, only automated iPhone-to-Android voice and video calls over Bluetooth LE GATT have been tried, on one iPhone and one Android phone. Android calling the iPhone, live streams, LE L2CAP, the QR scanner, the emergency wipe and every experimental feature are untested on phones.

**Interoperability**

| Feature | iPhone -> Android | Android -> iPhone |
| --- | --- | --- |
| Call (voice/video; hold Mute to talk) | iPhone calls Android: tried (GATT) | Android calls iPhone: needs Android's "find iPhones" experiment |
| Watch a live stream | needs the same Android experiment on the source | needs the same experiment on the viewer |
| Identity verification (QR, safety code) | same codes on both | same codes on both |

**Impossible or restricted on iOS**

- Bluetooth Classic RFCOMM: no public API.
- Discovery while backgrounded: iOS drops the local name and moves service UUIDs to an Apple-only overflow area, so Android cannot see a backgrounded iPhone.
- Incoming calls while the app is closed: that would need internet push.
- Manufacturer data in advertisements: hence the compact UUID.
- VP9/AV1 hardware encoding: the iPhone encodes VP9 in software with libvpx.

**Not implemented yet:** relaying streams and calls (in development), store-and-forward messages, group (BGK1) relays, CallKit.

## Interface

One product on two platforms. Android's design direction (`DESIGN-DIRECTION.md` in the Android project, "Field radio") is the source for the screens, flow, features, wording and brand colours; each app renders them natively. Android uses Material 3; the iPhone follows Apple's HIG: SF fonts with Dynamic Type, inset grouped lists, iOS navigation and sheets, SF Symbols and native controls.

- **Shared tokens:** `Design/design-tokens.json` copies Android's colours, type scale and dimensions. `python3 Scripts/tokens.py` generates `App/UI/DesignTokens.swift`; `--check` fails when it is stale. The iPhone uses the brand colours on iOS semantic roles: amber is the app tint and the primary action, teal means safe or connected (never a button), red means stop, on air or danger. Text and backgrounds are iOS system colours.
- **Components:** `App/UI/Components.swift` is the one component set every screen uses: SF Symbol counterparts of Android's icons, list rows, the status line, primary/secondary/destructive buttons, notices, the empty state, the Live tag and round call controls.
- **Wording:** the same plain words as Android, with no jargon (transport, codec, relay, mesh) outside Advanced and the call's link details: "Reachable for calls", "Hold Mute to talk", "Couldn't reach ABCDE-FGHIJ - they may have moved away".

Screens (the same order and flow as Android):
- **Home:** status line ("Bluetooth on", "Visible to nearby phones"), "Your ID", Watch, Go live, and one prominent "Call someone" button at the bottom.
- **People nearby:** contacts by their saved name, everyone else by full handle.
- **Call:** always dark. One name line and a state line or timer. Encryption, route, verification and the safety code are in the info sheet behind the lock; only an identity mismatch shows loudly. There is no push-to-talk mode: while muted, press and hold Mute to talk, with a one-time hint. A short message appears only when the phone is hot or the battery is at 20 % or less.
- **Watch and Go live:** a red Live tag with a blinking dot and viewer count; the viewer screen has no broadcaster controls.
- **Settings:** Your identity, Calls and video, Safety, then Advanced (connection type, mismatch policy, codecs and experiments).

Every screen reads names through `PeerLabel`, following the naming review (R5). It shows your verified contact's saved name; otherwise a signed self-chosen name in quotes (experimental labels); otherwise the full handle. It never uses advertised device names or raw hex. The handle is Crockford Base32 of the 48-bit prefix (`M6SC7-N75YR`).

## Diagnostics and remote testing (DEBUG)

- `AppLog` writes Android-style `BENCHMARK <event>: k=v | ...` lines to the app's Documents/logs: permissions, audio session and route, discovery, connect stages, call phases, authentication and codec, call_stats every 5 s (captured/encoded/sent and received/decoded/played counts), rate changes, and the end reason. They contain no keys, text or media.
- Launch arguments (`App/Diagnostics/Automation.swift`) run a call without touching the phone: `-NearbyAutoCall <handle>`, `-NearbyCallType voice|video`, `-NearbyCallSeconds N`, `-NearbyAutoAccept voice|video` and others.
- `Scripts/gui-run.sh install` builds, signs, installs and launches through the logged-in GUI session (`Scripts/device-gui.command`), because SSH sessions cannot use the login keychain. `Scripts/run-scenario.sh call|answer` runs a scenario over SSH, and `Scripts/pull-logs.sh` copies the logs. `Scripts/screenshots.sh` takes simulator screenshots. `Scripts/gui-run.sh uitest call|people` runs the XCUITest scenarios (`UITests/`), with a screenshot at each step.

## Build

```sh
bash Scripts/prepare-opus.sh      # pinned libopus 1.6.1 -> Vendor/Opus.xcframework (ignored)
bash Scripts/prepare-libvpx.sh    # pinned libvpx 1.15.2, SHA256 26fcd3db... -> Vendor/VPX.xcframework (ignored)
python3 Scripts/project.py        # regenerate NearbyIntercom.xcodeproj (no signing data)
bash Scripts/test.sh              # swift test: core, media and v1-experiment suites
bash Scripts/build.sh iphoneos    # unsigned device build; iphonesimulator = ad-hoc signed simulator build
bash Scripts/smoke-simulator.sh   # launch in a simulator (UI only; simulators have no Bluetooth)
```

To run on a phone, open `NearbyIntercom.xcodeproj`, choose your team and a unique bundle identifier, and run the **NearbyIntercom** scheme, or use `TEAM=<team> BUNDLE=<id> bash Scripts/run-device.sh`. Physical test steps are in [TESTING.md](TESTING.md).

## Layout

| Path | Contents |
| --- | --- |
| `Sources/NearbyCore` | Android protocol: BMH2, BMS1/BME1, BMC2, BTV3, BMV1/BFG1, discovery, GATT chunks, identity verification. Also the sans-I/O `CallEngine`, `StreamViewerEngine` and `StreamSourceEngine`, audio playout and VP9/AV1 bitstream parsing |
| `Sources/NearbyMedia`, `Sources/CNearbyVPX` | libvpx VP9 encoder/decoder bridge, VideoToolbox VP9/AV1 decoding, pixel conversion |
| `App/` | SwiftUI app: `MeshRadio` (Core Bluetooth), links and driver, Opus audio, camera, identity/Keychain/wipe, screens |
| `Interop/` | reviewed discovery addendum and the Android vector generator (`android-vectors/`); `java/` is the v1 reference |
| `Experimental/` | the default-off standalone v1 app and its protocol |

## Experimental, alternative and optional behaviour

| Item | Default | Switch / reason |
| --- | --- | --- |
| Standalone v1 protocol (Noise XX, X25519/ChaChaPoly, 40-bit SAS; iPhone-to-iPhone only) | Off | `NearbyV1Experimental` library and tests, the Java reference (`Scripts/interop.sh`), and the old app via `python3 Scripts/project.py --v1-experiment`. Kept as the losing alternative; it cannot talk to Android |
| Call video fragments (Android's experiment, BME1 type 9) | Off | `CallEngine(videoFragments:)`. Only useful when the Android peer enables `test_call_video_fragments` |
| H.264 codec (addendum B) | Not built | PLAN entry pending Android review B2-B6; the iPhone uses VP9 |
| Identity mismatch policy | Refuse | Settings › "Warn instead of refusing an identity mismatch" (Android `MismatchPolicy.WARN`) |
| Names and titles (peer labels, naming phase 1) | Off | Settings › Advanced › "Names and titles (experimental)", like Android's `test_peer_labels`. BNL1 signed labels in a BLB1 container (BME1 type 10), negotiated by end-to-end hello bit 5; title pages (version 3) are read, not sent |
| Readouts at condensed width | Off | `TokenType` keeps Android's declaration for reference only; the iPhone uses Dynamic Type text styles |
| Discovery rows keyed by node prefix | On | `DiscoveryTable` (rows by prefix + kind + route token, 8 s expiry, one rediscovering retry). Replaced per-peripheral rows, which left stale duplicates when Android rotated its advertising address |
| Default call and stream video | 426x240 (portrait 240x426), 15 FPS, 200 kbps | `MediaDefaults` (user decision 2026-10-10, as Android, which also offers 360p/480p); the resolution ladder steps down from it on weak links |
| Call resolution ladder | On (user calls) | `CallResolutionLadder`: WebRTC start limits; the portrait 240x426 call steps to 180x320 below 120 kbps and back with hysteresis (keyframe restart, header unchanged). DEBUG `-NearbyResolutionLadder 0` turns it off, as Android benchmark launches |
| Call audio error correction (libopus in-band FEC) | Off | Settings › Advanced › "Call audio error correction (experimental)", Android `test_call_native_opus`: 10 % loss hint, constrained VBR, the frame before an arrived packet rebuilt with decode_fec |
| Rotating discovery IDs, phase 1 | Off | Settings › Advanced › "Rotating discovery IDs (experimental)": call-ready presence advertises compact UUID v2 with a 15-minute role-0 RDI (P in the Keychain, RV4 clock, 1-8 s boundary silence), BDO1 openings with link hello bit 3, the RV15 caller check, pins, the RV8 tarpit and "Visible by your ID for 10 to 25 minutes". iOS cannot change the device name (RV1): the setting tells the user to rename the phone |
| Video rate adaptation | On | `VideoRateController`: the encoder follows the delivered video rate, bounded by the requested bitrate. It was added after a measured GATT backlog |

## Contributing and security

See the MeshLive organisation's [contributing guide](https://github.com/MeshLive/.github/blob/main/CONTRIBUTING.md) and [security policy](https://github.com/MeshLive/.github/blob/main/SECURITY.md). Please report security problems privately as described there, not in public issues.

## License

Copyright (C) 2026 The MeshLive Authors (see [AUTHORS](AUTHORS)).

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See [LICENSE](LICENSE) for the full text.

Third-party components keep their own licences: libopus and libvpx (BSD-3-Clause; libvpx also grants the patent licence in `Vendor/LIBVPX-PATENTS`), Unicode data (Unicode License v3), and, for the default-off experimental v1 reference only, Bouncy Castle, JSON-java and noise-c. Their texts are in `Vendor/`, and [Vendor/README.md](Vendor/README.md) describes how the pinned libraries are fetched and built. The scripts download libopus and libvpx sources at build time; no third-party binaries are included.

The bundle identifier (`org.nearbyintercom.ios`) is a placeholder until the first release.
