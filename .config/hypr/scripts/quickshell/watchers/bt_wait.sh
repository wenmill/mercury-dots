#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/../../caching.sh"

# ── Singleton: prune any stale copy of this watcher before starting ──────────
# Kill any older instance of THIS script + its pipeline children so exactly one
# ever runs. Detached watchers SURVIVE shell restarts, so without this every
# reload leaked another blocking monitor (we found 22 copies of each).
__self="$(basename "${BASH_SOURCE[0]}")"
for __pid in $(pgrep -f "watchers/$__self" 2>/dev/null); do
    [ "$__pid" = "$$" ] && continue
    pkill -P "$__pid" 2>/dev/null
    kill "$__pid" 2>/dev/null
done


PIPE="$QS_RUN_DIR/qs_bt_wait_$$.fifo"
mkfifo "$PIPE" 2>/dev/null
trap 'rm -f "$PIPE"; kill $(jobs -p) 2>/dev/null; exit 0' EXIT INT TERM
LC_ALL=C dbus-monitor --system "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',arg0='org.bluez.Device1'" 2>/dev/null | grep --line-buffered 'string "Connected"' > "$PIPE" &
LC_ALL=C dbus-monitor --system "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',arg0='org.bluez.Adapter1'" 2>/dev/null | grep --line-buffered 'string "Powered"' > "$PIPE" &
read -r _ < "$PIPE"
