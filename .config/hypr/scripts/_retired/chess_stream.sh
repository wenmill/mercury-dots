#!/usr/bin/env bash
# chess_stream.sh — stream Lichess board game events to /tmp/qs_chess_event
# Called by AiPopup.qml via Quickshell.execDetached.
#
# Usage: LICHESS_TOKEN="lip_xxx" chess_stream.sh <gameId>
# Each NDJSON event from the game stream is written to /tmp/qs_chess_event
# (overwriting), which triggers the QML's inotifywait-based reader.

set -u
GAME_ID="${1:?Usage: chess_stream.sh <gameId>}"
TOKEN="${LICHESS_TOKEN:?Set LICHESS_TOKEN}"
EVENT_FILE="/tmp/qs_chess_event"

# Clean up on exit
cleanup() { rm -f "/tmp/chess_stream_${GAME_ID}.pid"; }
trap cleanup EXIT
echo $$ > "/tmp/chess_stream_${GAME_ID}.pid"

# Stream game events — curl streams NDJSON, one JSON object per line.
# We write each non-empty line to the event file so inotifywait picks it up.
curl -sN \
    -H "Authorization: Bearer ${TOKEN}" \
    "https://lichess.org/api/board/game/stream/${GAME_ID}" \
    2>/dev/null | while IFS= read -r line; do
    # Skip empty keep-alive lines
    [ -z "$line" ] && continue
    # Atomic write: write to temp then mv to avoid partial reads
    printf '%s' "$line" > "${EVENT_FILE}.tmp"
    mv -f "${EVENT_FILE}.tmp" "$EVENT_FILE"
done
