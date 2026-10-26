# Building from source

There is no App Store, TestFlight or other binary release of MeshLive for iPhone or Mac. To run it you build it
yourself. This page is the developer view; the [user guide](../user-guide.md#install) has the short version.

## Requirements

- A Mac with Xcode 26 or later (the scripts call `xcodebuild`, `xcrun`, `swift` and `shasum`) and Python 3.
- Network access for the first build: the scripts download the pinned libopus and libvpx sources, check their
  SHA-256 and build them into ignored `Vendor/*.xcframework` folders. No third-party binaries are committed
  ([third-party notices](../../THIRD_PARTY_NOTICES.md), [Vendor/README.md](../../Vendor/README.md)).
- For a phone: an iPhone on iOS 16 or newer and an Apple developer team (a free personal team works) to sign it.
- For the native Mac app: an Apple Silicon Mac on macOS 14 or later. Local builds are ad-hoc signed and need no
  account; to keep the app's permissions across rebuilds, sign with your own certificate
  ([below](#keep-mac-permissions-across-rebuilds)).

## iPhone app and package tests

```sh
bash Scripts/prepare-opus.sh      # pinned libopus 1.6.1 -> Vendor/Opus.xcframework (ignored)
bash Scripts/prepare-libvpx.sh    # pinned libvpx 1.15.2, SHA256 26fcd3db... -> Vendor/VPX.xcframework (ignored)
python3 Scripts/project.py        # regenerate MeshLive.xcodeproj (no signing data)
python3 Scripts/tokens.py --check # design tokens are up to date
bash Scripts/test.sh              # swift test: core, media, desktop and v1-experiment suites
bash Scripts/build.sh iphoneos    # unsigned device build; iphonesimulator = ad-hoc signed simulator build
bash Scripts/smoke-simulator.sh   # launch in a simulator (UI only; simulators have no Bluetooth)
```

These are the same offline checks the CI workflow runs on every pull request
([.github/workflows/ci.yml](../../.github/workflows/ci.yml)). A green run says nothing about Bluetooth, the camera or
the microphone.

To run on a phone, open `MeshLive.xcodeproj`, choose your team and a unique bundle identifier, and run the
**MeshLive-iOS** scheme, or use `TEAM=<team> BUNDLE=<id> bash Scripts/run-device.sh`. The bundle identifier is
`io.github.meshlive.app`, the same as the Android app; pass `BUNDLE=<id>` only if your Apple team cannot register it.
The phone must have Bluetooth, Camera and Microphone allowed; for test launches it must be unlocked with the screen
on. Do not commit your team ID, provisioning data or a personal bundle identifier.

## Native macOS app (experimental)

The **MeshLive** scheme builds a native SwiftUI/AppKit app that shares the iPhone screens, media and CoreBluetooth
transport. To prepare only the Mac dependencies:

```sh
bash Scripts/prepare-opus-macos.sh      # pinned Opus for macOS arm64 under .build/opus (iOS artifacts untouched)
bash Scripts/prepare-libvpx.sh macos-only   # Vendor/VPX-macos.xcframework
python3 Scripts/project.py
bash Scripts/build-macos.sh             # Debug app in .build/dd-mac/Build/Products/Debug/MeshLive.app
bash Scripts/build-macos.sh Release     # Release app
bash Scripts/check-macos-media.sh       # offline Opus bridge check with ASan/UBSan
bash Scripts/run-macos-uitest.sh        # native UI tests in DEBUG preview mode
```

The UI tests need an unlocked desktop and the macOS UI-testing (automation) permission. They use the DEBUG-only
`-NearbyPreview` mode: an ephemeral identity, isolated preferences and no Bluetooth, camera or microphone. Never
reset privacy permissions to run tests; grant Bluetooth, camera, microphone and notifications yourself when the app
asks.

### Keep Mac permissions across rebuilds

An ad-hoc signed app is identified only by the hash of its code, and macOS remembers the Bluetooth, camera and
microphone permissions (and Keychain access) for exactly that hash. Every rebuild therefore looks like a new app and
asks again. Signing with your own certificate gives every build the same code identity, so a permission granted
once stays granted:

```sh
security find-identity -v -p codesigning        # pick your "Apple Development" identity (a free team works)
export MESHLIVE_SIGN_IDENTITY=<its SHA-1 or full name>
export MESHLIVE_TEAM=<team ID>                  # optional, only if Xcode asks for a team
bash Scripts/build-macos.sh                     # also used by Scripts/run-macos-uitest.sh
```

The script prints the app's designated requirement: a `cdhash` means ad-hoc, a requirement naming your certificate
means permissions will survive rebuilds. The first launch of the newly signed app asks once more; later builds do
not. Keep your identity and team in your shell environment, never in the project. Without the variables the build
stays ad-hoc. Over SSH the login keychain is locked, so `codesign` fails with `errSecInternalComponent`; run the build
from the logged-in desktop, or from SSH with `bash Scripts/gui-run.sh mac-build [Debug|Release]` (or `mac-uitest`),
which runs it in that session and passes these variables along.

## Test on phones

Calls and streams can only be proven on real devices. The physical steps and what has been checked so far are in
[testing](testing.md). Please send what you find with the
[device test report](https://github.com/MeshLive/meshlive-apple/issues/new?template=device-report.yml).
