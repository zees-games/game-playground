#!/usr/bin/env bash
# Renders the admin profile workbench to docs/ at the real viewport size, to look at.
#
#   tools/render_workbench.sh
#
# xvfb-run because --headless gives a null renderer and empty frames.
set -euo pipefail
# A short frame sequence beside each still (DotShotSeq), so Nightly -> Review can play and scrub it.
export DOT_SHOT_FRAMES=${DOT_SHOT_FRAMES:-8} DOT_SHOT_SECS=${DOT_SHOT_SECS:-1}
cd "$(dirname "$0")/.."
exec xvfb-run -a godot --path . --resolution 1280x720 res://tools/render_workbench.tscn
