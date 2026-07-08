#!/usr/bin/env bash
#
# Toggle the Home Assistant dashboard overlay (a Qt WebEngine window).
# Bound via Super+A -> qs_manager.sh, which forwards "homeassistant" here.
# Cloned from matrix/matrix_toggle.sh.
#
#   (no arg) / toggle : launch if absent, else show/hide
#   open              : ensure visible (launch if needed)
#   close             : hide
#   preload           : warm it at login (loads onto the hidden workspace)
#
# Visibility is toggled by parking the live window on a special workspace, so HA
# stays loaded (no reload / re-auth on every open).

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
ACTION="${1:-toggle}"
CLASS="home-assistant-overlay"
HIDDEN="special:homeassistant"
OVERLAY="$HOME/.config/hypr/scripts/quickshell/homeassistant/ha_overlay.py"

addr=$(hyprctl clients -j 2>/dev/null | jq -r --arg c "$CLASS" '.[]|select(.class==$c)|.address' | head -1)

launch() { nohup python3 "$OVERLAY" >/dev/null 2>&1 & }

# HA is an xdg window, so the layer-shell master popups always render ABOVE it.
# Make them mutually exclusive instead (same feel as the other widgets): showing
# HA closes any open master popup, and qs_manager closes HA when opening one.
close_master() {
    quickshell -p "$HOME/.config/hypr/scripts/quickshell/Shell.qml" \
        ipc call main handleCommand "close" "" "" >/dev/null 2>&1
}

show() {
    local cur
    close_master
    cur=$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id')
    hyprctl dispatch movetoworkspacesilent "$cur,address:$addr" >/dev/null 2>&1
    hyprctl dispatch focuswindow "address:$addr" >/dev/null 2>&1
}
hide() { hyprctl dispatch movetoworkspacesilent "$HIDDEN,address:$addr" >/dev/null 2>&1; }

# preload: warm the overlay at login so the FIRST open is an instant un-park
# instead of a cold Chromium init + HA load. Loads STRAIGHT onto the hidden
# workspace (silent) so it never flashes on screen. Waits for HA to be reachable
# first so it doesn't cache a connection-refused page.
if [ "$ACTION" = "preload" ]; then
    [ -n "$addr" ] && exit 0                 # already running
    URL="${HA_URL:-http://10.0.0.15:8123}"
    (
        for _ in $(seq 1 120); do
            curl -sf -o /dev/null "$URL" 2>/dev/null && break
            sleep 0.5
        done
        a=$(hyprctl clients -j 2>/dev/null | jq -r --arg c "$CLASS" '.[]|select(.class==$c)|.address' | head -1)
        [ -n "$a" ] && exit 0                 # someone opened it during the wait
        hyprctl dispatch exec "[workspace $HIDDEN silent] python3 $OVERLAY" >/dev/null 2>&1
    ) &
    exit 0
fi

if [ -z "$addr" ]; then
    # Not running — launch it (the windowrule places it on the current workspace).
    [ "$ACTION" = "close" ] || { close_master; launch; }
    exit 0
fi

ws=$(hyprctl clients -j 2>/dev/null | jq -r --arg c "$CLASS" '.[]|select(.class==$c)|.workspace.name' | head -1)
case "$ACTION" in
    open)  [ "$ws" = "$HIDDEN" ] && show ;;
    close) [ "$ws" = "$HIDDEN" ] || hide ;;
    *)     if [ "$ws" = "$HIDDEN" ]; then show; else hide; fi ;;
esac
