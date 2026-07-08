#!/usr/bin/env bash
#
# Launch ani-cli in a terminal, with playback routed into the mpv PiP.
#
# ani-cli is interactive (fzf-style menus), so it runs in a terminal window. We
# put a shim dir first on PATH whose `mpv` forwards to pip_mpv.sh — so when
# ani-cli plays an episode it loads into the PiP (with the Referer/title headers
# ani-cli passes) instead of spawning its own window. Pick the next episode and
# the PiP simply swaps to it.
#
# An optional search query is forwarded to ani-cli (pre-fills the search):
#   pip_anicli.sh ["search terms"]
#
DIR="$(cd "$(dirname "$0")" && pwd)"
SHIM="$DIR/shim"
TERM_BIN="${TERMINAL:-kitty}"
command -v "$TERM_BIN" >/dev/null 2>&1 || TERM_BIN="kitty"

if ! command -v ani-cli >/dev/null 2>&1; then
    exec "$TERM_BIN" -e bash -lc \
        'echo "ani-cli is not installed."; echo; echo "Install it with:"; echo "    paru -S ani-cli"; echo; echo "(Press any key to close)"; read -rsn1'
fi

# (Re)generate the mpv shim so the embedded DIR path is always correct.
mkdir -p "$SHIM"
cat > "$SHIM/mpv" <<EOF
#!/usr/bin/env bash
exec bash "$DIR/pip_mpv.sh" "\$@"
EOF
chmod +x "$SHIM/mpv"

exec "$TERM_BIN" -e bash -lc 'export PATH="'"$SHIM"':$PATH"; exec ani-cli "$@"' _ "$@"
