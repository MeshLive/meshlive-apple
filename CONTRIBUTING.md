# Contributing to MeshLive for iPhone and Mac

Thank you for wanting to help. MeshLive sends live video and voice calls between nearby phones over Bluetooth with
no internet. This repository is the iPhone app and the experimental native Mac app. Both are early and have had very little
hardware testing, so the most valuable contribution is usually a **test report from a real iPhone or Mac** paired
with an Android phone. You do not need
to write code to help.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md). If you found a security problem, do
not open a public issue; read [SECURITY.md](SECURITY.md) first.

## Where things are documented

| You want to know | Read |
| --- | --- |
| What the apps do and their status | [README.md](README.md) |
| How to build and test from source | [docs/dev/building.md](docs/dev/building.md) |
| How the code is organised | [docs/dev/architecture.md](docs/dev/architecture.md) |
| The iPhone-specific protocol notes | [docs/dev/protocol.md](docs/dev/protocol.md) |
| The canonical wire protocol and security rules | [meshlive-android protocol reference](https://github.com/MeshLive/meshlive-android/blob/main/docs/dev/protocol/README.md) |
| What has been checked, and the physical test steps | [docs/dev/testing.md](docs/dev/testing.md) |
| Experimental and optional switches | [docs/dev/switches.md](docs/dev/switches.md) |
| How iPhone discovery works and what Android reviewed | [Interop/ANDROID_DISCOVERY_ADDENDUM.md](Interop/ANDROID_DISCOVERY_ADDENDUM.md) |
| Where the pinned libopus and libvpx come from, and their licences | [Vendor/README.md](Vendor/README.md), [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) |

Changes to the wire format start in [meshlive-android](https://github.com/MeshLive/meshlive-android): its
protocol reference (`docs/dev/protocol/`) is authoritative, and this repository follows it.

## Development setup

You need a Mac with Xcode 26 or later and Python 3. The steps are in
[Building from source](docs/dev/building.md): fetch the pinned libopus and libvpx with `Scripts/prepare-opus.sh`
and `Scripts/prepare-libvpx.sh`, regenerate the Xcode project with `python3 Scripts/project.py`, then run
`bash Scripts/test.sh` for the unit tests and `bash Scripts/build.sh iphonesimulator` for a build. A simulator has no
Bluetooth, so calls and streams can only be proven on real devices ([testing](docs/dev/testing.md)). For the Mac app,
also build the **MeshLive** scheme and run `bash Scripts/run-macos-uitest.sh`.

Do not commit your Apple team ID, provisioning data or a personal bundle identifier. The repository's bundle
identifier is a placeholder; pass your own through `TEAM` and `BUNDLE` (`Scripts/run-device.sh`).

## Reporting bugs and device results

Use the forms in [.github/ISSUE_TEMPLATE/](.github/ISSUE_TEMPLATE/) (the **New issue** button offers them):

- **Device test report**: what worked on your iPhone or Mac with an Android phone, including when everything worked.
- **Bug report**: something failed (connection, video, audio, crash, build).
- **Feature request**: describe your situation (who, where, how many phones, what connectivity), not only the feature.

A good report names both phones (model and OS version), the commit you built, the transport, what you expected and
what happened, and how often. Please do not attach photos, videos, recordings or screenshots of other people.

## Before you open a pull request

For anything bigger than a typo, open an issue first and describe the problem you see.

- **Reproduce first**, and keep fixes narrow. Add a focused test that fails without the fix.
- **Measure on real phones** when the change touches streaming, Bluetooth, codecs, audio or lifecycle. Say which
  phones and OS versions you used, and compare before and after at the same settings.
- **Never silently change a requested bitrate, frame rate, resolution, codec, transport or buffer to make a test
  pass.** If the effective value differs from the requested one, say so.
- **Keep the safety guards:** authentication, ordered encryption, hop-local control, admission and overload
  protection. If you think a limit is too low, show measured evidence rather than removing it.
- **Do not call something passed without measured evidence.** Unmeasured stays unmeasured.
- New behaviour that is not yet proven ships **default off**, labelled Experimental, and gets a row in the
  [switch register](docs/dev/switches.md). Do not delete the losing side of a comparison; keep it
  switchable.
- Anything that changes the wire format, identity, encryption or admission needs a reviewed design in the Android
  repository's protocol reference (`docs/dev/protocol/`) first.

## Using AI tools

AI-assisted contributions are welcome and go through the same review as any other change.

- You are responsible for every line. Read, understand and run what the tool wrote.
- Say in the pull request when AI did a substantial part (a sentence: which tool, for what).
- An agent's claim that it "tested" something is not evidence until you see the logs or numbers.
- Check licences: do not submit code you cannot license under GPL-3.0-or-later, and keep attribution for adapted code.
- Keep secrets and private data out of prompts (see the privacy rules below).
- Pull requests with no sign of human review, or whose author cannot explain the change, may be closed.

The working rules for people and coding agents are in [AGENTS.md](AGENTS.md).

## Licensing and sign-off

MeshLive for iPhone is licensed under **GPL-3.0-or-later** ([LICENSE](LICENSE)). Contributions are accepted under the
same licence, and you keep your copyright. Copyright lines read "The MeshLive Authors" ([AUTHORS](AUTHORS)).

- Sign off every commit with `git commit -s`. That adds a `Signed-off-by:` line and certifies the
  [Developer Certificate of Origin 1.1](https://developercertificate.org/).
- Do not copy code, assets, test media or protocol text from another project unless its licence is compatible with
  GPL-3.0-or-later; keep its notice and add it to [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- Test media must be generated or licensed for redistribution. Do not commit footage of real people.

## Privacy rules for contributions

The repository is public and permanent. Never commit, paste into an issue, or include in a test fixture:

- device identifiers (UDIDs, serial numbers), Bluetooth addresses, or real node IDs and key fingerprints,
- Apple team IDs, signing certificates, provisioning profiles or keychain exports,
- private photos, voice recordings or video, or screenshots of other people,
- personal file paths, usernames, email addresses or phone numbers.

Use placeholders such as `AA:BB:CC:00:00:01` for addresses. Share summaries (numbers, phone models, short commit
hashes) in the pull request or issue instead of raw logs.

## Pull request checklist

- [ ] The problem is described, with evidence that it is real.
- [ ] The change is narrow, and a focused test covers it.
- [ ] `bash Scripts/test.sh` and `python3 Scripts/tokens.py --check` pass, `bash Scripts/build.sh iphonesimulator`
  builds, and Mac changes also build the **MeshLive** scheme and pass `bash Scripts/run-macos-uitest.sh`.
- [ ] Streaming-related changes name the phones, OS versions and the same-settings comparison.
- [ ] New behaviour is default off, labelled Experimental, and listed in [switches.md](docs/dev/switches.md).
- [ ] Protocol or security changes link to a reviewed design in the Android repository.
- [ ] The documents that own the changed behaviour are updated.
- [ ] Commits are signed off (`git commit -s`), the diff contains no private data, and substantial AI assistance
  is disclosed.
