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
#
# ── THE LOCKOUT ───────────────────────────────────────────────────────────────
# There is a third fact, and it is the dangerous one. hyprpm's state store is
# created lazily by DataState::ensureStateStoreExists(), which calls
# NSys::root::createDirectory -> sudo. And getPluginStates() calls it. So on a
# machine where /var/cache/hyprpm/<user>/headersRoot does not exist yet, even
# `hyprpm list` and `hyprpm reload` invoke sudo.
#
# Run from autostart there is no terminal, so sudo cannot prompt:
#
#     sudo: pam_unix(sudo:auth): conversation failed
#     sudo: pam_unix(sudo:auth): auth could not identify password for [user]
#
# pam_faillock counts that as a failed authentication. Arch wires pam_faillock
# into system-auth with deny=3, so a couple of logins — or one run that calls
# update, add and enable — locks the account. The user's real password then
# stops working, at the greeter and at the lock screen. `hyprpm reload` in
# autostart, which the wiki recommends, is enough to do it on a fresh install.
#
# Hence the guard below: NEVER invoke hyprpm unless its state store already
# exists. If it does not, the only safe move is a terminal, where sudo can ask.
# Recover a locked account with:  faillock --user <name> --reset   (as root)
set -uo pipefail

PLUGIN="hyprbars"
REPO="https://github.com/hyprwm/hyprland-plugins"
LOG="/tmp/hyprpm-ensure.log"
STAMP="${XDG_RUNTIME_DIR:-/tmp}/hyprpm-ensure-prompted"   # per-boot, not per-login
STORE="/var/cache/hyprpm/$(id -un)/headersRoot"

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

# Everything that needs root happens HERE, in a terminal, where sudo has a tty to
# prompt on. Asked once per boot: if the window is closed without finishing,
# reopening it on every login is worse than leaving hyprbars off.
prompt_in_terminal() {   # <reason>
    [ -e "$STAMP" ] && return 0
    : > "$STAMP"

    local term="${TERMINAL:-kitty}"
    if ! command -v "$term" >/dev/null 2>&1; then
        notify-send -u critical "hyprbars not installed" \
            "Open a terminal and run: hyprpm update && hyprpm add $REPO && hyprpm enable $PLUGIN && hyprpm reload -n" \
            2>/dev/null || true
        return 0
    fi

    # `hyprpm add` fails on a repo it already has, so only add when it is absent.
    # Each step is a precondition for the next; stop at the first failure so the
    # error stays on screen instead of scrolling past three more.
    "$term" --title "hyprbars setup" -e bash -c '
        set -e
        echo "'"$1"'"
        echo "Installing the hyprbars plugin. hyprpm writes /var/cache/hyprpm as root."
        echo
        hyprpm update
        hyprpm list 2>/dev/null | grep -q "Plugin hyprbars" || hyprpm add '"$REPO"'
        hyprpm enable '"$PLUGIN"'
        hyprpm reload -n
        echo
        echo "Done — hyprbars is enabled and loads automatically from now on."
        read -rp "Press enter to close."
    ' >>"$LOG" 2>&1 &
}

: > "$LOG"

# No state store => ANY hyprpm call would sudo, and from autostart that is a
# failed authentication that pam_faillock counts. Go straight to the terminal.
# Calling plugin_state() before this check would itself be the bug.
if [ ! -d "$STORE" ]; then
    prompt_in_terminal "hyprpm has never run here; its state store is created as root."
    exit 0
fi

if [ "$(plugin_state)" = "true" ]; then
    # Enabling only records state on disk; the plugin still has to be loaded into
    # this instance. The store exists, so this needs no root. -n makes hyprpm say
    # so on screen (the wiki's suggestion).
    timeout 60 hyprpm reload -n </dev/null >>"$LOG" 2>&1 || true
    exit 0
fi

# Present but disabled, or repo absent. Both write state, so both need root.
prompt_in_terminal "hyprbars is not enabled yet."
