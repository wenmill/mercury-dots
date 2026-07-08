#!/usr/bin/env bash
# Gaming overlay passthrough toggle.
#
# Flips ~/.cache/qs_overlay_passthrough between 1 (on) and 0 (off). Both the mpv
# movies window and the floating AI/notes window watch this file: when it's 1 they
# drop their input mask entirely, so the windows stay VISIBLE (the video keeps
# playing, the panels stay on screen) but become click-through — your clicks land
# on the game underneath, and the floating window's edge zones no longer spawn the
# AI selector. Flip it off to make them interactive again.
#
# Bind it to a key, e.g. in Hyprland:
#   bind = SUPER SHIFT, G, exec, ~/.config/hypr/scripts/overlay_passthrough.sh

F="$HOME/.cache/qs_overlay_passthrough"
cur="$(cat "$F" 2>/dev/null || echo 0)"

if [ "$cur" = "1" ]; then
    echo 0 > "$F"
    notify-send -t 1500 "Overlays interactive" "mpv / AI windows accept clicks again."
else
    echo 1 > "$F"
    notify-send -t 1500 "Overlays click-through" "Gaming mode: clicks pass through the mpv / AI windows."
fi
