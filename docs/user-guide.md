# User guide

MeshLive makes voice and video calls and live streams between nearby devices over Bluetooth, with no internet, SIM
or account. This guide covers the iPhone app and the experimental native Mac app. Both are **early**: read the
[download and status table](../README.md#download) before relying on them.

## Install

**iPhone:** install MeshLive from the [App Store](https://apps.apple.com/app/id6834136798) (listed as "MeshLive: Live
Video & Calls"; it needs iOS 17 or later). Updates come from the App Store.

**Mac:** the native Mac app is coming soon to the Mac App Store. Until then, and for your own iPhone build, build it
yourself on a Mac:

1. Install Xcode 26 or later and Python 3.
2. Get the source: `git clone https://github.com/MeshLive/meshlive-apple.git`.
3. Follow [Building from source](dev/building.md): prepare the pinned codecs, generate the Xcode project, then
   - **iPhone:** open `MeshLive.xcodeproj`, choose your Apple developer team (a free personal team works) and
     run the **MeshLive-iOS** scheme on your iPhone (iOS 17 or newer);
   - **Mac:** build and run the **MeshLive** scheme (Apple Silicon, macOS 14 or newer; no account needed).
4. On first launch, read the terms and tap **Agree and continue**, then tap **Continue** once. The app asks for
   Bluetooth, the microphone and notifications one at a time; the camera is asked for the first time you use video.
   If you say no to one, the app still opens.

To update a build of your own, pull the latest source and build again. Your identity and contacts stay on the device.

## Features

- **Live video broadcast.** Stream your camera (VP9 video, mono Opus audio) to nearby devices. Pause, resume and stop
  with authenticated state. Manual video settings choose the resolution, frame rate and bitrate; the app shows what you
  asked for and what is sent, and never changes your choice silently. iPhones and Macs encode VP9 in software and play
  VP9, and AV1 on devices with a hardware AV1 decoder.
- **Relay chains.** A viewer can pass the stream on to one more device ("Relay video for others": experimental and off
  on iPhone and Mac until it has been tested on devices, and its row is hidden in this build; it pauses itself below
  20 % battery when not charging and in Low Power Mode). Each device talks only to the device it receives from and the
  one it passes to, and the viewer checks that the stream really comes from the original source. If a stream drops,
  the viewer looks for it again, also through other devices.
- **Private calls.** Voice or video calls between two devices, started from the list of people nearby or from
  Contacts. Both directions are independent; Mute, Camera and Flip only affect your own side. When the other person's
  picture has a very different shape from your screen, the whole picture is shown with black bars; double-tap their
  video to switch for that call.
- **Two Bluetooth transports.** LE GATT (the default, needs no pairing) and LE L2CAP CoC (experimental). Discovery is
  always Bluetooth LE. iPhones and Macs cannot use Bluetooth Classic.
- **Authenticated and encrypted.** Every device has its own signing key. Links use signed handshakes and ordered
  AES-256-GCM records, with a second end-to-end layer so a device in the middle cannot read or alter your media. Scan
  each other's code in person, or compare the safety code in a call, to verify a contact.
- **Voice calls** (hold Mute to talk, like an intercom), with a ringing tone while the other device rings and, on an
  iPhone, the camera pausing while the phone is at your ear. Calls ring while MeshLive is open (on a Mac, while it
  runs); a closed app cannot ring.
- **Experimental: calls through other devices** (Settings > Advanced > Experiments).
- **Names and titles.** An optional name (Settings > Your name) and an optional stream title on Go live. Your name is
  never broadcast: it goes, encrypted, only to the people "Who sees my name" allows. A stream title is public:
  everyone nearby can read it.
- **Audio-only live (radio).** Go live with sound only: announcements, an event, a neighbourhood channel. It uses a
  fraction of the Bluetooth capacity of video, reaches more devices, and keeps playing with the screen off. Choose it
  from Go live.
- **Privacy by default.** Rotating Bluetooth IDs, hidden identities in the call handshake and a temporary identity
  toward people you have not verified are always on.
- **Delete everything.** Delete the app's keys and data from inside the app (type DELETE to confirm; an optional
  triple-tap gesture).
- **No tracking.** No account, no ads, no analytics, no internet connection for media.

Not on iPhone and Mac yet: moving a call to a new Bluetooth link, hardware video encoding, store-and-forward messages,
and going live or passing a stream on with changing IDs. Sharing the app with a nearby phone is not possible on iPhone and Mac.

## Use the app

The app has four tabs (on the Mac, a sidebar): **Live**, **Calls**, **Contacts** and **Settings**.

- **Calls:** people nearby appear under Nearby. Tap a person, then Voice call or Video call; touch and hold (Control-click on a Mac) for Call, Add contact, Block and Report. If more than one nearby phone shows the same ID, the row says so and a call asks first. While their phone rings you hear ringing, and an iPhone at your ear pauses your camera in a video call. If nobody is listed, Search again looks once more. Recent shows how each call ended; someone you did not save cannot be called back, but you can add them as a contact. While muted, press and
  hold Mute to talk. **Recent** lists your last calls on this device only: it is not backed up or moved to a new
  device, and only verified contacts can be called back from it. If camera access is off when you answer or place a
  video call, it goes on as a voice call and says so. If the camera or microphone is refused in a way you must fix, the
  call keeps ringing or is not placed, says what is missing, and offers Open settings when Settings can change it.
- **Video settings:** Settings > Advanced > Manual video sets the resolution (240p, 360p or 480p), frame rate and
  bitrate your calls and broadcasts ask for. The other device, a route through other phones, a hot device or a slow
  link can send less; during a video call, the call info (the lock) shows what you asked for and what is sent now.
  With many people nearby, Calls shows a search field.
  If your phone (or Mac) gets too hot, video stops: a call goes on with sound only, a video live ends, and new video
  can start again once it has cooled down. You can still make and answer calls; they start as voice calls. With Manual video settings on, a call over Bluetooth LE starts at no more
  than 180 kbps (GATT) or 200 kbps (L2CAP); Settings > Advanced > Connection shows what the next call will send. In a
  call, double-tap the other person's video to switch between filling the screen and showing the whole picture.
- **Live:** streams from people nearby. **Go live** shares your camera and microphone, or audio only, with everyone
  around you. Calls and broadcasts have one row of round buttons with the red End in the middle. A call: Mute, Camera,
  End, Flip, Speaker (Flip works once the camera is on; with headphones or a Bluetooth headset, Speaker opens the list of
  where the sound can play). A video live: Mute (your sound stops, the video goes on), Camera (your picture stops, the
  sound goes on), End, Flip, Pause. **Audio only** opens its own screen: add an optional title, pick Voice, Low data or
  Music and tap Start; watch the level meter and the listener count. Mute sends silence, Pause sends nothing, End stops,
  and Switch to video ends the radio and starts a video live with the same title. The first time, the app tells you that
  anyone nearby with MeshLive can listen. A reminder asks after 30 minutes without a listener or two hours on the air,
  and the broadcast stops five minutes after an unanswered reminder. Listening to a radio shows the title, the route, a
  sound meter, Mute and Stop.
  If the stream drops, the app keeps the last picture and looks for it again, also through other phones, until it is
  back or you leave. Ending a live while people watch asks first. A stream this device cannot play says so in the list.
  With Relay video for others on, relaying pauses below 20 % battery when not charging and in Low Power Mode. A stream
  whose broadcaster cannot be confirmed can be hidden from its info (the lock): "Hide this livestream".
- **Contacts:** Add contact has two sides, Scan their code and Show my code. Stand together, show your code, scan
  theirs, and answer "Is this <name>'s screen?" only when it is the phone of the person in front of you. A code works
  once and for five minutes; no call is needed first. If the camera is off, restricted or unavailable, Scan their code
  explains which and offers Open settings when it can be changed; the scanner never opens behind a blocked camera. The question also asks "Let <name>'s phone recognise yours
  nearby" (on by default): leave it on so you can call each other from Contacts; turn it off to stay unrecognised (you
  can still call from Nearby), and you can change it later with "Can see when I'm nearby" on their contact sheet (until
  you answer one of the two, it is off). When
  you have both scanned and both allowed it, your phones recognise each other, Add contact says so and offers Call now
  for a minute, and you can call from Contacts. Comparing the safety code during a call still works, as "Checked by code". Verified
  contacts show by their saved name.
  Tap a contact for its sheet: Rename, Block or Unblock, Report, Forget, and Scan to confirm for someone you only
  checked with the safety code. If they now call themselves something else, the sheet offers "Use it as my label"; it
  never changes the name by itself. When your phone cannot recognise a contact yet, the list says "Ask them to scan
  your code too" (or "Scan each other's codes again"): open Add contact together and scan each other's code.
- **Names:** Settings > Your name is the one name others see; "Who sees my name" (people you call or who call you, only
  your contacts, or nobody) decides who receives it. It is sent encrypted inside the call, never broadcast (a stranger you call gets it only after they answer and their phone proves who it is, and never if you blocked them), and your QR
  code carries it unless you chose Nobody. A name someone gave themselves shows with a tilde, "~Rahul": they said it and nobody checked. Your
  own name for a contact always wins. People whose name you cannot see show a made-up name such as "Blue Otter".
- **Blocking:** Settings > Privacy > Block unknown callers (off by default) declines, without ringing, every call from
  someone who is not a verified contact; it shows in Recent as "Blocked call". Blocked people lists everyone you
  blocked and unblocks them. Block from a Recent row (press and hold; Control-click on a Mac), from a contact, with
  "Decline and block" on an incoming call, or from the radio listener. A blocked person's calls are declined, their live
  streams and radio are hidden from the list (a copy another phone relays can stay listed, because the list only knows
  who sends a stream it hears directly; opening it stops it as soon as the app knows who is sending it), and your device
  relays nothing for them. Strangers call under a one-time ID, so for
  strangers use Block unknown callers; if a stranger turns out to be someone you blocked, the call ends within a few
  seconds without your camera or microphone having been on. **Report** blocks and hides on your device and offers
  "Tell MeshLive", an email draft to meshlive.dev@gmail.com with the subject "MeshLive: report a concern". A blocked
  contact may notice: your name no longer appears while it rings, and your phone stops being recognisable to them
  nearby (your other contacts recognise your phone again after your next call with each of them). If you answer a
  stranger who turns out to be someone you blocked, answering has already shown them who you are, and your name if
  "Who sees my name" allows it; the call then ends within a few seconds without your camera or microphone having been
  on. If you call someone who turns out to be someone you blocked (by the ID their phone shows, or when a stranger's
  phone proves who it is), your name is not sent, your camera and microphone stay off, and the call ends within a few
  seconds like any call that is not answered. If the saved block
  list can't be read, Privacy and Blocked people show "Block list can't be read" with Reset: until you reset it nobody
  is blocked and calls ring as usual, and Reset unblocks everyone so you can block people again.
- **Settings:** Your code, your name (and Who sees my name once a name is set), Allow calls,
  Video quality (fill the screen, temperature, lower quality when hot, and a warning when a stream's picture freezes),
  Privacy (Show names on lock screen, triple-tap to delete everything, Block unknown callers, Blocked people, Reset
  private ID), on the Mac a Desktop card (keep running with windows closed, menu bar, start at login, keep the Mac
  awake), Advanced (Connection, which also shows what the next call and broadcast will send; Manual video;
  Experiments, including Relayed calls; and Help and feedback with Export diagnostics), About (version, the commit it
  was built from, Privacy policy, Terms of use and Open-source licences), Contact us, and **Delete everything** (type
  DELETE). On the Mac, Cmd+, opens Settings.
- **Status:** the dot at the end of each title shows whether the device is ready; when something needs you it adds
  a word such as "Bluetooth off" or "Hidden". "Calls unavailable" means Bluetooth stopped responding, so nobody can call
  you: turn Bluetooth off and on (restart the device if that does not help). Tap the word for the Status sheet.

Keep the app open and in the foreground on an iPhone: iOS stops Bluetooth advertising for apps in the background,
so other phones cannot find a backgrounded iPhone, and there are no incoming calls while the app is closed. The Mac
app keeps working with its window in the background until you quit it.

## Talking to Android phones

MeshLive for iPhone and Mac speaks the same protocol as
[MeshLive for Android](https://github.com/MeshLive/meshlive-android) and, since November 2026, uses the same privacy
defaults: rotating nearby IDs, hidden identities and a temporary ID toward people you have not verified are always on.

- Android phones list iPhones and Macs while their Settings > Advanced > Connection switch **Find iPhones** is on
  (the default).
- Calls work both ways with an Android phone on its default settings: short voice and video calls between an iPhone,
  a Mac and an Android phone worked in November 2026. An Android phone with default settings may not appear under
  Nearby on an iPhone or Mac until you are contacts: add each other in Contacts > Add contact (scan each other's
  codes), then call from Contacts. The Android phone can always call you.
- Live streams and radio from a default Android phone use changing IDs. An iPhone or Mac joins them with a changing ID
  of its own, so joining does not show the device's fixed ID; it cannot yet pass such a stream on to another device.
  Joining one has not been tried on an iPhone or Mac yet.

Please report what happens (see below).

## FAQ

**How far does it reach?** Bluetooth reaches roughly 10 to 30 metres between two devices, less through walls and
people. Video is small because Bluetooth is slow.

**Why does my Mac ask about Wi-Fi before video?** Wi-Fi on 2.4 GHz shares the radio with Bluetooth and can make video
slow. Before a video call, a video live or watching, the Mac app suggests a 5 GHz network or turning Wi-Fi off, at
most once a day. It reads only which band the Wi-Fi uses, never the network's name, and asks for no location access.
The iPhone cannot read the band.

**Does Pause turn the microphone off?** On a Mac, yes: Pause in an audio-only broadcast turns the microphone off and
Resume turns it on again. On an iPhone the microphone stays on while paused so the broadcast can go on with the screen
off; nothing is sent while paused.

**Is it private?** Calls and streams are encrypted end to end, but a nearby Bluetooth scanner can see that a
MeshLive device is there. See [Privacy](privacy.md).

**Is it on the App Store?** The iPhone app is:
[MeshLive: Live Video & Calls](https://apps.apple.com/app/id6834136798). The Mac app is coming soon to the Mac App
Store; build it from source meanwhile. See [Devices](devices.md) for what has been tested.

**Can an iPhone call a Mac?** Yes. Short voice and video calls between an iPhone 12 and a Mac worked both ways in November 2026.

## Contact us

- Something did not work: the [bug form](https://github.com/MeshLive/meshlive-apple/issues/new?template=bug_report.yml).
- To help us find a problem, add an **Export diagnostics** text (Settings > Advanced > Help and feedback). You see the
  whole text first; it has no names, IDs, messages or media.
- It worked, or partly worked, on your device: the
  [device test report](https://github.com/MeshLive/meshlive-apple/issues/new?template=device-report.yml).
- A security problem: report it privately as described in [SECURITY.md](../SECURITY.md), never in a public issue.
