#!/bin/bash
# Writes, every few seconds, how loaded and how full the Mac is while a voice is made, so that a speed or a
# memory number of phase 37's test can be read against what else the Mac was doing at the time.
#
#   Scripts/voice-test/watch-mac.sh <pid> <file.tsv> [<seconds between lines, default 5>]
#
# One line per look, until process <pid> has ended: the time, the load average of the last minute, the
# system's free memory in percent (memory_pressure), the swap in use in MB, and what process <pid> holds
# (its physical footprint in MB, the measure Activity Monitor calls Memory, the graphics processor's share
# included on Apple Silicon). Nothing is changed on the Mac; it only reads.
set -euo pipefail
PID="$1"; OUT="$2"; EVERY="${3:-5}"
printf 'time\tload1\tfreePercent\tswapUsedMB\tfootprintMB\n' > "$OUT"
while kill -0 "$PID" 2>/dev/null; do
    load="$(sysctl -n vm.loadavg | awk '{print $2}')"
    free="$(memory_pressure -Q 2>/dev/null | awk -F': ' '/free percentage/ {gsub("%","",$2); print $2}')"
    swap="$(sysctl -n vm.swapusage | awk '{gsub("M","",$6); print $6}')"
    held="$(footprint -p "$PID" 2>/dev/null | sed -n 's/.*Footprint: \([0-9.]*\) \([KMG]B\).*/\1 \2/p' | head -1)"
    case "$held" in
        *GB) held="$(echo "$held" | awk '{printf "%.0f", $1 * 1024}')" ;;
        *MB) held="$(echo "$held" | awk '{printf "%.0f", $1}')" ;;
        *) held="" ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%H:%M:%S)" "$load" "$free" "$swap" "$held" >> "$OUT"
    sleep "$EVERY"
done
