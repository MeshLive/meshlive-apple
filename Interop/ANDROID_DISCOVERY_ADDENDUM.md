# Review of the iPhone discovery / H.264 addendum (Android owner, 2026-10-10)

## Verdict

**Section A** is sound. Android implements it behind a default-off switch, with the corrections below. The bit layout sums to 128 bits. All four vectors were recomputed independently in Python and by the Kotlin encoder and decoder.

**Section B** has no bit conflicts, but it is not coded. It is a PLAN entry and needs a PROTOCOL design review on points B2-B6 first.

## Corrections the iOS side must adopt (exact)

- **R1. Codec bits.** Decoders carry codec bits 56..54 into `capabilitySummary` bits 2..0 and accept every value 0..7. Only encoders keep bit 56 at 0 until H.264 is negotiated. Rejecting bit 56 would make a future H.264 iPhone invisible.
- **R2. Exact reject list.** Reject only these cases:
  - wrong magic;
  - version other than 1;
  - kind 3;
  - bit 57 with kind other than 2;
  - kind 0 with any of bits 49..0 set;
  - kind 1 with any of bits 11..0 set.

  Delete "route cost above 15": 4 bits cannot exceed 15. Delete "except route cost/flags/codecs": those are bits 59..50, outside 49..0.
- **R3. Viewer-request tokens.** A viewer request always carries a route token copied from a discovered stream offer. Token 0 (Android's DEBUG direct-receiver mode) is not representable. Decoders set bit 31 for kinds 1 and 2.
- **R4. Bitrate units.** Units = min(floor(kbps / 25), 127), so the bitrate saturates at 3175 kbps. Android's settings (100-1500 kbps in 25 kbps steps) encode exactly.
- **R5. One kind at a time.** The iPhone advertises one kind and restarts advertising when its role changes. A pending viewer request takes precedence over call availability.
- **R6. Host fallback depends on slots, not masks.** AOSP re-checks every filter on the host (`ScanController.matchesFilters`). Each `ScanFilter` takes one controller slot. A scanner with more filters than free slots goes all-pass (`ScanManager.shouldUseAllPassFilter`). A controller with fewer than 10 slots offloads nothing. A controller that accepts the 128-bit APCF mask but mishandles it would drop iPhone results silently. No such OEM bug is documented, and none was found for Samsung, Qualcomm, MediaTek or Exynos. Each phone still needs a physical check.
- **R7. Advertising placement.** Keep the UUID in the foreground advertising PDU; it fits Apple's 28-byte budget. Keep the local name at 8 bytes or less; a longer name moves to the scan response. Controllers may not match a UUID that appears only in the scan response.
- **R8. Android scan counters.** Android counts `compact` and `compactInvalid` in the DEBUG `scan_stats` line. The malformed 22-byte path is not counted today.
- **R9. Android flag name.** The flag is `test_ios_compact_discovery` with the Advanced setting "Experimental: find iPhones". It is not `test_compact_announcement`.
- **R10. Unverified claim.** This review did not verify the 6-8 s stale-sender admission claim.

## Checked and agreed

- **Security.** The trust level equals the forgeable 22-byte form.
  - BMH2 binds the full 48-bit prefix.
  - Route tokens carry 31 bits in both forms: `advertiserMask` sets bit 31 and logical tokens are 1..2^31-1. They are public anyway.
  - A fake announcement only triggers a connection attempt, which the existing auth, admission and overload guards gate.
  - The new decoder is fixed-size integer code.
- **No duplicate entries.** Android's own UUID is `c8d5a101` (top 16 bits `c8d5`), so it never matches the filter. Manufacturer data wins when both are present.
- **Scan quota.** Unchanged: it is still one `startScan`, and the limit of 5 starts per 30 s is per app.
- **Screen-off rule.** A masked filter counts as a filtered scan.
- **Battery.** Each scanner uses one extra controller slot. If slots run out, all-pass wake-ups follow.
- **Backward compatibility.** As stated in the addendum.

## Section B review

- **B1. Bits are free.**
  - `BTV3` uses codecs 2 and 3.
  - The codec masks use bits 0, 1 and 7.
  - The 22-byte `capabilitySummary` uses bits 0 and 1.
  - Transport-mask bits 6 and 7 are in a different byte.
  - Unknown codecs already fail closed.
- **Open before coding:**
  - **B2.** Bit 7 wins if both preference bits are set.
  - **B3.** Accept SPS/PPS either as a config packet or in-band in the IDR.
  - **B4.** No B-frames.
  - **B5.** Accept any profile the decoder supports.
  - **B6.** An H.264-only iPhone fails cleanly against older Android builds.

`[Review Rn/Bn]` marks each change in the corrected text below.

---

# PROTOCOL addendum (proposal, for review): iPhone discovery and optional H.264

Status: design proposal from the iOS owner, 2026-10-10. Nothing here changes BMH2, BMS1, BME1, BMC2, BTV3 framing, BFG1, BGK1 or any record type. Section A changes only discovery hints; section B adds an optional codec behind capability bits. Android ships section A behind default-off `test_ios_compact_discovery` / Advanced setting "Experimental: find iPhones"; section B is a PLAN entry, not coded (future flag `test_h264_codec`). [Review R9]

## A. Compact announcement in one 128-bit service UUID

### Why

Android announces itself with the 22-byte `DiscoveryAnnouncementCodec` value in manufacturer data (company `0xFFFF`) in the scan response, plus service UUID `c8d5a101-…` in the advertising data. iOS `CBPeripheralManager.startAdvertising` accepts only `CBAdvertisementDataLocalNameKey` and `CBAdvertisementDataServiceUUIDsKey`. No manufacturer or service data is possible. In the foreground iOS uses at most 28 bytes of the advertising PDU for those keys. Service UUIDs that do not fit go to Apple's "overflow area", which only iOS scanners can read, and only the local name may use the scan response (10 bytes). In the background the local name is dropped and every UUID goes to the overflow area ([CBPeripheralManager.startAdvertising](https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager/startadvertising(_:)); [Core Bluetooth background guide](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)).

So an Android-visible iPhone advertisement can hold exactly one 128-bit UUID (2 + 16 = 18 bytes) plus a short local name (2 + at most 8 bytes). A second UUID (the original proposal) would land in the overflow area and be invisible to Android. The iPhone therefore advertises **only** the compact-announcement UUID below, not `c8d5a101-…`.

Without this, Android cannot discover an iPhone private-call callee, an iPhone viewer request (Android stream sources are LE centrals that connect to viewers), or an iPhone stream offer. The iPhone can already discover and call Android with no Android change.

### Layout

The 16 UUID bytes in canonical string order (Java `UUID.mostSignificantBits` then `leastSignificantBits`; `CBUUID.data`; the on-air 128-bit AD value is the same bytes reversed, which both stacks already handle) form one big-endian 128-bit integer `U`. Bit 127 is the most significant bit of byte 0.

| Bits of `U` | Width | Field |
| --- | ---: | --- |
| 127..112 | 16 | Magic `0xC8D6` |
| 111..110 | 2 | Version, `01` |
| 109..108 | 2 | Kind: `0` private-call offer, `1` viewer request, `2` stream offer, `3` reserved (reject) |
| 107..60 | 48 | Node ID prefix (first 6 bytes of the node ID, as in the 22-byte announcement) |
| 59 | 1 | GATT transport (`FLAG_GATT_TRANSPORT`); 0 means LE CoC. There is no Classic bit: iOS has no RFCOMM |
| 58 | 1 | Relay capable (`FLAG_RELAY_CAPABLE`) |
| 57 | 1 | Stream paused (`FLAG_STREAM_PAUSED`); must be 0 unless kind = stream offer |
| 56..54 | 3 | Codec summary: bit 54 VP9 (`CODEC_VP9` = 1), bit 55 AV1 (`CODEC_AV1` = 2), bit 56 H.264 (section B, `4`). Encoders keep bit 56 at 0 while H.264 is not negotiated; decoders carry all three bits into `capabilitySummary` and never reject on them [Review R1] |
| 53..50 | 4 | Route cost 0..15 |
| 49..19 | 31 | Route token bits 30..0. Call offer: must be 0 (token 0). Viewer request / stream offer: token = `0x80000000 or field` |
| 18..0 | 19 | Kind-specific, below |

Kind-specific bits 18..0:

- **Private-call offer:** all 0.
- **Viewer request:** bits 18..12 bitrate in 25 kbps units (0 = unknown; decoded kbps = value x 25). Bits 11..0 must be 0 (reserved for a future recovery hint). The route token is always copied from a discovered stream offer; a viewer request without one (token 0, Android's DEBUG direct-receiver mode) is not representable and an iPhone never advertises it [Review R3].
- **Stream offer:** bits 18..11 the announcement `sequence` byte unchanged (bit 7 `SEQUENCE_SOURCE_FULL`, bits 6..0 capacity generation). Bits 10..9 resolution index: `0` 426x240, `1` 640x360, `2` 854x480, `3` unspecified (width = height = 0). Bits 8..7 FPS index: `0` 15, `1` 24, `2` 30, `3` unspecified (0). Bits 6..0 bitrate in 25 kbps units.

Total 16 + 2 + 2 + 48 + 3 + 3 + 4 + 31 + 19 = 128 bits.

### Mapping to `DiscoveryAnnouncement`

A decoder produces an ordinary `DiscoveryAnnouncement`, so every existing consumer (stream-offer lists, viewer-request matching with `isViewerRequest(routeToken)`, private-call admission, relay-chain checks) is unchanged:

| Kind | `flags` |
| --- | --- |
| Private-call offer | `FLAG_ACCEPTING_CONNECTIONS or FLAG_PRIVATE_CALL_AVAILABLE` |
| Viewer request | `FLAG_ACCEPTING_CONNECTIONS` |
| Stream offer | `FLAG_STREAM_AVAILABLE` |

…then OR `FLAG_GATT_TRANSPORT`, `FLAG_RELAY_CAPABLE` and `FLAG_STREAM_PAUSED` from bits 59..57. `capabilitySummary` = codec bits 56..54 as a mask; `streamToken`, `routeCost`, `sequence`, `streamWidth/Height/Fps` (from the index tables) and `streamBitrateKbps` as above; `recoveryFromNodeIdPrefix = null`. Route recovery (`FLAG_ROUTE_RECOVERY`) is not representable in v1.

Decoding is strict, and exactly this list rejects the UUID: wrong magic, version other than 1, kind 3, the paused bit (57) with kind other than stream offer, a call offer with any of bits 49..0 set, a viewer request with any of bits 11..0 set. Nothing else is rejected (codec bits are carried; route cost is 4 bits and cannot exceed 15) [Review R2]. An encoder never emits a value it cannot represent: it refuses route cost > 15, Classic and route recovery; bitrate units = min(floor(kbps / 25), 127), so 3175 kbps saturates and 0 = unknown [Review R4]; geometry/FPS outside the tables use index 3. These fields are display and budgeting hints; the BTV3 stream header remains the authoritative format.

### Android scanning (receive side)

- Add one `ScanFilter` with `setServiceUuid(ParcelUuid(UUID(0xC8D6_0000_0000_0000, 0)), ParcelUuid(UUID(0xFFFF_0000_0000_0000, 0)))` beside the existing `c8d5a101-…` filter, in the same `startScan` call. Filters are ORed; masked service-UUID filters are public API since API 21. AOSP re-applies every filter on the host for every result (`ScanController.matchesFilters`). Each `ScanFilter` takes one controller (APCF) slot; a scanner with more filters than free slots runs all-pass for the whole scanner (`ScanManager.shouldUseAllPassFilter`), and a controller with fewer than 10 filters offloads nothing. The fallback is triggered by slot count, not by mask support: a controller that accepts the APCF 128-bit mask but mishandles it would drop iPhone results in hardware with no host fallback, so each phone needs a physical check [Review R6].
- In `BleL2capDiscovery.addResult`: if manufacturer data `0xFFFF` is present, use it exactly as today (it wins if both exist). Otherwise take the first `scanRecord.serviceUuids` entry whose top 16 bits are `0xC8D6` and decode it as above; a decode failure drops the result (counted as `compactInvalid`; decoded ones as `compact`, both appended to the DEBUG `scan_stats` line only while the switch is on) [Review R8].
- Display name: `scanRecord.deviceName` as today (the iPhone may advertise up to 8 bytes; unauthenticated label).

### Connecting to an iPhone (unchanged Android client code)

The iPhone peripheral hosts the same GATT database Android hosts:

- LE CoC: primary service `c8d5a101-9f88-4f65-a03d-7f5a2fb921fa` with read characteristic `c8d5a102-…` = big-endian 16-bit PSM from `publishL2CAPChannel(withEncryption: false)` (dynamic, never hardcoded; insecure like `listenUsingInsecureL2capChannel`). Android's `BleCocClient`/`BleL2capPsmReader` reads it and calls `createInsecureL2capChannel(psm)`.
- GATT: primary service `c8d5a105-…` with `c8d5a103-…` (write, write without response) and `c8d5a104-…` (notify + CCCD). Chunks are `0x01 | u32 big-endian sequence | payload` in each direction from sequence 0, exactly as `ChunkedGattOutputStream`/`GattBytePipe`. One central at a time, admitted on its CCCD subscription.
- Then BMH2 link handshake (Android central = initiator), BMH2 endpoint handshake, BMS1/BME1 as today. The iPhone validates the same transport bit in the signed link hello.

### Security and collision analysis

- **Same trust level as today.** The 22-byte announcement is already unauthenticated and forgeable by any advertiser. The compact form carries the same hints. Identity binding is unchanged: the full 48-bit node prefix is present, and calls/streams still require the BMH2 endpoint identity to match it (and, for verified contacts, the full fingerprint). Prefix grinding costs about 2^48 key generations in both forms.
- **Route token.** Route tokens are `logical xor mask` with `mask` bit 31 always set (`StreamRouteToken.advertiserMask`: `hash or Int.MIN_VALUE`) and logical tokens in `1..Int.MAX_VALUE` (`StreamTokenGenerator`), so every nonzero route token already has bit 31 set. Implying it loses no entropy (31 bits in both forms). Route tokens are broadcast correlation values, not secrets: a forger copies them in either form, so their entropy is not a security property. Call offers keep token 0. [Review: verified]
- **One role at a time.** One compact UUID means one kind per advertisement. The iPhone advertises exactly one kind and restarts advertising on a role change; a pending viewer request (short-lived, time-critical) takes precedence over call availability. Android tolerates the content change at the same address: a scanner accepts by kind before its per-address de-duplication [Review R5].
- **What is reduced.** Route cost is capped at 15 (calls use at most 4 relays; stream depth beyond 15 is not supported from iPhones). Stream geometry/FPS/bitrate are quantized hints. Capability summary carries only codec bits (no other bits are used in announcements). Route recovery is absent, so an iPhone viewer that lost its parent advertises an ordinary viewer request. A source that still holds the stale sender for that prefix admits it only after the child heartbeat timeout (6-8 s), instead of through the recovery shortcut (iOS-side claim, not verified by this review) [Review R10]. Classic is not representable (impossible on iOS).
- **Foreign collisions.** A random 128-bit UUID passes the 16-bit masked filter with probability 2^-16 and must then pass version, kind and reserved-bit checks. A false positive can only cause a connection attempt that fails at GATT discovery or BMH2. It grants no trust. The same is true of a deliberate forgery today.
- **Metadata.** An observer learns the same fields as from the 22-byte announcement (prefix, role, token, transport, codecs, route cost, coarse stream format), plus an optional short local name chosen by the iPhone user.
- **No new attack surface on the wire.** Records, signatures, keys, admission, overload guards and hop-local rules are untouched.

### Compatibility

- Android builds without this change filter on `c8d5a101-…` only. iPhone advertisements never match, so iPhones are invisible to them (no crash, no partial state). iPhones still see and call those Android phones as centrals.
- Android with the flag off: unchanged. With the flag on: the extra filter and decode path only. The 22-byte manufacturer-data format is never changed or sent by iPhones.
- iPhone in the background: invisible to Android (Apple moves UUIDs to the overflow area). Incoming calls and viewer requests need the iPhone app in the foreground.

### Test vectors (to share between Swift and Kotlin)

Computed from the layout (`U = 0xC8D6<<112 | 1<<110 | kind<<108 | prefix<<60 | gatt<<59 | relay<<58 | paused<<57 | codecs<<54 | cost<<50 | (token & 0x7fffffff)<<19 | specific`). Encoders on both platforms must produce these exact strings, and decoders must return the listed fields:

| # | Input | UUID |
| --- | --- | --- |
| 1 | Call offer, prefix `010203040506`, LE CoC, codecs VP9+AV1 (3), cost 0 | `C8D64010-2030-4050-60C0-000000000000` |
| 2 | Call offer, prefix `a1b2c3d4e5f6`, GATT, VP9 (1), cost 2 | `C8D64A1B-2C3D-4E5F-6848-000000000000` |
| 3 | Viewer request, prefix `010203040506`, LE CoC, decode VP9+AV1, token `0x9abcdef0`, cost 0, 300 kbps (12 units) | `C8D65010-2030-4050-60C0-D5E6F780C000` |
| 4 | Stream offer, prefix `a1b2c3d4e5f6`, GATT, relay capable, paused, VP9, cost 1, token `0xdeadbeef`, sequence `0x85`, 640x360 (index 1), 15 FPS (index 0), 300 kbps | `C8D66A1B-2C3D-4E5F-6E46-F56DF77C2A0C` |

The same table is a Swift test in the iOS repository (`Tests/NearbyCoreTests/CompactAnnouncementTests.swift`) and a Kotlin test in Android (`CompactDiscoveryAnnouncementTest`). All four were verified by an independent Python recomputation and by the Kotlin encoder and decoder. Add to the Swift tests: vector 4 with bit 56 set decodes (capability `0x05`) instead of rejecting; vector 1 with bit 19 or bit 0 set rejects; vector 3 with any of bits 11..0 set rejects; vectors 1 and 3 with bit 57 set reject; versions 0, 2, 3 and kind 3 reject; a viewer bitrate of 310 kbps encodes as 300 and a stream bitrate of 5000 kbps as 3175 [Review R2, R4].

## B. Optional H.264 video codec (later, behind a flag)

### Why

iPhones encode and decode H.264 in hardware on every model (VideoToolbox), but have no VP9/AV1 encoder; AV1 hardware decode exists only on A17 Pro/M3 and later, and VP9 decode needs iOS 26.2+ (`VTRegisterSupplementalVideoDecoderIfAvailable`) or software libvpx. Every Android phone decodes H.264 (CDD requirement) and nearly all encode it in hardware. H.264 would lower iPhone CPU/battery cost against software VP9 encoding.

### Wire changes (all capability-gated)

- `BTV3` codec ID **4 = H.264** (ID 1 stays unassigned to avoid confusion with retired formats and the Windows capability constant). Verified free: `StreamProtocol` uses 2 (VP9) and 3 (AV1); `codecCapabilityMask` maps unknown IDs to 0, so current receivers reject codec 4 [Review B1].
- `NodeCapabilities` encode/decode mask bit 2 (`0x04`) = H.264. Readers already test only the bits they need, so older peers ignore it. Verified free: codec masks use bit 0 (VP9), 1 (AV1) and 7 (`DECODE_PREFERS_VP9`, end-to-end call hello only). Transport-mask bit 6 (call relay, link hello) and bit 7 (call video fragments, end-to-end hello) are a different byte and do not conflict [Review B1].
- End-to-end call hello decode-mask bit 6 (`0x40`) = "prefer H.264 when you can encode it; other listed codecs are decodable fallbacks", mirroring bit 7 (`DECODE_PREFERS_VP9`). Not a codec; link hellos never carry it. An iPhone sets it. An endpoint sets at most one preference bit; if both are present, bit 7 wins (`privateCallCodecForPeer` already tests it first) [Review B2].
- Compact announcement codec bit 56 (section A) and the 22-byte `capabilitySummary` bit 2 advertise H.264 for stream offers/viewer requests.
- Payload: one complete access unit per `BTV3` media packet in **Annex B** form (4-byte start codes), as MediaCodec `video/avc` emits. Before the first frame the sender sends a `FLAG_CODEC_CONFIG` packet containing SPS and PPS (Annex B); late joiners get the broadcaster's cached codec-config replay. Android MediaCodec emits SPS/PPS once (`BUFFER_FLAG_CODEC_CONFIG`), so an Android sender either replays the cached config before each IDR or sets `KEY_PREPEND_HEADER_TO_SYNC_FRAMES` (API 29); every receiver therefore accepts SPS/PPS either as a config packet or in-band at the start of an IDR access unit [Review B3]. `FLAG_KEY_FRAME` marks IDR access units only. No B-frames (`AllowFrameReordering = false` on VideoToolbox, `KEY_MAX_B_FRAMES = 0` on Android): `BTV3` timestamps are monotonic [Review B4]. Senders request Constrained Baseline, level at most 3.1 for 854x480/30; receivers accept any profile their decoder supports, because some Android encoders ignore `KEY_PROFILE` [Review B5]. The receiver converts to AVCC for VideoToolbox; Android feeds Annex B to `video/avc` decoders directly.
- `BTV3.readHeader` accepts codec 4 only when the local flag is on and the local decode mask has bit 2. With the flag off, codec 4 is rejected exactly like any unknown codec, and bit 2 is never set.

### Negotiation

Calls: unchanged algorithm (`privateCallCodecForPeer`) with H.264 as one more local codec. An iPhone that can decode only H.264 fails cleanly against Android builds without H.264 ("Peer cannot decode any locally available call codec"); it should also list VP9 decode where available (iOS 26.2+ supplemental decoder or libvpx) [Review B6]. A peer's decode-mask bit 6 makes Android prefer its H.264 encoder when present; otherwise VP9/AV1 as today. Streams: the source still chooses one codec; it can stream H.264 only if every admitted viewer's endpoint hello decodes it, as for VP9/AV1 today (`Final receiver cannot decode …`). Relays forward ciphertext unchanged and need no codec support.

### Security

No change: codec bytes are inside BME1; capability bits are inside the signed hellos. The only new parser is the H.264 access-unit validation before the hardware decoder (NAL length/type checks, configured-format-only), which both platforms already require for VP9/AV1.
