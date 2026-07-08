#!/usr/bin/env bash
# kavita_learn_extract.sh — extract plain text for a single Kavita chapter so
# AiPopup's Learn module can feed it to the AI tutor.
#
# Result is cached at ~/.local/share/quickshell-learn/chapters/ch_<chapterId>.txt
# so subsequent loads are instant.
#
# Usage:
#   KAVITA_URL="http://localhost:5000" \
#   KAVITA_TOKEN="<jwt>" \
#   KAVITA_API_KEY="<key>" \
#   kavita_learn_extract.sh <chapterId> <pageCount> <format>
#
# format: 3 = EPUB (HTML per page, Bearer auth), 4 = PDF (raw bytes, apiKey auth)
#
# Why two auth modes: Kavita's Reader endpoints (/api/Reader/pdf, image, etc.)
# authenticate via `apiKey=` query param; Bearer gets HTTP 400. The Book
# endpoints (/api/Book/*) use Bearer like everything else.

set -u
CID="${1:?Usage: kavita_learn_extract.sh <chapterId> <pageCount> <format>}"
PAGES="${2:-0}"
FMT="${3:-0}"
URL="${KAVITA_URL:?Set KAVITA_URL}"
TOK="${KAVITA_TOKEN:?Set KAVITA_TOKEN}"
KEY="${KAVITA_API_KEY:-}"

CID="${CID//[^0-9]/}"   # chapterId is numeric in Kavita
[ -z "$CID" ] && { echo "Invalid chapterId."; exit 2; }

LEARN_DIR="$HOME/.local/share/quickshell-learn"
CDIR="$LEARN_DIR/chapters"
mkdir -p "$CDIR"
CACHE="$CDIR/ch_${CID}.txt"

LOG_DIR="$HOME/.cache/quickshell"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/kavita.log"
log() { printf '[%s] [learn-extract %s] %s\n' "$(date '+%F %T')" "$CID" "$*" >>"$LOG"; }

# Cache hit → return immediately.
if [ -s "$CACHE" ]; then
    cat "$CACHE"
    exit 0
fi

log "extracting (fmt=$FMT pages=$PAGES)"

case "$FMT" in
    3)
        # EPUB: Kavita serves rewritten HTML, one page at a time. Loop, strip tags.
        if [ "$PAGES" -lt 1 ]; then PAGES=1; fi
        for p in $(seq 0 $((PAGES - 1))); do
            curl -s "$URL/api/Book/$CID/book-page?page=$p" \
                -H "Authorization: Bearer $TOK" 2>>"$LOG"
            printf '\n\n'
        done | python3 - >"$CACHE" 2>>"$LOG" <<'PY'
import sys, html
from html.parser import HTMLParser
BLOCK = {"p","br","div","li","h1","h2","h3","h4","h5","h6","tr","blockquote"}
class TextOnly(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out = []
    def handle_data(self, d):
        self.out.append(d)
    def handle_starttag(self, tag, attrs):
        if tag in BLOCK: self.out.append("\n")
    def handle_endtag(self, tag):
        if tag in BLOCK: self.out.append("\n")
p = TextOnly()
p.feed(sys.stdin.read())
# Collapse runs of blank lines down to one.
import re
text = "".join(p.out)
text = re.sub(r"\n{3,}", "\n\n", text)
sys.stdout.write(text.strip() + "\n")
PY
        ;;
    4)
        # PDF: pull bytes into tmpfs ($XDG_RUNTIME_DIR), extract text, drop the
        # scratch file. We never keep a persistent copy — Kavita already has it.
        if [ -z "$KEY" ]; then
            echo "Kavita API key not set (KAVITA_API_KEY). /api/Reader/pdf needs it." >"$CACHE"
        else
            SCRATCH_DIR="${XDG_RUNTIME_DIR:-/tmp}/quickshell-kavita"
            mkdir -p "$SCRATCH_DIR"; chmod 700 "$SCRATCH_DIR"
            PDF="$SCRATCH_DIR/learn_${CID}.pdf"
            # /api/Reader/pdf uses apiKey query auth, NOT Bearer.
            HTTP=$(curl -s -o "$PDF" -w '%{http_code}' \
                "$URL/api/Reader/pdf?chapterId=$CID&apiKey=$KEY" 2>>"$LOG" || echo 000)
            if [ "$HTTP" != "200" ] || [ ! -s "$PDF" ]; then
                log "pdf download failed http=$HTTP bytes=$(stat -c%s "$PDF" 2>/dev/null || echo 0)"
                rm -f "$PDF"
                echo "Could not download PDF for chapter ${CID} (http=$HTTP)." >"$CACHE"
            elif ! command -v pdftotext >/dev/null 2>&1; then
                echo "pdftotext is not installed (install poppler)." >"$CACHE"
                rm -f "$PDF"
            else
                pdftotext -layout "$PDF" - >"$CACHE" 2>>"$LOG" \
                    || echo "pdftotext failed on chapter ${CID}." >"$CACHE"
                rm -f "$PDF"   # text is extracted; scratch PDF no longer needed
            fi
        fi
        ;;
    *)
        echo "Format $FMT is not supported for Learn mode (only EPUB and PDF have text content)." >"$CACHE"
        ;;
esac

cat "$CACHE"
