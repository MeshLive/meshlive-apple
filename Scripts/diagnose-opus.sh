#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_dir="$(pwd)/.build/opus/opus-1.6.1"
[[ -f "$source_dir/configure" ]] || bash Scripts/prepare-opus.sh
mkdir -p .build/opus/macosx-arm64 .build/diagnostics
task_dir="$(pwd)/.build/opus/macosx-arm64"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
(
    cd "$task_dir"
    CC="$(xcrun --find clang)" CFLAGS="-O2 -target arm64-apple-macos13.0 -isysroot $sdk_path" LDFLAGS="-target arm64-apple-macos13.0 -isysroot $sdk_path" "$source_dir/configure" --host=aarch64-apple-darwin --disable-shared --enable-static --disable-asm --disable-rtcd --disable-extra-programs --disable-doc --disable-intrinsics --disable-dred --disable-osce
    make -j4
) > .build/opus/mac-diagnostic-build.log 2>&1
xcrun clang -std=c11 -O1 -fsanitize=address,undefined -I App/Media -I "$source_dir/include" App/Media/NativeAudio.c Scripts/opus-check.c "$task_dir/.libs/libopus.a" -o .build/diagnostics/opus-check
.build/diagnostics/opus-check
