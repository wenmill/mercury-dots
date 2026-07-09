#!/usr/bin/env bash
#
# Launch lobster in a terminal, with playback routed into the mpv PiP.
#
# Like pip_anicli.sh: lobster is interactive (fzf), so it runs in
# a terminal, and a shim `mpv` (first on PATH) forwards its playback — the stream
# URL plus lobster's referrer / http-header-fields / sub-file flags — into the
# single PiP window via pip_mpv.sh.
#
# All arguments pass straight through to lobster, so the movies/TV grid can drive
# it directly, e.g.:
#   pip_lobster.sh "The Matrix"          # search + interactive pick, play in PiP
#   pip_lobster.sh -t                    # browse trending
#   pip_lobster.sh -r tv                 # recently-added TV
# With no arguments it opens lobster's search prompt.
#
DIR="$(cd "$(dirname "$0")" && pwd)"
SHIM="$DIR/shim-lobster"
TERM_BIN="${TERMINAL:-kitty}"
command -v "$TERM_BIN" >/dev/null 2>&1 || TERM_BIN="kitty"

if ! command -v lobster >/dev/null 2>&1; then
    exec "$TERM_BIN" -e bash -lc \
        'echo "lobster is not installed."; echo; echo "Install it with:"; echo "    paru -S lobster-git"; echo; echo "(Press any key to close)"; read -rsn1'
fi

# (Re)generate the mpv shim so the embedded DIR path is always correct.
mkdir -p "$SHIM"
cat > "$SHIM/mpv" <<EOF
#!/usr/bin/env bash
exec bash "$DIR/pip_mpv.sh" "\$@"
EOF
chmod +x "$SHIM/mpv"

exec "$TERM_BIN" -e bash -lc 'export PATH="'"$SHIM"':$PATH"; exec lobster "$@"' _ "$@"
