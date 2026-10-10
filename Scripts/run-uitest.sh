#!/bin/bash
# XCUITest device scenarios with screenshots (UITests/ScenarioTests.swift). Needs code signing, so run it in
# the GUI session: bash Scripts/gui-run.sh uitest call ABCDE-FGHIJ voice 30 | bash Scripts/gui-run.sh uitest people
# Output: the .xcresult and its exported screenshots/attachments under the gui-run log folder (or .build/device-logs).
set -uo pipefail
cd "$(dirname "$0")/.."
device="${DEVICE:?Set DEVICE to the iPhone UDID}"; team="${TEAM:?Set TEAM to your Apple team ID}"
scenario="${1:-people}"; shift || true
out="${OUT:-.build/device-logs/$(date +%Y%m%d-%H%M%S)-uitest}"
mkdir -p "$out"
case "$scenario" in
    call) export TEST_RUNNER_NEARBY_TARGET="${1:-first}" TEST_RUNNER_NEARBY_CALL_TYPE="${2:-voice}" TEST_RUNNER_NEARBY_HOLD_SECONDS="${3:-20}"
          only=NearbyIntercomUITests/ScenarioTests/testCall ;;
    people) export TEST_RUNNER_NEARBY_SCAN_SECONDS="${1:-8}"; only=NearbyIntercomUITests/ScenarioTests/testPeopleList ;;
    *) echo "Unknown scenario $scenario (call|people)" >&2; exit 2 ;;
esac
xcodebuild test -project NearbyIntercom.xcodeproj -scheme NearbyIntercom -configuration Debug -destination "id=$device" \
    -derivedDataPath .build/xcode-device -resultBundlePath "$out/result.xcresult" -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic -only-testing:"$only" > "$out/xcodebuild.log" 2>&1
code=$?
mkdir -p "$out/attachments"
xcrun xcresulttool export attachments --path "$out/result.xcresult" --output-path "$out/attachments" > "$out/export.log" 2>&1 || true
# Name the exported files by step (01-home.png, people.txt, ...).
python3 - "$out/attachments" <<'EOF'
import json, os, re, sys
d = sys.argv[1]
try: manifest = json.load(open(os.path.join(d, "manifest.json")))
except Exception: sys.exit(0)
for test in manifest:
    for a in test.get("attachments", []):
        name = re.sub(r"_\d+_[0-9A-F-]{36}", "", a["suggestedHumanReadableName"])
        src = os.path.join(d, a["exportedFileName"])
        if os.path.exists(src): os.replace(src, os.path.join(d, name))
EOF
grep -E "Test Case|error:|passed|failed" "$out/xcodebuild.log" | tail -n 15
ls "$out/attachments" | head -40
echo "exit=$code out=$out"
exit $code
