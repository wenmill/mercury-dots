#!/usr/bin/env bash
#
# AirPods telemetry producer for the Quickshell bar.
#
# LibrePods is the only process that can hold the AirPods AAP (L2CAP) link, and it
# exposes no IPC/D-Bus/file for battery — it only logs state via Qt logging. So we
# launch LibrePods ourselves with stderr logging forced on, parse the battery and
# noise-control lines out of the stream, and publish them to a small JSON state file
# that bluetooth_panel_logic.sh merges into the network panel.
#
# Output: ~/.cache/qs_airpods.json
#   {"connected":true,"mac":"70:8C:...","left":90,"right":89,"case":0,"anc":"anc","ts":1782170000}
#
# Replaces a bare `exec-once = librepods`: it execs LibrePods (same single-instance
# app, same tray/GUI) and just tees its log through the parser.

# ── Singleton: prune any stale copy before starting. Matters here beyond
#    duplication: a second launch whose librepods exits (single-instance app)
#    would fire the EXIT trap and stamp {"connected":false} over live data. ──
__self="$(basename "${BASH_SOURCE[0]}")"
for __pid in $(pgrep -f "scripts/$__self" 2>/dev/null); do
    [ "$__pid" = "$$" ] && continue
    pkill -P "$__pid" 2>/dev/null
    kill "$__pid" 2>/dev/null
done

STATE="${XDG_CACHE_HOME:-$HOME/.cache}/qs_airpods.json"
mkdir -p "$(dirname "$STATE")"

# Force Qt to log to stderr (otherwise it goes to journald when not a TTY) and enable
# the app's own log category (custom categories default to warnings-only).
export QT_FORCE_STDERR_LOGGING=1
export QT_LOGGING_RULES=$'qt.*=false\n*.info=true\n*.debug=true'

# Mark disconnected when LibrePods exits, so the bar doesn't show stale data forever.
cleanup() {
    printf '{"connected":false,"ts":%s}\n' "$(date +%s)" > "$STATE.tmp" 2>/dev/null \
        && mv -f "$STATE.tmp" "$STATE" 2>/dev/null
}
trap cleanup EXIT

# stdbuf keeps LibrePods' stderr unbuffered so updates land promptly.
# --hide starts LibrePods straight to the system tray (no window on login);
# it still logs battery/noise to stderr, so the parser below is unaffected.
# Default MAC from config.json (personal identifier — never hardcoded); the
# parser still updates it live from LibrePods' own "Found ... AirPods:" line.
CFG_MAC="$(jq -r '.airpods_mac // empty' "$HOME/.config/hypr/config.json" 2>/dev/null)"
stdbuf -oL -eL librepods --hide 2>&1 | gawk -v state="$STATE" -v cfgmac="$CFG_MAC" '
    function publish(   tmp) {
        tmp = state ".tmp"
        printf "{\"connected\":true,\"mac\":\"%s\",\"left\":%d,\"right\":%d,\"case\":%d,\"anc\":\"%s\",\"ts\":%d}\n",
               mac, left, right, casev, anc, systime() > tmp
        close(tmp)
        system("mv -f \"" tmp "\" \"" state "\"")
    }
    BEGIN { mac=cfgmac; left=0; right=0; casev=0; anc="off" }
    {
        line = $0
        gsub(/\033\[[0-9;]*m/, "", line)   # strip ANSI colour codes

        if (line ~ /Found already connected AirPods:/ && match(line, /[0-9A-Fa-f:]{17}/))
            mac = substr(line, RSTART, RLENGTH)

        if (match(line, /Battery status:[^"]*"Left: ([0-9]+)%, Right: ([0-9]+)%, Case: ([0-9]+)%"/, m)) {
            left = m[1]; right = m[2]; casev = m[3]; publish()
        }
        else if (line ~ /Noise control mode received:/) {
            if (line ~ /NoiseCancellation/) anc = "anc"
            else if (line ~ /Transparency/) anc = "transparency"
            else if (line ~ /Adaptive/)     anc = "adaptive"
            else if (line ~ /Off/)          anc = "off"
            publish()
        }
        else if (match(line, /Noise control mode (received|is already set to):[^0-9]*([0-3])/, m)) {
            n = m[2]
            anc = (n=="0"?"off":(n=="1"?"anc":(n=="2"?"transparency":"adaptive")))
            publish()
        }
    }
'
