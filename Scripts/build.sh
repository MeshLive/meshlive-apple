#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# DERIVED: derived data folder (default .build/xcode); the app lands in $DERIVED/Build/Products/Debug-<sdk>/.
sdk="${1:-iphoneos}"
if [[ "$sdk" != iphoneos && "$sdk" != iphonesimulator ]]; then echo "Use iphoneos or iphonesimulator" >&2; exit 2; fi
if [[ ! -d Vendor/Opus.xcframework ]] && grep -q 'Opus.xcframework' MeshLive.xcodeproj/project.pbxproj; then
    echo 'Run bash Scripts/prepare-opus.sh first. For the explicitly labeled PCM diagnostic only, regenerate with python3 Scripts/project.py.' >&2
    exit 1
fi
xcodebuild -project MeshLive.xcodeproj -scheme MeshLive-iOS -configuration Debug -sdk "$sdk" -destination "generic/platform=$([[ "$sdk" == iphoneos ]] && echo iOS || echo 'iOS Simulator')" -derivedDataPath "${DERIVED:-.build/xcode}" $([[ "$sdk" == iphonesimulator ]] && echo "CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES" || echo "CODE_SIGNING_ALLOWED=NO") build
