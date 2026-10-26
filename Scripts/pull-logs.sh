#!/bin/bash
# Copies the app's Documents/logs from a connected iPhone into .build/device-logs/<timestamp>/logs.
# Usage: bash Scripts/pull-logs.sh [device-udid] [bundle-id]
set -euo pipefail
cd "$(dirname "$0")/.."
device="${1:-${DEVICE:?Set DEVICE to the iPhone UDID}}"
bundle="${2:-${BUNDLE:-io.github.meshlive.app}}"
out=".build/device-logs/$(date +%Y%m%d-%H%M%S)-pull"
mkdir -p "$out"
xcrun devicectl device copy from --device "$device" --domain-type appDataContainer --domain-identifier "$bundle" \
    --source Documents/logs --destination "$out/logs" > "$out/copy.txt" 2>&1 || { cat "$out/copy.txt"; exit 1; }
ls -1t "$out/logs" | head -5
echo "$out"
