#!/bin/bash
# Publishes this game's pack. Every addon is left out: the host ships them and the weapon packs come from their own pins. images/ and screenshots/ are README art.
#   tools/publish.sh VERSION [extra publish_pack.sh flags, e.g. --site URL --token-file F --lock F --dry-run]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
V=${1:?usage: tools/publish.sh VERSION [flags]}; shift
exec "$HERE/../dot-cloud/tools/publish_pack.sh" publish --source "$HERE" --id game-playground --version "$V" \
    --exclude-dir addons --exclude-dir images --exclude-dir screenshots \
    --lock "$HERE/content.lock.json" "$@"
