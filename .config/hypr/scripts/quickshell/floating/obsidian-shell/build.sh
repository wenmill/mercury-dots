#!/usr/bin/env bash
# Build + run the obsidian-shell Phase-1 spike.
#
#   ./build.sh        configure + build, then run
#   ./build.sh build  configure + build only
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

if ! pacman -Q layer-shell-qt &>/dev/null; then
    echo "!! layer-shell-qt is not installed. Run:"
    echo "     sudo pacman -S layer-shell-qt"
    exit 1
fi

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build build -j"$(nproc)"

[ "${1:-run}" = "build" ] && { echo "built: $HERE/build/obsidian-shell"; exit 0; }

# Make sure the Ignis server (serves Obsidian on :8765) is up before launching.
systemctl --user is-active --quiet ignis.service 2>/dev/null \
    || systemctl --user start ignis.service >/dev/null 2>&1 || true

exec "$HERE/build/obsidian-shell"
