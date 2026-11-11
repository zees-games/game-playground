#!/usr/bin/env bash
# Renders a real client under its loading cover and just after it lifts (screenshots/cover_*.png).
set -euo pipefail
# A short frame sequence beside each still (DotShotSeq), so Nightly -> Review can play and scrub it.
export DOT_SHOT_FRAMES=${DOT_SHOT_FRAMES:-8} DOT_SHOT_SECS=${DOT_SHOT_SECS:-1}
cd "$(dirname "$0")/.."
mkdir -p screenshots
exec xvfb-run -a godot --path . --resolution 1280x720 res://tools/render_cover.tscn -- "$@"
