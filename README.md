<div align="center">

<img src="docs/brand/meshlive-icon-1024.png" width="96" alt="MeshLive icon" />

# MeshLive for iPhone and Mac

Voice and video calls and livestreams between nearby devices, over Bluetooth.<br/>
No internet, no SIM, no account. The Apple side of [MeshLive](https://github.com/MeshLive).

<br/>

<p>
  <img alt="iOS 16+" src="https://img.shields.io/badge/iOS-16%2B-000000?style=flat&logo=apple&logoColor=white" />
  <img alt="macOS 14+ Apple Silicon (experimental)" src="https://img.shields.io/badge/macOS-14%2B%20Apple%20Silicon%20%C2%B7%20experimental-000000?style=flat&logo=apple&logoColor=white" />
  <img alt="License GPLv3" src="https://img.shields.io/badge/License-GPLv3-FF3B30?style=flat&logo=gnu&logoColor=white" />
  <a href="https://github.com/MeshLive/meshlive-ios/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/MeshLive/meshlive-ios/actions/workflows/ci.yml/badge.svg" /></a>
  <img alt="Status: early" src="https://img.shields.io/badge/status-early%20%C2%B7%20little%20hardware%20testing-orange?style=flat" />
  <a href="https://github.com/MeshLive/meshlive-ios/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/MeshLive/meshlive-ios?style=flat&color=FF3B30&labelColor=181717&logo=github" /></a>
</p>

<a href="docs/dev/building.md#iphone-app-and-package-tests"><img alt="Build for iPhone" src="https://img.shields.io/badge/Build%20for-iPhone-000000?style=for-the-badge&logo=apple&logoColor=white" /></a>
&nbsp;
<a href="docs/dev/building.md#native-macos-app-experimental"><img alt="Build for Mac" src="https://img.shields.io/badge/Build%20for-Mac-000000?style=for-the-badge&logo=apple&logoColor=white" /></a>

<sub>Free · open source · no App Store build yet · <a href="docs/user-guide.md#install">How to install</a></sub>

</div>

> **Status: early.** The iPhone app has had only a handful of short test calls, and the current iPhone code
> has not been tested on an iPhone at all. The native Mac app is **experimental**: voice calls with Android phones
> have worked, but video calls with an Android phone still drop after between 17 seconds and about 5.5 minutes.
> Neither has had an independent security audit. Please do not rely on MeshLive where your safety depends on it.

## What it does

MeshLive sends encrypted live camera video and microphone audio directly between nearby devices over Bluetooth, with
no account, no server and no internet. This repository holds the native SwiftUI iPhone app and a native macOS app
built from the same sources. They speak the same protocol as [MeshLive for Android](https://github.com/MeshLive/meshlive-android)
(BMH2/BMH3 authentication, BMS1/BME1 AES-GCM records, BMC2 calls, BTV3 media, BMV1/BFG1 forwarded streams, over
Bluetooth LE GATT and LE L2CAP CoC), so an iPhone, a Mac and an Android phone are meant to call each other and watch
each other's streams.

- **Calls:** voice and video calls with people nearby, end-to-end encrypted; hold Mute to talk.
- **Live:** go live with your camera, or audio only, and watch streams from people around you.
- **Contacts:** verify each other by QR code or safety code; contacts show by their saved name.
- **Privacy:** no account or server; erase your identity, contacts and settings in seconds.

## Status

| | iPhone | Mac (native app, experimental) |
| --- | --- | --- |
| Builds and offline tests | Yes: 268 package tests (protocol vectors from Android's own classes, engines over loopback links), simulator UI tests, CI on every pull request | Yes: Release build, package tests, native UI tests in a hardware-free preview mode |
| Tried on hardware | An earlier build: voice and video calls both ways and live streams both ways with one Android phone, short runs | Discovery of Android phones; voice calls both ways over GATT |
| Known problems | The current code (Android-style screens, relaying, audio-only live) is not yet device-tested | Video calls drop after 17 s to about 5.5 min when the phone's incoming Bluetooth data stops; cause unknown |
| Untested | LE L2CAP CoC, relaying, the QR scanner, the emergency wipe on a device, other models | Live streams, relays, sleep and wake, CoC, Mac-to-iPhone calls |

Details: [device results](docs/devices.md) and [testing](docs/dev/testing.md). Android phones list iPhones and Macs
only with their Advanced setting "Experimental: find iPhones" on; see
[Talking to Android phones](docs/user-guide.md#talking-to-android-phones).

**Impossible or restricted on iOS:** Bluetooth Classic, discovery while the app is in the background (iOS hides the
advertisement), incoming calls while the app is closed (that needs internet push), manufacturer data in adverts
(hence the compact UUID), and hardware VP9/AV1 encoding (the iPhone encodes VP9 in software with libvpx).

**Not implemented yet:** store-and-forward messages, group (BGK1) relays, relay re-anchor and parent-silence
recovery, the route-recovery hint and CallKit.

## Help wanted

The most useful thing you can do is **test it on your iPhone or Mac with an Android phone running MeshLive** and tell
us what happened, including when everything worked.

1. Build and install it ([user guide](docs/user-guide.md#install)).
2. Install [MeshLive for Android](https://github.com/MeshLive/meshlive-android) on the phone and switch on Advanced >
   "Experimental: find iPhones".
3. Follow the physical checks in [testing](docs/dev/testing.md#physical-checks-when-an-iphone-and-android-phones-are-available),
   keeping both apps in the foreground, 30-60 seconds per run.
4. Fill in the [device test report](https://github.com/MeshLive/meshlive-ios/issues/new?template=device-report.yml)
   (about two minutes). Failures go in the [bug form](https://github.com/MeshLive/meshlive-ios/issues/new?template=bug_report.yml).

Please do not post photos, recordings or the names of other people.

## MeshLive on other platforms

| Platform | Repository | Status |
| --- | --- | --- |
| Android 10+ | [meshlive-android](https://github.com/MeshLive/meshlive-android) | Beta, with releases; owns the protocol |
| iPhone and Mac | meshlive-ios (this repository) | Early; build from source |
| Windows | [meshlive-windows](https://github.com/MeshLive/meshlive-windows) | Beta-quality source; build from source |
| Benchmarks | [meshlive-benchmarks](https://github.com/MeshLive/meshlive-benchmarks) | Measured Android phone runs |

## Privacy

No accounts, no ads, no analytics, no servers. Calls and streams are encrypted, but a nearby Bluetooth scanner can see
that a MeshLive device is there, and while the app advertises it carries a stable ID prefix (rotating IDs are still
an experiment). What nearby devices can and cannot see is explained in [Privacy](docs/privacy.md).

## Documentation

### For users

| Document | What it covers |
| --- | --- |
| [User guide](docs/user-guide.md) | Install (build it yourself), use the app, talk to Android phones, common questions |
| [Privacy](docs/privacy.md) | What nearby devices can see, what is hidden, and the known limits |
| [Devices](docs/devices.md) | Which iPhones and Macs have been tried and how it went; report yours |

### For contributors

| Document | What it covers |
| --- | --- |
| [Contributing](CONTRIBUTING.md) | How to report a bug or a device result and send a change |
| [Building](docs/dev/building.md) | Build and test from source, for iPhone and Mac |
| [Architecture](docs/dev/architecture.md) | Code layout, screens and design, the native Mac app, diagnostics |
| [Protocol notes](docs/dev/protocol.md) | The iPhone-specific parts of the protocol; the canonical reference is [Android's](https://github.com/MeshLive/meshlive-android/blob/main/docs/dev/protocol/README.md) |
| [Switches](docs/dev/switches.md) | The register of experimental, alternative and optional switches |
| [Testing](docs/dev/testing.md) | What has been checked offline and on hardware, and the physical test steps |
| [Working rules](AGENTS.md) | Rules for people and coding agents who change the code |
| [Security](SECURITY.md) | Report a vulnerability privately |
| [Code of conduct](CODE_OF_CONDUCT.md) | How we treat each other |

## Contributing

Bug reports, device results and code are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md) and follow the
[code of conduct](CODE_OF_CONDUCT.md). Protocol changes start in [meshlive-android](https://github.com/MeshLive/meshlive-android),
which owns the wire format. Report security issues privately: see [SECURITY.md](SECURITY.md).

## License

Copyright (C) 2026 The MeshLive Authors (see [AUTHORS](AUTHORS)). GPL-3.0-or-later: see [LICENSE](LICENSE).
Third-party components keep their own licences; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The scripts
download the pinned libopus and libvpx sources at build time; no third-party binaries are included. The bundle
identifier is `io.github.meshlive.app`, the same as the Android app.
