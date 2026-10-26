#!/bin/bash
# Build, install and launch on a connected iPhone with your own signing (nothing personal is committed).
# Usage: TEAM=<team id> BUNDLE=<unique bundle id> bash Scripts/run-device.sh [device-udid]
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/xcode-device/results
: "${TEAM:?Set TEAM to your Apple development team ID}"
: "${BUNDLE:?Set BUNDLE to a unique bundle identifier, e.g. com.yourname.meshlive}"
device="${1:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /connected/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) {print $i; exit}}')}"
[[ -n "$device" ]] || { echo "No connected iPhone found (xcrun devicectl list devices)" >&2; exit 1; }
xcodebuild -project MeshLive.xcodeproj -scheme MeshLive-iOS -configuration Debug -destination "id=$device" \
    -derivedDataPath .build/xcode-device -resultBundlePath ".build/xcode-device/results/$(date +%Y%m%d-%H%M%S).xcresult" -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE" CODE_SIGN_STYLE=Automatic build
app=.build/xcode-device/Build/Products/Debug-iphoneos/MeshLive.app
xcrun devicectl device install app --device "$device" "$app"
echo "Installed $BUNDLE on $device"
xcrun devicectl device process launch --device "$device" --terminate-existing "$BUNDLE" || echo "Installed, but not launched (unlock the iPhone and keep it unlocked)" >&2
