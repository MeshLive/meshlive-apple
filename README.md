# MeshLive for iPhone

**Live video and voice calls between nearby phones, over Bluetooth, with no internet. The iPhone side of MeshLive: early, and not yet tested on enough hardware.**

> **Status: early.** This app has had only a handful of automated test calls on one iPhone. It is **not on the App Store or TestFlight**, no binary is published, and you cannot install it without building it yourself on a Mac. Please do not rely on it where your safety depends on it.
>
> **Privacy warning:** like the Android app, MeshLive's Bluetooth announcements currently carry a stable node-ID prefix that lets anyone listening link a phone's changing Bluetooth addresses over time. Rotating IDs are only an untested experiment so far; see [What nearby phones can see](#what-nearby-phones-can-see).

<p align="center">
  <a href="LICENSE"><img alt="License: GPL-3.0-or-later" src="https://img.shields.io/badge/license-GPL--3.0--or--later-blue?style=for-the-badge"></a>
  <img alt="Platform: iOS 16 or newer" src="https://img.shields.io/badge/platform-iOS%2016%2B-black?style=for-the-badge&logo=apple&logoColor=white">
  <img alt="Status: early, not yet device-tested" src="https://img.shields.io/badge/status-early%20%C2%B7%20not%20yet%20device--tested-orange?style=for-the-badge">
</p>

<p align="center">
  <a href="https://github.com/MeshLive/meshlive-android">MeshLive for Android</a> ·
  <a href="https://github.com/MeshLive/meshlive-benchmarks">Benchmarks</a> ·
  <a href="https://github.com/MeshLive">MeshLive organisation</a> ·
  <a href="https://github.com/MeshLive/meshlive-ios/issues/new?template=device-report.yml">Report your iPhone</a>
</p>

MeshLive sends encrypted live camera video and microphone audio directly between nearby phones over Bluetooth, with
no account, no server and no internet. This is the native SwiftUI iPhone app. It speaks the same protocol as
[MeshLive for Android](https://github.com/MeshLive/meshlive-android): BMH2 authentication, BMS1/BME1 AES-GCM records,
BMC2 calls, BTV3 media and BMV1/BFG1 forwarded streams, over Bluetooth LE GATT and LE L2CAP CoC. An iPhone and an
Android phone running MeshLive are meant to call each other and watch each other's streams.

MeshLive is free software under the GNU GPL, version 3 or later. It is built by volunteers and has not had an
independent security review. See [Status](#status) before you rely on it.

**The protocol specification is canonical in [meshlive-android/docs/PROTOCOL.md](https://github.com/MeshLive/meshlive-android/blob/main/docs/PROTOCOL.md).** [PROTOCOL.md](PROTOCOL.md) here lists the iPhone-specific parts (the compact discovery UUID and what iOS can and cannot do). Minimum iOS 16; built with Xcode 26 or later.

- [Status](#status) | [Help wanted](#help-wanted-iphone-owners) | [Install](#install) | [Build from source](#build-from-source) |
  [What nearby phones can see](#what-nearby-phones-can-see) | [Interface](#interface) | [Layout](#layout) |
  [How this was built](#how-this-was-built) | [Contributing and security](#contributing-and-security) | [License](#license)

## Status

MeshLive for iPhone is **early and mostly untested on hardware.**

- **What is implemented** (per this repository's own tests and [TESTING.md](TESTING.md)): the Android wire protocol, checked offline against vectors produced by the Android app's own classes in both directions; private voice and video calls; watching and going live; identity verification (QR and safety code); emergency wipe; a VP9 software encoder (libvpx) and VP9/AV1 decoding; Opus audio. Every engine has loopback tests.
- **What has been tried on hardware:** automated iPhone-to-Android voice and video calls over Bluetooth LE GATT, on one iPhone and one Android phone. Voice carried packets both ways; video decoded both ways, but the iPhone's video was limited to roughly 125-135 kbps before rate control was added (see [TESTING.md](TESTING.md)).
- **What is untested on phones:** Android calling the iPhone, live streams in either direction, LE L2CAP, the QR scanner, the emergency wipe, other Android models, and every experimental feature. **Interoperability with Android is verified by byte-level test vectors, not yet on a range of real phones.**
- **No iPhone device table exists yet.** No pass or fail results are published per iPhone model, because there is not enough test data.

**Interoperability**

| Feature | iPhone -> Android | Android -> iPhone |
| --- | --- | --- |
| Call (voice/video; hold Mute to talk) | iPhone calls Android: tried (GATT) | Android calls iPhone: needs Android's "find iPhones" experiment |
| Watch a live stream | needs the same Android experiment on the source | needs the same experiment on the viewer |
| Identity verification (QR, safety code) | same codes on both | same codes on both |

**Experimental, off by default (this branch, `relay`):** passing streams and calls on to other phones (Settings › Advanced › "Help pass streams and calls to others nearby (experimental)"). Not yet tried on phones.

**Impossible or restricted on iOS**

- Bluetooth Classic RFCOMM: no public API.
- Discovery while backgrounded: iOS drops the local name and moves service UUIDs to an Apple-only overflow area, so Android cannot see a backgrounded iPhone.
- Incoming calls while the app is closed: that would need internet push.
- Manufacturer data in advertisements: hence the compact UUID.
- VP9/AV1 hardware encoding: the iPhone encodes VP9 in software with libvpx.

**Not implemented yet:** store-and-forward messages, group (BGK1) relays, relay re-anchor and parent-silence recovery, the route-recovery hint and CallKit.

## Help wanted (iPhone owners)

The most useful thing you can do is **test it on your iPhone with an Android phone running MeshLive** and tell us what happened, including when everything worked. You need a Mac with Xcode and an Apple developer team to sign the app for your own phone, because there is no prebuilt app yet.

1. Build and install it ([Build from source](#build-from-source)).
2. On the Android phone, install [MeshLive for Android](https://github.com/MeshLive/meshlive-android) and, for the directions that need it, switch on Advanced > "Experimental: find iPhones".
3. Follow the physical checks in [TESTING.md](TESTING.md) ("Physical checks"), keeping both apps in the foreground, 30-60 seconds per run.
4. Fill in the [iPhone device test report](https://github.com/MeshLive/meshlive-ios/issues/new?template=device-report.yml) (about two minutes). Failures go in the [bug form](https://github.com/MeshLive/meshlive-ios/issues/new?template=bug_report.yml).

Please do not post photos, recordings or the names of other people.

## Install

There is **no App Store, TestFlight or other binary release.** MeshLive for iPhone is not published as an app. To run it you build it yourself and sign it with your own Apple developer team; see [Build from source](#build-from-source). We will publish a build only after it has been tested on real iPhones and the results are public.

## Build from source

You need a Mac with Xcode 26 or later (the scripts call `xcodebuild`, `xcrun`, `swift` and `shasum`), Python 3, and network access for the first build, because the scripts download the pinned libopus and libvpx sources and build them into ignored `Vendor/*.xcframework` folders. No third-party binaries are included in this repository.

```sh
bash Scripts/prepare-opus.sh      # pinned libopus 1.6.1 -> Vendor/Opus.xcframework (ignored)
bash Scripts/prepare-libvpx.sh    # pinned libvpx 1.15.2, SHA256 26fcd3db... -> Vendor/VPX.xcframework (ignored)
python3 Scripts/project.py        # regenerate NearbyIntercom.xcodeproj (no signing data)
bash Scripts/test.sh              # swift test: core, media and v1-experiment suites
bash Scripts/build.sh iphoneos    # unsigned device build; iphonesimulator = ad-hoc signed simulator build
bash Scripts/smoke-simulator.sh   # launch in a simulator (UI only; simulators have no Bluetooth)
```

To run on a phone, open `NearbyIntercom.xcodeproj`, choose your team and a unique bundle identifier, and run the **NearbyIntercom** scheme, or use `TEAM=<team> BUNDLE=<id> bash Scripts/run-device.sh`. The bundle identifier is `io.github.meshlive.app`, the same as the Android app; pass `BUNDLE=<id>` only if your Apple team cannot register it. The phone must run iOS 16 or newer and have Bluetooth, Camera and Microphone allowed; for test launches it must be unlocked with the screen on. Physical test steps are in [TESTING.md](TESTING.md).

There are no screenshots in this repository yet.

## What nearby phones can see

Anyone with a Bluetooth scanner in range can read what MeshLive broadcasts. They do not need to connect or pair. The **content** of calls and streams is encrypted, but the fact that a MeshLive phone is nearby is not hidden. The iPhone has the same exposure as the Android app, with differences that come from iOS.

**What an iPhone broadcasts.** While the app is in the foreground and offering a call, a stream or a viewer request, the iPhone advertises one 128-bit compact-announcement service UUID (magic `0xC8D6`, [addendum A](Interop/ANDROID_DISCOVERY_ADDENDUM.md)). iOS apps cannot put manufacturer data in an advertisement, so the whole announcement is packed into that UUID. It contains:

- a **stable node-ID prefix** (48 bits, the first 6 bytes of the node ID derived from the phone's identity key). It does not change until the identity is wiped or reset;
- the kind of announcement (call offer, viewer request or stream offer), the Bluetooth transport it offers (LE GATT or LE CoC), whether it can relay, which video codecs it supports, and the route cost;
- for a stream offer or viewer request: a route token and a coarse resolution, frame rate and bitrate.

[PROTOCOL.md](PROTOCOL.md) also allows an optional local name of up to 8 bytes; the current code advertises only the UUID.

**Why this lets people be tracked.** The prefix is in the advertised payload and stays the same, so a scanner that records prefixes can link the iPhone's changing Bluetooth addresses to the same phone, across places and days, while the app is open and advertising. Rotating discovery IDs exist, but they are **experimental, off by default and untested on phones** (Settings > Advanced > "Rotating discovery IDs (experimental)"), and they cover only the "ready for calls" announcement. Assume the stable prefix can be used to track a phone.

**Anyone who connects learns who you are.** The signed handshake message that starts every Bluetooth connection contains the phone's public key and is not encrypted, so a connection attempt, or a sniffer watching one, reveals the identity. LE connections need no pairing, so any nearby scanner can try.

**Names.** iOS does not let an app change the phone's Bluetooth device name, so a name such as "Your Name's iPhone" may be visible to a phone that connects. Give your iPhone a neutral name (Settings > General > About > Name), especially before switching on the rotating-IDs experiment. Names and titles (signed labels) are off by default and public while enabled.

**Background.** When the app is in the background iOS removes the local name and moves service UUIDs to an Apple-only area, so Android phones cannot see the iPhone then. That is an iOS restriction, not a privacy feature. The size and timing of the encrypted data still shows that a call or stream is happening.

To reduce your exposure now: close the app or switch Bluetooth off when you do not need it, leave names and titles off, and give the phone a neutral name. The Android README's section [What nearby phones can see](https://github.com/MeshLive/meshlive-android#what-nearby-phones-can-see) covers the shared protocol-level exposure in more detail.

## Interface

One product on two platforms. Android's design direction (`DESIGN-DIRECTION.md` in the Android project, "Field radio") is the source for the screens, flow, features, wording and brand colours; each app renders them natively. Android uses Material 3; the iPhone follows Apple's HIG: SF fonts with Dynamic Type, inset grouped lists, iOS navigation and sheets, SF Symbols and native controls.

- **Shared tokens:** `Design/design-tokens.json` copies Android's colours, type scale and dimensions. `python3 Scripts/tokens.py` generates `App/UI/DesignTokens.swift`; `--check` fails when it is stale. The iPhone uses the brand colours on iOS semantic roles: amber is the app tint and the primary action, teal means safe or connected (never a button), red means stop, on air or danger. Text and backgrounds are iOS system colours.
- **Components:** `App/UI/Components.swift` is the one component set every screen uses: SF Symbol counterparts of Android's icons, list rows, the status line, primary/secondary/destructive buttons, notices, the empty state, the Live tag and round call controls.
- **Wording:** the same plain words as Android, with no jargon (transport, codec, relay, mesh) outside Advanced and the call's link details: "Allow calls", "Hold Mute to talk", "Couldn't reach ABCDE-FGHIJ - they may have moved away".

Screens (the same tabs and flow as Android's 2026-10-17 redesign; pure black, white text, red only for live, ending a call and Wipe everything):
- **Tabs:** Live, Calls, Contacts and Settings. Each tab has a large title and a status dot (green when Bluetooth is ready); three quick taps on the title ask to erase when the opt-in quick wipe is on.
- **Live:** "Live nearby" streams (the title, else "Live from <name>", and the route in words; audio-only rows have the radio disc and "Audio only") and the white "Go live" capsule with the red broadcast icon. Go live offers "Video and audio" or "Audio only" (Voice, Low data or Music) and, with names and titles on, the optional title. Audio-only streams (experimental "radio", interoperable with Android: `0x40` offer marker, `BTL1` header, every record signed by a per-stream key certified by the source identity) keep playing and broadcasting with the screen off. Watching and broadcasting are full screen.
- **Calls:** Nearby and Recent chips. Nearby rows show contacts by their saved name with a check mark, everyone else by full handle; a row opens "Call <name>" with Voice call and Video call.
- **Contacts:** your verified contacts with video call, voice call and info buttons, and "Add contact" (your code and scanning theirs). The info sheet shows how and when you verified them, the short and full ID, "Can see when I'm nearby" (rotating IDs) and Forget. Android's Rename and Block have no iPhone counterpart yet.
- **Call:** always dark. One name line and a state line or timer. Encryption, route, verification and the safety code are in the info sheet behind the lock; only an identity mismatch shows loudly. There is no push-to-talk mode: while muted, press and hold Mute to talk, with a one-time hint. A short message appears only when the phone is hot or the battery is at 20 % or less.
- **Settings:** grouped cards: Your name and Your ID; Allow calls, Call alerts, Relay video for others and Privacy (quick wipe, names and titles, then Advanced privacy: rotating IDs, hidden identities, pseudonyms, mismatch policy); Advanced (Connection, Experiments); About this app; and the red Wipe everything (type WIPE to confirm).

Every screen reads names through `PeerLabel`, following the naming review (R5). It shows your verified contact's saved name; otherwise a signed self-chosen name in quotes (experimental labels); otherwise the full handle. It never uses advertised device names or raw hex. The handle is Crockford Base32 of the 48-bit prefix (`M6SC7-N75YR`).

## Diagnostics and remote testing (DEBUG)

- `AppLog` writes Android-style `BENCHMARK <event>: k=v | ...` lines to the app's Documents/logs: permissions, audio session and route, discovery, connect stages, call phases, authentication and codec, call_stats every 5 s (captured/encoded/sent and received/decoded/played counts), rate changes, and the end reason. They contain no keys, text or media.
- Launch arguments (`App/Diagnostics/Automation.swift`) run a call without touching the phone: `-NearbyAutoCall <handle>`, `-NearbyCallType voice|video`, `-NearbyCallSeconds N`, `-NearbyAutoAccept voice|video` and others.
- `Scripts/gui-run.sh install` builds, signs, installs and launches through the logged-in GUI session (`Scripts/device-gui.command`), because SSH sessions cannot use the login keychain. `Scripts/run-scenario.sh call|answer` runs a scenario over SSH, and `Scripts/pull-logs.sh` copies the logs. `Scripts/screenshots.sh` takes simulator screenshots. `Scripts/gui-run.sh uitest call|people` runs the XCUITest scenarios (`UITests/`), with a screenshot at each step.

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
| Stream forwarding (viewer passes a stream on to one child) | Off | Settings › Advanced › "Help pass streams and calls to others nearby (experimental)". Port of Android's hop-local forwarder: BFG1 grant, unchanged BMV1 envelopes in order, cold-start admission (one child with no relay evidence), child health withdrawal, hop-local keyframe/end/withdrawal. Foreground only; one advertised UUID (the onward offer only while no child is connected) |
| Call relay hop | Off | DEBUG launch argument `-NearbyRelayCallee <handle>` with the same switch, as Android's DEBUG-only `test_private_call_relay`. Downstream first, one parent and one child, bit 6 and maxChildren 1 in both link hellos, end-to-end records copied unchanged, heartbeats replaced with version-1 liveness, 180 s parent wait, relayed calls capped at 110 kbps video |
| Video rate adaptation | On | `VideoRateController`: the encoder follows the delivered video rate, bounded by the requested bitrate. It was added after a measured GATT backlog |

## How this was built

Like the Android app, this iPhone app is built with heavy AI assistance: most of the code was written by Anthropic's
Claude (through Claude Code), directed by the maintainer, who decides what the product should do, runs the tests and
reviews the changes. [meshlive-android's AI-assisted development page](https://github.com/MeshLive/meshlive-android/blob/main/docs/AI_ASSISTED_DEVELOPMENT.md)
describes the process and the rules the agents follow.

- **Hardware testing is thin.** See [Status](#status): a handful of automated test calls on one iPhone and one Android
  phone, plus byte-level test vectors checked against the Android app's own classes. That is why this repository
  asks for iPhone testers rather than claiming compatibility.
- **Not independently security-audited.** Neither the protocol nor this implementation has had a third-party review.
  Do not rely on it where your safety depends on it.
- **Measurements are real.** The device numbers MeshLive publishes ([benchmarks](https://github.com/MeshLive/meshlive-benchmarks))
  come from real Android phone runs; none exist for iPhones yet.

Found a problem? Use the [bug form](https://github.com/MeshLive/meshlive-ios/issues/new?template=bug_report.yml) or the
[iPhone device test report](https://github.com/MeshLive/meshlive-ios/issues/new?template=device-report.yml). Security
problems go through the private route in [SECURITY.md](SECURITY.md), never a public issue.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). Protocol changes start in [meshlive-android](https://github.com/MeshLive/meshlive-android), which owns the wire format. **Please report security problems privately** as described in [SECURITY.md](SECURITY.md), not in public issues.

Using AI coding tools is welcome; you remain responsible for every line you submit. Say in the pull request when they did a substantial part of the work.

## License

Copyright (C) 2026 The MeshLive Authors (see [AUTHORS](AUTHORS)).

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See [LICENSE](LICENSE) for the full text.

Third-party components keep their own licences: libopus and libvpx (BSD-3-Clause; libvpx also grants the patent licence in `Vendor/LIBVPX-PATENTS`), Unicode data (Unicode License v3), and, for the default-off experimental v1 reference only, Bouncy Castle, JSON-java and noise-c. Their texts are in `Vendor/`, and [Vendor/README.md](Vendor/README.md) describes how the pinned libraries are fetched and built. The scripts download libopus and libvpx sources at build time; no third-party binaries are included.

The bundle identifier is `io.github.meshlive.app`, the same as the Android app.
