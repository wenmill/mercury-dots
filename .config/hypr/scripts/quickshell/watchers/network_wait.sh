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


PIPE="$QS_RUN_DIR/qs_network_wait_$$.fifo"
mkfifo "$PIPE" 2>/dev/null

# Trap ensures we delete the FIFO and specifically kill nmcli, leaving no zombie processes
trap 'rm -f "$PIPE"; kill $MONITOR_PID 2>/dev/null; exit 0' EXIT INT TERM

# Run nmcli completely isolated and capture its exact PID
LC_ALL=C nmcli monitor 2>/dev/null > "$PIPE" &
MONITOR_PID=$!

# Grep blocks until it reads the first match from the FIFO, then exits.
# Exiting triggers the trap, immediately killing nmcli and ending the script.
grep -m 1 -iwE "connected|disconnected|enabled|disabled|activated|deactivated|available|unavailable" < "$PIPE" > /dev/null
