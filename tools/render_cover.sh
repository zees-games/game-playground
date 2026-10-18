#!/usr/bin/env bash
# Renders a real client under its loading cover and just after it lifts (screenshots/cover_*.png).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p screenshots
exec xvfb-run -a godot --path . --resolution 1280x720 res://tools/render_cover.tscn -- "$@"
