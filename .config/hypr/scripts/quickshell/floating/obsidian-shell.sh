#!/usr/bin/env bash
#
# Launch / drive the obsidian-shell layer panel — the merged floating panel +
# web hub (Obsidian / Hermes / Dify) that replaces Floating.qml AND the old
# notes_overlay.py window. It is an always-on wlr-layer-shell surface (edge-peek
# selector), so this script just makes sure it's running and forwards a one-shot
# command to it via ~/.cache/qs_obsidian_cmd (the QML polls that file).
#
#   (no arg)/toggle : ensure running, then pop the panel open / closed
#   open|close      : ensure running, then open / close
#   notes|hermes|learn : ensure running, open on that view
#   start           : just ensure running (used by autostart; no open)
#   restart         : kill + relaunch the binary (picks up edited QML/JS); leaves it
#                     idle/unpinned (closed) — reach an edge or use the keybind to open

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
# Chromium DevTools (CDP) is OFF by default: it is an UNauthenticated localhost
# control channel into every hub (any local process could read the Obsidian DOM
# or execute JS through it). Opt in per-run when debugging the injections:
#   QTWEBENGINE_REMOTE_DEBUGGING=9333 ./obsidian-shell.sh restart
# (the variable passes through to the binary if you export it yourself; 9222 is
# taken by the hermes app, so use 9333.)
ACTION="${1:-toggle}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/obsidian-shell/build/obsidian-shell"
CMDFILE="$HOME/.cache/qs_obsidian_cmd"

ensure_ignis() {
    # Ignis serves Obsidian as a web app on :8765 (quadlet → ignis.service).
    systemctl --user is-active --quiet ignis.service 2>/dev/null \
        || systemctl --user start ignis.service >/dev/null 2>&1 &
}

ensure_servers() {
    # The panel preloads all three web hubs at startup, so make sure every backing
    # server is up before the binary launches (otherwise the preloaded views would
    # load an error page and need a manual reload).
    ensure_ignis
    # Dify (:8090) — quadlet service, same pattern as Ignis.
    systemctl --user is-active --quiet dify.service 2>/dev/null \
        || systemctl --user start dify.service >/dev/null 2>&1 &
    # Hermes dashboard (:9119) — a plain process, started on demand if not serving.
    # HERMES_TUI_DIR points at a prebuilt copy of the chat TUI bundle: the system
    # install (/usr/local/lib/hermes-agent) is root-owned, so the dashboard can't
    # build ui-tui/dist on demand (esbuild → "permission denied"), which made the
    # /chat tab show "Chat unavailable: 1". We prebuild it once into ~/.hermes/
    # tui-build (see that dir) and hand the dashboard the ready bundle.
    ss -tln 2>/dev/null | grep -q ':9119 ' \
        || ( export PATH="$HOME/.local/bin:$HOME/.hermes/venv/bin:$PATH"; \
             export HERMES_TUI_DIR="$HOME/.hermes/tui-build"; \
             setsid hermes dashboard --no-open --port 9119 --skip-build >/dev/null 2>&1 & )
}

is_running() { pgrep -f "$BIN" >/dev/null 2>&1; }

launch() {
    ensure_servers
    [ -x "$BIN" ] || { notify-send "obsidian-shell" "Not built — run build.sh" 2>/dev/null; exit 1; }
    nohup "$BIN" >/dev/null 2>&1 &
    # give the layer surface a moment to map before the first command lands
    for _ in $(seq 1 20); do is_running && break; sleep 0.1; done
    sleep 0.3
}

mkdir -p "$HOME/.cache"

# Full process restart — the ONLY way to pick up edited QML/JS, since the running
# binary reads those once at startup (toggle/open just message the live process
# over $CMDFILE and never re-exec it). Kill, relaunch, and leave it idle/unpinned
# (closed) so the page doesn't stay open by default — open it via the edge-peek or
# the keybind.
if [ "$ACTION" = "restart" ]; then
    pkill -f "$BIN" 2>/dev/null
    for _ in $(seq 1 20); do is_running || break; sleep 0.1; done
    launch
    exit 0
fi

if ! is_running; then
    launch
    # On a cold start, "start" just leaves it running; everything else opens it.
    [ "$ACTION" = "start" ] && exit 0
    [ "$ACTION" = "close" ] && exit 0
    printf '%s' "${ACTION/toggle/open}" > "$CMDFILE"
    exit 0
fi

# Already running — forward the command (start is a no-op).
[ "$ACTION" = "start" ] && exit 0
printf '%s' "$ACTION" > "$CMDFILE"
