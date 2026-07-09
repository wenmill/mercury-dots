#!/usr/bin/env bash
#
# Universal "play this in the mpv PiP" router.
#
# Also works as a drop-in `mpv` replacement for tools like ani-cli (see
# pip_anicli.sh): it captures the media URL plus the headers/title/UA those tools
# pass on the command line, ensures the single python PiP window is up, then loads
# the media into it over mpv's IPC socket. Reusing one PiP keeps the click-through
# toggle and window placement intact, and routing media via IPC (not argv) means
# per-file options like Referer always apply — even on a fresh launch.
#
#   pip_mpv.sh [mpv-style flags...] <URL_OR_FILE>
#
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
DIR="$(cd "$(dirname "$0")" && pwd)"
SOCK="$XDG_RUNTIME_DIR/mpv-pip.sock"

URL=""
declare -a OPTS=()
for a in "$@"; do
    case "$a" in
        --http-header-fields=*) OPTS+=("http-header-fields=${a#*=}") ;;
        --referrer=*)           OPTS+=("referrer=${a#*=}") ;;
        --user-agent=*)         OPTS+=("user-agent=${a#*=}") ;;
        --force-media-title=*)  OPTS+=("force-media-title=${a#*=}") ;;
        --audio-file=*)         OPTS+=("audio-file=${a#*=}") ;;   # scraper split audio
        --sub-file=*)           OPTS+=("sub-file=${a#*=}") ;;
        --sub-files=*)          OPTS+=("sub-files=${a#*=}") ;;
        --) ;;                  # arg separator
        --*) ;;                 # ignore any other mpv flag
        *)  [ -z "$URL" ] && URL="$a" ;;   # first positional = the media
    esac
done

if [ -z "$URL" ]; then
    echo "pip_mpv: no URL/file found in args" >&2
    exit 1
fi

# VPN routing: when the video CLI's vid_vpn_guard exported QS_VID_PROXY (movie/
# tv/anime with vpn_enabled), stream THIS load through the gluetun proxy as a
# per-file option — the embedded mpv fetches the media itself, so the scraper's
# proxy env alone wouldn't cover the actual video traffic. Per-file means the
# next non-VPN load (YouTube/music) is naturally unproxied — no reset needed.
if [ -n "${QS_VID_PROXY:-}" ]; then
    case "$URL" in http*) OPTS+=("http-proxy=$QS_VID_PROXY") ;; esac
fi

# The PiP is the embedded MpvItem in the movies widget, which owns the IPC
# socket while the widget is loaded. We just load into it over IPC below.
# Wait for the IPC socket, then loadfile with any captured options.
python3 - "$SOCK" "$URL" "${OPTS[@]}" <<'PY'
import json, socket, sys, time

sock, url = sys.argv[1], sys.argv[2]
pairs = [o.split("=", 1) for o in sys.argv[3:] if "=" in o]

# mpv's option-string escaping for values that may contain commas/colons/spaces:
#   key=%<bytelen>%<value>
def esc(v):
    return "%%%d%%%s" % (len(v.encode()), v)

s = None
deadline = time.time() + 6.0
while time.time() < deadline:
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect(sock)
        break
    except OSError:
        s = None
        time.sleep(0.15)
if s is None:
    sys.exit(0)  # player never came up; nothing to do

cmd = ["loadfile", url, "replace"]
if pairs:
    optstr = ",".join("%s=%s" % (k, esc(v)) for k, v in pairs)
    cmd += [0, optstr]
try:
    s.sendall((json.dumps({"command": cmd}) + "\n").encode())
    # Ensure it actually plays from the start (clear any keep-open EOF pause).
    s.sendall((json.dumps({"command": ["set_property", "pause", False]}) + "\n").encode())
    s.close()
except OSError:
    pass
PY
