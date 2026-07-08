#!/usr/bin/env bash
#
# Reddit r/anime episode-discussion comments -> NDJSON {author,text,likes}.
#
#   reddit_comments.sh "<title>" [episode]
#
# Reddit killed its unauthenticated .json endpoints (403), so this uses the
# OAuth "installed_client" flow: register a free Reddit app (type: installed
# app) and put its client ID in the "reddit_client_id" key in:
#   ~/.config/hypr/config.json
# No client secret is needed. A bearer token is cached in $XDG_RUNTIME_DIR.
#
# Emits __NOKEY__ if no client ID, __NONE__ if no matching thread/comments,
# __ERR__ on auth/transport failure. Used by the in-player comments panel.
#
TITLE="$1"; EP="$2"
CONFIG="$HOME/.config/hypr/config.json"
UA="linux:quickshell-movies:1.1 (by /u/local)"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
TOKCACHE="$XDG_RUNTIME_DIR/qs_reddit_token"

[ -z "$TITLE" ] && { echo "__NONE__"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "__ERR__"; exit 0; }

CID="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("reddit_client_id","").strip())
except Exception: pass' "$CONFIG" 2>/dev/null)"
[ -z "$CID" ] && { echo "__NOKEY__"; exit 0; }

# --- bearer token (cached until ~5 min before expiry) ---
TOKEN=""
if [ -f "$TOKCACHE" ]; then
    read -r EXP CACHED < "$TOKCACHE" 2>/dev/null
    if [ -n "$EXP" ] && [ "$EXP" -gt "$(date +%s)" ] 2>/dev/null; then
        TOKEN="$CACHED"
    fi
fi
if [ -z "$TOKEN" ]; then
    TRESP="$(curl -fsS -A "$UA" -u "${CID}:" \
        --data 'grant_type=https://oauth.reddit.com/grants/installed_client&device_id=DO_NOT_TRACK_THIS_DEVICE' \
        https://www.reddit.com/api/v1/access_token 2>/dev/null)"
    TOKEN="$(printf '%s' "$TRESP" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get("access_token", ""))
    print(d.get("expires_in", 0))
except Exception:
    pass
' 2>/dev/null)"
    EXPIRES_IN="$(printf '%s\n' "$TOKEN" | sed -n 2p)"
    TOKEN="$(printf '%s\n' "$TOKEN" | sed -n 1p)"
    [ -z "$TOKEN" ] && { echo "__NOKEY__"; exit 0; }
    [ -z "$EXPIRES_IN" ] && EXPIRES_IN=3600
    echo "$(( $(date +%s) + EXPIRES_IN - 300 )) $TOKEN" > "$TOKCACHE"
    chmod 600 "$TOKCACHE" 2>/dev/null
fi

if [ -n "$EP" ] && [ "$EP" != "0" ]; then
    QUERY="$TITLE Episode $EP discussion"
else
    QUERY="$TITLE discussion"
fi
ENCQ="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$QUERY")"

SRES="$(curl -fsS -A "$UA" -H "Authorization: bearer $TOKEN" \
    "https://oauth.reddit.com/r/anime/search?q=${ENCQ}&restrict_sr=1&sort=relevance&limit=10&raw_json=1" 2>/dev/null)"
[ -z "$SRES" ] && { echo "__NONE__"; exit 0; }

TID="$(printf '%s' "$SRES" | TITLE="$TITLE" EP="$EP" python3 -c '
import sys, os, re, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
title = os.environ.get("TITLE", "").lower()
ep = os.environ.get("EP", "").strip()
toks = [w for w in re.split(r"\W+", title) if len(w) > 2]
best, best_score = None, -1
for ch in d.get("data", {}).get("children", []):
    p = ch.get("data", {})
    t = (p.get("title") or "").lower()
    score = 0
    if "discussion" in t: score += 2
    if ep and re.search(r"episode\s*0*%s\b" % re.escape(ep), t): score += 4
    score += sum(1 for w in toks if w in t)
    if score > best_score:
        best_score, best = score, p.get("id")
if best and best_score >= 2:
    print(best)
')"
[ -z "$TID" ] && { echo "__NONE__"; exit 0; }

CRES="$(curl -fsS -A "$UA" -H "Authorization: bearer $TOKEN" \
    "https://oauth.reddit.com/comments/${TID}?limit=60&sort=top&raw_json=1" 2>/dev/null)"
[ -z "$CRES" ] && { echo "__NONE__"; exit 0; }

printf '%s' "$CRES" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("__ERR__"); sys.exit(0)
try:
    kids = d[1]["data"]["children"]
except Exception:
    kids = []
n = 0
for ch in kids:
    if ch.get("kind") != "t1":
        continue
    p = ch.get("data", {})
    body = (p.get("body") or "").strip()
    if not body or body in ("[deleted]", "[removed]"):
        continue
    print(json.dumps({
        "author": p.get("author") or "redditor",
        "text": body,
        "likes": p.get("score") or 0,
    }))
    n += 1
    if n >= 60:
        break
if n == 0:
    print("__NONE__")
'
