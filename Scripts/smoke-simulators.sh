#!/bin/bash
set -euo pipefail
app="$1"
out="$2"
mkdir -p "$out"
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
    xcrun simctl launch "$device" io.github.wang-sy.RelayWorkspace
    sleep 3
    xcrun simctl spawn "$device" launchctl list > "$out/$family-processes.txt"
    awk '$1 ~ /^[0-9]+$/ && /io.github.wang-sy.RelayWorkspace/ {seen=1} END {exit !seen}' "$out/$family-processes.txt"
    xcrun simctl io "$device" screenshot "$out/$family.png"
    xcrun simctl shutdown "$device"
done <<< "$devices"
