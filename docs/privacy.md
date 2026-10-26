# Privacy and security

What MeshLive for iPhone and the Mac app expose over the air, what is hidden, and the known limits. The shared
protocol is the same as Android's; this page covers what is different on Apple devices.

## In short

- No account, server, internet, analytics or ads. Calls and streams go directly between nearby devices over
  Bluetooth and are end-to-end encrypted.
- The **content** is encrypted; the fact that a MeshLive device is nearby is not hidden.
- While the app advertises, its Bluetooth announcement carries a **stable ID prefix** that a scanner can use to
  recognise the same device over time. Rotating IDs exist only as an experiment.
- Your identity key stays in the Keychain on the device. Wipe everything (and the optional quick wipe) erases it, your
  contacts and settings, but cannot reach backups or copies outside the app.
- Nothing has had an independent security audit. Do not rely on MeshLive where your safety depends on it.

## What nearby phones can see

Anyone with a Bluetooth scanner in range can read what MeshLive broadcasts. They do not need to connect or pair. The **content** of calls and streams is encrypted, but the fact that a MeshLive phone is nearby is not hidden. The iPhone has the same exposure as the Android app, with differences that come from iOS.

**What an iPhone broadcasts.** While the app is in the foreground and offering a call, a stream or a viewer request, the iPhone advertises one 128-bit compact-announcement service UUID (magic `0xC8D6`, [addendum A](../Interop/ANDROID_DISCOVERY_ADDENDUM.md)). iOS apps cannot put manufacturer data in an advertisement, so the whole announcement is packed into that UUID. It contains:

- a **stable node-ID prefix** (48 bits, the first 6 bytes of the node ID derived from the phone's identity key). It does not change until the identity is wiped or reset;
- the kind of announcement (call offer, viewer request or stream offer), the Bluetooth transport it offers (LE GATT or LE CoC), whether it can relay, which video codecs it supports, and the route cost;
- for a stream offer or viewer request: a route token and a coarse resolution, frame rate and bitrate.

The [protocol notes](dev/protocol.md) also allow an optional local name of up to 8 bytes; the current code advertises only the UUID.

**Why this lets people be tracked.** The prefix is in the advertised payload and stays the same, so a scanner that records prefixes can link the iPhone's changing Bluetooth addresses to the same phone, across places and days, while the app is open and advertising. Rotating discovery IDs exist, but they are **experimental, off by default and untested on phones** (Settings > Privacy > Advanced privacy > "Rotating discovery IDs"), and they cover only the "ready for calls" announcement. Live streams still use the stable prefix, so while the experiment is on the app does not join a stream that uses private discovery (its request would show the stable prefix). Assume the stable prefix can be used to track a phone.

**Anyone who connects learns who you are.** The signed handshake message that starts every Bluetooth connection contains the phone's public key and is not encrypted, so a connection attempt, or a sniffer watching one, reveals the identity. LE connections need no pairing, so any nearby scanner can try.

**Names.** iOS does not let an app change the phone's Bluetooth device name, so a name such as "Your Name's iPhone" may be visible to a phone that connects. Give your iPhone a neutral name (Settings > General > About > Name), especially before switching on the rotating-IDs experiment. Names and titles (signed labels) are off by default and public while enabled.

**Background.** When the app is in the background iOS removes the local name and moves service UUIDs to an Apple-only area, so Android phones cannot see the iPhone then. That is an iOS restriction, not a privacy feature. The size and timing of the encrypted data still shows that a call or stream is happening.

To reduce your exposure now: close the app or switch Bluetooth off when you do not need it, leave names and titles off, and give the phone a neutral name. The Android app's [privacy page](https://github.com/MeshLive/meshlive-android/blob/main/docs/privacy.md#what-nearby-phones-can-see) covers the shared protocol-level exposure in more detail.

## On a Mac

The Mac app advertises and connects like the iPhone, with these differences:

- macOS may expose the Mac's **system Bluetooth name** (System Settings > General > About > Name) to devices that connect. Use a neutral computer name.
- The Mac keeps discovery running while the app is open, including when its window is in the background, so it stays
  visible to nearby phones until you quit it (or close its windows, unless "Keep running with windows closed" is on).
- The first Bluetooth connection to some phones can show a system pairing prompt on both devices. MeshLive itself does
  not need pairing; the prompt appears to come from macOS itself reading the phone's device name. Accepting it stores a normal system
  Bluetooth pairing.
- Generated nearby names (an off-by-default Mac experiment) show two-word names derived from public rotating
  announcements; they are not verified identities.

## Security model and limitations

The security model, scope and known limitations are in [SECURITY.md](../SECURITY.md). Report vulnerabilities
privately as described there, never in a public issue.
