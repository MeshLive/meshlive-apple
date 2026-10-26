#!/bin/bash
# Build the native Mac app: bash Scripts/build-macos.sh [Debug|Release]
# Signing: ad-hoc unless MESHLIVE_SIGN_IDENTITY is set (see Scripts/macos-signing.sh).
# DERIVED: derived data folder (default .build/dd-mac); the app lands in $DERIVED/Build/Products/<config>/MeshLive.app.
set -euo pipefail
cd "$(dirname "$0")/.."
config="${1:-Debug}"
[[ "$config" == Debug || "$config" == Release ]] || { echo "Use Debug or Release" >&2; exit 2; }
source Scripts/macos-signing.sh
derived="${DERIVED:-.build/dd-mac}"
xcodebuild -project MeshLive.xcodeproj -scheme MeshLive -configuration "$config" -destination "platform=macOS" \
    -derivedDataPath "$derived" ${MAC_SIGNING[@]+"${MAC_SIGNING[@]}"} build
app="$derived/Build/Products/$config/MeshLive.app"
codesign --verify --strict "$app"
echo "Built $app"
# The designated requirement is what macOS privacy permissions remember: a cdhash changes with every build, a
# certificate-based requirement stays the same.
codesign -d -r- "$app" 2>&1 | sed -En 's/^(# )?designated => /Designated requirement: /p'
