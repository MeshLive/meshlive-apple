> **Experimental, default off.** This is the original standalone v1 (Noise XX) protocol of the first iPhone prototype. It cannot talk to Android. The app now speaks the Android protocol (the Android project's protocol reference, docs/dev/protocol/).

# Experimental v1 wire protocol (`NearbyIntercom/v1`)

`NearbyIntercom` was the project's working name before MeshLive. The v1 Noise prologue, the safety-code label and
the fixtures still use it, because they are hashed into every handshake and test vector; they are left unchanged on
purpose.

This documents the current independent iPhone prototype protocol. It is a default-off experiment that only iPhones speak; MeshLive itself uses the Android protocol. Swift and a portable Java **v1 reference** pass cross-language checks, but the actual iPhone/Android custom-protocol agreement and adapters remain pending. Another implementation needs the complete contract below and implementations of BLE roles, Noise and the negotiated codecs. All integer fields are unsigned, **big endian**, unless explicitly identified as PCM or a Noise nonce. Strings are strict UTF-8. UUID strings below are conventional hexadecimal notation, not wire byte strings. Fields have no implicit padding. Extra bytes, unknown versions/types/flag bits, unsupported selections, bad lengths, failed authentication or sequences terminate the session; there is no permissive upgrade/downgrade behavior in v1.

## Discovery and link selection

One user chooses Host (GATT server/Noise responder) and the other Join (GATT client/Noise initiator). Roles do not constrain media direction. An app instance supports one peer; it does not simultaneously scan and advertise. Duplicate/crossed connections are prevented by this UI contract, one active attempt and callback identity/generation checks. A role change creates a new run and new host token.

| Attribute | UUID | Properties |
|---|---|---|
| Service | `7D2C9B68-19E6-4F03-8B41-82AE51F26790` | primary |
| Info | `7D2C9B68-19E6-4F03-8B41-82AE51F26791` | read |
| Client → host | `7D2C9B68-19E6-4F03-8B41-82AE51F26792` | write, write without response |
| Host → client | `7D2C9B68-19E6-4F03-8B41-82AE51F26793` | notify |

Advertise only the service UUID and the short local name `Nearby`. Names are hints, never authenticated identities. Info is 19 bytes: `version:u8=1 | PSM:u16 | hostToken:16 bytes`. Token is a fresh random UUID's raw 16 bytes for the host run. PSM is assigned by `publishL2CAPChannel(withEncryption:false)` and never hardcoded. Zero means unavailable. The host waits for service addition and the publish result before advertising. Info is dynamic and supports ATT read offsets.

Join reads Info, subscribes to notifications and waits for notification-state success. It writes a 19-byte selection **with ATT response**: `A1:byte | 01:byte | transport:u8 | hostToken:16`. Transport is 1=GATT, 2=LE L2CAP. Host accepts only its chosen subscribed central and replies in a notification with `A2 | 01 | transport | hostToken`. Join waits for both the write completion and this acceptance. A peer unable to accept selection fails visibly; no automatic fallback occurs. A user may stop and start a fresh GATT run. These two selection records are the only characteristic values outside BLE chunk framing. Handshake records cannot be sent before selection completes.

For GATT, keep the subscription active. Application chunks may use ATT writes with or without response; they have identical wire framing. The iOS client uses write without response, querying `maximumWriteValueLength(for:.withoutResponse)` and honoring `canSendWriteWithoutResponse` and its delegate readiness callback. A client using writes with response must wait for each completion before the next write. Host queries `CBCentral.maximumUpdateValueLength`, honors `updateValue` false and resumes from `peripheralManagerIsReady(toUpdateSubscribers:)`. Android integration must also write the notification CCCD and wait for its asynchronous success before selection.

For L2CAP, Join opens the current discovered PSM and both await `didOpen`. Host checks the channel's peer against its selected central. Keep the GATT subscription for link lifecycle; data now travels **only on the L2CAP stream**. Link encryption is deliberately not required here; all application data uses the session encryption below. Enabling BLE pairing would be a separate policy, not a replacement for peer authentication.

## BLE chunks and application records

Each GATT update has a 9-byte chunk header: `chunkVersion:u8=1 | recordID:u32 | offset:u16 | total:u16 | bytes:remaining`. `total` includes the complete application length prefix and record. IDs start at zero independently in each direction and increment once per complete record. Offsets start at zero and must exactly equal bytes accumulated so far; ID and total must remain unchanged throughout that record. No interleaving, missing, duplicated, empty or oversized chunks is accepted. Total is 5…32772. Fragment capacity is the actual platform write/update limit minus 9. One incomplete record per direction is retained. Counters must not wrap; reconnect first.

On L2CAP there are no BLE chunks: partial writes/read readiness, coalesced records, EOF and errors are stream operations. Both transports produce the same application framing: `length:u32 | record:length bytes`. Length excludes its own 4 bytes, is 1…32768, and includes the record-type byte. A reader accumulates partial input and extracts every complete record; a stream read is never treated as one message. Incremental receive memory is bounded to 65544 bytes. One ordered writer per link bounds pending bytes to 131072 and entries to 1024. A send failure after encrypting closes the session; no ciphertext is silently dropped or re-encrypted with a reused nonce.

## Noise XX handshake and authentication

Use [Noise revision 34](https://noiseprotocol.org/noise.html), exactly `Noise_XX_25519_ChaChaPoly_SHA256`. CryptoKit implements X25519, SHA-256, HMAC-SHA256 and ChaCha20-Poly1305; Swift handles the standard XX token/state processing. The Java reference uses Bouncy Castle 1.86 lightweight X25519/ChaCha20-Poly1305 and standard SHA-256/HMAC. Both are checked against an independent [noise-c known-answer vector](https://github.com/rweather/noise-c/blob/master/tests/vector/noise-c-basic.txt), exact Swift fixtures and separate cross-language peers. This is not an independent security audit of the app.

Initialize Noise with prologue `UTF8("NearbyIntercom/v1") | selectedTransport:u8 | hostToken:16`. Persistent static X25519 keys identify peers. iOS generates them and stores their 32-byte private representations as `WhenUnlockedThisDeviceOnly` Keychain items; production has no fixed keys. Every connection generates fresh ephemeral X25519 keys. The public peer identity is the remote static key received inside XX, not the Bluetooth identifier/name.

| Outer record type | Direction | XX tokens | Noise payload |
|---|---|---|---|
| 1 | Join → Host | e | Join capabilities |
| 2 | Host → Join | e, ee, s, es | Host capabilities |
| 3 | Join → Host | s, se | selected media profile |

Each record is `type:u8 | standardNoiseMessage:remaining`. Handshake messages are limited to 512 bytes; application handshake payloads to 256. Capabilities are `version:u8=1 | transport:u8 | audioMask:u8 | videoMask:u8 | nameLength:u8 | name:nameLength bytes`. Audio mask bit0=Opus, bit1=diagnostic PCM; one or both must be set. Video mask bit0=H.264 pattern experiment. Other bits reject. Name is 0…48 bytes and untrusted before verification. All handshake payloads, encrypted static keys and ephemeral keys are bound into Noise's final transcript hash `h`. Profile selection is deterministic: Opus if both support it, otherwise PCM if both support it, otherwise reject. Video is enabled only with Opus and both H.264 capability bits; the app offers H.264 only on L2CAP. Both transport values must equal the actual selected link.

The selected profile is 13 bytes: `audioCodec:u8 | sampleRate:u32 | channels:u8=1 | packetMS:u16=20 | bitrate:u32 | videoEnabled:u8`. Codec 1=Opus, 48000 Hz, 20000 bps; codec 2=PCM diagnostic, 8000 Hz, 128000 bps. `videoEnabled` is exactly 0 or 1. Host compares all 13 selection bytes to its independently computed selection. The audio selection serves as its configuration record; H.264 sends a separate configuration below.

Noise's `MixKey` uses HKDF-HMAC-SHA256: `temp=HMAC(ck,input)`, `out1=HMAC(temp,01)`, `out2=HMAC(temp,out1|02)`. Chaining keys and handshake cipher keys follow the XX algorithm. `Split()` with empty input returns the Join→Host and Host→Join keys in that order. They are separate directional keys; counters start at zero. Noise's 96-bit ChaCha nonce is **four zero bytes followed by the counter as little-endian u64**. Counter uniqueness follows the ordered writer and fresh handshake; this implementation ends sessions before 1,000,000,000 encrypted records under one key. No rekey extension is supported.

Before accepting text/media, both users compare the displayed **40-bit session code in person**: uppercase hex of the first five bytes of `SHA256(UTF8("NearbyIntercom SAS v1") | h)`, visually grouped as five characters, space, five characters. Displayed peer fingerprint is the first eight bytes of `SHA256(remoteStaticPublicKey)`, hexadecimal; the shorter fingerprint is diagnostic and does not replace session-code comparison. Each user explicitly confirms, sending encrypted message 1 with payload `h` (32 bytes). Ready requires both local confirmation and a valid remote confirmation. Reject/timeout closes. No automatic trusted-peer memory is implemented; compare on every run. An optional expected full static key is supported in the core and rejects wrong peers, but the UI does not persist pins.

XX proves possession of the presented static keys; manual verification decides whether they belong to the intended person. The short code gives limited collision resistance, depends on correct human comparison over a trustworthy out-of-band channel, and permits transcript-grinding attacks. It is weaker than comparing a full 256-bit transcript/QR and is not suitable as unattended identity authentication. Device names or BLE pairing alone never establish trust. Metadata/length/timing and nearby presence are not hidden; denial of service, endpoint compromise, Swift memory zeroization and traffic analysis are outside this prototype's guarantees.

## Encrypted application records

Outer type 4 has this **31-byte clear authenticated header**:

`04:u8 | version:u8=1 | messageKind:u8 | sessionID:16 | sequence:u64 | plaintextLength:u32`

Then `ciphertext:plaintextLength bytes | Poly1305Tag:16`. Session ID is the first 16 bytes of final `h`. Associated data is `h | entire31ByteHeader`. Nonce is the directional sequence/cipher counter described above. Receive sequence must equal the next expected counter exactly; replay, gap, tamper, wrong session or unknown kind ends the connection. Plaintext length is at most 32721. Only verification/close/close-ack are permitted before Ready. Even authenticated unknown messages reject in v1; future incompatible additions need a new version.

| Kind | Plaintext payload / behavior |
|---|---|
| 1 verify | `h:32`; exactly one remote confirmation in Verification state |
| 2 text | `messageID:u32 | UTF8 text:remaining`; ID starts at 1 and strictly increases; text 1…4096 bytes |
| 3 ACK | `messageID:u32`; receiver emits after bounded application acceptance; matches a locally submitted ID |
| 4 cancel | `messageID:u32`; advisory cancellation of text; already received content cannot be retracted |
| 5 ping | `elapsedMilliseconds:u64`; sender's elapsed run duration; peer echoes it in pong |
| 6 pong | exact ping payload; diagnostic/keepalive, no clock synchronization |
| 7 close | UTF-8 reason, 0…128 bytes; stop accepting media/data and reply with kind 8 |
| 8 close ACK | empty; only accepted while Closing |
| 9 audio | audio packet below; lossy real-time playout, no per-packet application ACK |
| 10 H.264 config | configuration below, only if negotiated |
| 11 H.264 frame | access unit below, only if negotiated, at most 24576 payload bytes |
| 12 audio cancel | `streamID:u32`; nonzero; discard that active receive stream and await a new discontinuity |

Text has up to 16 pending ACKs and a 10-second ACK deadline. There is no automatic application retransmission: BLE/L2CAP ordering plus the authenticated sequence and the remote ACK expose success/failure without duplicate display. Local queue admission, bytes consumed/accepted by Core Bluetooth or a stream, and **remote app ACK** are distinct. OS submission is not proof of radio delivery, speaker output or display. Cancellation does not recall submitted bytes. Ping every 5 seconds of send inactivity; verified receive inactivity over 15 seconds closes. Discovery deadline 120 seconds; connect/service/subscription/selection/open 15 seconds; Noise 20 seconds; human verification 120 seconds from session creation. Closing waits at most 2 seconds for close ACK. A receiver keeps the link briefly until peer disconnect/EOF or a 2-second cleanup deadline so its ACK can drain; forced/background stop is best effort. Session truncation without an authenticated close is not an orderly close.

## Audio

Packet: `streamID:u32 | timestamp:u64 | flags:u8 | validSamples:u16 | codecBytes:remaining`. Bit0=final, bit1=discontinuity; other bits reject. Stream IDs start at 1 and strictly increase over the session, including hardware re-enables. First packet in a stream has discontinuity, timestamp zero. Timestamp is the start sample in the negotiated mono sample clock, increments by exactly one 20 ms frame (960 Opus / 160 PCM); it is independent in each direction, not a shared physical clock. The receiver permits gaps to conceal with Opus PLC or PCM silence and rejects repeated/unaligned timestamps. A new stream resets playout. `validSamples` is 1…frameSamples, with a short padded final packet allowed. Release flushes converter output; an empty final marker (`validSamples=0`, empty bytes) may follow a full nonfinal packet or a press with no samples. A delayed final marker still ends its stream. Close/cancel/interruption terminates pending media.

Opus is one raw RFC 6716 mono 20 ms packet, not Ogg/RTP, at most 1275 bytes. Decode duration must be exactly 960 samples; a final valid-sample count trims padding for playback. PCM is signed 16-bit **little endian**, 160 samples/320 bytes each normal packet; it is a diagnostic requiring 128 kbps before framing overhead, not the completed efficient intercom. Never relabel captured sample rates. The app inspects the actual planar Float32 capture format, uses channel 0, and explicitly resamples to the negotiated mono rate using AVAudioConverter. Conversion/encoding run on the media queue; the capture callback only writes a preallocated atomic SPSC ring.

Receive jitter target is 3 packets (60 ms), capacity 10 (200 ms); overflow discards oldest audio and advances its sample clock. Missing samples produce PLC/silence and increment underruns. Playback schedules at most 4 buffers (80 ms). Sender/receiver handoffs each hold at most 16 packets. Capture ring holds 32768 samples. Capture overflow stops audio. During send, transport queue ≥8192 bytes or oldest age ≥250 ms closes the session with a visible overload reason. Generic transport age over 3 seconds also closes. These are conservative implementation bounds to measure, not Bluetooth operating guarantees. PTT release finalizes recorded samples already published at the capture cutoff; an in-flight tap at that boundary may be excluded. Mute finalizes then releases hardware; interruptions send audio cancel; Stop cancels immediately.

The app's foreground AVAudioSession is playAndRecord/voiceChat with voice processing. Requested hardware rate is 48 kHz and I/O duration 20 ms; actual values/routes are reported. Enabling audio keeps the microphone active locally with an obvious indicator; only Hold Talk transmits, unless duplex is explicitly enabled. Speaker/earpiece override is best effort (route-dependent). Duplex is an unverified Opus/L2CAP experiment, not a guaranteed operating mode.

## H.264 generated-pattern experiment

This version sends a live controlled generated pattern, **not camera video**. No camera permission or recordings. It is selectable only after the users confirm voice is usable and Opus/L2CAP/H.264 were negotiated. Capability indicates code support; actual VideoToolbox encoder/decoder creation can fail and the reason is reported.

Config: `codec:u8=1 | width:u16=160 | height:u16=120 | fps:u8=5 | requestedBitrate:u32=32000 | orientation:u8=0 | spsLength:u16 | SPS | ppsLength:u16 | PPS`. Each parameter set is 1…1024 bytes and has the corresponding H.264 NAL type 7/8. Baseline profile, no B frames, 4-byte NAL lengths, requested 10-frame maximum keyframe interval, requested burst limit 8000 bytes/second. Configuration is sent before the first access unit and whenever SPS/PPS change. Effective dimensions and actual encoded bytes/peak access unit/hardware-encoder status (when available) are diagnosed rather than assumed.

Frame: `timestampMicroseconds:u64 | flags:u8 | AVCC:remaining`. Timestamp must fit signed 64-bit Core Media time. Bit0=IDR/keyframe, bit1=discontinuity; discontinuity requires IDR. AVCC is one complete access unit with each NAL encoded `nalLength:u32 | NAL`, no Annex B start codes. AVCC 1…24000 bytes, at most 32 NALs; allowed NAL types 1,5,6,7,8,9,12; IDR flag must agree with type 5. Orientation 0 is upright landscape pixels for the synthetic target. Timestamp originates at the sender's video experiment start; 5 FPS normally advances 200000 µs. It is not speaker/display latency or cross-device synchronization. Decoder creation rejects SPS dimensions that differ from 160×120.

On configuration change or decoder error, wait for IDR. Discontinuity IDR may reset the video clock after an experiment restart. Encoder has at most 2 frames outstanding; decoder at most 3; incoming config/frame handoff at most 4 records; UI image handoff capacity 1. Incoming handoff overload stops the video experiment visibly; further video is ignored until explicit restart/new session. Restart both ends so configuration precedes frames. Audio has priority: before application encryption, reject video while local speech is transmitting, queue ≥2048 bytes or age ≥100 ms. Shed whole access units and require the next transmitted frame to be a freshly forced IDR; never randomly discard a P-frame and continue its dependent chain. Oversized output is shed and an IDR requested. Video stop releases encoder/decoder but does not disconnect voice; no retention of pixel/codec output files occurs. A first frame/connection does not demonstrate sustainable video.

## Fixtures and lifecycle

`Tests/NearbyCoreTests/Fixtures/session-v1.json` contains known **test-only** static and ephemeral keys, host token, handshake/confirmation/text/ACK records without length prefixes, session ID and matching codes. Reproduce with `bash Scripts/fixtures.sh`; use `--write` only when intentionally updating this protocol fixture. Never ship fixture keys as identities. The independent Noise vector is tested separately, with its upstream license retained. `bash Scripts/interop.sh` checks Java against the same fixture and runs separate random-key Swift/Java peers in both roles, with GATT chunking and fragmented/coalesced stream frames. Its pipes are diagnostic infrastructure, not a production transport or physical Bluetooth evidence.

Both apps must stay foreground/unlocked. The iPhone implementation stops microphone, video, advertising, scanning, links and pending work on background; foregrounding requires a new explicit run. Inactive state releases microphone; Bluetooth reset/disable/denial, route changes and audio interruptions have explicit reasons. Android must implement equivalent foreground lifecycle handling in its own app. No background modes, Wi-Fi, Multipeer Connectivity, cloud, generic RFCOMM, mesh or group calls are implemented. The Java reference is not an Android Bluetooth endpoint.
