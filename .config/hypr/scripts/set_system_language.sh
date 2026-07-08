#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Switch input + app language between English and Japanese (topbar kb pill RIGHT-click)
# ─────────────────────────────────────────────────────────────────────────────
# Does NOT touch the system-wide locale (no root, no relogin). It:
#   1. Switches the fcitx5 input method (keyboard-us <-> mozc) for ALL windows.
#   2. Pushes LANG/LC_MESSAGES/LANGUAGE into the live session so apps launched FROM NOW
#      ON come up in the chosen language.
#   3. Calls an optional reload hook so already-open apps can be restarted into the new
#      language — see the LINK section at the bottom (dormant until you build it).
set -e

# Direction from the CURRENT input mode (so it matches the pill): fcitx5-remote == 2
# means Japanese (Mozc) is active.
if [ "$(fcitx5-remote 2>/dev/null)" = "2" ]; then
    lang=en_US.UTF-8; im=keyboard-us; langlist=en_US:en   # currently Japanese -> English
else
    lang=ja_JP.UTF-8; im=mozc;        langlist=ja:en      # currently English  -> Japanese
fi

# 1) Input method for every window (fcitx5 global shared state).
fcitx5-remote -s "$im" 2>/dev/null || true

# 2) Live session environment, so apps launched from now on use this language without a
#    relogin. LANGUAGE is a gettext fallback list ("ja:en" = try Japanese, fall back English).
#    Covers: Hyprland keybind + topbar-launcher apps (both via `hyprctl dispatch exec`),
#    and systemd/D-Bus-activated apps.
hyprctl keyword env "LANG,$lang"          >/dev/null 2>&1 || true
hyprctl keyword env "LC_MESSAGES,$lang"   >/dev/null 2>&1 || true
hyprctl keyword env "LANGUAGE,$langlist"  >/dev/null 2>&1 || true
systemctl --user set-environment "LANG=$lang" "LC_MESSAGES=$lang" "LANGUAGE=$langlist" 2>/dev/null || true
dbus-update-activation-environment --systemd "LANG=$lang" "LC_MESSAGES=$lang" "LANGUAGE=$langlist" 2>/dev/null || true

# ── LINK: app-reload hook (future build) ─────────────────────────────────────────────
# Already-open apps can't change language at runtime — they must be relaunched (they'll
# then inherit the env set above). This is the integration point for that: a future build
# that caches the current workspaces, closes the apps, and reopens them in place.
#
# It is intentionally NOT implemented here. The hook stays DORMANT until an EXECUTABLE
# exists at the path below (the [ -x ] guard skips it otherwise). Drop in / wire up your
# workspace-cache-and-restart script there and `chmod +x` it to activate.
#   Receives: $1 = input method (mozc|keyboard-us)   $2 = LANG   $3 = LANGUAGE list
LANG_RELOAD_HOOK="$HOME/.config/hypr/scripts/reload_apps_language.sh"
[ -x "$LANG_RELOAD_HOOK" ] && "$LANG_RELOAD_HOOK" "$im" "$lang" "$langlist" || true
