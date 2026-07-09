#!/usr/bin/env bash
# =============================================================================
# video/lib/common.sh — shared helpers for the `video` CLI and its providers.
# -----------------------------------------------------------------------------
# The `video` CLI is a thin, pluggable FACADE over the proven low-level playback
# transport that still lives in ../../pip/ (the embedded-mpv IPC loader, the
# fzf/mpv shim, the pop-out window). Providers (video/providers/*) are the part
# you wire new sources into; the transport below never needs to change.
# =============================================================================
set -uo pipefail

# Resolve our own dir even when a provider is exec'd directly (VIDEO_DIR unset).
: "${VIDEO_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export VIDEO_DIR
# Low-level transport (unchanged, shared with the rest of the shell).
PIP_DIR="$(cd "$VIDEO_DIR/../../pip" && pwd)"
export PIP_DIR
CONFIG_JSON="$HOME/.config/hypr/config.json"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
VIDEO_LOG="${XDG_RUNTIME_DIR:-/tmp}/video.log"

vlog()    { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$VIDEO_LOG"; }
vnotify() { command -v notify-send >/dev/null 2>&1 && notify-send "Video" "$1" || echo "$1" >&2; }

# --- transport primitives (wrap the existing pip/ scripts) -------------------

# Load a direct URL/file into the running embedded PiP over its IPC socket.
# Accepts optional mpv-style flags (--referrer= --http-header-fields= --sub-file= …).
vid_load()   { bash "$PIP_DIR/pip_mpv.sh" "$@"; }

# Send a raw mpv JSON-IPC command to the PiP (no-op if it isn't running).
vid_ipc()    { bash "$PIP_DIR/pip_ipc.sh" "${1:-}"; }

# Pop the stream out into a standalone floating mpv window.
vid_popout() { bash "$PIP_DIR/pip_popout.sh" "$@"; }

# Read a plain key from ~/.config/hypr/config.json.
vid_cfg()    { jq -r --arg k "$1" '.[$k] // empty' "$CONFIG_JSON" 2>/dev/null; }
# Read a SECRET key: keyring first (secrets.sh), plaintext file as fallback —
# secret values are migrated out of config.json and live in the Secret Service.
vid_secret() {
    local v
    v="$(bash "$HOME/.config/hypr/scripts/secrets.sh" get "$1" 2>/dev/null)"
    [ -n "$v" ] && { printf '%s' "$v"; return; }
    vid_cfg "$1"
}

# Where `video download …` puts files. Precedence:
#   VID_DOWNLOAD_DIR (env — set by lib/download.sh's folder picker)
#   config.json "download_dir"
#   ~/Videos/Mercury
vid_download_dir() {
    local d="${VID_DOWNLOAD_DIR:-}"
    [ -n "$d" ] || d="$(vid_cfg download_dir)"
    [ -n "$d" ] || d="$HOME/Videos/Mercury"
    mkdir -p "$d" 2>/dev/null
    printf '%s' "$d"
}

# ── VPN routing (gluetun) — movie/tv/anime ONLY ──────────────────────────────
# When config.json "vpn_enabled" is true, ALL movie/tv/anime source traffic
# (scraper lookups AND the resolved stream into the PiP) is routed through the
# gluetun container's HTTP proxy. FAILSAFE: before anything reaches out we
# demand a working end-to-end fetch THROUGH the tunnel; gluetun's internal
# firewall drops any non-tunnel egress, so "proxy works" == "tunnel is up".
# If that check fails, playback is refused — nothing falls back to the bare
# network. YouTube/music/books are deliberately NOT routed.
VID_VPN_KINDS="movie tv anime"
vid_vpn_enabled() { [ "$(vid_cfg vpn_enabled)" = "true" ]; }
vid_vpn_proxy()   { local p; p="$(vid_cfg vpn_proxy)"; printf '%s' "${p:-http://127.0.0.1:8889}"; }
# End-to-end health: fetch an external IP through the proxy (≤4s). Succeeds only
# when gluetun is running AND its tunnel is connected (its killswitch blocks the
# request otherwise) — this probe itself cannot leak: it targets the proxy.
vid_vpn_up() {
    curl -sf -m 4 -x "$(vid_vpn_proxy)" https://api.ipify.org >/dev/null 2>&1 \
 || curl -sf -m 4 -x "$(vid_vpn_proxy)" https://ifconfig.me/ip >/dev/null 2>&1
}
# Guard + route: no-op for non-VPN kinds or when vpn_enabled is off. For VPN
# kinds: hard-fail (return 1) unless the tunnel is verifiably up; on success,
# export proxy env for every child (curl/yt-dlp/httpx in the scrapers) and
# QS_VID_PROXY so pip_mpv.sh routes the actual stream through the tunnel too.
vid_vpn_guard() {   # <kind>
    case " $VID_VPN_KINDS " in *" $1 "*) ;; *) return 0 ;; esac
    vid_vpn_enabled || return 0
    if ! vid_vpn_up; then
        vlog "vpn guard: $(vid_vpn_proxy) unreachable/tunnel down — BLOCKING $1 (failsafe)"
        vnotify "VPN not connected — $1 blocked (failsafe). Start it:  systemctl --user start gluetun"
        return 1
    fi
    local p; p="$(vid_vpn_proxy)"
    export http_proxy="$p" https_proxy="$p" HTTP_PROXY="$p" HTTPS_PROXY="$p" ALL_PROXY="$p"
    export QS_VID_PROXY="$p"
    vlog "vpn guard: $1 routed via $p"
    return 0
}

# Build (idempotently) the headless shim dir — `fzf`→auto-pick (auto_fzf.sh),
# `mpv`→PiP (pip_mpv.sh) — and echo its path. Prepend it to PATH so a scraper
# CLI resolves a stream and hands it to the PiP without any prompt. Split out so
# providers that must CAPTURE a scraper's output (to detect failure — some, e.g.
# lobster, exit 0 even on "no results") can run the CLI themselves under it.
vid_headless_shim() {
    local shim="$VIDEO_DIR/.shim"
    mkdir -p "$shim"
    printf '#!/usr/bin/env bash\nexec bash "%s/pip_mpv.sh" "$@"\n'  "$PIP_DIR" > "$shim/mpv"
    printf '#!/usr/bin/env bash\nexec bash "%s/auto_fzf.sh" "$@"\n' "$PIP_DIR" > "$shim/fzf"
    chmod +x "$shim/mpv" "$shim/fzf"
    printf '%s\n' "$shim"
}

# Run a scraper CLI (lobster/ani-cli/…) fully headless. Fire-and-forget friendly.
#   vid_run_headless lobster -q 1080 "The Matrix"
vid_run_headless() {
    local shim; shim="$(vid_headless_shim)"
    PATH="$shim:$PATH" "$@" </dev/null >>"$VIDEO_LOG" 2>&1
}

# Run a scraper CLI headless under the shim, CAPTURING its output, and return
# FAILURE when it printed a "nothing found" marker — many scrapers (lobster,
# ani-cli) exit 0 even on no results, so a backend that wants the
# dispatcher to fall through must use this instead of vid_run_headless.
#   vid_run_checked 'no results|error -' lobster -q 1080 "The Matrix"
vid_run_checked() {   # <fail-regex> <cmd> [args...]
    local re="$1"; shift
    local shim out; shim="$(vid_headless_shim)"
    out="$(PATH="$shim:$PATH" "$@" </dev/null 2>&1)"
    printf '%s\n' "$out" >> "$VIDEO_LOG"
    printf '%s' "$out" | grep -qiE "$re" && return 1
    return 0
}

# ── Pluggable backends ────────────────────────────────────────────────────────
# The movie/tv/anime providers are thin: they DISPATCH to a selectable backend in
# backends/ (one drop-in file per source — lobster, ani-cli, torrentio, or your own
# e.g. Jellyfin). Selection per kind via config.json "<kind>_backend"; unset uses
# the built-in defaults below. See backends/README + backends/jellyfin.example.
_vid_default_backends() {   # <kind>
    # Scrapers lead; torrentio is the SAFETY NET at the end of every chain —
    # it only runs once lobster/anicli have failed (a dead scraper exits
    # non-zero and vid_dispatch cascades). It also self-skips instantly unless
    # a debrid provider is configured, so it costs nothing when unused.
    #
    # NB: mov-cli was retired (upstream deprecated). It was the only backend
    # that could target an exact TV episode headlessly — lobster defers
    # anything but S1E1 — so TV episodes now resolve through torrentio, which
    # needs a debrid account. Without one, only S1E1 has a movie/tv source.
    case "$1" in
        movie|tv) echo "lobster torrentio" ;;
        anime)    echo "anicli torrentio" ;;
        *)        echo "" ;;
    esac
}
# Ordered backend names to try for <kind>: config first (if set), then defaults.
vid_backend_chain() {   # <kind>
    local kind="$1" cfg; cfg="$(vid_cfg "${kind}_backend")"
    # shellcheck disable=SC2086
    printf '%s\n' $cfg $(_vid_default_backends "$kind") | awk 'NF && !seen[$0]++'
}
# Dispatch a verb (play|browse|download) for <kind> to the backend chain.
# `browse` execs the first capable backend (interactive); `play`/`download` try
# each in order and fall through when a backend exits non-zero, so a dead
# source cascades to the next. `download` additionally skips backends that
# don't advertise the `download` capability.
vid_dispatch() {   # <kind> <verb:play|browse|download> [args...]
    local kind="$1" verb="$2"; shift 2
    # VPN failsafe FIRST: for movie/tv/anime with vpn_enabled, refuse to launch
    # any backend unless the gluetun tunnel is verifiably up (see vid_vpn_guard).
    # Downloads are source traffic too — same guard, same fail-closed rule.
    vid_vpn_guard "$kind" || return 1
    local b prov tried=0 caps
    for b in $(vid_backend_chain "$kind"); do
        prov="$VIDEO_DIR/backends/$b"
        [ -x "$prov" ] || { vlog "backend '$b' missing/not executable — skip"; continue; }
        caps="$("$prov" capabilities 2>/dev/null)"
        printf '%s\n' $caps | grep -qx "$kind" || continue
        if [ "$verb" = "browse" ]; then exec "$prov" browse "$kind" "$@"; fi
        if [ "$verb" = "download" ]; then
            printf '%s\n' $caps | grep -qx "download" || {
                vlog "backend '$b' can't download — trying next"; continue; }
        fi
        tried=1
        if "$prov" "$verb" "$kind" "$@"; then return 0; fi
        vlog "backend '$b' failed for $kind ($verb) — trying next"
    done
    if [ "$verb" = "download" ]; then
        [ "$tried" = 1 ] && vnotify "download failed for $kind (all backends)" \
                         || vnotify "no backend can download $kind"
        return 1
    fi
    [ "$tried" = 1 ] && vnotify "no working source for $kind (all backends failed)" \
                     || vnotify "no backend available for $kind"
    return 1
}
