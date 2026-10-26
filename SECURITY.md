# Security policy

MeshLive is meant for places where the internet may be down or watched, so a security flaw can matter more than in
an ordinary app. We take reports seriously, and we would rather hear about a problem privately and fix it than read
about it in a public issue first.

MeshLive for iPhone and Mac speaks the same protocol as [MeshLive for Android](https://github.com/MeshLive/meshlive-android),
so a flaw in the protocol itself (handshakes, record format, key agreement) may affect both. Report it here or in the
Android repository; we will coordinate.

## Supported versions

MeshLive for iPhone and Mac is early, pre-release software with no published binary. Security fixes go to `main` only.

## Reporting a vulnerability

**Please do not open a public issue, pull request or discussion for a security problem.**

Report it privately through GitHub Security Advisories:

1. Open the repository's **Security** tab and choose **Report a vulnerability**, or go straight to
   <https://github.com/MeshLive/meshlive-ios/security/advisories/new>.
2. Describe the problem as below and submit. Only the maintainers can see the report.

If you cannot use GitHub Security Advisories, open a public issue that says only "security report" with no details,
and a maintainer will arrange a private channel. Do not include technical details, keys or a proof of concept in
that issue.

### What to include

- Which part is affected (see "Scope") and which commit.
- What an attacker needs (physical range, a malicious relay or peer, a jailbroken device, and so on) and what they
  gain (read content, impersonate someone, make a call misbehave, recover wiped data).
- Steps to reproduce, or a short proof of concept.
- The iPhone or Mac and the Android phones, with OS versions, you tested on.
- Whether you plan to publish your findings, and any date you would like us to work towards.

Please do not include real private media, other people's data or your own keys, and test with phones you own.

## What to expect

This is a volunteer project, so response times are best effort, with no service-level promise and no bounty. We aim
to acknowledge a report within about a week, tell you whether we can reproduce it, fix confirmed problems as soon as
we reasonably can, then publish an advisory and credit you if you wish. Without a better reason we prefer to publish
once a fix is available, and no later than 90 days after the report.

## Scope

In scope:

- **Protocol, identity and encryption** as implemented in `Sources/NearbyCore`: the BMH2 handshakes, BMS1 hop
  records, BME1 endpoint content, key agreement, signatures, replay and ordering protection, and identity
  verification ([protocol notes](docs/dev/protocol.md)).
- **Private calls and stream viewing**, including the admission checks and the check that a stream comes from its
  authenticated original source.
- **Identity storage and emergency wipe**: Keychain and Secure Enclave key handling, and cases where a completed wipe
  leaves keys or app data that the design says it removes.
- **Discovery**: anything that lets a nearby device cause more than a failed connection attempt through a forged
  announcement.
- Build and supply-chain problems in this repository (the pinned libopus and libvpx downloads and their checksums).

Out of scope:

- Attacks that need a jailbroken or already-compromised phone, a debugger, or physical access to an unlocked phone.
- Flash remanence and copies outside the app (backups, system logs, a phone seized before the wipe).
- Bluetooth radio facts that the project documents: a nearby listener sees that Bluetooth traffic exists, its timing
  and its size.
- Denial of service by radio jamming, or by a nearby device that connects and refuses to cooperate.
- Findings in third-party components that have no effect on MeshLive (report those upstream).
- Reports from automated scanners without a demonstrated impact.

If you are unsure whether something is in scope, report it privately anyway.

## Known limitations

- **No independent security audit.** The design uses standard primitives (P-256 ECDH and ECDSA, HKDF-SHA-256,
  AES-256-GCM), but the protocol has been reviewed only by the project and its reviewers.
- **Bluetooth metadata is visible.** Anyone in radio range can see advertisements, connection timing, and the size
  and timing of encrypted records. Encryption protects content, not the fact that you are communicating.
- **A stable discovery prefix is broadcast while the app advertises.** A passive scanner could recognise the same
  phone over time. Rotating discovery IDs exist behind an **Experimental** switch and are not yet validated on
  phones. See [Privacy](docs/privacy.md#what-nearby-phones-can-see).
- **The app has had very little hardware testing.** Treat its behaviour on a real iPhone or Mac as unproven.
- **Experimental features are experimental.** Anything in the [switch register](docs/dev/switches.md) marked experimental is off by default and has
  had less review.
- **Emergency wipe has limits** (see "Emergency wipe" in the [Android protocol reference](https://github.com/MeshLive/meshlive-android/blob/main/docs/dev/protocol/identity.md#emergency-wipe)): it cannot reach copies outside the app and
  cannot promise erasure of flash storage.

Thank you for helping keep MeshLive users safe.
