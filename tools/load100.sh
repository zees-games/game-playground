#!/usr/bin/env bash
# Load ladder: a dedicated server (load_server.tscn) vs N synthetic clients (load_swarm.tscn) per step.
# Run as one job: heavy -- ./tools/load100.sh   (or ./gpu.sh run on staging02)
# usage: tools/load100.sh [--seconds 30] [steps...]   default steps: 16 32 64 100 128
cd "$(dirname "$0")/.." || exit 1
SECONDS_PER=30
if [ "$1" = "--seconds" ]; then SECONDS_PER=$2; shift 2; fi
STEPS=("$@"); [ ${#STEPS[@]} -eq 0 ] && STEPS=(16 32 64 100 128)
OUT=${LOAD_OUT:-/tmp/load100}; mkdir -p "$OUT"
PORT=27399
# A box that never imported this project has no class cache and a run would hang.
[ -f .godot/global_script_class_cache.cfg ] || godot --headless --path . --import > /dev/null 2>&1
for n in "${STEPS[@]}"; do
	taskset -c 0-3 timeout $((SECONDS_PER + 150)) godot --headless --path . res://tools/load_server.tscn -- --port $PORT --slots 128 +sv_maxplayers 128 > "$OUT/server_$n.log" 2>&1 &
	SPID=$!
	sleep 12
	taskset -c 4-11 timeout $((SECONDS_PER + 120)) godot --headless --path . res://tools/load_swarm.tscn -- --port $PORT --clients "$n" --seconds "$SECONDS_PER" > "$OUT/swarm_$n.log" 2>&1
	kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null
	echo "== $n clients: $(grep -m1 'SWARM joined' "$OUT/swarm_$n.log")"
	echo "   $(grep 'SWARM playing' "$OUT/swarm_$n.log" | tail -1)"
	# Last 10 STAT lines are the steady state.
	grep '^STAT' "$OUT/server_$n.log" | tail -10 | tail -1
	grep -c 'SCRIPT ERROR' "$OUT/server_$n.log" "$OUT/swarm_$n.log" | sed 's/^/   errors /'
	grep -E 'WARN|trim' "$OUT/server_$n.log" | sort | uniq -c | head -3
done
