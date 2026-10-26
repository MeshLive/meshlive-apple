<div align="center">

<img src="docs/brand/meshlive-icon-1024.png" width="96" alt="MeshLive icon" />

# MeshLive for iPhone and Mac

Calls and livestreams between nearby devices, over Bluetooth.<br/>
The iPhone and Mac side of MeshLive.<br/>
No internet, no SIM, no account.

<br/>

<p>
  <img alt="iOS 16+" src="https://img.shields.io/badge/iOS-16%2B-000000?style=flat&logo=apple&logoColor=white" />
  <img alt="macOS 14+ on Apple Silicon" src="https://img.shields.io/badge/macOS-14%2B%20Apple%20Silicon-000000?style=flat&logo=apple&logoColor=white" />
  <img alt="License GPLv3" src="https://img.shields.io/badge/License-GPLv3-FF3B30?style=flat&logo=gnu&logoColor=white" />
  <a href="https://github.com/MeshLive/meshlive-ios/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/MeshLive/meshlive-ios?style=flat&color=FF3B30&labelColor=181717&logo=github" /></a>
  <a href="https://github.com/MeshLive/meshlive-ios/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/MeshLive/meshlive-ios/ci.yml?branch=main&style=flat&label=CI&color=181717&labelColor=000000&logo=githubactions&logoColor=white" /></a>
  <img alt="Status: early" src="https://img.shields.io/badge/Status-early-181717?style=flat" />
</p>

<a href="docs/dev/building.md#iphone-app-and-package-tests"><img alt="Build for iPhone" src="https://img.shields.io/badge/Build%20for-iPhone-181717?style=for-the-badge&logo=apple&logoColor=white" /></a>
&nbsp;
<a href="docs/dev/building.md#native-macos-app-experimental"><img alt="Build for Mac" src="https://img.shields.io/badge/Build%20for-Mac-181717?style=for-the-badge&logo=apple&logoColor=white" /></a>

<sub>Free · open source · no App Store build yet · <a href="docs/user-guide.md#install">How to install</a></sub>

</div>

## What it does

<table>
<tr>
<td width="50%" valign="top">

**Calls**
- Voice and video calls with people nearby
- End-to-end encrypted, device to device
- Hold Mute to talk, like a walkie-talkie

**Livestream**
- Go live and share your camera with everyone around you
- Or go live with audio only
- Watch streams from people nearby

</td>
<td width="50%" valign="top">

**Contacts**
- Add people by scanning each other's code
- Or compare a safety code after a call
- Contacts show by the name you saved

**Your privacy**
- No internet, SIM, account or server
- Your calls never touch the internet
- Erase everything from the device in seconds

</td>
</tr>
</table>

An iPhone, a Mac, a Windows PC and an Android phone running MeshLive are meant to call each other and watch each
other's streams. MeshLive for iPhone and Mac is **early**: read the status below, and don't rely on it where your
safety depends on it.

## Status

There is no App Store or TestFlight build yet: you build it yourself on a Mac. The iPhone app has only had a few
short test calls on an earlier build, and the current code has not been tested on an iPhone. The Mac app is an
experimental native app: voice calls with Android phones work, but video calls still drop after a few minutes.
Neither has had an independent security audit.

| Device | Status |
| --- | --- |
| iPhone (iOS 16+) | Source build. The current code is not yet tested on an iPhone. |
| Mac (Apple Silicon, macOS 14+) | Experimental native app. Voice calls with Android work; video calls drop after a few minutes. |

Details are in [devices](docs/devices.md) and [testing](docs/dev/testing.md). Android phones only list iPhones and
Macs when their Advanced setting "Experimental: find iPhones" is on; see
[Talking to Android phones](docs/user-guide.md#talking-to-android-phones).

## Build it yourself

You need a Mac with Xcode 26 or later and Python 3. For an iPhone:

```sh
git clone https://github.com/MeshLive/meshlive-ios.git && cd meshlive-ios
bash Scripts/prepare-opus.sh && bash Scripts/prepare-libvpx.sh   # pinned audio and video codecs
python3 Scripts/project.py                                       # creates MeshLive.xcodeproj
open MeshLive.xcodeproj
```

Pick your Apple developer team (a free personal team works) and run the **MeshLive-iOS** scheme on your iPhone, or
the **MeshLive** scheme for the Mac app. The full steps, the Mac-only setup and the tests are in
[Building from source](docs/dev/building.md).

## Help wanted

We need **people with an iPhone or a Mac** to try it with an Android phone running MeshLive and tell us what
happened. Reports where everything worked are as useful as failures.

1. Build it ([above](#build-it-yourself)) and install [MeshLive for Android](https://github.com/MeshLive/meshlive-android)
   on a phone, with Advanced > "Experimental: find iPhones" on.
2. Try the [physical checks](docs/dev/testing.md#physical-checks-when-an-iphone-and-android-phones-are-available),
   keeping both apps open, 30-60 seconds per run.
3. Fill in the [device test report](https://github.com/MeshLive/meshlive-ios/issues/new?template=device-report.yml)
   (about two minutes), or the [bug form](https://github.com/MeshLive/meshlive-ios/issues/new?template=bug_report.yml)
   when something breaks.

Please do not post photos, recordings or the names of other people.

## MeshLive everywhere

| | Where | Status |
| --- | --- | --- |
| Android 10+ | [meshlive-android](https://github.com/MeshLive/meshlive-android) | Beta, with releases; holds the protocol |
| Windows | [meshlive-windows](https://github.com/MeshLive/meshlive-windows) | Beta-quality source; build it yourself |
| iPhone and Mac | meshlive-ios (this repository) | Early; build it yourself |
| Benchmarks | [meshlive-benchmarks](https://github.com/MeshLive/meshlive-benchmarks) | Measured results on real Android phones |
| Website | [meshlive.github.io](https://meshlive.github.io) | Overview and privacy policy |

## Privacy

No accounts, no ads, no analytics, no servers. Calls and streams are encrypted, but a nearby Bluetooth scanner can see
that a MeshLive device is there, and while the app advertises it carries a stable ID prefix (rotating IDs are still
an experiment). What nearby devices can and can't see is explained in [Privacy](docs/privacy.md).

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
| [Architecture](docs/dev/architecture.md) | Code layout, screens and design, the native Mac app, platform limits, diagnostics |
| [Protocol notes](docs/dev/protocol.md) | The iPhone-specific parts of the protocol; the canonical reference is [Android's](https://github.com/MeshLive/meshlive-android/blob/main/docs/dev/protocol/README.md) |
| [Switches](docs/dev/switches.md) | The register of experimental, alternative and optional switches |
| [Testing](docs/dev/testing.md) | What has been checked offline and on hardware, and the physical test steps |
| [Working rules](AGENTS.md) | Rules for people and coding agents who change the code |
| [Security](SECURITY.md) | Report a vulnerability privately |
| [Code of conduct](CODE_OF_CONDUCT.md) | How we treat each other |

## Contributing

Bug reports, device results and code are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md), and please follow
the [code of conduct](CODE_OF_CONDUCT.md). Protocol changes start in
[meshlive-android](https://github.com/MeshLive/meshlive-android), which owns the wire format. Report security issues
privately: see [SECURITY.md](SECURITY.md).

## License

GPL-3.0-or-later, copyright (C) 2026 The MeshLive Authors ([AUTHORS](AUTHORS)). See [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The build scripts download the pinned libopus and libvpx sources;
no third-party binaries are included.
