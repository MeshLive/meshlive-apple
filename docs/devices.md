# Device compatibility

Which iPhones and Macs MeshLive has been tried on, and how it went. The iPhone app needs iOS 16 or newer; the native
Mac app needs an Apple Silicon Mac with macOS 14 or newer.

**There is no pass yet.** Apple-device testing so far is a few manual and scripted runs by the maintainers, always
paired with Android phones running MeshLive. Interoperability is mainly checked offline, with byte-level test vectors
produced by the Android app's own classes ([testing](dev/testing.md)). The current code (Android-style screens,
relaying, audio-only live and the Mac app) has **not** been installed on an iPhone yet.

## Results so far

| Device | Build | Peer | What was tried | Result |
| --- | --- | --- | --- | --- |
| iPhone 14 Plus | early build, 2026-10-10 | Samsung Galaxy M31 (Android 12) | scripted voice and video calls over LE GATT, iPhone calling | partial: voice carried packets both ways; video decoded both ways but the iPhone's video was limited to about 125-135 kbps before rate control was added |
| iPhone 16 Plus, iOS 26.6 | 0.3.0, 2026-10-17 | Samsung Galaxy M31 (Android 12, "find iPhones" on) | voice and video calls both ways, watching a live stream both ways, over LE GATT | partial: every direction connected and carried audio and video for 20-40 s; short runs only, no quality gates |
| Apple Silicon Mac, macOS 26 (native app) | current, 2026-10-24 to 10-26 | several Android phones, mostly a Samsung Galaxy S24 (MeshLive 0.3.1-beta, Android 16) | discovery, voice and video calls over LE GATT | partial: voice calls worked both ways; video calls decode both ways but always dropped after 17 s to about 5.5 min ([details](dev/testing.md#hardware-results-release-app-mac-with-android-phones-over-gatt)) |

**Not tested yet:** LE L2CAP CoC, relaying, audio-only live, the QR scanner, the emergency wipe on a device, other
iPhone and Mac models, and iPhone-to-Mac calls.

## Add your device

Fill in the [device test report](https://github.com/MeshLive/meshlive-ios/issues/new?template=device-report.yml)
(about two minutes) for an iPhone or a Mac. Reports where everything worked are as useful as failures. The Android
phones that MeshLive is tested on are listed in the
[Android device page](https://github.com/MeshLive/meshlive-android/blob/main/docs/devices.md).
