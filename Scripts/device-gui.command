#!/bin/bash
# Runs one queued action inside the logged-in GUI session, where the login keychain is unlocked for codesign
# (SSH sessions see it locked). Started by Scripts/gui-run.sh via `open -a Terminal`; never asks for or stores a
# password and changes no settings. Output: .build/device-logs/<stamp>-<action>/.
cd "$(dirname "$0")/.." || exit 1
request=.build/device-gui/request
[[ -f "$request" ]] || { echo "No queued request ($request)"; exit 0; }
read -r action rest < "$request"
out=$(cat .build/device-gui/outdir)
rm -f "$request"
if [[ -f .build/device-gui/env ]]; then source .build/device-gui/env; rm -f .build/device-gui/env; fi
mkdir -p "$out"
iphone() {
    [[ -n "${TEAM:-}" && -n "${DEVICE:-}" ]] || { echo "Set TEAM (Apple team ID) and DEVICE (iPhone UDID)" > "$out/build.log"; return 1; }
    export TEAM DEVICE BUNDLE="${BUNDLE:-io.github.meshlive.app}"
}
echo "MeshLive GUI action: $action $rest (log: $out)"
case "$action" in
    install) iphone && bash Scripts/run-device.sh "$DEVICE" > "$out/build.log" 2>&1 ;;
    uitest) iphone && OUT="$out" bash Scripts/run-uitest.sh $rest > "$out/uitest.log" 2>&1 ;;
    mac-build) bash Scripts/build-macos.sh $rest > "$out/build.log" 2>&1 ;;
    mac-uitest) bash Scripts/run-macos-uitest.sh "$out/ui" > "$out/build.log" 2>&1 ;;
    *) echo "Unknown action $action" > "$out/build.log"; false ;;
esac
code=$?
echo "$code" > "$out/exit-code"
echo "Done ($code). This window can close."
exit 0
