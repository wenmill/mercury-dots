#!/usr/bin/env bash
#
# download.sh — the widget's download entry point (single item or a whole season),
# with an optional "choose a folder" picker.
#
#   download.sh [--pick] movie <title>
#   download.sh [--pick] tv    <title> <season> <ep|ep1,ep2,…>
#   download.sh [--pick] anime <title> <0>      <ep|ep1,ep2,…>  [sub|dub] [idx]
#
# --pick opens a native folder chooser (kdialog → zenity) and downloads there;
# without it, files go to config.json "download_dir" (default ~/Videos/Mercury).
#
# Episode lists run SEQUENTIALLY on purpose: a season is 12-1000 files, and
# firing them all at once would hammer the scraper/debrid host (and the VPN
# tunnel) hard enough to get throttled. Each item goes through the normal
# `video download` path, so the backend chain and the fail-closed VPN guard
# apply to every single file.
set -uo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIDEO="$LIB_DIR/../video"

notify() { command -v notify-send >/dev/null 2>&1 && notify-send "Download" "$1" || echo "$1" >&2; }

PICK=false
[ "${1:-}" = "--pick" ] && { PICK=true; shift; }

KIND="${1:?kind required}"; TITLE="${2:?title required}"
SEASON="${3:-0}"; EPS="${4:-}"; MODE="${5:-sub}"; IDX="${6:-1}"

if $PICK; then
    dir=""
    if command -v kdialog >/dev/null 2>&1; then
        dir="$(kdialog --getexistingdirectory "$HOME" 2>/dev/null)"
    elif command -v zenity >/dev/null 2>&1; then
        dir="$(zenity --file-selection --directory \
                      --title="Download “$TITLE” to…" --filename="$HOME/" 2>/dev/null)"
    else
        notify "No folder picker found (install kdialog or zenity)"; exit 1
    fi
    # Cancelled / empty → do nothing at all (don't silently use the default).
    [ -n "$dir" ] || exit 0
    [ -d "$dir" ] || { notify "Not a folder: $dir"; exit 1; }
    export VID_DOWNLOAD_DIR="$dir"
fi

# One item, or a comma-separated episode list (a whole season).
run_one() {   # <ep>
    case "$KIND" in
        movie) bash "$VIDEO" download movie "$TITLE" ;;
        tv)    bash "$VIDEO" download tv "$TITLE" "$SEASON" "$1" ;;
        anime) bash "$VIDEO" download anime "$TITLE" "$1" "$MODE" "$IDX" ;;
        *)     echo "download.sh: unknown kind '$KIND'" >&2; return 2 ;;
    esac
}

if [ "$KIND" = "movie" ] || [ -z "$EPS" ]; then
    run_one ""
    exit $?
fi

IFS=',' read -ra ep_list <<< "$EPS"
total="${#ep_list[@]}"
[ "$total" -gt 1 ] && notify "Queued $total episodes: $TITLE${VID_DOWNLOAD_DIR:+ → $VID_DOWNLOAD_DIR}"

ok=0; fail=0
for ep in "${ep_list[@]}"; do
    [ -n "$ep" ] || continue
    if run_one "$ep"; then ok=$((ok+1)); else fail=$((fail+1)); fi
done

if [ "$total" -gt 1 ]; then
    notify "$TITLE: $ok downloaded, $fail failed"
fi
[ "$fail" -eq 0 ]
