#!/usr/bin/env bash
# Block until the shared weather cache (weather.json) is rewritten, then exit so the
# topbar re-reads it. The calendar popup's `weather.sh --json` call is what actually
# refreshes weather.json (it triggers get_data when the cache is stale), so watching the
# file keeps the topbar's weather in lockstep with the calendar — it updates the instant
# the underlying data does, no matter what triggered the refresh.
source "$(dirname "${BASH_SOURCE[0]}")/../../caching.sh"

# ── Singleton: prune any stale copy of this watcher before starting ──────────
# Kill any older instance of THIS script + its pipeline children so exactly one
# ever runs (prevents orphaned inotifywait piling up across reloads/crashes).
__self="$(basename "${BASH_SOURCE[0]}")"
for __pid in $(pgrep -f "watchers/$__self" 2>/dev/null); do
    [ "$__pid" = "$$" ] && continue
    pkill -9 -P "$__pid" 2>/dev/null
    kill -9 "$__pid" 2>/dev/null
done

WJSON="$QS_CACHE_DIR/weather/weather.json"

# Reap the watcher if we're killed (e.g. on bar reload) so no inotifywait is orphaned.
trap 'kill "$MONITOR_PID" 2>/dev/null; exit 0' EXIT INT TERM

# If the cache doesn't exist yet, wait briefly and let the poller (re)create it instead
# of spinning on a missing path.
[ -f "$WJSON" ] || { sleep 3; exit 0; }

# No -m: inotifywait prints one event and EXITS by itself, so the normal path leaves
# nothing to clean up. `wait` lets the trap still fire on TERM during the block.
inotifywait -qq -e close_write "$WJSON" >/dev/null 2>&1 &
MONITOR_PID=$!
wait "$MONITOR_PID"
