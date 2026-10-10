# Android-generated vectors

`Tests/NearbyCoreTests/Fixtures/android-vectors.json` is produced by the Android app's own protocol classes, not by a reimplementation. `Gen.kt` is the generator. It is compiled together with unchanged copies of these Android sources (repository `app/src/main/java/com/example/bluetoothtest/`): `MeshSecurity.kt`, `MeshControlMessages.kt`, `SecureBluetoothLink.kt` (lines 1-345), `StreamProtocol.kt`, `PrivateCallSession.kt`, `EndToEndVideoSecurity.kt`, `MeshCore.kt` (lines 1-118), `ForwardedStreamSecurity.kt` (lines 1-46), `IdentityVerification.kt` (lines 1-225), `StreamDiscovery.kt`, `CallVideoFragments.kt`, `LinkSelfMeasurement.kt` (lines 1-159) and `BluetoothTransportOption.kt`. Two stubs replace Android-only types: `android.util.Log`/`android.content.Context` (no-ops), and `PeerIdentityGate` (admits every peer; it never changes wire bytes). The Android sources are not copied into this repository.

```sh
kotlinc src -include-runtime -d android-vectors.jar   # src = Gen.kt + the Android copies + stubs
java -jar android-vectors.jar > android-vectors.json  # forward vectors (Android -> Swift tests)
# Reverse check: Swift writes a transcript, Android's classes verify it.
NEARBY_TRANSCRIPT_OUT=$PWD/.build/interop-android/swift-transcript.json bash Scripts/test.sh --filter testSwiftTranscript
java -jar android-vectors.jar verify swift-transcript.json
```

Keys and signatures are random per generation; the Swift tests recompute every derived value (node IDs, ECDH/HKDF keys, AES-GCM records, codes) from the recorded secrets, so a regenerated file needs no test edits. Last generated 2026-10-10 from the Android working tree with Kotlin 2.0 (Android Studio bundled kotlinc) on Temurin 21; the reverse check printed "Swift transcript verified by Android classes".

## Peer-label vectors (naming phase 1)

`Tests/NearbyCoreTests/Fixtures/android-labels.json` comes from `GenLabels.kt`. It is compiled with the same Android copies plus `LabelText.kt`, `SignedLabel.kt` (without the `LabelRecords` stream helper) and `TitlePage.kt`, taken unchanged from the reviewed naming patch (`0001-Experimental-peer-labels-*.patch`). A small `IdentityHandle` stand-in provides `parse`/`parseShort`. The file holds Android-signed name, subject and title labels (call, stream and zero-ID bindings), a container, title pages, and Android's `LabelText` verdicts for 49 strings: scripts, handle shapes, whitespace, marks and limits. Swift must match every one. Reverse check: `NEARBY_LABELS_OUT=... bash Scripts/test.sh --filter testSwiftLabelsForAndroidVerification`, then `java -jar labels.jar verify swift-labels.json`. On 2026-10-10 it printed "Swift labels verified by Android classes".
