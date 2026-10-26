#!/bin/bash
# Build the pinned codec for the native Apple Silicon Mac app only (iOS artifacts are untouched).
set -euo pipefail
cd "$(dirname "$0")/.."
version=1.6.1
expected=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
mkdir -p .build/opus/macos-source .build/opus/macos-arm64
archive="$(pwd)/.build/opus/opus-$version.tar.gz"
if [[ ! -f "$archive" ]]; then curl --fail --location --max-time 180 "https://downloads.xiph.org/releases/opus/opus-$version.tar.gz" -o "$archive"; fi
[[ "$(shasum -a 256 "$archive" | awk '{print $1}')" == "$expected" ]] || { echo "Opus SHA256 mismatch" >&2; exit 1; }
tar -xzf "$archive" -C .build/opus/macos-source
source_dir="$(pwd)/.build/opus/macos-source/opus-$version"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
compiler="$(xcrun --sdk macosx --find clang)"
(
    cd .build/opus/macos-arm64
    CC="$compiler" CFLAGS="-O2 -target arm64-apple-macos14.0 -isysroot $sdk_path" LDFLAGS="-target arm64-apple-macos14.0 -isysroot $sdk_path" "$source_dir/configure" --host=aarch64-apple-darwin --disable-shared --enable-static --disable-asm --disable-rtcd --disable-extra-programs --disable-doc --disable-intrinsics --disable-dred --disable-osce
    make -j4
)
python3 Scripts/project.py
echo "Pinned macOS Opus ready; iOS artifacts are unchanged."
