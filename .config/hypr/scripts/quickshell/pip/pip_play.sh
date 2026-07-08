#!/usr/bin/env bash
#
# Background "find & play" service.
#
# Given a title (and season/episode), resolve the stream fully non-interactively
# with mov-cli (movies/TV) or ani-cli (anime) and play it in the mpv PiP from the
# start. No terminal, no prompts.
#
#   pip_play.sh movie "<title>"
#   pip_play.sh tv    "<title>" <season> <episode>
#   pip_play.sh anime "<title>" <episode>
#
# How it stays non-interactive: a shim dir is put first on PATH so the CLI's
#   mpv  -> pip_mpv.sh  (loads the resolved URL into the PiP and returns at once)
#   fzf  -> auto_fzf.sh (auto-picks the first result; quits ani-cli's post menu)
# mov-cli is auto-selected with `-c 1`; ani-cli with `-S 1`. Episodes are passed
# with mov-cli `-ep <ep>:<season>` and ani-cli `-e <ep>`.
#
DIR="$(cd "$(dirname "$0")" && pwd)"
KIND="$1"
TITLE="$2"
A="$3"
B="$4"

if [ -z "$KIND" ] || [ -z "$TITLE" ]; then
    echo "usage: pip_play.sh movie|tv|anime <title> [season] [episode]" >&2
    exit 1
fi

LOG="${XDG_RUNTIME_DIR:-/tmp}/pip_play.log"

# Prefer the uv-tool mov-cli (isolated env with a working scraper + nodejs
# runtime) over the system one, which has no usable scraper.
MOVCLI="$HOME/.local/bin/mov-cli"
[ -x "$MOVCLI" ] || MOVCLI="mov-cli"

notify() { command -v notify-send >/dev/null 2>&1 && notify-send "PiP" "$1" || echo "$1" >&2; }

# Build the auto shim (mpv + fzf) with the embedded DIR path always current.
SHIM="$DIR/shim-auto"
mkdir -p "$SHIM"
cat > "$SHIM/mpv" <<EOF
#!/usr/bin/env bash
exec bash "$DIR/pip_mpv.sh" "\$@"
EOF
cat > "$SHIM/fzf" <<EOF
#!/usr/bin/env bash
exec bash "$DIR/auto_fzf.sh" "\$@"
EOF
chmod +x "$SHIM/mpv" "$SHIM/fzf"

# The PiP is now the embedded MpvItem inside the movies widget; it owns the IPC
# socket whenever the widget is loaded, so we don't launch a separate mpv window.
echo "=== $(date '+%F %T') pip_play $KIND :: $TITLE :: s=$A e=$B ===" >> "$LOG"

case "$KIND" in
    movie)
        if ! command -v "$MOVCLI" >/dev/null 2>&1; then notify "mov-cli is not installed"; exit 1; fi
        PATH="$SHIM:$PATH" "$MOVCLI" -c 1 --player mpv "$TITLE" </dev/null >>"$LOG" 2>&1
        ;;
    tv)
        SEASON="${A:-1}"; EP="${B:-1}"
        if ! command -v "$MOVCLI" >/dev/null 2>&1; then notify "mov-cli is not installed"; exit 1; fi
        PATH="$SHIM:$PATH" "$MOVCLI" -c 1 -ep "${EP}:${SEASON}" --player mpv "$TITLE" </dev/null >>"$LOG" 2>&1
        ;;
    anime)
        EP="${A:-1}"
        if ! command -v ani-cli >/dev/null 2>&1; then notify "ani-cli is not installed (paru -S ani-cli)"; exit 1; fi
        PATH="$SHIM:$PATH" ani-cli -S 1 -e "$EP" "$TITLE" </dev/null >>"$LOG" 2>&1
        ;;
    *)
        echo "unknown kind: $KIND" >&2; exit 1 ;;
esac
