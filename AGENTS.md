# Working rules for contributors and coding agents

These rules apply to everyone who changes this repository, whether you are a person, an AI coding agent, or a team of
both. They are short on purpose; the detail lives in the documents named below. The Android repository's
[working rules](https://github.com/MeshLive/meshlive-android/blob/main/AGENTS.md) are the fuller version and apply
here where they are not platform-specific.

## Read first

1. [README.md](README.md): what the apps do and their status, with links to the other documents.
2. [testing.md](docs/dev/testing.md): what has been checked and the physical test steps. Read it before you test on
   an iPhone, a Mac or a phone.
3. [architecture.md](docs/dev/architecture.md) and the [switch register](docs/dev/switches.md).
4. The [protocol notes](docs/dev/protocol.md) and Android's canonical
   [protocol reference](https://github.com/MeshLive/meshlive-android/blob/main/docs/dev/protocol/README.md) before you
   touch anything that is sent, encrypted, authenticated or stored.

Contribution rules for everyone, including the policy for AI-assisted work, are in [CONTRIBUTING.md](CONTRIBUTING.md).

## Fixes and evidence

- **Reproduce first**, then make the narrowest fix that explains the failure and add a focused test that fails
  without it. Trace the request, the attempt and session, and the pipeline stage before you claim a cause.
- **Wire and security rules match Android exactly.** Use the Android protocol reference and its test vectors. Platform
  behaviour (layout, input, lifecycle, media APIs) follows the best native design for iOS or macOS.
- **Never silently change a requested setting** (bitrate, frame rate, resolution, codec, audio, transport, buffer) to
  make a test pass. If the effective value differs, report both.
- **Keep the guards:** authentication, ordered encryption, hop-local control, admission and overload protection.
- **Builds, simulators and previews are not hardware proof.** Calls, streams, Bluetooth, camera and audio quality are
  shown only on real devices. Unmeasured stays unmeasured; a fallback is not a pass for the requested path.
- **Test behaviour, not source text.** Write tests for user flows and failures; no source-grep, copied-source or
  count-based change detectors.

## Experiments and decisions

- New, unproven behaviour ships **off by default**, labelled Experimental, with a row in the
  [switch register](docs/dev/switches.md). Never delete an experiment or the losing side of a comparison; keep it
  switchable.
- Changes to the wire format, identity, encryption or admission need a reviewed design in the Android repository
  first.

## Privacy and hygiene

- The repository is public and permanent. Never commit device identifiers (UDIDs, serials), Bluetooth addresses, real
  node IDs or fingerprints, Apple team IDs, signing or provisioning data, personal paths, user names, emails, or
  photos, recordings or screenshots of people. Use placeholders.
- Keep local notes, logs and test output outside Git (an ignored folder such as `.build/`). Do not reset privacy
  permissions or wipe identity data on someone's device to make a test run.
- Run `bash Scripts/test.sh`, `python3 Scripts/tokens.py --check` and the builds in
  [building](docs/dev/building.md) before you hand work back, and update the document that owns any behaviour you
  changed.
