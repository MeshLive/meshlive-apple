#!/bin/bash
# UI launch smoke only. A simulator cannot verify this app's physical Bluetooth path.
set -euo pipefail
cd "$(dirname "$0")/.."
device="${1:-$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["udid"] for v in d["devices"].values() for x in v if "iPhone" in x["name"]))')}"
app="${DERIVED:-.build/xcode}/Build/Products/Debug-iphonesimulator/NearbyIntercom.app"
[[ -d "$app" ]] || bash Scripts/build.sh iphonesimulator
state="$(xcrun simctl list devices -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["state"] for v in d["devices"].values() for x in v if x["udid"]==sys.argv[1]))' "$device")"
if [[ "$state" != Booted ]]; then xcrun simctl boot "$device"; fi
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" "$app"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")"
xcrun simctl launch "$device" "$bundle_id"
echo "UI launched on $device. This is not a Bluetooth, microphone or physical media test."
