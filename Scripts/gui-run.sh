#!/bin/bash
# From SSH: queue an action for the GUI session (where codesign can use the login keychain) and wait for it.
# Usage: bash Scripts/gui-run.sh install | uitest <scenario> [args...]   (iPhone; needs TEAM and DEVICE)
#        bash Scripts/gui-run.sh mac-build [Debug|Release] | mac-uitest       (Mac; MESHLIVE_SIGN_IDENTITY optional)
# TEAM, DEVICE, BUNDLE, MESHLIVE_SIGN_IDENTITY and MESHLIVE_TEAM from this shell are passed to that one action
# through an ignored file under .build that the GUI side deletes after reading.
set -uo pipefail
cd "$(dirname "$0")/.."
action="${1:?install or uitest}"; shift || true
out=".build/device-logs/$(date +%Y%m%d-%H%M%S)-$action"
mkdir -p .build/device-gui "$out"
echo "$out" > .build/device-gui/outdir
( umask 077; for name in TEAM DEVICE BUNDLE MESHLIVE_SIGN_IDENTITY MESHLIVE_TEAM; do
    if [[ -n "${!name:-}" ]]; then printf 'export %s=%q
' "$name" "${!name}"; fi
done > .build/device-gui/env )
echo "$action $*" > .build/device-gui/request
chmod +x Scripts/device-gui.command
open -a Terminal Scripts/device-gui.command
for _ in $(seq 1 ${WAIT_SECONDS:-1500}); do
    [[ -f "$out/exit-code" ]] && break
    sleep 1
done
[[ -f "$out/exit-code" ]] || { echo "Timed out waiting for $out/exit-code"; exit 124; }
code=$(cat "$out/exit-code")
tail -n 25 "$out"/*.log
echo "exit=$code log=$out"
exit "$code"
