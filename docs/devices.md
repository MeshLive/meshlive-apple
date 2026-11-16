# Device compatibility

Which iPhones and Macs MeshLive has been tried on, and how it went. The iPhone app needs iOS 17 or newer; the native
Mac app needs an Apple Silicon Mac with macOS 14 or newer.

**There is no formal pass yet.** Apple-device testing is manual and scripted runs by the maintainers over Bluetooth
LE GATT, without quality gates. Interoperability is also checked offline, with byte-level test vectors produced by
the Android app's own classes ([testing](dev/testing.md)). Before version 1.0 went on the App Store, its test builds
were tested on an iPhone 12 with Android phones and a Mac in November 2026 (the last row).

## Results so far

| Device | Build | Peer | What was tried | Result |
| --- | --- | --- | --- | --- |
| iPhone 14 Plus | early build, 2026-10-10 | Samsung Galaxy M31 (Android 12) | scripted voice and video calls over LE GATT, iPhone calling | partial: voice carried packets both ways; video decoded both ways but the iPhone's video was limited to about 125-135 kbps before rate control was added |
| iPhone 16 Plus, iOS 26.6 | 0.3.0, 2026-10-17 | Samsung Galaxy M31 (Android 12, "find iPhones" on) | voice and video calls both ways, watching a live stream both ways, over LE GATT | partial: every direction connected and carried audio and video for 20-40 s; short runs only, no quality gates |
| Apple Silicon Mac, macOS 26 (native app) | current, 2026-10-24 to 10-26 | several Android phones, mostly a Samsung Galaxy S24 (MeshLive 0.3.1-beta, Android 16) | discovery, voice and video calls over LE GATT | partial: voice calls worked both ways; video calls decode both ways but always dropped after 17 s to about 5.5 min ([details](dev/testing.md#hardware-results-release-app-mac-with-android-phones-over-gatt)). Advertises with the Mac's fixed Bluetooth address (macOS limitation); see [privacy](privacy.md#on-a-mac) |
| iPhone 12, iOS 26.5 | build of 2026-11-05 (verification codes) | Apple Silicon Mac, macOS 27 (native app, same build) | discovery, voice and video calls both ways over LE GATT, adding each other by code (a test helper read the code instead of the camera), the iPhone app in the background and closed mid-call | partial: every test passed in 20-45 s calls; turning Bluetooth off and locking the iPhone mid-call were not tried |
| iPhone 12 and the Mac (native app) | build of 2026-11-05 (verification codes) | Samsung Galaxy M31 (Android 12, MeshLive for Android with default settings) | voice and video calls both ways between each Apple device and the phone, over LE GATT | partial: every direction connected and carried audio and video for 20-26 s; the iPhone and the Mac listed the Android phone only while it showed its code or once it was a contact |
| iPhone 12, iOS 26.5 | test builds of 1.0 (the App Store version), 2026-11-12 to 11-13 | Samsung Galaxy M31 (Android 12) and OPPO A15s with MeshLive for Android; an Apple Silicon Mac | short voice and video calls both ways (the iPhone sends hardware HEVC video), watching video and audio-only streams (audio also with the screen locked), adding contacts by scanning codes with the camera, Decline and block, locking and leaving the app during a call, an incoming phone call, Airplane mode on and off, a fresh install with the camera or microphone refused, a Release-build call | partial: all of these worked, several after fixes made during the tests; turning Bluetooth off mid-call was fixed but not re-tested; one 9.4 s freeze when locking during a call ended that call and was not seen in two retests; AirPods, wired headsets, long calls and sleep were not tried |

**Not tested yet:** the Experimental in-call link renewal outside scripted runs (off by default; on an armed iPhone
it needs the app in the foreground), LE L2CAP CoC, relaying, the emergency wipe on a device, AirPods and wired
headsets, long calls, and other iPhone and Mac models.

## Add your device

Fill in the [device test report](https://github.com/MeshLive/meshlive-apple/issues/new?template=device-report.yml)
(about two minutes) for an iPhone or a Mac. Reports where everything worked are as useful as failures. The Android
phones that MeshLive is tested on are listed in the
[Android device page](https://github.com/MeshLive/meshlive-android/blob/main/docs/devices.md).
