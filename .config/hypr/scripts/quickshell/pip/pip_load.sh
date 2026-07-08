#!/usr/bin/env bash
#
# Retarget a RUNNING mpv PiP instance to a new URL/file via its IPC socket.
# No-op (exit 0) if the socket isn't there yet — a freshly launched player picks
# up its media from argv instead, so callers can fire this unconditionally.
#
#   pip_load.sh <url_or_file>
#
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SOCK="$XDG_RUNTIME_DIR/mpv-pip.sock"
MEDIA="$1"

[ -z "$MEDIA" ] && exit 0
[ -S "$SOCK" ] || exit 0

python3 - "$SOCK" "$MEDIA" <<'PY'
import json, socket, sys
sock, media = sys.argv[1], sys.argv[2]
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(1.0)
    s.connect(sock)
    s.sendall((json.dumps({"command": ["loadfile", media]}) + "\n").encode())
    s.close()
except OSError:
    pass
PY
