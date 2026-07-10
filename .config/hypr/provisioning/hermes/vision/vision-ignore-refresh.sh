#!/usr/bin/env bash
# vision-ignore-refresh.sh — regenerate the hermes-vision "don't look" list.
#
# Writes ~/.hermes/vision-ignore.txt: one glob per line, matched (case-insensitive)
# against the active window's class / initialClass / title / initialTitle. When the
# focused window matches, hermes-vision skips the capture entirely (nothing is even
# grabbed, let alone sent to gemma/honcho).
#
# Two parts:
#   * a STATIC block of sensitive apps (password managers, banking, private windows)
#     — edit STATIC below to taste; it is preserved verbatim on every refresh;
#   * a GENERATED block of every installed Steam game as `steam_app_<appid>` (the
#     window class Steam gives games), pulled from the same steam_games.sh the
#     movies-widget games module uses — so "all games in the games module" are
#     title-locked, and the list self-updates as you install/remove games.
#
# Fullscreen windows are always skipped by the daemon regardless of this list
# (games run fullscreen), so this mainly covers windowed games + sensitive apps.
set -uo pipefail
OUT="$HOME/.hermes/vision-ignore.txt"
STEAM_GAMES="$HOME/.config/hypr/scripts/steam_games.sh"
mkdir -p "$(dirname "$OUT")"

# ── STATIC: sensitive apps never to capture (globs, case-insensitive) ──
read -r -d '' STATIC <<'EOF'
# --- sensitive apps (edit freely; preserved across refreshes) ---
*bitwarden*
*keepass*
*1password*
*proton pass*
*gnome-keyring*
*polkit*
*org.freedesktop.secrets*
*private browsing*
*incognito*
*steam login*
*sudo*
*password*
EOF

tmp="$(mktemp)"
{
  echo "# hermes-vision ignore list — regenerated $(date '+%F %T') by vision-ignore-refresh.sh"
  echo "# Active-window class/title globs to skip. Edit the STATIC block in the script,"
  echo "# not this file (it is overwritten). Games are auto-generated below."
  echo
  printf '%s\n' "$STATIC"
  echo
  echo "# --- games from the movies-widget games module (steam_app_<appid>) ---"
  if [ -x "$STEAM_GAMES" ] || [ -f "$STEAM_GAMES" ]; then
    bash "$STEAM_GAMES" 2>/dev/null | python3 -c "
import sys, json
try: a = json.load(sys.stdin)
except Exception: a = []
seen = set()
for g in a:
    ap = str(g.get('appid') or '').strip()
    if ap and ap not in seen:
        seen.add(ap)
        print('steam_app_%s' % ap)
        n = (g.get('name') or '').strip()
        if n: print('*%s*' % n.lower())
" 2>/dev/null
  fi
  echo "gamescope"
} > "$tmp"

mv "$tmp" "$OUT"
echo "wrote $OUT ($(grep -cvE '^\s*(#|$)' "$OUT") active patterns)"
