#!/usr/bin/env bash
# vision-shot.sh — take ONE screenshot right now and drop it in the vision spool.
#
# For Hermes to trigger a capture on demand (it has the terminal capability), on
# top of the automatic 10s cadence. The hermes-vision daemon picks the file up on
# its next loop, describes it, files it into honcho, and deletes it. An optional
# reason is recorded alongside so the observation notes why Hermes looked.
#
# Usage:  vision-shot.sh ["why hermes wanted a look"]
set -euo pipefail
SPOOL="$HOME/.hermes/vision-spool"
mkdir -p "$SPOOL"
ts="$(date +%Y%m%d-%H%M%S-%N)"
out="$SPOOL/ondemand-$ts.png"
grim "$out" >/dev/null 2>&1 || { echo "vision-shot: grim failed (no Wayland display?)" >&2; exit 1; }
[ $# -ge 1 ] && [ -n "$1" ] && printf '%s' "$1" > "$SPOOL/ondemand-$ts.reason"
echo "captured $out"
