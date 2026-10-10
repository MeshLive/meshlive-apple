#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/diagnostics
xcrun clang -std=c11 -fsanitize=address,undefined -I App/Media App/Media/NativeAudio.c Scripts/native-audio-check.c -o .build/diagnostics/audio-ring-check
.build/diagnostics/audio-ring-check
bash Scripts/test.sh --filter CoreUtilityTests/testRealResamplingPreservesToneAndDuration
