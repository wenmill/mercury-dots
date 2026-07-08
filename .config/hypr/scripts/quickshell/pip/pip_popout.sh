#!/usr/bin/env bash
#
# Pop the currently-playing stream out of the embedded player into a standalone
# floating mpv PiP window. Called by the movies widget when you drag the player's
# top bar down (or hit the pop-out button).
#
#   pip_popout.sh <url-or-file> [start-seconds]
#
# Uses its OWN window (title mpv-pip-player, matched by a Hyprland window-rule
# to float/pin it) and native OSC controls, with no IPC socket so it never
# collides with the embedded player's $XDG_RUNTIME_DIR/mpv-pip.sock.
#
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
URL="$1"
START="${2:-0}"
TITLE="mpv-pip-player"

[ -z "$URL" ] && { echo "pip_popout: no url" >&2; exit 1; }

setsid mpv \
    --force-window=yes --keep-open=yes --no-border --osc=yes \
    --title="$TITLE" --no-terminal --ytdl=yes --volume=70 \
    --start="${START}" \
    "$URL" >/dev/null 2>&1 < /dev/null &

exit 0
