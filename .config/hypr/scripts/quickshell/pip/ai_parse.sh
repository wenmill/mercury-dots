#!/usr/bin/env bash
#
# "Parse this video" with the local llama.cpp model (Qwable on :11434).
#
# Two modes:
#   ai_parse.sh <kind> <arg...>                 → initial summary, TRANSCRIPT ONLY (no web)
#   ai_parse.sh --ask "<question>" <kind> <arg...>  → follow-up Q&A, grounded with live web search
#
# The web (SearXNG) is only hit for follow-up questions, never for the first
# summary. Conversation state is kept in a per-video session file so follow-ups
# stay coherent; the transcript is cached so we don't re-hit yt-dlp each turn.
#
# For youtube: <arg> is the video id. Otherwise <arg...> is the title.
# Prints the answer, or __NOAI__ (model down) / __ERR__.
#
QUESTION=""
if [ "$1" = "--ask" ]; then QUESTION="$2"; shift 2; fi
KIND="$1"; shift || true
VID=""; [ "$KIND" = "youtube" ] && VID="$1"   # raw id, so history entries can replay

CONFIG="$HOME/.config/hypr/config.json"
command -v curl >/dev/null 2>&1 || { echo "__ERR__"; exit 0; }
cfg() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$CONFIG" "$1" 2>/dev/null; }

LLAMA="http://localhost:11434"
SEARX="$(cfg searxng_url)"; [ -z "$SEARX" ] && SEARX="http://localhost:8888"

STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/ai_parse"
mkdir -p "$STATE_DIR" 2>/dev/null
KEY="$(printf '%s|%s' "$KIND" "$*" | md5sum | cut -d' ' -f1)"
TXT_CACHE="$STATE_DIR/$KEY.transcript"
SESSION="$STATE_DIR/$KEY.session.json"
# Persistent, AI-searchable watch history: {id,kind,title,summary,ts}, last 500.
HISTORY="$HOME/.cache/qs_ai_history.json"

# Model reachable? The qwable-proxy loads the model on demand: the first request
# after an idle-unload blocks while llama-server warms up. A cold load can take a
# few minutes (more under GPU contention), and /health on the public :11434 only
# answers 200 once the proxy is forwarding. So poll patiently, and tell warming
# (backend up, still loading) apart from truly offline so the UI can say so.
BACKEND="http://localhost:11435"   # internal llama-server; answers 503 while loading
ready=0
for _ in $(seq 1 80); do           # ceiling ~ a few min of curl timeout + 3s sleeps
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$LLAMA/health" 2>/dev/null)"
    [ "$code" = "200" ] && { ready=1; break; }
    sleep 3
done
if [ "$ready" != 1 ]; then
    # 503/200 from the internal backend = it's up and (still) loading → warming.
    # Empty/000 = backend not running → genuinely offline.
    bcode="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$BACKEND/health" 2>/dev/null)"
    if [ "$bcode" = "503" ] || [ "$bcode" = "200" ]; then
        echo "__WARMING__"
    else
        echo "__NOAI__"
    fi
    exit 0
fi
MODEL="$(curl -s -m 15 "$LLAMA/v1/models" 2>/dev/null | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["data"][0]["id"])
except Exception: print("")')"
[ -z "$MODEL" ] && MODEL="Qwable-v1.IQ4_XS.gguf"

# ── transcript + title (cached per video) ──────────────────────────────────
get_transcript() {
    if [ -s "$TXT_CACHE" ]; then cat "$TXT_CACHE"; return; fi
    local title="" transcript=""
    if [ "$KIND" = "youtube" ]; then
        local vid="$1" url="https://www.youtube.com/watch?v=$1"
        if [ -n "$vid" ] && command -v yt-dlp >/dev/null 2>&1; then
            # YouTube bot-checks bare yt-dlp on this IP — ride the browser's live
            # cookies (firefox-compatible Zen profile) like the player does.
            local ckargs=()
            local ckdb; ckdb="$(ls -d "$HOME"/.config/zen/*/cookies.sqlite 2>/dev/null | head -1)"
            [ -n "$ckdb" ] && ckargs=(--cookies-from-browser "firefox:$(dirname "$ckdb")")
            title="$(yt-dlp "${ckargs[@]}" --skip-download --no-warnings --print '%(title)s' "$url" 2>/dev/null | head -1)"
            local tmp; tmp="$(mktemp -d)"
            yt-dlp "${ckargs[@]}" --skip-download --write-auto-subs --write-subs \
                --sub-langs "en.*,en" --sub-format json3 -o "$tmp/s" "$url" >/dev/null 2>&1
            local f; f="$(ls "$tmp"/*.json3 2>/dev/null | head -1)"
            if [ -n "$f" ]; then
                transcript="$(python3 -c '
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
out=[]
for e in d.get("events",[]):
    for s in e.get("segs",[]) or []:
        t=s.get("utf8","")
        if t: out.append(t)
print("".join(out).replace("\n"," ")[:6000])
' "$f")"
            fi
            rm -rf "$tmp"
        fi
        [ -z "$title" ] && title="YouTube video $vid"
    else
        title="$*"
    fi
    [ -z "$transcript" ] && transcript="(transcript unavailable)"
    { printf 'TITLE: %s\n' "$title"; printf '%s' "$transcript"; } | tee "$TXT_CACHE"
}

CTX="$(get_transcript "$@")"
TITLE="$(printf '%s' "$CTX" | sed -n 's/^TITLE: //p' | head -1)"
[ -z "$TITLE" ] && TITLE="this video"

# ── build the messages array ───────────────────────────────────────────────
if [ -z "$QUESTION" ]; then
    # Initial summary — transcript only, no web. Fresh session.
    rm -f "$SESSION"
    SYS="You are summarising a video titled \"$TITLE\" using ONLY the transcript. Write it as an essay of plain paragraphs separated by blank lines: an introduction paragraph (what the video is), one paragraph per main part of the video (as many as the content actually has), and a closing paragraph (the takeaway). Each paragraph must be 50-100 words. NEVER label the paragraphs — no 'Intro', 'Body 1', 'Conclusion' or any other headings, no bold section titles, no numbering, no bullet lists, no preamble; the structure shows only through the paragraph breaks. Do not invent facts that aren't in the transcript. The user can ask follow-up questions afterward."
    USERMSG="VIDEO TRANSCRIPT (may be partial/auto-generated):
$CTX

Summarise this video."
    MESSAGES="$(SYS="$SYS" U="$USERMSG" python3 -c '
import os,json
print(json.dumps([
  {"role":"system","content": os.environ["SYS"]},
  {"role":"user","content": os.environ["U"]}
]))')"
else
    # Follow-up — pull in live web search on the question, carry prior context.
    WEB="$(curl -s -m 20 --get "$SEARX/search" \
            --data-urlencode "q=$QUESTION ($TITLE)" --data-urlencode "format=json" 2>/dev/null \
        | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for r in (d.get("results") or [])[:5]:
    t=(r.get("title") or "").strip(); u=(r.get("url") or "").strip()
    print("- %s — %s" % (t,u))
    c=(r.get("content") or "").strip()
    if c: print("  %s" % c[:240])
')"
    [ -z "$WEB" ] && WEB="(no web results)"

    # Search your own watch history (past video summaries) for anything relevant.
    HIST="$(QUESTION="$QUESTION" HISTORY="$HISTORY" python3 -c '
import os,json,re
try: h=json.load(open(os.environ["HISTORY"]))
except Exception: h=[]
if not isinstance(h,list): h=[]
terms=set(re.findall(r"[a-z0-9]{3,}", os.environ["QUESTION"].lower()))
def score(e):
    blob=((e.get("title") or "")+" "+(e.get("summary") or "")).lower()
    return sum(1 for t in terms if t in blob)
scored=sorted(((score(e),e) for e in h), key=lambda x:-x[0])
for s,e in scored[:4]:
    if s<=0: break
    print("- %s: %s" % ((e.get("title") or "?"), (e.get("summary") or "").strip()))
' 2>/dev/null)"
    [ -z "$HIST" ] && HIST="(nothing relevant in your watch history)"

    NEWUSER="WEB SEARCH RESULTS (SearXNG) for my question:
$WEB

FROM YOUR WATCH HISTORY (past videos you've summarised that may be relevant):
$HIST

MY QUESTION about \"$TITLE\":
$QUESTION

Answer in Markdown, grounded in the transcript, the web results, and your watch history above. Cite only URLs that appear above."
    if [ -s "$SESSION" ]; then
        MESSAGES="$(SESSION="$SESSION" U="$NEWUSER" python3 -c '
import os,json
try: msgs=json.load(open(os.environ["SESSION"]))
except Exception: msgs=[]
# keep system + last ~6 turns to bound prompt size
sys_msgs=[m for m in msgs if m.get("role")=="system"][:1]
rest=[m for m in msgs if m.get("role")!="system"][-6:]
msgs=sys_msgs+rest
msgs.append({"role":"user","content": os.environ["U"]})
print(json.dumps(msgs))')"
    else
        SYS="You are helping the user understand a video titled \"$TITLE\". Use the transcript plus the live web search results to answer their questions in Markdown. Cite only URLs that appear in the results."
        MESSAGES="$(SYS="$SYS" CTX="$CTX" U="$NEWUSER" python3 -c '
import os,json
print(json.dumps([
  {"role":"system","content": os.environ["SYS"]},
  {"role":"user","content": "VIDEO TRANSCRIPT:\n"+os.environ["CTX"]},
  {"role":"assistant","content": "Got it — I have the transcript. Ask away."},
  {"role":"user","content": os.environ["U"]}
]))')"
    fi
fi

# ── call the model ─────────────────────────────────────────────────────────
# Initial summaries: intro + one paragraph per part + close, 50-100 words
# each — a many-part video can reach ~500 words, so leave token headroom.
# Follow-up answers keep room to breathe.
MAXTOK=1536; [ -z "$QUESTION" ] && MAXTOK=1100
PAYLOAD="$(MESSAGES="$MESSAGES" MODEL="$MODEL" MAXTOK="$MAXTOK" python3 -c '
import os,json
print(json.dumps({
  "model": os.environ["MODEL"], "stream": False, "max_tokens": int(os.environ["MAXTOK"]), "temperature": 0.4,
  # gemma-4 does chain-of-thought and leaves `content` EMPTY (text goes to
  # reasoning_content) unless thinking is disabled — without this every call
  # parsed to "" and the UI showed __ERR__. Ignored by non-gemma models.
  "chat_template_kwargs": {"enable_thinking": False},
  "messages": json.loads(os.environ["MESSAGES"])
}))')"

RESP="$(curl -s -m 300 "$LLAMA/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "$PAYLOAD" 2>/dev/null)"
OUT="$(printf '%s' "$RESP" | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: print(""); sys.exit(0)
try:
    m=d["choices"][0]["message"]
    out=(m.get("content") or "").strip()
    # Belt-and-braces: if a thinking-mode model still routed everything into
    # reasoning_content, salvage that rather than erroring out.
    if not out: out=(m.get("reasoning_content") or "").strip()
    print(out)
except Exception: print("")')"

[ -z "$OUT" ] && { echo "__ERR__"; exit 0; }

# persist the turn into the session for coherent follow-ups
MESSAGES="$MESSAGES" OUT="$OUT" SESSION="$SESSION" python3 -c '
import os,json
msgs=json.loads(os.environ["MESSAGES"])
msgs.append({"role":"assistant","content": os.environ["OUT"]})
try: json.dump(msgs, open(os.environ["SESSION"],"w"))
except Exception: pass
' 2>/dev/null

# Save the <50-word summary into the searchable watch history (only initial
# summaries, deduped by video, capped at the last 500).
if [ -z "$QUESTION" ]; then
    KEY="$KEY" KIND="$KIND" TITLE="$TITLE" OUT="$OUT" VID="$VID" HISTORY="$HISTORY" python3 -c '
import os,json,time
p=os.environ["HISTORY"]
try: h=json.load(open(p))
except Exception: h=[]
if not isinstance(h,list): h=[]
key=os.environ["KEY"]
h=[e for e in h if e.get("id")!=key]                    # newest summary wins
h.append({"id":key,"kind":os.environ["KIND"],"title":os.environ["TITLE"],"vid":os.environ.get("VID",""),
          "summary":os.environ["OUT"],"ts":int(time.time())})
h=h[-500:]                                              # keep only the last 500
try: json.dump(h, open(p,"w"))
except Exception: pass
' 2>/dev/null
fi

printf '%s\n' "$OUT"
