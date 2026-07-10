#!/usr/bin/env bash
# Load hyprbars at login, and get it installed the first time.
#
# Reference: https://wiki.hypr.land/Plugins/Using-Plugins/
#
# Two facts drive everything here, and neither is obvious:
#
# 1. hyprpm needs a RUNNING Hyprland. Every subcommand asks the compositor which
#    version it is, so the plugin is built against matching headers. From a TTY
#    (which is how install.sh is meant to be run) even `hyprpm add` dies with
#    "failed to get the current hyprland version. Are you running hyprland?".
#    So none of this can live in the installer.
#
# 2. hyprpm writes its state as root. DataState::getDataStatePath() is
#    /var/cache/hyprpm/<user>, and every write goes through
#    `sudo install -m644 -o0 -g0 ...` (hyprpm/src/helpers/Sys.cpp). `add`,
#    `enable` and `update` therefore prompt for a password. With no terminal to
#    answer it they fail with "Failed to write plugin state" — silently, if you
#    are not reading the log.
#
# `reload` is the exception: it only loads the .so through hyprctl, needs no
# root, and is what the wiki tells you to put in your autostart. So:
#
#   already enabled  -> hyprpm reload -n     (silent, every login, no password)
#   not enabled yet  -> open a terminal once so the sudo prompt can be answered
#
# The terminal is not a nicety. A password prompt with nowhere to appear is the
# whole reason hyprbars never installed.
set -uo pipefail

PLUGIN="hyprbars"
REPO="https://github.com/hyprwm/hyprland-plugins"
LOG="/tmp/hyprpm-ensure.log"
STAMP="${XDG_RUNTIME_DIR:-/tmp}/hyprpm-ensure-prompted"   # per-boot, not per-login

command -v hyprpm >/dev/null 2>&1 || exit 0
[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || exit 0   # nothing to load into

# `hyprpm list` prints every plugin in every added repo, enabled or not:
#
#     │ Plugin hyprbars
#     └─ enabled: false
#
# so `hyprpm list | grep -q hyprbars` is true for a plugin that is present and
# switched OFF. Read the flag. Prints "true", "false", or nothing when the repo
# was never added. The sed strips hyprpm's colour codes, which otherwise land in
# the middle of the value.
plugin_state() {
    timeout 60 hyprpm list 2>/dev/null </dev/null \
        | sed 's/\x1b\[[0-9;]*m//g' \
        | awk -v p="$PLUGIN" '
            $0 ~ ("Plugin " p "$") { f = 1; next }
            f && /enabled:/          { print $NF; exit }'
}

: > "$LOG"

if [ "$(plugin_state)" = "true" ]; then
    # Enabling only records state on disk; the plugin still has to be loaded into
    # this instance. -n makes hyprpm say so on screen (wiki's suggestion).
    timeout 60 hyprpm reload -n </dev/null >>"$LOG" 2>&1 || true
    exit 0
fi

# Not installed, or installed and disabled. Both need a root write, so both need
# somewhere to type a password. Ask once per boot: if the user closes the window
# without finishing, nagging them at every workspace switch helps nobody.
[ -e "$STAMP" ] && exit 0
: > "$STAMP"

TERMINAL="${TERMINAL:-kitty}"
command -v "$TERMINAL" >/dev/null 2>&1 || {
    notify-send -u critical "hyprbars not installed" \
        "Run: hyprpm add $REPO && hyprpm enable $PLUGIN && hyprpm reload" 2>/dev/null || true
    exit 0
}

# `hyprpm add` fails on a repo it already has, so only add when it is absent.
# Each step is a precondition for the next; stop at the first failure so the
# error stays on screen instead of scrolling past three more.
"$TERMINAL" --title "hyprbars setup" -e bash -c '
    set -e
    echo "Installing the hyprbars plugin (hyprpm needs sudo to write /var/cache/hyprpm)."
    echo
    hyprpm update
    hyprpm list 2>/dev/null | grep -q "Plugin hyprbars" || hyprpm add '"$REPO"'
    hyprpm enable '"$PLUGIN"'
    hyprpm reload -n
    echo
    echo "Done — hyprbars is enabled and will load automatically from now on."
    read -rp "Press enter to close."
' >>"$LOG" 2>&1 &
