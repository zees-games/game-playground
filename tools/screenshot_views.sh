#!/usr/bin/env bash
# Renders the sandbox in first and third person to screenshots/.
#
#   tools/screenshot_views.sh
#
# The third-person controller is a different MOTOR from the first-person one, not a moved
# camera, and no assertion reaches what a camera shows. xvfb-run because this needs a
# rendering context; --headless gives a null renderer and saves a frame of nothing.
set -euo pipefail
# A short frame sequence beside each still (DotShotSeq), so Nightly -> Review can play and scrub it.
export DOT_SHOT_FRAMES=${DOT_SHOT_FRAMES:-8} DOT_SHOT_SECS=${DOT_SHOT_SECS:-1}
cd "$(dirname "$0")/.."
mkdir -p screenshots
exec xvfb-run -a godot --path . --resolution 1600x900 --script tools/screenshot_views.gd
