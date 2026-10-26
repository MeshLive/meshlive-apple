#!/bin/bash
# Non-interactive iPhone scenarios over SSH through the DEBUG launch-argument hook (App/Diagnostics/Automation.swift).
# The iPhone must be unlocked; microphone/camera permission must already be granted (see docs/dev/testing.md).
#   bash Scripts/run-scenario.sh call <handle|short|prefix|first> voice|video <seconds>
#   bash Scripts/run-scenario.sh answer voice|video <listen-seconds> [hang-up-after-seconds]
#   bash Scripts/run-scenario.sh launch            # plain launch, logs only
# Output: .build/device-logs/<stamp>-<scenario>/ (launch output, pulled app logs, summary of BENCHMARK lines).
set -uo pipefail
cd "$(dirname "$0")/.."
device="${DEVICE:?Set DEVICE to the iPhone UDID}"; bundle="${BUNDLE:-io.github.meshlive.app}"
scenario="${1:?call, answer or launch}"; shift
args=(); wait_seconds=10
case "$scenario" in
    call)
        target="${1:?handle}"; type="${2:-voice}"; seconds="${3:-30}"
        args=(-NearbyAvailable 1 -NearbyAutoCall "$target" -NearbyCallType "$type" -NearbyCallSeconds "$seconds")
        wait_seconds=$((seconds + 75)) ;;
    answer)
        type="${1:-voice}"; listen="${2:-120}"
        args=(-NearbyAvailable 1 -NearbyAutoAccept "$type")
        [[ -n "${3:-}" ]] && args+=(-NearbyAnswerSeconds "$3")
        wait_seconds="$listen" ;;
    launch) ;;
    *) echo "Unknown scenario $scenario" >&2; exit 2 ;;
esac
out=".build/device-logs/$(date +%Y%m%d-%H%M%S)-$scenario"
mkdir -p "$out"
echo "Launching $bundle on $device: ${args[*]+${args[*]}}" | tee "$out/launch.txt"
if ! xcrun devicectl device process launch --device "$device" --terminate-existing "$bundle" ${args[@]+-- "${args[@]}"} >> "$out/launch.txt" 2>&1; then
    grep -q -i "locked" "$out/launch.txt" && echo "The iPhone is locked: unlock it (and keep Auto-Lock off while testing)." >&2
    tail -n 5 "$out/launch.txt"; exit 1
fi
echo "Running for ${wait_seconds}s..."
for ((i = 0; i < wait_seconds; i += 5)); do
    sleep 5
    # A call scenario is done once the app logs its final auto_call result.
    if [[ "$scenario" == call ]] && xcrun devicectl device copy from --device "$device" --domain-type appDataContainer --domain-identifier "$bundle" \
        --source Documents/logs --destination "$out/logs" > /dev/null 2>&1 && \
        grep -h -q -E "auto_call: .*result=(hang_up|failed|call_gone|not_found|never_active)" $(ls -1t "$out"/logs/*.log 2>/dev/null | head -1) 2>/dev/null; then
        sleep 3; break
    fi
done
xcrun devicectl device copy from --device "$device" --domain-type appDataContainer --domain-identifier "$bundle" \
    --source Documents/logs --destination "$out/logs" > "$out/copy.txt" 2>&1
latest=$(ls -1t "$out"/logs/*.log 2>/dev/null | head -1)
[[ -n "$latest" ]] || { echo "No app log pulled"; exit 1; }
grep -E "BENCHMARK (app_start|auto_|permissions|call_|audio_|camera_|connect|link_closed|incoming_link)" "$latest" > "$out/summary.txt"
cat "$out/summary.txt"
echo "log=$latest"
