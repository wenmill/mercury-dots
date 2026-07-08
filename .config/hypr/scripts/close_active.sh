#!/usr/bin/env bash
#
# Close-window action (bound to ALT+F4 in keybindings.conf — rebind freely,
# the behaviour rides with the bind, not the key).
#
# Normally closes the focused window (killactive). The mpv PiP window
# (title mpv-pip-player) is special-cased: it's a borderless pinned overlay
# that rarely holds focus — and never can while click-through is on — so
# plain killactive could not reach it. If the PiP is focused OR the cursor
# is over it, close the PiP instead.
set -u

# The movies widget's EMBEDDED player is a layer-shell surface — no toplevel
# window exists for killactive. If it's up (and not in gaming passthrough),
# close it. The IPC handler answers "closed" only when it actually did.
QS_SHELL="$HOME/.config/hypr/scripts/quickshell/Shell.qml"
if qs -p "$QS_SHELL" ipc call movieswin closePlayer 2>/dev/null | grep -q closed; then
    exit 0
fi

pip_addr="$(hyprctl clients -j 2>/dev/null | jq -r '.[] | select(.title=="mpv-pip-player") | .address' | head -1)"

if [ -n "$pip_addr" ]; then
    active="$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty')"
    if [ "$active" = "$pip_addr" ]; then
        hyprctl dispatch closewindow "address:$pip_addr" >/dev/null
        exit 0
    fi
    geo="$(hyprctl clients -j 2>/dev/null | jq -r --arg a "$pip_addr" \
        '.[] | select(.address==$a) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"')"
    cur="$(hyprctl cursorpos -j 2>/dev/null | jq -r '"\(.x) \(.y)"')"
    if [ -n "$geo" ] && [ -n "$cur" ]; then
        read -r x y w h <<< "$geo"
        read -r cx cy <<< "$cur"
        if [ "$cx" -ge "$x" ] && [ "$cx" -le $((x + w)) ] \
           && [ "$cy" -ge "$y" ] && [ "$cy" -le $((y + h)) ]; then
            hyprctl dispatch closewindow "address:$pip_addr" >/dev/null
            exit 0
        fi
    fi
fi

exec hyprctl dispatch killactive
