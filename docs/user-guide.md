# User guide

MeshLive makes voice and video calls and live streams between nearby devices over Bluetooth, with no internet, SIM
or account. This guide covers the iPhone app and the experimental native Mac app. Both are **early**: read the
[status](../README.md#status) before relying on them.

## Install

There is no App Store, TestFlight or other download yet. We will publish a build only after it has been tested on
real devices and the results are public. Until then you build it yourself on a Mac:

1. Install Xcode 26 or later and Python 3.
2. Get the source: `git clone https://github.com/MeshLive/meshlive-ios.git`.
3. Follow [Building from source](dev/building.md): prepare the pinned codecs, generate the Xcode project, then
   - **iPhone:** open `MeshLive.xcodeproj`, choose your Apple developer team (a free personal team works) and
     run the **MeshLive-iOS** scheme on your iPhone (iOS 16 or newer);
   - **Mac:** build and run the **MeshLive** scheme (Apple Silicon, macOS 14 or newer; no account needed).
4. On first launch, allow Bluetooth, and camera and microphone when you want video and calls.

To update, pull the latest source and build again. Your identity and contacts stay on the device.

## Use the app

The app has four tabs (on the Mac, a sidebar): **Live**, **Calls**, **Contacts** and **Settings**.

- **Calls:** people nearby appear under Nearby. Tap a person, then Voice call or Video call. While muted, press and
  hold Mute to talk. **Recent** lists your last calls on this device only: it is not backed up or moved to a new
  device, and only verified contacts can be called back from it.
- **Live:** streams from people nearby. **Go live** shares your camera and microphone, or audio only, with everyone
  around you.
- **Contacts:** add someone by scanning each other's code (or comparing the safety code after a call). Verified
  contacts show by their saved name.
- **Settings:** your name and ID, Allow calls, Privacy (quick wipe, names, advanced privacy), Advanced (connection
  and experiments), About, and **Wipe everything**.

Keep the app open and in the foreground on an iPhone: iOS stops Bluetooth advertising for apps in the background,
so other phones cannot find a backgrounded iPhone, and there are no incoming calls while the app is closed. The Mac
app keeps working with its window in the background until you quit it.

## Talking to Android phones

MeshLive for iPhone and Mac speaks the same protocol as
[MeshLive for Android](https://github.com/MeshLive/meshlive-android), but the defaults do not match yet:

- Android phones only list iPhones and Macs when their Advanced setting **"Experimental: find iPhones"** is on.
- Android uses hidden identities and rotating IDs by default. To call a default Android phone from an iPhone, switch
  on Settings > Privacy > Advanced privacy > **Rotating discovery IDs**, **Hidden identities** and **Pseudonymous
  toward strangers**. On the Mac, Settings > Advanced > Experiments > **Android compatibility** does this for calls.

These settings are experimental. Please report what happens (see below).

## FAQ

**How far does it reach?** Bluetooth reaches roughly 10 to 30 metres between two devices, less through walls and
people. Video is small because Bluetooth is slow.

**Is it private?** Calls and streams are encrypted end to end, but a nearby Bluetooth scanner can see that a
MeshLive device is there. See [Privacy](privacy.md).

**Why no App Store version?** Distribution needs more real-device testing first. See [Devices](devices.md).

**Can an iPhone call a Mac?** It should, since both use the same code, but it has not been tested.

## Contact us

- Something did not work: the [bug form](https://github.com/MeshLive/meshlive-ios/issues/new?template=bug_report.yml).
- It worked, or partly worked, on your device: the
  [device test report](https://github.com/MeshLive/meshlive-ios/issues/new?template=device-report.yml).
- A security problem: report it privately as described in [SECURITY.md](../SECURITY.md), never in a public issue.
