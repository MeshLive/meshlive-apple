#!/bin/bash
# Read-only store-build checks for a built MeshLive.app. Exit 0 only if every check passes.
#
#   Scripts/release-check.sh <path-to-MeshLive.app> [--store] [--archive <xcarchive>]
#
# Without --store the build must carry an empty MeshLiveDistribution (a source build). With --store it must say
# "appstore" and carry a source commit. --archive checks the archive's dSYMs against the app executable.
set -u

usage() {
    echo "usage: $0 <path-to-MeshLive.app> [--store] [--archive <xcarchive>]" >&2
    exit 2
}

[ $# -ge 1 ] || usage
app="$1"
shift
store=0
archive=""
while [ $# -gt 0 ]; do
    case "$1" in
        --store) store=1; shift ;;
        --archive) [ $# -ge 2 ] || usage; archive="$2"; shift 2 ;;
        *) usage ;;
    esac
done

failures=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }
info() { echo "INFO $1"; }
skip() { echo "SKIP $1"; }
pb() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

if [ ! -d "$app" ]; then
    fail "app bundle exists: $app"
    exit 1
fi
if [ -f "$app/Info.plist" ]; then
    plist="$app/Info.plist"
    resources="$app"
elif [ -f "$app/Contents/Info.plist" ]; then
    plist="$app/Contents/Info.plist"
    resources="$app/Contents/Resources"
    info "Mac bundle: Contents/Info.plist and Contents/Resources"
else
    fail "Info.plist exists (bundle root or Contents/)"
    exit 1
fi

# 1. Info.plist.
if [ -f "$plist" ] && plutil -lint "$plist" >/dev/null 2>&1; then
    pass "Info.plist is a valid plist"
else
    fail "Info.plist is a valid plist"
fi

version="$(pb "$plist" CFBundleShortVersionString)"
if [ "$version" = "1.0" ]; then
    pass "CFBundleShortVersionString is 1.0"
else
    fail "CFBundleShortVersionString is 1.0 (found: '${version}')"
fi

build="$(pb "$plist" CFBundleVersion)"
if [[ "$build" =~ ^[0-9]+$ ]]; then
    pass "CFBundleVersion is an integer (${build})"
else
    fail "CFBundleVersion is an integer (found: '${build}')"
fi

encryption="$(pb "$plist" ITSAppUsesNonExemptEncryption)"
if [ "$encryption" = "false" ]; then
    pass "ITSAppUsesNonExemptEncryption is false"
else
    fail "ITSAppUsesNonExemptEncryption is false (found: '${encryption}')"
fi

for key in NSBluetoothAlwaysUsageDescription NSCameraUsageDescription NSMicrophoneUsageDescription; do
    value="$(pb "$plist" "$key")"
    if [ -n "$value" ]; then
        pass "$key is present and non-empty"
    else
        fail "$key is present and non-empty"
    fi
done

iphone="$(pb "$plist" LSRequiresIPhoneOS)"
if [ "$iphone" = "true" ]; then
    if /usr/libexec/PlistBuddy -c "Print :NSLocalNetworkUsageDescription" "$plist" >/dev/null 2>&1; then
        fail "NSLocalNetworkUsageDescription is absent (iPhone bundle)"
    else
        pass "NSLocalNetworkUsageDescription is absent (iPhone bundle)"
    fi
    minimum="$(pb "$plist" MinimumOSVersion)"
    if [ "$minimum" = "17.0" ]; then
        pass "MinimumOSVersion is 17.0"
    else
        fail "MinimumOSVersion is 17.0 (found: '${minimum}')"
    fi
    modes="$(plutil -extract UIBackgroundModes json -o - "$plist" 2>/dev/null | tr -d '[]" ' | tr ',' '\n' | sort | tr '\n' ' ')"
    if [ "$modes" = "audio bluetooth-central bluetooth-peripheral " ]; then
        pass "UIBackgroundModes is exactly audio, bluetooth-central, bluetooth-peripheral"
    else
        fail "UIBackgroundModes is exactly audio, bluetooth-central, bluetooth-peripheral (found: '${modes}')"
    fi
else
    info "not an iPhone bundle: the iPhone-only plist checks are skipped"
    minimum="$(pb "$plist" LSMinimumSystemVersion)"
    if [ "$minimum" = "14.0" ]; then
        pass "LSMinimumSystemVersion is 14.0 (Mac bundle)"
    else
        fail "LSMinimumSystemVersion is 14.0 (Mac bundle) (found: '${minimum}')"
    fi
fi

# 2. Distribution.
distribution="$(pb "$plist" MeshLiveDistribution)"
if [ "$store" = 1 ]; then
    if [ "$distribution" = "appstore" ]; then
        pass "MeshLiveDistribution is appstore (store build)"
    else
        fail "MeshLiveDistribution is appstore (store build) (found: '${distribution}')"
    fi
    commit="$(pb "$plist" MeshLiveSourceCommit)"
    if [[ "$commit" =~ ^[0-9a-f]{7,40}$ ]]; then
        pass "MeshLiveSourceCommit is a commit hash (${commit})"
    else
        fail "MeshLiveSourceCommit is a commit hash (found: '${commit}')"
    fi
else
    if [ -z "$distribution" ]; then
        pass "MeshLiveDistribution is empty (source build)"
    else
        fail "MeshLiveDistribution is empty (source build) (found: '${distribution}')"
    fi
fi

# 3. Privacy manifest.
manifest="$resources/PrivacyInfo.xcprivacy"
if [ -f "$manifest" ]; then
    pass "PrivacyInfo.xcprivacy is in the bundle"
else
    fail "PrivacyInfo.xcprivacy is in the bundle"
fi
if [ -f "$manifest" ] && plutil -lint "$manifest" >/dev/null 2>&1; then
    pass "PrivacyInfo.xcprivacy is a valid plist"
else
    fail "PrivacyInfo.xcprivacy is a valid plist"
fi
tracking="$(pb "$manifest" NSPrivacyTracking)"
if [ "$tracking" = "false" ]; then
    pass "NSPrivacyTracking is false"
else
    fail "NSPrivacyTracking is false (found: '${tracking}')"
fi
collected="$(plutil -extract NSPrivacyCollectedDataTypes json -o - "$manifest" 2>/dev/null | tr -d '[:space:]')"
if [ "$collected" = "[]" ]; then
    pass "NSPrivacyCollectedDataTypes is empty"
else
    fail "NSPrivacyCollectedDataTypes is empty (found: '${collected}')"
fi
if python3 - "$manifest" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    manifest = plistlib.load(f)
wanted = {
    "NSPrivacyAccessedAPICategorySystemBootTime": "35F9.1",
    "NSPrivacyAccessedAPICategoryUserDefaults": "CA92.1",
    "NSPrivacyAccessedAPICategoryFileTimestamp": "C617.1",
}
found = {entry.get("NSPrivacyAccessedAPIType"): entry.get("NSPrivacyAccessedAPITypeReasons", [])
         for entry in manifest.get("NSPrivacyAccessedAPITypes", [])}
for category, reason in wanted.items():
    if category not in found:
        print("missing category " + category, file=sys.stderr)
        sys.exit(1)
    if reason not in found[category]:
        print("missing reason " + reason + " for " + category, file=sys.stderr)
        sys.exit(1)
PY
then
    pass "privacy manifest lists the three required-reason API categories with their reasons"
else
    fail "privacy manifest lists the three required-reason API categories with their reasons"
fi

# 4. Legal files at the bundle root.
legal="LICENSE LICENSE-EXCEPTION.md OPUS-COPYING LIBVPX-LICENSE LIBVPX-PATENTS UNICODE-LICENSE.txt WEBRTC-LICENSE"
for name in $legal; do
    if [ -s "$resources/$name" ]; then
        pass "$name is in the bundle and non-empty"
    else
        fail "$name is in the bundle and non-empty"
    fi
done

# 5. DEBUG screenshot arguments are only counted, never a failure.
exe_name="$(pb "$plist" CFBundleExecutable)"
if [ -x "$app/Contents/MacOS/$exe_name" ]; then
    executable="$app/Contents/MacOS/$exe_name"
else
    executable="$app/$exe_name"
fi
if [ -x "$executable" ]; then
    screen_count="$(strings -a "$executable" | grep -c -- "-NearbyScreen" || true)"
    fixture_count="$(strings -a "$executable" | grep -c -- "-NearbyFixture" || true)"
    info "-NearbyScreen strings: ${screen_count}"
    info "-NearbyFixture strings: ${fixture_count}"
else
    fail "app executable exists: ${executable}"
fi

# 6. Entitlements of a signed bundle.
if codesign -dv "$app" >/dev/null 2>&1; then
    entitlements="$(codesign -d --entitlements - "$app" 2>/dev/null)"
    if printf '%s\n' "$entitlements" | grep -q "com.apple.developer.networking.HotspotConfiguration"; then
        fail "entitlements carry no HotspotConfiguration"
    else
        pass "entitlements carry no HotspotConfiguration"
    fi
    if printf '%s\n' "$entitlements" | grep -A1 "get-task-allow" | grep -q "<true/>"; then
        fail "entitlements do not allow get-task-allow"
    else
        pass "entitlements do not allow get-task-allow"
    fi
else
    skip "code signing: the bundle is unsigned"
fi

# 7. dSYM beside the app or in an archive.
dsym=""
if [ -n "$archive" ]; then
    dsym="$archive/dSYMs/MeshLive.app.dSYM"
elif [ -d "$app.dSYM" ]; then
    dsym="$app.dSYM"
fi
if [ -z "$dsym" ]; then
    skip "dSYM: none beside the app (pass --archive <xcarchive>)"
elif [ ! -d "$dsym" ]; then
    fail "dSYM exists: ${dsym}"
elif [ -x "$executable" ] && [ "$(dwarfdump --uuid "$executable" | awk '{print $2}' | sort -u)" = "$(dwarfdump --uuid "$dsym" | awk '{print $2}' | sort -u)" ]; then
    pass "dSYM UUID matches the app executable"
else
    fail "dSYM UUID matches the app executable"
fi

if [ $failures -gt 0 ]; then
    exit 1
fi
exit 0
