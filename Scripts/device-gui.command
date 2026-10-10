#!/bin/bash
# Runs one queued device action inside the logged-in GUI session, where the login keychain is unlocked
# for codesign (SSH sessions see it locked). Started by Scripts/gui-run.sh via `open -a Terminal`;
# never asks for or stores a password and changes no settings. Output: .build/device-logs/<stamp>-<action>/.
cd "$(dirname "$0")/.." || exit 1
request=.build/device-gui/request
[[ -f "$request" ]] || { echo "No queued request ($request)"; exit 0; }
read -r action rest < "$request"
out=$(cat .build/device-gui/outdir)
rm -f "$request"
mkdir -p "$out"
: "${TEAM:?Set TEAM to your Apple team ID}" "${DEVICE:?Set DEVICE to the iPhone UDID}"; export TEAM DEVICE BUNDLE="${BUNDLE:-org.nearbyintercom.ios}"
echo "MeshLive device action: $action $rest (log: $out)"
case "$action" in
    install) bash Scripts/run-device.sh "$DEVICE" > "$out/build.log" 2>&1 ;;
    uitest) OUT="$out" bash Scripts/run-uitest.sh $rest > "$out/uitest.log" 2>&1 ;;
    *) echo "Unknown action $action" > "$out/build.log"; false ;;
esac
code=$?
echo "$code" > "$out/exit-code"
echo "Done ($code). This window can close."
exit 0
