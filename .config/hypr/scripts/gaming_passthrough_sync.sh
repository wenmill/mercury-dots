#!/usr/bin/env bash
# Auto-sync overlay passthrough to ACTUAL game launches.
#
# Turns the overlay passthrough ON (1) while a Steam game is running — whether the
# game was launched directly from Steam OR from the movies widget's Games tab (which
# routes through `steam steam://rungameid/<id>`). Turns it OFF (0) once no game is
# running. When passthrough is 1 the mpv movies window and the floating AI/notes
# window drop their input mask: the video keeps playing and the panels stay visible,
# but the floating window's edge zones no longer spawn the AI selector and clicks
# pass through to the game underneath.
#
# This REPLACES the old focus-mode trigger. Entering the "gaming" focus mode (e.g.
# accepting the controller-connect prompt) no longer forces passthrough by itself —
# only a real running game does, exactly as requested. The gaming focus mode still
# exists for everything else (movies widget opening on the Games tab, etc.); it just
# no longer controls click-through.
#
# The manual SUPER+SHIFT+G toggle (overlay_passthrough.sh) still works and now
# persists until the next real game start/stop, because we only WRITE on a state
# change (edge-triggered) rather than on every poll.
#
# Launched once at login: exec-once = ~/.config/hypr/scripts/gaming_passthrough_sync.sh

# ── Singleton: prune any stale copy before starting ──
__self="$(basename "${BASH_SOURCE[0]}")"
for __pid in $(pgrep -f "scripts/$__self" 2>/dev/null); do
    [ "$__pid" = "$$" ] && continue
    pkill -P "$__pid" 2>/dev/null
    kill "$__pid" 2>/dev/null
done

PASS="$HOME/.cache/qs_overlay_passthrough"

# A Steam game is running iff Steam's launch wrapper is alive — every game (native or
# Proton) is started under `reaper SteamLaunch AppId=<id> -- …`. Matching that is
# independent of HOW the game was launched (Steam UI, Big Picture, or the movies
# widget), so it covers both requested triggers. AppId=[1-9]… excludes AppId=0
# (Steam's own non-game launches).
game_running() { pgrep -f 'SteamLaunch AppId=[1-9]' >/dev/null 2>&1; }

mkdir -p "$HOME/.cache"

# Edge-triggered poll: only write when the running-state flips. pgrep is cheap, and a
# ~2s reaction on game start/exit is imperceptible for toggling click-through. Process
# start/stop has no reliable inotify signal, hence the poll rather than a file watch.
prev=""
while true; do
    if game_running; then cur=1; else cur=0; fi
    if [ "$cur" != "$prev" ]; then
        echo "$cur" > "$PASS"
        prev="$cur"
    fi
    sleep 2
done
