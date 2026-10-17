#!/bin/bash
# XCUITest device scenarios with screenshots (UITests/ScenarioTests.swift). Needs code signing, so run it in
# the GUI session: bash Scripts/gui-run.sh uitest call ABCDE-FGHIJ voice 30 | bash Scripts/gui-run.sh uitest people
# Simulator (no signing, no GUI session): SIMULATOR=<udid> bash Scripts/run-uitest.sh screens|alerts [testName]
#   (alerts: NEARBY_ALERT_ANSWER=allow|deny answers the notification prompt; each run starts uninstalled.)
#   (UITests/SimulatorScreensTests.swift; NEARBY_CONTENT_SIZE=<UIContentSizeCategory name>, NEARBY_RTL=1 optional).
# Output: the .xcresult and its exported screenshots/attachments under the gui-run log folder (or .build/device-logs).
set -uo pipefail
cd "$(dirname "$0")/.."
scenario="${1:-people}"; shift || true
out="${OUT:-.build/device-logs/$(date +%Y%m%d-%H%M%S)-uitest}"
mkdir -p "$out"
case "$scenario" in
    call) export TEST_RUNNER_NEARBY_TARGET="${1:-first}" TEST_RUNNER_NEARBY_CALL_TYPE="${2:-voice}" TEST_RUNNER_NEARBY_HOLD_SECONDS="${3:-20}"
          only=NearbyIntercomUITests/ScenarioTests/testCall ;;
    people) export TEST_RUNNER_NEARBY_SCAN_SECONDS="${1:-8}"; only=NearbyIntercomUITests/ScenarioTests/testPeopleList ;;
    screens) only=NearbyIntercomUITests/SimulatorScreensTests${1:+/$1}
             mkdir -p "$out/shots"
             export TEST_RUNNER_NEARBY_CONTENT_SIZE="${NEARBY_CONTENT_SIZE:-}" TEST_RUNNER_NEARBY_RTL="${NEARBY_RTL:-}"
             export TEST_RUNNER_NEARBY_SHOT_DIR="$(cd "$out/shots" && pwd)" ;;
    alerts) only=NearbyIntercomUITests/CallAlertUITests${1:+/$1}
             mkdir -p "$out/shots"
             export TEST_RUNNER_NEARBY_ALERT_ANSWER="${NEARBY_ALERT_ANSWER:-deny}" TEST_RUNNER_NEARBY_SHOT_DIR="$(cd "$out/shots" && pwd)" ;;
    *) echo "Unknown scenario $scenario (call|people|screens|alerts)" >&2; exit 2 ;;
esac
if [[ -n "${SIMULATOR:-}" ]]; then
    # Ad-hoc signed simulator build; the derived data path follows Scripts/build.sh's DERIVED convention.
    # Fresh permission state so the first-use prompts are part of the run (KEEP_PRIVACY=1 skips this).
    if [[ -z "${KEEP_PRIVACY:-}" ]]; then
        xcrun simctl boot "$SIMULATOR" 2>/dev/null || true
        xcrun simctl bootstatus "$SIMULATOR" -b > /dev/null 2>&1 || true
        xcrun simctl privacy "$SIMULATOR" reset all io.github.meshlive.app > /dev/null 2>&1 || true
        # Notification permission has no simctl privacy service: only an uninstall resets it.
        xcrun simctl uninstall "$SIMULATOR" io.github.meshlive.app > /dev/null 2>&1 || true
    fi
    xcodebuild test -project NearbyIntercom.xcodeproj -scheme NearbyIntercom -configuration Debug -destination "id=$SIMULATOR" \
        -derivedDataPath "${DERIVED:-.build/xcode}" -resultBundlePath "$out/result.xcresult" \
        CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES -only-testing:"$only" > "$out/xcodebuild.log" 2>&1 &
    pid=$!
    # Xcode 27.1 can hang after the last test while it records the runtime build ("IDESchemeActionSDKRecord ...
    # invalidDigitCount"). Give it 120 s after the final suite line, then stop it and say so (exit 125 = tests passed).
    finished=""; hung=""
    while kill -0 "$pid" 2>/dev/null; do
        if [[ -z "$finished" ]] && grep -qE "^Test Suite 'Selected tests' (passed|failed)" "$out/xcodebuild.log" 2>/dev/null; then finished=$(date +%s); fi
        if [[ -n "$finished" ]] && (( $(date +%s) - finished > 120 )); then
            echo "xcodebuild did not exit 120 s after the tests finished; stopped it (result bundle may be incomplete)" | tee -a "$out/xcodebuild.log"
            kill "$pid"; sleep 2; kill -9 "$pid" 2>/dev/null; hung=1; break
        fi
        sleep 5
    done
    wait "$pid" 2>/dev/null
    code=$?
    if [[ -n "$hung" ]]; then
        if grep -q "^Test Suite 'Selected tests' passed" "$out/xcodebuild.log"; then code=125; else code=1; fi
    fi
else
    device="${DEVICE:?Set DEVICE to the iPhone UDID (or SIMULATOR to a simulator UDID)}"; team="${TEAM:?Set TEAM to your Apple team ID}"
    xcodebuild test -project NearbyIntercom.xcodeproj -scheme NearbyIntercom -configuration Debug -destination "id=$device" \
        -derivedDataPath .build/xcode-device -resultBundlePath "$out/result.xcresult" -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic -only-testing:"$only" > "$out/xcodebuild.log" 2>&1
    code=$?
fi
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
[[ -d "$out/shots" ]] && ls "$out/shots" | head -80
echo "exit=$code out=$out"
exit $code
