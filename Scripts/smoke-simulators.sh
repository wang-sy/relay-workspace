#!/bin/bash
set -euo pipefail
app="$1"
out="$2"
mkdir -p "$out"
successful_reads() {
    awk -v path="$1" '$0 == "GET /v1/" path " 200" {count++} END {print count+0}' "$RELAY_TEST_ACCESS_LOG"
}
launch_and_wait() {
    local device="$1" family="$2" before=0 reads=1 route=workspace
    shift 2
    if [[ "${1:-}" == "--preview-hosted-functions" ]]; then route=functions; fi
    if [[ "${1:-}" == "--preview-context" ]]; then
        route=context/recall
        # The first response arrives during navigation. Capture after the detail view's next refresh.
        reads=2
    fi
    if [[ -n "${RELAY_TEST_ACCESS_LOG:-}" ]]; then before=$(successful_reads "$route"); fi
    xcrun simctl launch --terminate-running-process "$device" io.github.wang-sy.RelayWorkspace "$@"
    if [[ -n "${RELAY_TEST_ACCESS_LOG:-}" ]]; then
        for ((i=0; i<30 && $(successful_reads "$route")<before+reads; i++)); do sleep 1; done
        if (( $(successful_reads "$route") < before+reads )); then
            echo "$family did not load /v1/$route" >&2
            exit 1
        fi
    else
        sleep 3
    fi
}
devices=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
devices=json.load(sys.stdin)["devices"]
runtimes=[k for k in devices if ".iOS-" in k]
for key in sorted(runtimes,key=lambda k:tuple(map(int,k.split(".iOS-")[1].split("-"))),reverse=True):
    pair=[next((d for d in devices[key] if d["isAvailable"] and d["name"].startswith(f)),None) for f in ("iPhone","iPad")]
    if all(pair):
        for d in pair: print(d["udid"]+" "+d["name"].split()[0])
        break
else: raise SystemExit("An available iPhone and iPad runtime is required")
')
while read -r device family; do
    xcrun simctl boot "$device" || xcrun simctl list devices booted | grep -q "$device"
    xcrun simctl bootstatus "$device" -b
    xcrun simctl install "$device" "$app"
    launch_and_wait "$device" "$family"
    xcrun simctl spawn "$device" launchctl list > "$out/$family-processes.txt"
    awk '$1 ~ /^[0-9]+$/ && /io.github.wang-sy.RelayWorkspace/ {seen=1} END {exit !seen}' "$out/$family-processes.txt"
    xcrun simctl io "$device" screenshot "$out/$family.png"
    for layout in gantt cards; do
        launch_and_wait "$device" "$family" -relay.requirements.layout "$layout"
        xcrun simctl io "$device" screenshot "$out/$family-$layout.png"
    done
    launch_and_wait "$device" "$family" --preview-explorations
    xcrun simctl io "$device" screenshot "$out/$family-explorations.png"
    launch_and_wait "$device" "$family" --preview-workspace
    xcrun simctl io "$device" screenshot "$out/$family-workspace.png"
    launch_and_wait "$device" "$family" --preview-hosted-functions
    xcrun simctl io "$device" screenshot "$out/$family-functions.png"
    launch_and_wait "$device" "$family" --preview-context
    xcrun simctl io "$device" screenshot "$out/$family-context.png"
    xcrun simctl shutdown "$device"
done <<< "$devices"
