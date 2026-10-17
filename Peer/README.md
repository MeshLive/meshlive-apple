# MeshPeer: a macOS Bluetooth test peer (experimental, not part of the app)

MeshPeer runs the iPhone app's protocol core (`Sources/NearbyCore`) and its CoreBluetooth radio
(`App/Transport/MeshRadio.swift`, `MeshLinks.swift`) as a command-line tool on a Mac with Bluetooth. You can use it
to try interop with Android phones before an iPhone is available. macOS has the same advertising limits as iOS:
service UUIDs and a local name only, so the Mac announces itself with the iPhone compact UUID.

Media is stubbed. There is no camera, no microphone and no Opus encoder. Calls are voice calls that carry the
call signals, the stream header and the Opus configuration packet, but no audio frames. That is enough to test
discovery, the link and end-to-end handshakes (BMH2 or BMH3), rotating-ID openings, the pseudonym reveal and
ringing/accept/hang-up.

## Build

```sh
bash ~/MeshLive/buildlock.sh swift build --scratch-path .build/swift --disable-sandbox --product MeshPeer
peer=$(swift build --scratch-path .build/swift --disable-sandbox --product MeshPeer --show-bin-path)/MeshPeer
$peer help
```

`Peer/Info.plist` (with the Bluetooth usage text) is embedded in the binary (`__TEXT,__info_plist`), so macOS can
ask for permission.

## One-time Bluetooth permission (needs the Mac's screen)

macOS asks once, on the screen, before any app or tool can use Bluetooth. The question cannot be answered over SSH.

1. Sign in to the Mac's desktop. Open **Terminal** there (not an SSH session) and run `$peer scan --seconds 10`.
2. macOS shows "“Terminal” would like to use Bluetooth" (or names MeshPeer). Click **Allow**.
3. If no prompt appears, open **System Settings > Privacy & Security > Bluetooth** and turn on Terminal (or
   MeshPeer). The `bluetooth:` lines then stop saying "unauthorized".

macOS records the permission for the app that started the tool. A run started over SSH may still be refused (its
parent is `sshd`). In that case start the runs from Terminal on the Mac's desktop, or with `Scripts/gui-run.sh` if
that is set up. Removing the permission later: the same Settings page.

## Android switches

| To test | On the Android phone | MeshPeer |
| --- | --- | --- |
| Android sees or calls the Mac | Settings > Features **"Find iPhones"** (a DEBUG benchmark launch: `test_ios_compact_discovery=true`) | `listen` |
| Mac calls an Android phone with 0.2.0-beta defaults (rotating IDs, Hidden identities, Pseudonymous toward strangers all on) | nothing beyond the defaults | `call --android-defaults` |
| Android calls the Mac with those defaults | "Find iPhones" on | `listen --android-defaults` |
| Plain BMH2 (an older build, or those three switched off on Android) | "Find iPhones" for the Android-calls-Mac direction | no flags |

A DEBUG benchmark launch of the Android app reads only its extras: `test_rotating_ids`, `test_bmh3`,
`test_bmh3_pseudonyms` and `test_ios_compact_discovery`.

## Commands

```sh
$peer scan --seconds 20                                  # every MeshLive advert nearby, decoded
$peer listen --android-defaults --seconds 20             # answer the first call, hang up 20 s after it is active
$peer call --to first --android-defaults --seconds 20    # call the first call offer seen (or --to <12-hex prefix>)
```

`--transport l2cap` advertises LE CoC instead of GATT. The default identity is a software P-256 key in
`~/MeshLive/peer-identity.key`; it keeps the same node prefix across runs. Every event is printed as a `peer:` line,
and the radio prints the app's `BENCHMARK` lines. Redirect the output to `~/MeshLive/logs/peer-<date>-<case>.log`.
Use only phones assigned to the run.
