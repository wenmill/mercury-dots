#!/usr/bin/env bash
#
# Build the PipMpv QML module (embedded mpv player for the movies widget).
# Outputs to ../qml/PipMpv so Quickshell finds it via QML_IMPORT_PATH.
#
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
echo "Built -> $(cd "$DIR/../qml/PipMpv" && pwd)"
ls -1 "$DIR/../qml/PipMpv"
