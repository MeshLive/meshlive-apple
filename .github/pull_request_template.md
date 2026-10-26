## What and why

<!-- The problem, with evidence that it is real (a failing test, a log summary or a measurement), and what this changes. -->

## How it was checked

<!-- Commands you ran and their results. For Bluetooth, streaming, codec, audio or lifecycle changes: the devices and
OS versions, and a before/after comparison at the same settings. Builds and simulators are not hardware proof. -->

## Checklist

- [ ] The change is narrow, and a focused test covers it.
- [ ] `bash Scripts/test.sh` and `python3 Scripts/tokens.py --check` pass, and `bash Scripts/build.sh iphonesimulator` builds.
- [ ] Mac changes: the Mac **MeshLive** scheme builds and `bash Scripts/run-macos-uitest.sh` passes.
- [ ] New behaviour is off by default, labelled Experimental and listed in [docs/dev/switches.md](../docs/dev/switches.md).
- [ ] Protocol or security changes link to a reviewed design in the Android repository.
- [ ] The documents that own the changed behaviour are updated.
- [ ] Commits are signed off (`git commit -s`), the diff contains no private data (device IDs, Bluetooth addresses,
      team IDs, personal paths, recordings of people), and substantial AI assistance is disclosed.
