#!/bin/bash
# Optional dependency, installed only by explicitly running this script on a networked Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
version=1.6.1
expected=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
mkdir -p .build/opus Vendor
archive="$(pwd)/.build/opus/opus-$version.tar.gz"
if [[ ! -f "$archive" ]]; then curl --fail --location --max-time 180 "https://downloads.xiph.org/releases/opus/opus-$version.tar.gz" -o "$archive"; fi
actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || { echo "Opus SHA256 mismatch" >&2; exit 1; }
tar -xzf "$archive" -C .build/opus
source_dir="$(pwd)/.build/opus/opus-$version"
for spec in iphoneos:arm64 iphonesimulator:arm64 iphonesimulator:x86_64; do
    sdk="${spec%%:*}"; arch="${spec##*:}"
    task_dir="$(pwd)/.build/opus/$sdk-$arch"; mkdir -p "$task_dir"
    sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
    compiler="$(xcrun --sdk "$sdk" --find clang)"
    if [[ "$sdk" == iphoneos ]]; then target="$arch-apple-ios16.0"; else target="$arch-apple-ios16.0-simulator"; fi
    if [[ "$arch" == arm64 ]]; then host=aarch64-apple-darwin; else host=x86_64-apple-darwin; fi
    (
        cd "$task_dir"
        CC="$compiler" CFLAGS="-O2 -target $target -isysroot $sdk_path" LDFLAGS="-target $target -isysroot $sdk_path" "$source_dir/configure" --host="$host" --disable-shared --enable-static --disable-asm --disable-rtcd --disable-extra-programs --disable-doc --disable-intrinsics --disable-dred --disable-osce
        make -j4
    )
done
mkdir -p .build/opus/simulator
xcrun lipo -create .build/opus/iphonesimulator-arm64/.libs/libopus.a .build/opus/iphonesimulator-x86_64/.libs/libopus.a -output .build/opus/simulator/libopus.a
if [[ -d Vendor/Opus.xcframework ]]; then mv Vendor/Opus.xcframework ".build/opus/previous-$(date +%s).xcframework"; fi
xcodebuild -create-xcframework -library .build/opus/iphoneos-arm64/.libs/libopus.a -headers "$source_dir/include" -library .build/opus/simulator/libopus.a -headers "$source_dir/include" -output Vendor/Opus.xcframework
cp "$source_dir/COPYING" Vendor/OPUS-COPYING
cp "$source_dir/README" Vendor/OPUS-README
python3 Scripts/project.py
echo "Pinned Opus installed. Build both SDKs, then run the physical voice checks in docs/dev/testing.md."
