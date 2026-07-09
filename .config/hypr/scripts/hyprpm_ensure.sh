#!/usr/bin/env bash
# Ensure the hyprbars plugin is installed, enabled and loaded — from inside a
# Hyprland session.
#
# The installer cannot do this. `hyprpm enable` needs a live Hyprland instance to
# load the plugin into, so running install.sh from a TTY always fails there and
# only warns. `exec-once = hyprpm reload` in autostart.conf reloads plugins that
# are already enabled, so a fresh machine never enables hyprbars at all: the
# titlebars in float mode simply never appear, with nothing on screen to say why.
#
# This runs from autostart, does nothing when hyprbars is already enabled (the
# normal case, costing one `hyprpm list`), and is safe to run repeatedly.
#
# Every hyprpm call gets stdin closed and a timeout: `hyprpm add` compiles the
# plugin against Hyprland's headers, which can take minutes, and a build that
# wedges must not leave a hung process attached to the session forever.
set -uo pipefail

PLUGIN="hyprbars"
REPO="https://github.com/hyprwm/hyprland-plugins"
LOG="/tmp/hyprpm-ensure.log"
BUILD_TIMEOUT="${HYPRPM_BUILD_TIMEOUT:-900}"   # 15 min for a headers + plugin build

command -v hyprpm >/dev/null 2>&1 || exit 0

# Refuse to run outside a session — hyprpm would fail in exactly the way the
# installer already fails, and we would log noise on every TTY login.
[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || exit 0

: > "$LOG"

# Already enabled? Just make sure it is loaded into the running compositor.
if hyprpm list 2>/dev/null | grep -q "$PLUGIN"; then
    timeout 60 hyprpm reload </dev/null >>"$LOG" 2>&1 || true
    exit 0
fi

# Headers first: `add` needs them, and `update` is what fetches them.
timeout "$BUILD_TIMEOUT" hyprpm update </dev/null >>"$LOG" 2>&1 || true
timeout "$BUILD_TIMEOUT" hyprpm add "$REPO" </dev/null >>"$LOG" 2>&1 || true

if timeout 120 hyprpm enable "$PLUGIN" </dev/null >>"$LOG" 2>&1; then
    timeout 60 hyprpm reload </dev/null >>"$LOG" 2>&1 || true
    notify-send "Hyprland plugins" "hyprbars enabled" 2>/dev/null || true
else
    notify-send -u critical "Hyprland plugins" \
        "hyprbars could not be enabled — see $LOG" 2>/dev/null || true
fi
