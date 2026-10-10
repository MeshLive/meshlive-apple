#!/bin/bash
# Simulator screenshots of the main screens in dark and light mode (DEBUG -NearbyScreen aid).
# Usage: bash Scripts/screenshots.sh [simulator-udid]   Output: .build/screenshots/<stamp>/
set -euo pipefail
cd "$(dirname "$0")/.."
sim="${1:-booted}"
app=.build/xcode/Build/Products/Debug-iphonesimulator/NearbyIntercom.app
[[ -d "$app" ]] || bash Scripts/build.sh iphonesimulator
out=".build/screenshots/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
xcrun simctl install "$sim" "$app"
for appearance in dark light; do
    xcrun simctl ui "$sim" appearance "$appearance"
    for screen in home people watch call settings verify; do
        args=(); [[ "$screen" != home ]] && args=(-NearbyScreen "$screen")
        xcrun simctl launch --terminate-running-process "$sim" org.nearbyintercom.ios ${args[@]+"${args[@]}"} > /dev/null
        sleep 3
        xcrun simctl io "$sim" screenshot "$out/$screen-$appearance.png" > /dev/null 2>&1
    done
done
xcrun simctl ui "$sim" appearance dark
ls "$out"
echo "$out"
