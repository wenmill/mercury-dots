#!/usr/bin/env bash
#
# Trakt comments -> NDJSON {author,text,likes,spoiler}, sorted by likes.
#
#   trakt_comments.sh movie <imdb-id>
#   trakt_comments.sh show  <imdb-id> <season> <episode>
#   trakt_comments.sh show  <imdb-id>                      (whole-show comments)
#
# Trakt accepts an IMDb id (tt…) directly as the {id}, so no extra lookup is
# needed. Reads a free Trakt API client ID from the "trakt_client_id" key in
#   ~/.config/hypr/config.json
# Emits __NOKEY__ if that's empty, __NONE__ if there are no comments, __ERR__
# on a bad response. Used by the movies widget's in-player comments panel.
#
KIND="$1"; ID="$2"; SEASON="$3"; EP="$4"
CONFIG="$HOME/.config/hypr/config.json"

[ -z "$ID" ] && { echo "__NONE__"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "__ERR__"; exit 0; }

CID="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("trakt_client_id","").strip())
except Exception: pass' "$CONFIG" 2>/dev/null)"
[ -z "$CID" ] && { echo "__NOKEY__"; exit 0; }

case "$KIND" in
    movie) Q="movies/$ID/comments/likes" ;;
    show)
        if [ -n "$SEASON" ] && [ -n "$EP" ] && [ "$EP" != "0" ]; then
            Q="shows/$ID/seasons/$SEASON/episodes/$EP/comments/likes"
        else
            Q="shows/$ID/comments/likes"
        fi ;;
    *) echo "__NONE__"; exit 0 ;;
esac

RESP="$(curl -fsS \
    -H "Content-Type: application/json" \
    -H "trakt-api-version: 2" \
    -H "trakt-api-key: $CID" \
    "https://api.trakt.tv/$Q?limit=60" 2>/dev/null)"
[ -z "$RESP" ] && { echo "__NONE__"; exit 0; }

printf '%s' "$RESP" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    print("__ERR__"); sys.exit(0)
if not isinstance(data, list) or not data:
    print("__NONE__"); sys.exit(0)
n = 0
for c in data:
    txt = (c.get("comment") or "").strip()
    if not txt:
        continue
    print(json.dumps({
        "author": (c.get("user") or {}).get("username") or "trakt user",
        "text": txt,
        "likes": c.get("likes") or 0,
        "spoiler": bool(c.get("spoiler")),
    }))
    n += 1
if n == 0:
    print("__NONE__")
'
