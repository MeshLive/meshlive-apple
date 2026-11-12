#!/bin/bash
# Store screenshots for App Store Connect, from fixtures and simulators only.
#
#   bash Scripts/store-screenshots.sh ios [OUT]
#   bash Scripts/store-screenshots.sh mac [OUT]
#
# Default OUT: .build/store-screenshots/<UTC stamp>. The script boots the two named iOS 26.5 simulators one after the
# other (or runs the Mac UI tests), writes fixture-only PNGs, and normalises them to the App Store pixel sizes without an
# alpha channel. It never touches a real device and never uploads anything.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    echo "usage: $0 ios|mac [OUT]" >&2
    exit 2
}

platform="${1:-}"
[ -n "$platform" ] || usage
shift
[ "$#" -le 1 ] || usage

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${1:-.build/store-screenshots/$stamp}"
DERIVED="${DERIVED:-.build/xcode}"
SLOT="${SLOT:-$HOME/MeshLive/bin/slot}"
CURRENT_UDID=""
mkdir -p "$OUT"

cleanup() {
    if [ -n "$CURRENT_UDID" ]; then
        xcrun simctl status_bar "$CURRENT_UDID" clear >/dev/null 2>&1 || true
    fi
    rm -rf "$OUT"/.result-*.xcresult >/dev/null 2>&1 || true
}
trap cleanup EXIT

run() {
    if [ -x "$SLOT" ]; then "$SLOT" "$@"; else "$@"; fi
}

find_udid() {
    local wanted="$1"
    xcrun simctl list devices available | awk -v wanted="$wanted" '
        /^-- iOS 26\.5 --/ { section = 1; next }
        /^-- / { section = 0 }
        section && index($0, wanted " (") > 0 {
            if (match($0, /\(([0-9A-Fa-f-]{36})\)/)) {
                print substr($0, RSTART + 1, RLENGTH - 2)
                exit
            }
        }'
}

normalize() {
    local dir="$1" pixels="$2"
    local width="${pixels%x*}" height="${pixels#*x}"
    local file
    for file in "$dir"/*.png; do
        [ -f "$file" ] || continue
        swift Scripts/store-shot-normalize.swift "$file" "$file.normalized.png" "$width" "$height"
        mv "$file.normalized.png" "$file"
    done
}

run_ios_set() {
    local name="$1" pixels="$2" folder="$3"
    local udid
    udid="$(find_udid "$name")"
    if [ -z "$udid" ]; then
        echo "No '$name' on iOS 26.5 in 'xcrun simctl list devices available'; stopping." >&2
        exit 1
    fi
    echo "$name ($pixels): $udid"
    CURRENT_UDID="$udid"
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b
    xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 \
        --cellularMode active --cellularBars 4 --wifiBars 3 --dataNetwork wifi
    xcrun simctl ui "$udid" appearance dark
    xcrun simctl privacy "$udid" reset all io.github.meshlive.app >/dev/null 2>&1 || true
    xcrun simctl uninstall "$udid" io.github.meshlive.app >/dev/null 2>&1 || true

    local shots="$OUT/$folder" result="$OUT/.result-$folder.xcresult"
    mkdir -p "$shots"
    rm -rf "$result"
    export TEST_RUNNER_NEARBY_STORE_SHOTS=1
    export TEST_RUNNER_NEARBY_EXPECT_PIXELS="$pixels"
    export TEST_RUNNER_NEARBY_SHOT_DIR="$shots"
    run xcodebuild test -project MeshLive.xcodeproj -scheme MeshLive-iOS -configuration Debug \
        -destination "id=$udid" -derivedDataPath "$DERIVED" -resultBundlePath "$result" \
        CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES \
        -only-testing:MeshLive-iOS-UITests/StoreScreenshotTests

    xcrun simctl status_bar "$udid" clear >/dev/null 2>&1 || true
    CURRENT_UDID=""
    normalize "$shots" "$pixels"
    rm -rf "$result"
}

run_ios() {
    run_ios_set "iPhone 17 Pro Max" 1320x2868 ios-6.9
    run_ios_set "iPhone 17 Pro" 1206x2622 ios-6.3
}

# The Mac UI test runner cannot write outside its own container, so the Mac screenshots are taken from the result
# bundle's attachments (each test attaches its PNG as "store-<NN>-<name>").
export_attachments() {
    local result="$1" shots="$2" tmp
    tmp="$(mktemp -d)"
    if xcrun xcresulttool export attachments --path "$result" --output-path "$tmp" >/dev/null 2>&1; then
        python3 - "$tmp" "$shots" <<'PY'
import json, shutil, sys, pathlib
tmp, shots = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
for test in json.loads((tmp / "manifest.json").read_text()):
    for item in test.get("attachments", []):
        name = item.get("suggestedHumanReadableName", "")
        if name.startswith("store-") and not (shots / (name[6:].split("_0_")[0] + ".png")).exists():
            shutil.copy(tmp / item["exportedFileName"], shots / (name[6:].split("_0_")[0] + ".png"))
PY
    fi
    rm -rf "$tmp"
}

run_mac() {
    local shots="$OUT/mac" result="$OUT/.result-mac.xcresult" status=0
    mkdir -p "$shots"
    rm -rf "$result"
    export TEST_RUNNER_NEARBY_STORE_SHOTS=1
    export TEST_RUNNER_NEARBY_SHOT_DIR="$shots"
    unset TEST_RUNNER_NEARBY_EXPECT_PIXELS
    run xcodebuild test -project MeshLive.xcodeproj -scheme MeshLive -configuration Debug \
        -destination "platform=macOS" -derivedDataPath "$DERIVED" -resultBundlePath "$result" \
        -only-testing:MeshLiveUITests/StoreScreenshotTests || status=$?
    export_attachments "$result" "$shots"
    normalize "$shots" 2880x1800
    rm -rf "$result"
    return "$status"
}

case "$platform" in
    ios) run_ios ;;
    mac) run_mac ;;
    *) usage ;;
esac

echo "Screenshots in $OUT:"
find "$OUT" -type f -name '*.png' | sort | while IFS= read -r file; do
    printf '%10s bytes  %s\n' "$(stat -f%z "$file")" "$file"
done
echo "Review the PNGs, then copy them to App Store Connect by hand. Nothing was uploaded."
