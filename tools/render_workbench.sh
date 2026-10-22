#!/usr/bin/env bash
# Renders the admin profile workbench to docs/ at the real viewport size, to look at.
#
#   tools/render_workbench.sh
#
# xvfb-run because --headless gives a null renderer and empty frames.
set -euo pipefail
cd "$(dirname "$0")/.."
exec xvfb-run -a godot --path . --resolution 1280x720 res://tools/render_workbench.tscn
