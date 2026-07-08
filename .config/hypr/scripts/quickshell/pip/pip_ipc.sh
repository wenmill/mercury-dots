#!/usr/bin/env bash
#
# Send a raw mpv IPC command (JSON) to a RUNNING PiP instance.
# No-op if the socket isn't present.
#
#   pip_ipc.sh '{"command":["cycle","pause"]}'
#
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SOCK="$XDG_RUNTIME_DIR/mpv-pip.sock"
PAYLOAD="$1"

[ -z "$PAYLOAD" ] && exit 0
[ -S "$SOCK" ] || exit 0

python3 - "$SOCK" "$PAYLOAD" <<'PY'
import socket, sys
sock, payload = sys.argv[1], sys.argv[2]
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(1.0)
    s.connect(sock)
    s.sendall((payload + "\n").encode())
    s.close()
except OSError:
    pass
PY
