# Wire protocol: iPhone notes

The canonical specification is [meshlive-android protocol reference](https://github.com/MeshLive/meshlive-android/blob/main/docs/dev/protocol/README.md). This file summarises what the iPhone implements and the iPhone-only parts.

The iPhone app speaks the Android app's protocol. The Android repository's protocol reference (`docs/dev/protocol/`) is authoritative. iPhone discovery uses the reviewed [addendum A](../../Interop/ANDROID_DISCOVERY_ADDENDUM.md); Android ships it behind `test_ios_compact_discovery` ("Experimental: find iPhones"), off by default. This file records the byte layouts as implemented in `Sources/NearbyCore` and checked against vectors produced by Android's own classes ([Interop/android-vectors](../../Interop/android-vectors/README.md)). Where this file and Android differ, Android wins and this file is a bug.

All integers are big-endian unless noted. Every parser is strict: wrong magic, length, version, type or trailing bytes fail closed.

## Discovery

| Item | Value |
| --- | --- |
| Android advertising data | 128-bit service UUID `C8D5A101-9F88-4F65-A03D-7F5A2FB921FA` |
| Android scan response | manufacturer data, company `0xFFFF`, 22-byte announcement |
| iPhone advertising | one 128-bit compact-announcement UUID (magic `0xC8D6`, addendum A) + local name of at most 8 bytes; one kind at a time, a pending viewer request beats call availability (review R5) |

22-byte announcement (version 2): `version 02 | nodePrefix 6 | flags 1 | capabilitySummary 1 | streamToken 4 | routeCost 1 | (sequence 1, width 2, height 2, fps 1 | or recoveryPrefix 6 when flags bit 7) | bitrateKbps 2`. Flags: 1 accepting connections, 2 relay capable, 4 stream available, 8 GATT transport (else LE CoC), 16 Classic, 32 stream paused, 64 private call available, 128 route recovery. Stream-offer `sequence`: bit 7 source full, bits 6..0 capacity generation. Route token = logical token (1..2^31-1) XOR FNV-1a-32 over `UTF8("bluetooth-video-route-v1") || prefix`, with bit 31 forced to 1. A viewer request copies the offer's route token. Announcements are unauthenticated hints; identity comes from BMH2.

Roles: a private-call callee and a stream **viewer** are peripherals (they advertise and accept); a caller and a stream **source** are centrals. iPhones act in both roles. iPhones scan without a service filter in the foreground (compact UUIDs differ per device) and parse both forms.

## GATT database and links

| UUID | Role |
| --- | --- |
| `C8D5A101-…` service, `C8D5A102-…` read | LE CoC: 2-byte big-endian PSM (dynamic; iPhone publishes with `publishL2CAPChannel(withEncryption: false)`, Android uses insecure CoC) |
| `C8D5A105-…` service | GATT data service |
| `C8D5A103-…` | central → peripheral, write and write-without-response |
| `C8D5A104-…` + CCCD | peripheral → central, notify; subscription admits one central |

LE CoC carries the byte stream directly. GATT carries it in chunks: each ATT value is `0x01 | u32 chunkSequence | payload`, sequences start at 0 per direction, payload = min(MTU-3, 512) - 5. Values starting `0x02` are ignored; duplicates are ignored and up to 4,096 early chunks are held for reordering (Android `GattBytePipe`). The iPhone writes without response, honouring `canSendWriteWithoutResponse`, and notifies honouring `updateValue` back-pressure.

## BMH2 handshakes

Link handshake on the raw stream: the initiator (central) writes `u32 length | hello`, the responder verifies it and answers the same way (length 1..2048). The endpoint handshake repeats the exchange inside BMS1 type 4 records with the end-to-end domain.

Hello: `"BMH2" | role (1 initiator, 2 responder) | nodeId 16 | u16 len + identity SPKI DER | u16 len + ephemeral SPKI DER | nonce 32 | capabilities 7 | u16 len + DER ECDSA-SHA256 signature`. The signature covers `context || hello-without-signature`; contexts are `BluetoothVideoMesh/LinkHandshake/1` and `BluetoothVideoMesh/EndToEndHandshake/1`. NodeId = SHA-256(identity SPKI)[0:16]. Keys: ECDH(P-256 ephemerals) x-coordinate; salt = SHA-256(initiatorNonce || responderNonce); info = `BluetoothVideoMesh/LinkSession/1` (or `…/EndToEndSession/1`) || SHA-256(initiatorHello || responderHello); HKDF-SHA-256 → 64 bytes: initiator→responder key, then responder→initiator key.

Capabilities: `version 01 | transportMask | encodeCodecMask | decodeCodecMask | u16 maxBitrateKbps | maxChildren`. Transport bits: 1 Classic, 2 LE CoC, 4 GATT, 64 call relay (link hello), 128 call video fragments (endpoint hello). Codec bits: 1 VP9, 2 AV1; decode-mask bit 128 "prefer VP9" (end-to-end call hellos). Each side requires the peer's link hello to sign the transport actually in use. The iPhone signs encode VP9 (libvpx) and decode VP9 (+ AV1 where VideoToolbox has hardware AV1), maxBitrate 1200 (CoC) / 1100 (GATT), maxChildren 0.

The iPhone identity is a P-256 key in the Secure Enclave (Keychain software key where none exists). CryptoKit's SPKI encoding is byte-identical to Java's, so node IDs and fingerprints match Android's.

## BMS1 hop records and BME1 endpoint content

BMS1: `"BMS1" | type | u64 sequence | u32 ciphertextLength | AES-256-GCM(ciphertext || 16-byte tag)`, the 17-byte header is the AAD, nonce = `00000000 || u64 sequence`, exact next sequence per direction. Types: 4 endpoint handshake, 5 endpoint content, 6 heartbeat, 7 mesh envelope, 8 group control, 9 route withdrawal, 10 withdrawal ack (11 store-and-forward is rejected).

BME1 (inside type 5, or inside a mesh envelope): `"BME1" | contentType | u64 sequence | flags | u32 ciphertextLength | ciphertext+tag`, header as AAD, endpoint keys; increasing gaps allowed, replay/reorder rejected. Content types: 1 stream header, 2 media packet, 4 lifecycle (`LIVE 1`, `PAUSED 2`, `ENDED 3`), 5 keyframe request (empty), 6 private-call signal, 7 group key / forwarded-stream grant, 8 terminal ack (empty), 9 call video fragment (only if advertised). Only media/fragments may carry flags.

Heartbeats (type 6): `01` liveness; version 2 `02 | u16 arrivalKbps | flags | u16 addedDelayMs` (6 bytes); version 3 adds `u32 receivedMediaBytes | u32 linkClockMs` (14 bytes, flag bit 1 delivery-only). A call endpoint sends one `01` after the endpoint handshake to announce it accepts version 3; the iPhone sends version 3 only to a direct call peer that sent that `01`, otherwise version 2, every second. Stream viewers send `01` every 2 s. Silent-link timeouts: call 8 s; stream 8 s (CoC) / 6 s (GATT).

## Calls (BMC2)

Signal payload (23 bytes): `"BMC2" | signal | callId 16 | reason | relayHops`. Signals: 1 invite, 2 ringing, 3 accept, 4 decline (reason 1 rejected, 2 busy, 3 unsupported), 5 cancel, 6 hang-up (4 normal, 5 error), 7/8 camera off/on, 9/10 microphone muted/unmuted. Only Invite carries relay hops.

Sequence (caller = link and endpoint initiator): both sides send heartbeat `01`; caller sends Invite (voice call: Invite then Camera off); callee replies Ringing; on Accept (voice answer: Accept then Camera off) each side sends its BTV3 header (with Opus), then the Opus configuration packet, then media. A remote header moves the call to active. The header codec must be in the sender's signed encode mask and the receiver's decode mask; the sender chooses a codec the peer decodes (VP9 preference bit first). Push-to-talk: holding sends Microphone unmuted, releasing sends Microphone muted; muted audio is not sent. Video fragments (type 9: `u32 total | u32 offset | chunk`, 2,048-byte chunks for packets over 3,072 bytes, only audio may interleave) are an Android experiment: the iPhone supports them but keeps them off by default.

## Streams (BTV3, BMV1, BFG1)

BTV3 header (15 bytes): `"BTV3" | u16 width | u16 height | fps | codec (2 VP9, 3 AV1) | rotation quarter-turns | audioCodec (0 none, 1 Opus) | u16 sampleRate (48000) | channels (1)`. Media packet: `i32 payloadLength | flags | i64 ptsMicroseconds | payload`; flags 1 codec config, 2 keyframe, 4 display rotation (1-byte quarter-turns payload), 8 audio, 32 discontinuity, 64 audio pair/batch, 128 discardable. The inner flags must equal the BME1 header flags. Audio: raw 20 ms Opus packets at 48 kHz mono; the first audio packet is a codec configuration carrying a 19-byte `OpusHead` (Android may send `AOPUSHDR` blocks; the iPhone ignores either). Pairs `"BTA1" | i32 delta | u16 len + unit | u16 len + unit` and batches `"BTA2" | count 3..20 | (i32 delta | u16 len + unit)*` are split on receipt. Audio and video share one monotonic microsecond timeline.

Viewer (link and endpoint responder): if the source's link hello signs `maxChildren > 1` (BGK1 group relay) the iPhone refuses. If the endpoint signs `maxChildren > 0` it is a viewer-forwarder: the next record is a type-7 content holding `"BFG1" | sourceNodeId 16 | streamId 16 | mediaKey 32`, and media arrive as mesh envelopes opened with that key. Mesh envelope (BMS1 type 7): `"BMV1" | streamId 16 | sourceNodeId 16 | u64 sequence | ttl | flags | u32 length | sealed BME1`; source must match, sequence strictly increases, duplicates rejected. The viewer sends keyframe requests and heartbeats, answers ENDED with a terminal ack and a route withdrawal (type 9, `01` local capacity) with a type-10 ack. Source (link and endpoint initiator): header first, then config/media; direct BME1 records, or mesh envelopes (TTL 8) when the viewer signed `maxChildren` 1; pause clears queued media and repeats PAUSED every 2 s; end sends ENDED and waits up to 2 s for the ack.

## Identity verification and wipe

Fingerprint = SHA-256(identity SPKI), shown as 16 groups of four hex digits. Safety code: `h1 = SHA-512("BluetoothVideoMesh/IdentityVerification/SafetyCode/2" || fp)`, `h(i+1) = SHA-512(h(i) || fp)` to `h5200`; six 40-bit groups mod 100000 per half; the pair code is both halves sorted (60 digits). QR text: `BVMID1.<64 hex>.<base64url NFC name>`, strict parser. A contact is marked verified only if the scanned/confirmed fingerprint equals one authenticated in this process; a verified contact's prefix with another key refuses the endpoint (configurable to warn). Emergency wipe: pending marker, Keychain items first (identity, contacts key), then files and settings, a second sweep, marker removed only when complete; it resumes on the next launch. Triple-tap on the home title is the panic gesture.

## Media formats used by the iPhone

| Direction | Format |
| --- | --- |
| iPhone → Android video | VP9 profile 0, libvpx real-time CBR, keyframes on demand, portrait 240×426 (calls) / 360×640 (live), 15 fps, rotation 0 |
| Android → iPhone video | VP9 via VideoToolbox (Apple's supplemental decoder, iOS 26.2+) or bundled libvpx; AV1 via VideoToolbox only with hardware AV1 (A17 Pro/M3 and later) |
| Audio both ways | Opus 48 kHz mono, 20 ms, 24 kbps calls / 32 kbps live |

H.264 (addendum B) is a PLAN entry only; the iPhone stays on VP9.

## Peer labels (experimental, naming phase 1)

Off by default on both platforms (iPhone: Settings › Advanced › "Names and titles (experimental)"). Reviewed design: Android `DESIGN-reviewed.md`; vectors: `Interop/android-vectors/GenLabels.kt`.

- **Negotiation:** end-to-end hello transport bit 5 (`0x20`), never in link hellos. A sender writes content type 10 only when both endpoints set it; an opener that did not advertise it keeps rejecting type 10 (fail closed). On stream hops, labels travel only when the link peer is the endpoint.
- **BNL1 label:** `"BNL1" | version 1 | kind (1 name, 2 stream title, 3 call subject) | u16 SPKI length | SPKI | u32 sequence | binding type (1 call, 2 stream) | 16-byte call or stream ID | u8 text length | UTF-8 text | u16 signature length | DER ECDSA P-256 signature`. The signature covers `"BluetoothVideoMesh/Label/1" 0x00 || signed part` and uses the identity key. The receiver checks the signer against the authenticated endpoint (calls) or the grant's source (streams), the binding (the call ID, the grant stream ID, or 16 zero bytes on a direct stream), the signature, and that the text is already canonical.
- **BLB1 container:** `"BLB1" | count 0..3 | (u16 length | BNL1)*`, sent as BME1 type 10. In calls, the caller's container (name and subject) goes before Invite; a callee buffers one container until Invite (R3). The callee's name goes only immediately before Accept, or at Ringing to a verified contact (R1). In streams, one container (possibly empty) goes before the header, at a fixed position. Receivers keep the higher sequence and limit updates (2 s, 8 per minute).
- **Text rules:** trim, collapse whitespace, NFC; at most 32/48/64 UTF-8 bytes (name/title/subject). Reject: Cc/Cf/Co/Cs/Cn/Zl/Zp, more than 3 combining marks, check-mark symbols, handle-shaped text (R6), and scripts outside UTS #39 Moderately Restrictive (Unicode 15.0 Scripts.txt table, `Vendor/UNICODE-LICENSE.txt`).
- **Title pages:** manufacturer payload `03 | route token u32 | digest u16 | index<<4 | count | 1-19 bytes`; never split a code point. They are shown "unconfirmed" until the signed title arrives; conflicting titles show none for 60 s. The iPhone reads them and cannot send manufacturer data.
- **R11:** in a compact call offer (kind 0), bit 18 means "may be relayed" and decodes as capabilitySummary `0x10`. Every other reserved bit still rejects. Vector: `C8D64010-2030-4050-60C0-000000040000`.

## Rotating discovery IDs (experimental, phase 1)

Off by default on both platforms; Android's PROTOCOL "Experimental rotating discovery IDs" and the reviewed design (RV1-RV19) are canonical.

- **ID:** `e = floor(unix / 900)`, `w = floor(e / 672)`, `L_w = HMAC-SHA256(P, "BluetoothVideoMesh/Discovery/Lease/1" 0x00 || u32 w)`, `salt = HMAC-SHA256(L_w, "BluetoothVideoMesh/Discovery/Salt/1" 0x00 || u32 e || role)`, `RDI = SHA-256("BluetoothVideoMesh/Discovery/Id/1" 0x00 || nodeId || u32 e || role || salt)[0:6]`. P is 32 random bytes in the Keychain (this device only).
- **Adverts:** call-ready presence (role 0) only. Compact UUID v2 (version bits `10`, RDI in place of the prefix; every v1 reject rule applies) or Android announcement version 5. With the switch off both are rejected, except that the native Mac's default-off Android compatibility experiment can independently accept them while scanning. A rotating advert is a "Nearby phone": no handle and no contact match before the handshake. Relayed rotating offers are not called in phase 1.
- **Link opening:** call-endpoint link hellos set transport bit 3; when both do, the first hop record each way is exactly one `BDO1` (type 13): `"BDO1" | 01 | count 0..2 | (RDI 6 | epoch u32 | role u8 | salt 32)*`. Anywhere else type 13 is an unknown record. The responder sends only pinned role-0 entries (on air, or off air for less than 60 s); the initiator sends count 0.
- **Caller check (RV15):** a selected rotating advert needs bit 3 and an entry with role 0 whose RDI equals the selected bytes and recomputes from the authenticated link node ID, and the endpoint must be that link peer; a selected fixed advert keeps the prefix check.
- **Clock and rotation:** the RV4 monotonic epoch (tick on a wall boundary or after 960 s of monotonic time; never repeats; a forward pin above 96 epochs for 1 h starts a new generation). At a boundary the iPhone stops advertising for a uniform 1-8 s. The RV8 tarpit delays a stranger's responder hello by `2^(n-6)` s (cap 30 s) per epoch, and an incoming call that rings forgives one.

## Presence leases (experimental, phase 2, with rotating IDs)

- **Keys:** independent random day keys `L_d` in the window `[dayOf(E - 1), dayOf(E) + 27]` (Android "Keys and epochs"), kept in one Keychain item (this device only), never derived from each other; every own salt is keyed by `L_d(e)`.
- **Exchange:** in an answered call between mutual verified contacts, BDX1 `RECOGNITION_OFFER` then `PRESENCE_LEASE` (28 days), real identities only (after both reveals in a pseudonym call). A recognised rotating advert shows the contact's label "seen nearby, unconfirmed", never a check mark. With a held lease the caller tags BMH3 msg1 (`K_tag`), and both sides present real keys.
- **Revocation (a new generation, a whole new key window):** Settings > Advanced "Reset presence key"; turning a contact's "Can see when I'm nearby" off (Verify screen, default on) after it received a lease; forgetting such a contact; "Reset contacts" when any contact received a lease (every contact record, and with it this phone's recognition of former contacts, goes); the RV4 forward-jump recovery. At launch, records of contacts that are no longer verified are dropped the same way (Android `reconcile`).
- **Storage discipline (Android PresenceVault):** a Keychain read error is never taken for an empty vault: the phone advertises from an in-memory window, sends no OFFER, recognises nobody and retries the read, but never writes over the stored vault. A generation floor in the preferences is raised before every revocation, so a revocation that could not be stored, or an older copy, can never bring revoked keys back: a stored vault below the floor is replaced by a fresh window at the next load. A vault that no longer decodes is kept until "Reset presence key" replaces it. Finished lease days are deleted from the store, not just from memory.
- **Reinstall (iPhone-specific):** iOS keeps Keychain items when the app is deleted, but not the app's files (verified contacts) or preferences. The first launch of a fresh install drops every contact record and starts a new generation, so phones that held the old keys recognise nothing. The emergency wipe deletes the vault (and the phase 1 presence key, which earlier builds left behind).

## Relaying (experimental, off by default)

Ports of Android's hop-local relays; each phone acts only on its parent and its direct child.

- **Stream forwarding.** A viewer that joined through a discovered offer signs `maxChildren` 1 in its link hello, so the source sends BMV1 envelopes (`> 1` would select Android's BGK1 group path). After the header, admission compares the relay need, 2 x per-link load, with the relay budget. Per-link load is `(video + 32 + 13 x 8 x (fps + 25) / 1000) x 1.2` kbps. With no relay evidence (cold start, Android e676ae5) the budget is `max(measured, 2 x per-link)`, which admits exactly one child; an unknown offer bitrate admits without a check.
- **Onward offer.** The forwarder advertises a stream offer with the relay bit, route cost + 1, the codec bit, and its own route token (`logical ^ mask(own prefix)`). The iPhone sends it as a compact UUID, so Android children need "Experimental: find iPhones". It connects as central to the child's viewer request, runs fresh BMH2 link and endpoint handshakes as initiator, and sends BFG1 (`"BFG1" | source ID | stream ID | media-open key`, BME1 type 7).
- **Envelope copying.** Bootstrap: the header, the newest 8 codec configs and the latest stream state. Then live envelopes go out with only TTL - 1 changed, in strict sequence order. Until a keyframe, non-key video is skipped while audio and control pass. Child keyframe requests are regenerated upstream. ENDED is acknowledged upstream only after the child (2 s max). A child that stays behind live (2.5 s for 3 s, a 1.5 s growing trend, or 6 s) is withdrawn with `ROUTE_CONTROL` LOCAL_CAPACITY and a 4 s ack wait.
- **Call relay hop.** Downstream first: link initiator to the child (the callee at cost 0, or a relay that signs maxChildren 1 and bit 6), then the callee's offer with relay flag and cost + 1 for one parent (link responder). `END_TO_END_HANDSHAKE` and `END_TO_END_CONTENT` are copied unchanged in order; `LINK_HEARTBEAT` is replaced with version 1; any other record closes the relay. Invite carries hops = route cost (0-4), and relayed calls cap video at 110 kbps. The relayed offer keeps only the codec bits and the relay-consent bit 4 of the child's `capabilitySummary` (mask `0x17`); it clears the dual-listening hint (bit 3, Android d58b604) and the reserved bits, because a relay is single-bearer and the compact encoder rejects other bits. Offers with a rotating ID are not relayed in phase 1. Backpressure follows Android's blocking copy loop: the relay stops parsing one hop's records while 64 KiB of copied records wait for the other hop and resumes below 16 KiB (an LE CoC hop also stops reading, so its credits slow the sender); a hop that holds more than 512 KiB of unparsed input (a GATT peer cannot be slowed) ends the relay instead of buffering without limit.
