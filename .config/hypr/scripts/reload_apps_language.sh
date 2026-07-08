#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  LINK / STUB — restart open apps so they relaunch in the new language
# ─────────────────────────────────────────────────────────────────────────────
# This is a DORMANT integration point, not an active feature. set_system_language.sh
# only calls it when it is EXECUTABLE ([ -x ] guard); it is shipped NON-executable on
# purpose, so nothing happens until you implement it and `chmod +x` it.
#
# Purpose (for the future build): already-running apps read their UI language once at
# startup and can't change it live. To make a language switch affect already-open
# windows, cache the current workspace layout, close the apps, and reopen them — they
# will inherit the LANG/LC_MESSAGES/LANGUAGE env that set_system_language.sh has already
# pushed into the live session, so they come back up in the new language.
#
# Arguments passed in by set_system_language.sh:
#   $1  input method   — "mozc" (Japanese) or "keyboard-us" (English)
#   $2  LANG           — e.g. "ja_JP.UTF-8"
#   $3  LANGUAGE list  — e.g. "ja:en"
#
# Suggested shape of a future implementation (NOT done here):
#   - read the workspace/app cache (you said you'll add that cache elsewhere),
#   - for each cached window: record its app + workspace + geometry,
#   - close it, then re-exec it via `hyprctl dispatch exec` (inherits the new env),
#   - restore it to its workspace/geometry.
#
# Until then, this script does nothing.

im="$1"; lang="$2"; langlist="$3"

# TODO: implement workspace cache + app relaunch here.
exit 0
