# Architecture

How MeshLive for iPhone and the native Mac app are built. Wire formats are in the [protocol notes](protocol.md) and,
canonically, in the [Android protocol reference](https://github.com/MeshLive/meshlive-android/blob/main/docs/dev/protocol/README.md).
Behaviour switches are in the [switch register](switches.md).

## Where the code is

| Path | Contents |
| --- | --- |
| `Sources/NearbyCore` | Android protocol: BMH2, BMS1/BME1, BMC2, BTV3, BMV1/BFG1, discovery, GATT chunks, identity verification. Also the sans-I/O `CallEngine`, `StreamViewerEngine` and `StreamSourceEngine`, audio playout and VP9/AV1 bitstream parsing |
| `Sources/NearbyMedia`, `Sources/CNearbyVPX` | libvpx VP9 encoder/decoder bridge, VideoToolbox VP9/AV1 decoding, pixel conversion |
| `App/` | SwiftUI app shared by iPhone and Mac: `MeshRadio` (Core Bluetooth), links and driver, Opus audio, camera, identity/Keychain/wipe, screens |
| `Desktop/` | native macOS app: app delegate and window lifecycle, camera picker, reading size, entitlements, Info.plist |
| `Desktop/Support` | Mac-only policy compiled into both the app and the `DesktopSupport` package target: Android compatibility, rotating advertising scheduler, generated names (`Names/`), delivery feedback, call scanning, connection timer, video layout, legacy Keychain cleanup |
| `Peer/` | MeshPeer, a macOS command-line test peer built from NearbyCore and the app's radio files ([Peer/README.md](../../Peer/README.md)) |
| `Tests/`, `UITests/`, `MacUITests/` | package tests (core, media, desktop policy, native transport, v1), simulator UI tests and native Mac UI tests |
| `Design/` | `design-tokens.json`, copied from Android and turned into `App/UI/DesignTokens.swift` by `Scripts/tokens.py` |
| `Scripts/` | build, codec preparation, project generation, test and device-run scripts |
| `Vendor/` | licences of the pinned third-party code (the built XCFrameworks are ignored) |
| `Interop/` | reviewed discovery addendum and the Android vector generator (`android-vectors/`); `java/` is the v1 reference |
| `Experimental/` | the default-off standalone v1 app and its protocol |

`Sources/NearbyCore` is sans-I/O: engines take bytes and time and return bytes and events, so the same code runs in
unit tests over in-memory links, in the iPhone app, in the Mac app and in MeshPeer. Only `App/Transport` touches
Core Bluetooth.

`Scripts/project.py` generates `MeshLive.xcodeproj` with two app schemes: **MeshLive-iOS** (the iPhone app, UI tests in
`MeshLive-iOS-UITests`) and **MeshLive** (the native Mac app, UI tests in `MeshLiveUITests`). Both build `MeshLive.app`
with the bundle identifier `io.github.meshlive.app`.

Some internal names keep the project's earlier working name, Nearby Intercom, on purpose:

- the Swift modules `NearbyCore`, `NearbyMedia`, `CNearbyVPX` and `NearbyV1Experimental`, and the `-Nearby...` DEBUG
  launch arguments. They are never shown to users, and renaming them would touch every import for no user benefit;
- the experimental v1 protocol labels (`NearbyIntercom/v1`, `NearbyIntercom SAS v1`), because they are hashed into
  every v1 handshake and test vector, and the v1 Java reference package (`org.nearbyintercom`) that checks them;
- stored identifiers: the Keychain services (`org.nearbyintercom.mesh.v2` and the legacy ones the wipe and the Mac's
  cleanup remove), the unified-log subsystem and queue labels, and the MeshPeer bundle identifier. Renaming them would
  orphan the identity and contacts of existing installs, or make the wipe miss old items.

## Platform limits and missing features

**Impossible or restricted on iOS:** Bluetooth Classic; discovery while the app is in the background (iOS hides the
advertisement); incoming calls while the app is closed (that needs internet push); manufacturer data in adverts (hence
the compact UUID); and hardware VP9/AV1 encoding (the iPhone encodes VP9 in software with libvpx).

**Not implemented yet:** store-and-forward messages, group (BGK1) relays, relay re-anchor and parent-silence recovery,
the route-recovery hint and CallKit. See [testing](testing.md#remaining-work).

## Screens and design

One product on two platforms. Android's design direction (`DESIGN-DIRECTION.md` in the Android project, "Field radio") is the source for the screens, flow, features, wording and brand colours; each app renders them natively. Android uses Material 3; the iPhone follows Apple's HIG: SF fonts with Dynamic Type, inset grouped lists, iOS navigation and sheets, SF Symbols and native controls.

- **Shared tokens:** `Design/design-tokens.json` copies Android's colours, type scale and dimensions. `python3 Scripts/tokens.py` generates `App/UI/DesignTokens.swift`; `--check` fails when it is stale. The look is functional minimal dark: pure black, white text, and red reserved for live state; `Scripts/design-check.py` (run by `Scripts/test.sh`) fails on any other use of red.
- **Components:** `App/UI/Components.swift` is the one component set every screen uses: SF Symbol counterparts of Android's icons, list rows, the status line, primary/secondary/destructive buttons, notices, the empty state, the Live tag and round call controls.
- **Wording:** the same plain words as Android, with no jargon (transport, codec, relay, mesh) outside Advanced and the call's link details: "Allow calls", "Hold Mute to talk", "Couldn't reach ABCDE-FGHIJ - they may have moved away".

Screens (the same tabs and flow as Android's 2026-10-17 redesign; pure black, white text, red only for live, ending a call and Wipe everything):
- **Tabs:** Live, Calls, Contacts and Settings. Each tab has a large title and a status dot (green when Bluetooth is ready); three quick taps on the title ask to erase when the opt-in quick wipe is on.
- **Live:** "Live nearby" streams (the title, else "Live from <name>", and the route in words; audio-only rows have the radio disc and "Audio only") and the white "Go live" capsule with the red broadcast icon. Go live offers "Video and audio" or "Audio only" (Voice, Low data or Music) and, with names and titles on, the optional title. Audio-only streams (experimental "radio", interoperable with Android: `0x40` offer marker, `BTL1` header, every record signed by a per-stream key certified by the source identity) keep playing and broadcasting with the screen off. Watching and broadcasting are full screen.
- **Calls:** Nearby and Recent chips. Nearby rows show contacts by their saved name with a check mark, everyone else by full handle; a row opens "Call <name>" with Voice call and Video call.
- **Contacts:** your verified contacts with video call, voice call and info buttons, and "Add contact" (your code and scanning theirs). The info sheet shows how and when you verified them, the short and full ID, "Can see when I'm nearby" (rotating IDs) and Forget. Android's Rename and Block have no iPhone counterpart yet.
- **Call:** always dark. One name line and a state line or timer. Encryption, route, verification and the safety code are in the info sheet behind the lock; only an identity mismatch shows loudly. There is no push-to-talk mode: while muted, press and hold Mute to talk, with a one-time hint. A short message appears only when the phone is hot or the battery is at 20 % or less.
- **Settings:** grouped cards: Your name and Your ID; Allow calls, Call alerts, Relay live streams and Privacy (quick wipe, names and titles, then Advanced privacy: rotating IDs, hidden identities, pseudonyms, mismatch policy); Advanced (Connection, Experiments); About this app; and the red Wipe everything (type WIPE to confirm).

Every screen reads names through `PeerLabel`, following the naming review (R5). It shows your verified contact's saved name; otherwise a signed self-chosen name in quotes (experimental labels); otherwise the full handle. It never uses advertised device names or raw hex. The handle is Crockford Base32 of the 48-bit prefix (`M6SC7-N75YR`).

## The native macOS app

The **MeshLive** scheme builds a sandboxed macOS 14+ app for Apple Silicon from the shared `App/` sources plus
`Desktop/`. It shows the same Live, Calls, Contacts and Settings screens in a sidebar with a detail pane, menu
commands and keyboard shortcuts: Cmd-1 to Cmd-4 select Live, Calls, Contacts and Settings, Cmd-G opens Go live,
Cmd-comma opens Settings and Cmd-0 reopens the main window; in the call chooser Cmd-Shift-A picks Voice call and
Cmd-Shift-V picks Video call.

- **Transport:** the same CoreBluetooth central and peripheral code as the iPhone. The Mac's connection driver uses
  `DesktopConnectionTimer` in the common run-loop modes so menus, mouse tracking and modal panels cannot pause
  heartbeats.
- **Lifecycle:** discovery and media keep running when the app is deactivated (there is no iOS-style background
  path). Keep running with windows closed is optional and off by default. Quit ends local media and closes links;
  sleep can interrupt them.
- **Media:** Opus is built for macOS arm64 separately from the iOS XCFramework; VP9 uses
  `Vendor/VPX-macos.xcframework`. The camera picker accepts built-in and external cameras (not Continuity Camera),
  and a disconnected explicit choice never silently falls back to another camera.
- **Received video:** `DesktopVideoLayout` maps BTV3's clockwise display angle to AppKit coordinates.
- **Sandbox:** five entitlements (app sandbox, Bluetooth, camera, audio input, user-selected read-only files); no
  debugger-access entitlement in Release.
- **Preview:** the DEBUG-only `-NearbyPreview` argument runs the UI with an ephemeral identity, isolated preferences
  and no radio or media, for UI tests and screenshots. It is absent from Release builds.
- **Mac-only experiments** (Android compatibility, generated nearby names, delivery-based video adaptation, pausing
  discovery during calls) live in `Desktop/Support` and are off by default; see the [switch register](switches.md).

## Diagnostics and remote testing (DEBUG)

- `AppLog` writes Android-style `BENCHMARK <event>: k=v | ...` lines to the app's Documents/logs: permissions, audio session and route, discovery, connect stages, call phases, authentication and codec, call_stats every 5 s (captured/encoded/sent and received/decoded/played counts), rate changes, and the end reason. They contain no keys, text or media.
- Launch arguments (`App/Diagnostics/Automation.swift`) run a call without touching the phone: `-NearbyAutoCall <handle>`, `-NearbyCallType voice|video`, `-NearbyCallSeconds N`, `-NearbyAutoAccept voice|video` and others.
- `Scripts/gui-run.sh install` builds, signs, installs and launches through the logged-in GUI session (`Scripts/device-gui.command`), because SSH sessions cannot use the login keychain. `Scripts/run-scenario.sh call|answer` runs a scenario over SSH, and `Scripts/pull-logs.sh` copies the logs. `Scripts/screenshots.sh` takes simulator screenshots. `Scripts/gui-run.sh uitest call|people` runs the XCUITest scenarios (`UITests/`), with a screenshot at each step.
