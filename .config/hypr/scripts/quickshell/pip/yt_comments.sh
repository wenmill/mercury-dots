#!/usr/bin/env bash
#
# Fetch top-level YouTube comments for a video id and emit them as NDJSON
# (one {"author","text","likes"} object per line), sorted by likes desc.
#
#   yt_comments.sh <video-id>
#
# Emits the sentinel __NOYTDLP__ if yt-dlp is missing, or __NONE__ if there are
# no comments. Used by the movies widget's in-player comments panel.
#
VID="$1"
[ -z "$VID" ] && { echo "__NONE__"; exit 0; }

if ! command -v yt-dlp >/dev/null 2>&1; then
    echo "__NOYTDLP__"
    exit 0
fi

# max_comments=N,M,L,K -> N total, M per thread root pass; keep it small/fast.
yt-dlp --skip-download --no-warnings --ignore-no-formats-error \
    --extractor-args "youtube:comment_sort=top;max_comments=60,all,0,0" \
    --write-comments -O "%(comments)j" \
    "https://www.youtube.com/watch?v=$VID" 2>/dev/null \
| python3 -c '
import sys, json
raw = sys.stdin.read().strip()
if not raw:
    print("__NONE__"); sys.exit(0)
try:
    data = json.loads(raw)
except Exception:
    print("__NONE__"); sys.exit(0)
if not isinstance(data, list) or not data:
    print("__NONE__"); sys.exit(0)
# top-level comments only (yt-dlp marks replies with a non-root parent)
top = [c for c in data if c.get("parent") in (None, "", "root")]
if not top:
    top = data
top.sort(key=lambda c: (c.get("like_count") or 0), reverse=True)
emitted = 0
for c in top[:50]:
    txt = (c.get("text") or "").strip()
    if not txt:
        continue
    print(json.dumps({
        "author": (c.get("author") or "").lstrip("@"),
        "text": txt,
        "likes": c.get("like_count") or 0,
    }))
    emitted += 1
if emitted == 0:
    print("__NONE__")
'
