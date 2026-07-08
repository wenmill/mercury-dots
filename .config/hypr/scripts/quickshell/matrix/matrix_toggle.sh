#!/usr/bin/env bash
#
# Toggle the Element Matrix overlay window (the Qt WebEngine panel).
# Replaces the old Quickshell Matrix_Popup panel. Bound via the TopBar matrix
# button -> qs_manager.sh, which forwards "matrix" here.
#
#   (no arg) / toggle : launch if absent, else show/hide
#   open              : ensure visible (launch if needed)
#   close             : hide
#
# Visibility is toggled by parking the live window on a special workspace, so
# Element stays loaded (no reload / re-sync on every open).

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
ACTION="${1:-toggle}"
CLASS="element-matrix-overlay"
HIDDEN="special:matrix"
OVERLAY="$HOME/.config/hypr/scripts/quickshell/matrix/element_overlay.py"

addr=$(hyprctl clients -j 2>/dev/null | jq -r --arg c "$CLASS" '.[]|select(.class==$c)|.address' | head -1)

launch() { nohup python3 "$OVERLAY" >/dev/null 2>&1 & }

show() {
    local cur
    cur=$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id')
    hyprctl dispatch movetoworkspacesilent "$cur,address:$addr" >/dev/null 2>&1
    hyprctl dispatch focuswindow "address:$addr" >/dev/null 2>&1
}
hide() { hyprctl dispatch movetoworkspacesilent "$HIDDEN,address:$addr" >/dev/null 2>&1; }

# preload: warm the overlay at login so the FIRST user-open is an instant un-park
# instead of a cold Chromium init + Element SPA load (the "couple second wait").
# Launch it STRAIGHT onto the hidden workspace (silent) so it loads fully in the
# background without ever flashing on screen. Waits for Element web to be reachable
# first so it doesn't cache a connection-refused page; backgrounds itself so it
# never blocks the rest of autostart.
if [ "$ACTION" = "preload" ]; then
    [ -n "$addr" ] && exit 0                 # already running
    URL="${ELEMENT_URL:-http://127.0.0.1:8420}"
    (
        for _ in $(seq 1 60); do
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
    [ "$ACTION" = "close" ] || launch
    exit 0
fi

ws=$(hyprctl clients -j 2>/dev/null | jq -r --arg c "$CLASS" '.[]|select(.class==$c)|.workspace.name' | head -1)
case "$ACTION" in
    open)  [ "$ws" = "$HIDDEN" ] && show ;;
    close) [ "$ws" = "$HIDDEN" ] || hide ;;
    *)     if [ "$ws" = "$HIDDEN" ]; then show; else hide; fi ;;
esac
