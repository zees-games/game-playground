#!/usr/bin/env bash
# Renders a playground map to screenshots/<map>_*.png so a person can look at it.
#
#   tools/screenshot.sh pg_flatgrass
#
# Uses xvfb-run because this needs a rendering context and the machines this runs on
# have no display. Nothing here is headless-safe: `--headless` gives a null renderer and
# every frame it saves is empty, which is worse than no screenshot because it looks like
# one.
#
# Copied from game-arena's rather than shared with it: these are separate repositories
# and that is the family's rule. The angles differ, because a 200 m sandbox with a movement corner
# and a park is not a deathmatch arena.
set -euo pipefail
cd "$(dirname "$0")/.."
map="${1:-pg_flatgrass}"
# RENDERER=forward_plus renders with the other renderer; the project and the client shell
# draw with gl_compatibility, which is what a player sees, so check a look change in both.
exec xvfb-run -a godot --path . --resolution 1600x900 ${RENDERER:+--rendering-method "$RENDERER"} \
  --script tools/screenshot.gd -- --map "$map" "${@:2}"
