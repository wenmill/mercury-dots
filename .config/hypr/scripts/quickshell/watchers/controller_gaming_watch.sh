#!/usr/bin/env bash

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

#
# Opens the gaming-mode prompt (GamingPrompt.qml) when a Pro Controller
# (GuliKit King Kong 2 in Switch mode) connects over Bluetooth.
#
# Event-driven: wakes on any BlueZ device Connected change, then edge-detects the
# controller so it only prompts on a fresh connect (not on every BlueZ signal),
# and stays quiet if you're already in gaming mode.

is_connected() { bluetoothctl devices Connected 2>/dev/null | grep -qi "Pro Controller"; }

prev=0
is_connected && prev=1

LC_ALL=C dbus-monitor --system \
    "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',arg0='org.bluez.Device1'" 2>/dev/null | \
grep --line-buffered 'string "Connected"' | \
while read -r _; do
    sleep 0.5                       # let BlueZ/bluetoothctl state settle
    if is_connected; then cur=1; else cur=0; fi
    if [ "$cur" = 1 ] && [ "$prev" = 0 ]; then
        # Only prompt if not already in a gaming focus session.
        if [ "$(cat ~/.cache/qs_focus_mode 2>/dev/null)" != "gaming" ]; then
            ~/.config/hypr/scripts/qs_manager.sh open gamingprompt >/dev/null 2>&1
            # Drive the popup with the controller's D-pad while it's open.
            pkill -f gaming_prompt_controller.py 2>/dev/null
            setsid python3 ~/.config/hypr/scripts/quickshell/watchers/gaming_prompt_controller.py >/dev/null 2>&1 < /dev/null &
        fi
    fi
    prev=$cur
done
