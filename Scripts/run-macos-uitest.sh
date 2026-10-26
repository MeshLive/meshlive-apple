#!/bin/bash
# Native macOS UI tests: bash Scripts/run-macos-uitest.sh [output-dir]
# Needs an unlocked desktop and the macOS UI-testing (automation) permission. Output stays inside this checkout.
# DERIVED: derived data folder (default .build/dd-mac).
# Uses DEBUG -NearbyPreview: no Bluetooth/media requests or production identity/preferences.
set -u
cd "$(dirname "$0")/.." || exit 1
if [[ "$#" -gt 0 ]]; then out="$1"; else out=".build/mac-uitests-$(date +%Y%m%d-%H%M%S)"; fi
out="$(python3 - "$out" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]).expanduser().resolve()
if not p.is_relative_to(pathlib.Path.cwd().resolve()):
    raise SystemExit('UI output must be inside this checkout')
print(p)
PY
)" || exit 1
[[ ! -e "$out/result.xcresult" ]] || { echo "Choose a fresh output for this execution" >&2; exit 1; }
mkdir -p "$out"
xcodebuild test -project MeshLive.xcodeproj -scheme MeshLive -destination 'platform=macOS' -derivedDataPath "${DERIVED:-.build/dd-mac}" -resultBundlePath "$out/result.xcresult" -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 45 -maximum-test-execution-time-allowance 60 >"$out/xcodebuild.log" 2>&1 &
pid=$!
cleanup() { if kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid"; wait "$pid"; fi; }
trap cleanup EXIT
trap 'exit 130' INT TERM
elapsed=0
while kill -0 "$pid" 2>/dev/null; do
    sleep 5
    elapsed=$((elapsed+5))
    if [[ "$elapsed" -ge 240 ]]; then
        echo "UI harness exceeded 240 s. Check for a user permission prompt; do not reset permissions." >>"$out/xcodebuild.log"
        kill -TERM "$pid" 2>/dev/null
        break
    fi
done
wait "$pid"
result=$?
printf 'mac-ui=%s\n' "$result" >"$out/status"
xcrun xcresulttool export attachments --path "$out/result.xcresult" --output-path "$out/shots" >"$out/export.log" 2>&1 || true
python3 - "$out/shots" <<'PY'
import json,pathlib,re,sys
d=pathlib.Path(sys.argv[1])
if not (d/'manifest.json').exists(): raise SystemExit(0)
for row in json.loads((d/'manifest.json').read_text()):
    for item in row.get('attachments',[]):
        source=d/item['exportedFileName']
        name=re.sub(r"_\d+_[0-9A-F-]{36}","",item['suggestedHumanReadableName'])
        target=d/pathlib.Path(name).name
        if source.exists() and source!=target: source.replace(target)
PY
exit "$result"
