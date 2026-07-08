#!/usr/bin/env bash
#
# Launch mov-cli in a terminal, with playback routed into the mpv PiP.
#
# Like pip_anicli.sh: mov-cli is interactive, so it runs in a terminal, and a
# shim `mpv` (first on PATH) forwards its playback — URL plus the referrer/title/
# split-audio flags mov-cli passes — into the single PiP window via pip_mpv.sh.
#
# All arguments are passed straight through to mov-cli, so the movies/TV grid can
# drive it directly, e.g.:
#   pip_movcli.sh -c 1 "The Matrix"            # auto-pick first result, play
#   pip_movcli.sh -c 1 -ep 5:2 "Some Show"     # season 2, episode 5
# With no arguments it just opens mov-cli to browse.
#
DIR="$(cd "$(dirname "$0")" && pwd)"
SHIM="$DIR/shim"
TERM_BIN="${TERMINAL:-kitty}"
command -v "$TERM_BIN" >/dev/null 2>&1 || TERM_BIN="kitty"

if ! command -v mov-cli >/dev/null 2>&1; then
    exec "$TERM_BIN" -e bash -lc \
        'echo "mov-cli is not installed."; echo; echo "Install it with:"; echo "    paru -S mov-cli        # or: pipx install mov-cli"; echo; echo "Then add a scraper plugin (see: https://github.com/mov-cli/mov-cli/wiki)."; echo; echo "(Press any key to close)"; read -rsn1'
fi

# (Re)generate the mpv shim so the embedded DIR path is always correct.
mkdir -p "$SHIM"
cat > "$SHIM/mpv" <<EOF
#!/usr/bin/env bash
exec bash "$DIR/pip_mpv.sh" "\$@"
EOF
chmod +x "$SHIM/mpv"

exec "$TERM_BIN" -e bash -lc 'export PATH="'"$SHIM"':$PATH"; exec mov-cli "$@"' _ "$@"
