# Privacy and security

What MeshLive for iPhone and the Mac app expose over the air, what is hidden, and the known limits. The shared
protocol is the same as Android's; this page covers what is different on Apple devices.

## In short

- No account, server, internet, analytics or ads. Calls and streams go directly between nearby devices over
  Bluetooth and are end-to-end encrypted.
- The **content** is encrypted; the fact that a MeshLive device is nearby is not hidden.
- While the app is ready for calls, its Bluetooth announcement carries a **rotating ID** that changes every 15
  minutes. Live streams it offers or joins still carry a **stable ID prefix** that a scanner can use to recognise
  the same device over time.
- Your identity key stays in the Keychain on the device. Delete everything (and the optional triple-tap) erases it, your
  contacts, settings and the list of phones that used hidden identities with yours (kept 30 days, outside backups),
  but cannot reach backups or copies outside the app.
- Recent calls stay on this device, encrypted with a key that never leaves it, and are not backed up or moved to a
  new device. A call with someone who is not a verified contact is kept only as its made-up name and the time, never
  their ID.
- After a crash, the system gives MeshLive a crash diagnostic. The app keeps a short report from it (app and system
  version, device model and where the app failed; no names, IDs, messages or keys) for up to 7 days, outside backups,
  and asks at the next launch whether you want to share it. It is sent only if you share it yourself; "Don't ask again"
  deletes it and stops keeping reports.
- A store (Release) build keeps no diagnostic log file and writes nothing to the system log. Its first launch deletes
  logs left by an earlier build. About this app links the Terms of use and the Privacy policy, and the first run asks
  you to agree to the terms before any permission prompt.
- Nothing has had an independent security audit. Do not rely on MeshLive where your safety depends on it.

**Export diagnostics.** Settings > Advanced > Help and feedback > Export diagnostics shows a short technical text
before anything leaves: the app version, the commit it was built from, the device model (not its name), the system
version, Bluetooth support, the codecs and the newest crash report. It has no video, sound, messages, names, IDs or
keys. It is copied, and Share opens the system share sheet; nothing is sent unless you send it. Copy diagnostics in a
call's info adds that call's encryption, route, verification state and link counters, never the other person's ID or
name. A store build and a debug build produce the same export; it never reads the diagnostic log.

**Names on the lock screen.** Call and missed-call notifications show a contact's name only while the device is
unlocked, unless you set notification previews to Always; then the name is left out unless you turn on Settings >
Privacy > Show names on lock screen.

**What a contact calls themselves.** When a verified contact's name reaches you in a call, MeshLive keeps that last
name with the contact (encrypted like the rest of your contacts), so the contact sheet can say "They call themselves
...". It never replaces the name you gave them, unless you tap "Use it as my label". Forget and Delete everything
remove it. Nothing is kept for people who are not your contacts.

## What nearby phones can see

Anyone with a Bluetooth scanner in range can read what MeshLive broadcasts. They do not need to connect or pair. The **content** of calls and streams is encrypted, but the fact that a MeshLive phone is nearby is not hidden. The iPhone has the same exposure as the Android app, with differences that come from iOS.

**What an iPhone broadcasts.** While the app is in the foreground and offering a call, a stream or a viewer request, the iPhone advertises one 128-bit compact-announcement service UUID (magic `0xC8D6`, [addendum A](../Interop/ANDROID_DISCOVERY_ADDENDUM.md)). iOS apps cannot put manufacturer data in an advertisement, so the whole announcement is packed into that UUID. It contains:

- a **stable node-ID prefix** (48 bits, the first 6 bytes of the node ID derived from the phone's identity key). It does not change until the identity is wiped or reset; while it is ready for calls it advertises a rotating ID instead, which changes every 15 minutes (a stream offer or viewer request keeps the stable prefix);
- the kind of announcement (call offer, viewer request or stream offer), the Bluetooth transport it offers (LE GATT or LE CoC), whether it can relay, which video codecs it supports, and the route cost;
- for a stream offer or viewer request: a route token and a coarse resolution, frame rate and bitrate.

The [protocol notes](dev/protocol.md) also allow an optional local name of up to 8 bytes; the current code advertises only the UUID.

**Why this lets people be tracked.** A stream offer or viewer request carries the stable prefix, so a scanner that records prefixes can link the iPhone's changing Bluetooth addresses to the same phone, across places and days, while it is live or watching. While it is only ready for calls the announcement carries a rotating ID instead (always on since November 2026; it changes every 15 minutes and contacts you allowed can still recognise you). A stream that uses rotating IDs (a default Android phone's) is joined with a request that carries a rotating ID of this device's own instead of the stable prefix; such a stream is not passed on to other devices. Rotating IDs do not make you anonymous.

**Who learns who you are.** Connections use hidden identities: the signed handshake does not show the phone's key to someone it has not verified. Toward a stranger the app uses a temporary ID; your usual ID goes to verified contacts and, when you call someone or accept their call, to that person. LE connections need no pairing, so any nearby scanner can try to connect, but it learns only the temporary ID.

**Your verification code.** The code on Add contact is a live secret: it names your full ID, a one-time key and your current nearby ID, works once and for five minutes, and stops when you leave the page. Whoever scans it while it is valid reaches your phone and learns your full ID, nothing else; your phone shows "Two phones used your code" when a second phone tries it. The iPhone hides the code while the screen is recorded or mirrored and replaces it after a screenshot; the Mac keeps the window out of screen sharing while the code shows. While the page shows the code your phone can be found for calls even with Allow calls off, but it then accepts nothing but a scan of that code.

**Names.** iOS does not let an app change the phone's Bluetooth device name, so a name such as "Your Name's iPhone" may be visible to a phone that connects. Give your iPhone a neutral name (Settings > General > About > Name). "Your name" is never broadcast: it is sent, encrypted and signed, only to the people "Who sees my name" allows (people you call or who call you, only your contacts, or nobody), and the older static code (shown only when hidden identities are off) carries it unless you chose Nobody; the verification code carries no name. Someone you call who is not your contact gets it only after they answer and their phone proves who it is, and never if you blocked them. A live title is public to anyone who joins. Blocking is local: the block list holds full IDs only, sealed on this device with the other records and deleted by Delete everything; blocked people are not told, and a report only drafts an email you choose to send. If the saved block list can't be read, nobody is blocked until you reset it: Privacy and Blocked people say "Block list can't be read" and offer Reset, and the app logs it (never who is on it). The app keeps calls working rather than stopping every call over a file it cannot read.

**Hidden livestreams.** "Hide this livestream" keeps that stream's route (its token and the ID it was heard from) with
your block list, sealed on this device and deleted by Delete everything, once the phone it was heard from proved that
ID; otherwise it hides only that phone's offer until the app restarts. A report keeps hiding the person you reported,
never a route on its own. So a copied stream cannot make your device hide someone else's. Nobody is blocked or told,
and nothing is sent.

**Background.** When the app is in the background iOS removes the local name and moves service UUIDs to an Apple-only area, so Android phones cannot see the iPhone then. That is an iOS restriction, not a privacy feature. The size and timing of the encrypted data still shows that a call or stream is happening.

To reduce your exposure now: close the app or switch Bluetooth off when you do not need it, leave Your name empty or choose Nobody under Who sees my name, and give the phone a neutral name. The Android app's [privacy page](https://github.com/MeshLive/meshlive-android/blob/main/docs/privacy.md#what-nearby-phones-can-see) covers the shared protocol-level exposure in more detail.

- **In-call link renewal (Experimental, off).** With the DEBUG switch `-appleLinkRenewal YES`, a call whose connection
  stalls in one direction can be moved to a new Bluetooth connection. For up to 7 s the device then advertises one
  128-bit UUID instead of its usual advertisement. The UUID is new for every attempt and is derived from the call's own
  keys, so it links neither to this device nor to earlier calls. Apple devices cannot change their Bluetooth address
  for it, so a phone nearby can see that the device that was advertising a moment ago now advertises something else
  and is in a call that is renewing its connection; the call's own connection already shows that a call is in progress.
  In the background iOS moves the UUID to an Apple-only area (Android phones cannot see it, so no renewal happens).
- **Wi-Fi Direct calls (Experimental, off).** With Settings > Connection > Join Wi-Fi Direct groups on, during a call with an Android phone that offers it this device joins the other phone's temporary Wi-Fi Direct network. It is visible on that network, and the other phone can reach other apps on this device that accept connections from any network. The iPhone asks before every join and leaves its own Wi-Fi until the call ends; the Mac leaves its Wi-Fi too and asks for Location only to find the network (MeshLive never reads your location). Both switches are off by default.

## Audio-only live streams

Go live > Audio only. A radio broadcast is encrypted between devices like a video stream, but it is for anyone: every
device that completes the handshake can listen, and a device that passes the stream on hears it too.

- **Who learns what.** A listener (and a relay) learns the broadcaster's long-term identity key, because streams do
  not yet use a throwaway identity: broadcasts from different days can be linked to one device, and a verified contact
  is recognised. The broadcaster sees how many listeners are connected, and a relay sees its one listener; neither sees
  more of the chain.
- **Signed audio.** The broadcaster signs every audio record with a key certified by its identity key, so a device
  that passes the stream on cannot alter or forge the audio. It can still stop passing it on.
- **Announcements.** An audio-only offer carries a marker and no video size, so a scanner can tell a radio from a
  video stream, and like every stream offer from an iPhone or Mac it carries the device's stable ID prefix (see above).
  Nothing else about the content is visible.
- **The microphone.** Mute sends silence, and nothing recorded before the tap is sent afterwards. On an iPhone, Pause
  stops sending but the microphone stays on until you end the broadcast, because iOS would otherwise stop a broadcast
  running with the screen off. The app never records a broadcast.
- **Reminders and the lock screen.** A broadcast you forget asks "Still broadcasting" after 30 minutes without a
  listener or two hours on the air, and stops five minutes later if nobody answers. Its notification never shows a
  name or a title; a locked device shows only "Broadcasting audio".

## On a Mac

The Mac app advertises and connects like the iPhone, with these differences:

- On a Mac, MeshLive's Bluetooth advertisements and connections come from the Mac's fixed Bluetooth hardware
  address. macOS gives apps no way to change it, so anyone scanning nearby can recognise this Mac over time, even though its
  discovery ID rotates (that hides which MeshLive identity it is, not that it is the same Mac). Turn off Allow
  calls or quit MeshLive when you do not want to be recognisable. The experimental Settings › Desktop switch
  "Reachable only while the window is open" shortens the time it is on air: no call announcement while every MeshLive
  window is closed, minimised or hidden.

- macOS may expose the Mac's **system Bluetooth name** (System Settings > General > About > Name) to devices that connect. Use a neutral computer name.
- The Mac keeps discovery running while the app is open, including when its window is in the background, so it stays
  visible to nearby phones until you quit it (or close its windows, unless "Keep running with windows closed" is on).
- The first Bluetooth connection to some phones can show a system pairing prompt on both devices. MeshLive itself does
  not need pairing; the prompt appears to come from macOS itself reading the phone's device name. Accepting it stores a normal system
  Bluetooth pairing.
- Generated nearby names show two-word names derived from public rotating
  announcements; they are not verified identities.
- In an audio-only broadcast, Pause turns the Mac's microphone off and Resume turns it on again.
- Before video, the Mac reads which band its Wi-Fi connection uses (2.4, 5 or 6 GHz) to suggest a faster setting. It
  never reads the network's name, asks for no location access, and sends the band nowhere.

## Security model and limitations

The security model, scope and known limitations are in [SECURITY.md](../SECURITY.md). Report vulnerabilities
privately as described there, never in a public issue.
