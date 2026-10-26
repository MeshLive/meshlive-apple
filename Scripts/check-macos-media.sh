#!/bin/bash
# Offline codec regression: no camera, microphone, Bluetooth or permission requests.
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun --sdk macosx clang -target arm64-apple-macos14.0 -g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer -I App/Media -I .build/opus/macos-source/opus-1.6.1/include Scripts/opus-check.c App/Media/NativeAudio.c .build/opus/macos-arm64/.libs/libopus.a -o .build/opus/macos-codec-check
.build/opus/macos-codec-check
