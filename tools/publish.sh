#!/bin/bash
# Publishes this game's pack. Linked addons (symlinks in addons/) are left out: the host ships them. The game-owned adapters
# committed in addons/ (pg_timer, pg_natural_disasters) must ship, so addons/ is not excluded wholesale. images/ and screenshots/ are README art.
#   tools/publish.sh VERSION [extra publish_pack.sh flags, e.g. --site URL --token-file F --lock F --dry-run]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
V=${1:?usage: tools/publish.sh VERSION [flags]}; shift
EX=(); for l in "$HERE"/addons/*; do [ -L "$l" ] && EX+=(--exclude-dir "$(basename "$l")"); done
exec "$HERE/../dot-cloud/tools/publish_pack.sh" publish --source "$HERE" --id game-playground --version "$V" \
    "${EX[@]}" --exclude-dir images --exclude-dir screenshots \
    --lock "$HERE/content.lock.json" "$@"
