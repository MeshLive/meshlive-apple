#!/bin/bash
# Builds the pinned libvpx (VP9 encoder + decoder only) for iPhone, the simulator and macOS tests,
# inside this project's ignored .build folder, and installs Vendor/VPX.xcframework.
# Android sends and accepts only VP9/AV1, and iPhones have no VP9/AV1 hardware encoder, so the
# iPhone encodes VP9 in software (docs/dev/protocol.md "Media formats used by the iPhone").
set -euo pipefail
cd "$(dirname "$0")/.."
mode="all"
if [[ "$#" -gt 0 ]]; then mode="$1"; fi
[[ "$mode" == all || "$mode" == macos-only ]] || { echo "Usage: prepare-libvpx.sh [macos-only]" >&2; exit 1; }
version=1.15.2
expected=26fcd3db88045dee380e581862a6ef106f49b74b6396ee95c2993a260b4636aa
root="$(pwd)/.build/libvpx"; mkdir -p "$root" Vendor
archive="$root/libvpx-$version.tar.gz"
[[ -f "$archive" ]] || curl --fail --location --max-time 300 "https://github.com/webmproject/libvpx/archive/refs/tags/v$version.tar.gz" -o "$archive"
[[ "$(shasum -a 256 "$archive" | awk '{print $1}')" == "$expected" ]] || { echo "libvpx SHA256 mismatch" >&2; exit 1; }
[[ -d "$root/libvpx-$version" ]] || tar -xzf "$archive" -C "$root"
src="$root/libvpx-$version"
common=(--disable-examples --disable-tools --disable-docs --disable-unit-tests --disable-vp8 --enable-vp9
        --enable-realtime-only --disable-webm-io --disable-libyuv --enable-pic --enable-static --disable-shared
        --disable-debug --enable-multithread)
jobs=6
build() { # name target extra-cflags [CC]
    local name=$1 target=$2 cflags=$3 cc=${4:-}
    local dir="$root/$name"
    if [[ -f "$dir/libvpx.a" ]]; then echo "$name: cached"; return; fi
    mkdir -p "$dir"
    echo "$name: building ($target)"
    (
        cd "$dir"
        if [[ -n "$cc" ]]; then export CC="$cc" CXX="$cc" AR="$(xcrun --find ar)" LD="$cc" AS="$cc"; fi
        "$src/configure" --target="$target" "${common[@]}" --extra-cflags="$cflags"
        make -j"$jobs"
    ) > "$root/$name.log" 2>&1 || { tail -40 "$root/$name.log"; exit 1; }
}
if [[ "$mode" == all ]]; then
ios_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
sim_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
build iphoneos-arm64 arm64-darwin-gcc "-miphoneos-version-min=16.0 -O2"
# libvpx has no arm64 simulator target: use its portable C configuration (simulator speed is irrelevant).
build iphonesimulator-arm64 generic-gnu "-O2" "$(xcrun --sdk iphonesimulator --find clang) -target arm64-apple-ios16.0-simulator -isysroot $sim_sdk"
build iphonesimulator-x86_64 generic-gnu "-O2" "$(xcrun --sdk iphonesimulator --find clang) -target x86_64-apple-ios16.0-simulator -isysroot $sim_sdk"
fi
build macos-arm64 arm64-darwin24-gcc "-mmacosx-version-min=13.0 -O2"
headers="$root/headers"
if [[ "$mode" == macos-only ]]; then headers="$root/macos-headers"; fi
mkdir -p "$headers/vpx"
cp "$src"/vpx/vpx_codec.h "$src"/vpx/vpx_decoder.h "$src"/vpx/vpx_encoder.h "$src"/vpx/vpx_frame_buffer.h \
   "$src"/vpx/vpx_image.h "$src"/vpx/vpx_integer.h "$src"/vpx/vp8.h "$src"/vpx/vp8cx.h "$src"/vpx/vp8dx.h \
   "$src"/vpx/vpx_ext_ratectrl.h "$src"/vpx/vpx_tpl.h "$headers/vpx/" 2>/dev/null || true
cat > "$headers/module.modulemap" <<'MAP'
module VPX { header "vpx/vp8cx.h" header "vpx/vp8dx.h" header "vpx/vpx_encoder.h" header "vpx/vpx_decoder.h" link "vpx" export * }
MAP
if [[ "$mode" == macos-only ]]; then
    output=Vendor/VPX-macos.xcframework
    if [[ -d "$output" ]]; then mv "$output" "$root/previous-macos-$(date +%s).xcframework"; fi
    xcodebuild -create-xcframework -library "$root/macos-arm64/libvpx.a" -headers "$headers" -output "$output"
else
mkdir -p "$root/simulator"
xcrun lipo -create "$root/iphonesimulator-arm64/libvpx.a" "$root/iphonesimulator-x86_64/libvpx.a" -output "$root/simulator/libvpx.a"
if [[ -d Vendor/VPX.xcframework ]]; then mv Vendor/VPX.xcframework "$root/previous-$(date +%s).xcframework"; fi
xcodebuild -create-xcframework \
    -library "$root/iphoneos-arm64/libvpx.a" -headers "$headers" \
    -library "$root/simulator/libvpx.a" -headers "$headers" \
    -library "$root/macos-arm64/libvpx.a" -headers "$headers" \
    -output Vendor/VPX.xcframework
fi
cp "$src/LICENSE" Vendor/LIBVPX-LICENSE
cp "$src/PATENTS" Vendor/LIBVPX-PATENTS
echo "Pinned libvpx $version installed ($mode)."
