#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Float-mode toggle for the active workspace + hyprbars on/off
# ─────────────────────────────────────────────────────────────────────────────
# Flip EVERY window on the active workspace between tiled and floating, and keep
# hyprbars in lockstep: bars ON only while in floating mode, OFF in standard mode.
#
# Why a script (not QML): Quickshell's window list (lastIpcObject.floating) is an
# async cache that lags a togglefloating by a frame or two. Deciding the direction
# from that stale value made the un-float click misread the state and leave the
# bars on. Here we read LIVE state from `hyprctl clients -j`, so the direction is
# always correct and the bar flag can never desync from the windows.
#
# NOTE: deliberately NO `set -e`. The per-window dispatch loop is best-effort — a
# single window that refuses to float must NOT abort the script before it sets the
# hyprbars flag, or you get floated windows with no bars (the bug this replaces).

# Shell surfaces are IMMUNE: popups/overlays that float by windowrule and manage
# their own geometry. Counting them made the toggle misread an open overlay as
# "workspace is in floating mode" and tile it (centering the popup); toggling
# them breaks their fixed footprint. Keep in sync with config/rules.conf.
IMMUNE_JQ='((.class // "") | test("^(element-matrix-overlay|home-assistant-overlay|athena|quickshell)$"))
           or ((.title // "") | test("^(qs-master|mpv-pip-player)$"))'

# `float_toggle.sh window` — togglefloating for the ACTIVE window only (the
# SUPER+SHIFT+F bind), with the same immunity for shell surfaces.
if [ "${1:-}" = "window" ]; then
    hyprctl activewindow -j 2>/dev/null | jq -e "$IMMUNE_JQ" >/dev/null 2>&1 && exit 0
    hyprctl dispatch togglefloating active >/dev/null 2>&1
    exit 0
fi

ws=$(hyprctl activeworkspace -j | jq -r '.id')
[ -z "$ws" ] || [ "$ws" = "null" ] && exit 0

# Live snapshot: "<address> <floating>" per window on this workspace.
mapfile -t wins < <(hyprctl clients -j \
    | jq -r --argjson ws "$ws" ".[] | select(.workspace.id == \$ws) | select(($IMMUNE_JQ) | not) | \"\(.address) \(.floating)\"")

[ "${#wins[@]}" -eq 0 ] && exit 0

# If ANY window is floating we're in floating mode → tile everything (bars off).
# Otherwise → float everything (bars on). Decide this up front so the bar flag is
# correct regardless of how the per-window toggles below go.
any_floating=0
for w in "${wins[@]}"; do
    [ "${w##* }" = "true" ] && any_floating=1
done

if [ "$any_floating" -eq 1 ]; then
    target=false; enable=0
else
    target=true;  enable=1
fi

# Bars follow the mode. Set this FIRST so it always runs even if a dispatch below
# misbehaves — the flag is global and independent of the per-window toggles.
hyprctl keyword plugin:hyprbars:enabled "$enable" >/dev/null 2>&1

# Toggle only the windows whose live state differs from the target. Each call is
# non-fatal (|| true) so one stubborn window can't stop the rest.
for w in "${wins[@]}"; do
    addr=${w%% *}
    floating=${w##* }
    [ "$floating" != "$target" ] && hyprctl dispatch togglefloating "address:$addr" >/dev/null 2>&1 || true
done

# When entering FLOAT mode, keep every window's TOP EDGE (its hyprbar included, since
# bar_part_of_window=true means `.at` is the frame/bar top) BELOW the Quickshell top
# bar. Floating can otherwise leave a title bar tucked under the bar — remembered
# float geometry, centered popups, or windows that were fullscreen/maximized. So nudge
# any window whose top sits above the safe line straight back down to it.
if [ "$target" = "true" ]; then
    # Safe top = this monitor's top-reserved edge (the bar's exclusive zone) + gap.
    mon=$(hyprctl activeworkspace -j | jq -r '.monitor')
    read -r mon_y res_top < <(hyprctl monitors -j \
        | jq -r --arg m "$mon" '.[] | select(.name == $m) | "\(.y) \(.reserved[1])"')
    [ -z "$mon_y" ] && mon_y=0
    [ -z "$res_top" ] && res_top=0
    safe_top=$(( mon_y + res_top + 30 ))  # gap below the bar (bigger than the tiled 4px)
    # Give the togglefloating dispatches a beat to settle the new floating geometry.
    sleep 0.08
    while read -r addr x y; do
        [ -z "$addr" ] && continue
        [ "$y" -lt "$safe_top" ] && \
            hyprctl dispatch movewindowpixel "exact $x $safe_top,address:$addr" >/dev/null 2>&1 || true
    done < <(hyprctl clients -j \
        | jq -r --argjson ws "$ws" ".[] | select(.workspace.id == \$ws) | select(($IMMUNE_JQ) | not) | \"\(.address) \(.at[0]) \(.at[1])\"")
fi
