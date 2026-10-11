# Contributing to MeshLive for iPhone

Thank you for wanting to help. MeshLive sends live video and voice calls between nearby phones over Bluetooth with
no internet. This repository is the iPhone app. It is early and has had very little hardware testing, so the most
valuable contribution is usually a **test report from a real iPhone** paired with an Android phone. You do not need
to write code to help.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md). If you found a security problem, do
not open a public issue; read [SECURITY.md](SECURITY.md) first.

## Where things are documented

| You want to know | Read |
| --- | --- |
| What the app does, its status, how to build it | [README.md](README.md) |
| The iPhone-specific protocol notes | [PROTOCOL.md](PROTOCOL.md) |
| The canonical wire protocol and security rules | [meshlive-android/docs/PROTOCOL.md](https://github.com/MeshLive/meshlive-android/blob/main/docs/PROTOCOL.md) |
| What has been checked, and the physical test steps | [TESTING.md](TESTING.md) |
| How iPhone discovery works and what Android reviewed | [Interop/ANDROID_DISCOVERY_ADDENDUM.md](Interop/ANDROID_DISCOVERY_ADDENDUM.md) |
| Where the pinned libopus and libvpx come from | [Vendor/README.md](Vendor/README.md) |

Changes to the wire format start in [meshlive-android](https://github.com/MeshLive/meshlive-android): its
`docs/PROTOCOL.md` is authoritative, and this repository follows it.

## Development setup

You need a Mac with Xcode 26 or later and Python 3. The steps are in the README's
[Build from source](README.md#build-from-source): fetch the pinned libopus and libvpx with `Scripts/prepare-opus.sh`
and `Scripts/prepare-libvpx.sh`, regenerate the Xcode project with `python3 Scripts/project.py`, then run
`bash Scripts/test.sh` for the unit tests and `bash Scripts/build.sh iphonesimulator` for a build. A simulator has no
Bluetooth, so calls and streams can only be proven on real phones ([TESTING.md](TESTING.md)).

Do not commit your Apple team ID, provisioning data or a personal bundle identifier. The repository's bundle
identifier is a placeholder; pass your own through `TEAM` and `BUNDLE` (`Scripts/run-device.sh`).

## Reporting bugs and device results

Use the forms in [.github/ISSUE_TEMPLATE/](.github/ISSUE_TEMPLATE/) (the **New issue** button offers them):

- **iPhone device test report**: what worked on your iPhone and Android phone, including when everything worked.
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
- New behaviour that is not yet proven ships **default off**, labelled Experimental, and gets a row in the README's
  "Experimental, alternative and optional behaviour" table. Do not delete the losing side of a comparison; keep it
  switchable.
- Anything that changes the wire format, identity, encryption or admission needs a reviewed design in the Android
  repository's `docs/PROTOCOL.md` first.

## Licensing and sign-off

MeshLive for iPhone is licensed under **GPL-3.0-or-later** ([LICENSE](LICENSE)). Contributions are accepted under the
same licence, and you keep your copyright. Copyright lines read "The MeshLive Authors" ([AUTHORS](AUTHORS)).

- Sign off every commit with `git commit -s`. That adds a `Signed-off-by:` line and certifies the
  [Developer Certificate of Origin 1.1](https://developercertificate.org/).
- Do not copy code, assets, test media or protocol text from another project unless its licence is compatible with
  GPL-3.0-or-later; keep its notice and describe it in [Vendor/README.md](Vendor/README.md).
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
- [ ] `bash Scripts/test.sh` passes, and `bash Scripts/build.sh iphonesimulator` builds.
- [ ] Streaming-related changes name the phones, OS versions and the same-settings comparison.
- [ ] New behaviour is default off, labelled Experimental, and listed in the README table.
- [ ] Protocol or security changes link to a reviewed design in the Android repository.
- [ ] Commits are signed off (`git commit -s`), and the diff contains no private data.
