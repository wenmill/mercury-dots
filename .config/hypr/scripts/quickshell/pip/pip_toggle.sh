#!/usr/bin/env bash
#
# Launch / show / hide the mpv PiP window.
#   pip_toggle.sh open  [media]   launch (with media if given) or un-hide
#   pip_toggle.sh close           park on the special workspace (mpv stays loaded)
#   pip_toggle.sh toggle [media]  launch / show / hide
#
# The PiP is a plain native mpv window (vo=gpu) kept idle with an IPC socket, so
# ani-cli / lobster / pip_mpv.sh load into it over IPC. Hyprland window-rules
# (matched on the window TITLE) float/size/pin it.
#
# NOTE: this replaced an in-QML Qt+libmpv render player that segfaulted on this
# stack (PyQt6 6.11 / Python 3.14 / Wayland). Native mpv render is rock-solid.
#
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
ACTION="${1:-toggle}"
MEDIA="$2"
TITLE="mpv-pip-player"
HIDDEN="special:pip"
SOCK="$XDG_RUNTIME_DIR/mpv-pip.sock"

addr=$(hyprctl clients -j 2>/dev/null | jq -r --arg t "$TITLE" '.[]|select(.title==$t)|.address' | head -1)

launch() {
    setsid mpv --idle=yes --force-window=yes --keep-open=yes --no-border --osc=no \
        --title="$TITLE" --input-ipc-server="$SOCK" --no-terminal --ytdl=yes \
        --volume=70 ${MEDIA:+"$MEDIA"} >/dev/null 2>&1 < /dev/null &
}
show() {
    local cur; cur=$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id')
    hyprctl dispatch movetoworkspacesilent "$cur,address:$addr" >/dev/null 2>&1
    hyprctl dispatch pin "address:$addr" >/dev/null 2>&1   # show on all workspaces
}
hide() { hyprctl dispatch movetoworkspacesilent "$HIDDEN,address:$addr" >/dev/null 2>&1; }

if [ -z "$addr" ]; then
    [ "$ACTION" = "close" ] || launch
    exit 0
fi
ws=$(hyprctl clients -j 2>/dev/null | jq -r --arg t "$TITLE" '.[]|select(.title==$t)|.workspace.name' | head -1)
case "$ACTION" in
    open)  [ "$ws" = "$HIDDEN" ] && show ;;
    close) [ "$ws" = "$HIDDEN" ] || hide ;;
    *)     if [ "$ws" = "$HIDDEN" ]; then show; else hide; fi ;;
esac
