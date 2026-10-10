#!/bin/bash
# From SSH: queue a device action for the GUI session and wait for it.
# Usage: bash Scripts/gui-run.sh install | bash Scripts/gui-run.sh uitest <scenario> [args...]
set -uo pipefail
cd "$(dirname "$0")/.."
action="${1:?install or uitest}"; shift || true
out=".build/device-logs/$(date +%Y%m%d-%H%M%S)-$action"
mkdir -p .build/device-gui "$out"
echo "$out" > .build/device-gui/outdir
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
