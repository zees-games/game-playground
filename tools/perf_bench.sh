#!/usr/bin/env bash
# The sandbox benchmark (tools/perf_bench.tscn) windowed on a GPU box: dot-game's tool (addons/dot_game/tools/dot_game_perf_bench.sh).
export GPU_XORG=${GPU_XORG:-1}
# A sandbox has no match: nothing is fired or dropped, so few nodes enter the tree and the wrapper's INERT check (nodes per tick) would
# fail every run. The pile and the NPCs are the load here; the sidecar's props, npcs and phys_active say whether they were there.
export PERF_BENCH_INERT_PER_TICK=${PERF_BENCH_INERT_PER_TICK:-0}
exec bash "$(dirname "$0")/../addons/dot_game/tools/dot_game_perf_bench.sh" "$@"
