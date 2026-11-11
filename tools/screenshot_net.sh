#!/usr/bin/env bash
# Renders a CONNECTED client watching another player run across its view, to
# screenshots/net_0..3.png, and prints how evenly that player moved frame to frame.
#
#   tools/screenshot_net.sh                 # interpolated, as the client ships
#   tools/screenshot_net.sh --no-interp     # the client's interpolation off, for comparison
#   tools/screenshot_net.sh --seconds=10 --out=res://screenshots/later.png
#
# A server and a client in one process over a loopback. Nothing offline can show this: the
# local player is the only player there, and every bug this exists for was in how a client
# draws somebody it is only told about. xvfb-run because this needs a rendering context;
# --headless gives a null renderer and saves a frame of nothing.
set -euo pipefail
# A short frame sequence beside each still (DotShotSeq), so Nightly -> Review can play and scrub it.
export DOT_SHOT_FRAMES=${DOT_SHOT_FRAMES:-8} DOT_SHOT_SECS=${DOT_SHOT_SECS:-1}
cd "$(dirname "$0")/.."
mkdir -p screenshots
exec xvfb-run -a godot --path . --resolution 1280x720 res://tools/screenshot_net.tscn -- "$@"
