#!/usr/bin/env bash
#
# Pick the best subtitle track on the embedded PiP mpv, by preference list.
#
#   sub_select.sh en,eng,en-orig,en-US   # ordered codes, best match wins
#   sub_select.sh any                    # first available subtitle track
#
# Exists because the QML side can't be trusted for this: mpvqt's property
# marshalling silently drops map values (ytdl-raw-options set from QML stayed
# {}), so track-list (a list of maps) through the same layer is suspect too.
#
# YouTube caption tracks arrive as delay_open EDL placeholders wrapping
# timedtext URLs — and mpv/ffmpeg's own fetch of those URLs fails silently
# (codec stays null forever, no text renders) even though the URL serves fine.
# So for URL-backed tracks we download the file OURSELVES (curl, browser UA)
# into the movies cache and sub-add the local file, which always opens.
#
# Scoring: exact code beats a regional/derived prefix ("en" > "en-US"),
# earlier preference entries beat later ones.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SOCK="$XDG_RUNTIME_DIR/mpv-pip.sock"
CACHE="$HOME/.cache/quickshell/movies/subs"
[ -S "$SOCK" ] || exit 0
[ -n "${1:-}" ] || exit 0
mkdir -p "$CACHE"
# Keep the caption cache bounded (newest 40 files).
ls -t "$CACHE" 2>/dev/null | tail -n +41 | while read -r f; do rm -f "$CACHE/$f"; done

SUB_CACHE="$CACHE" python3 - "$SOCK" "$1" <<'PY'
import glob, json, os, re, shutil, socket, subprocess, sys, tempfile, time
from urllib.parse import urlparse, parse_qs

sock_path, want = sys.argv[1], sys.argv[2].strip().lower()
wants = [] if want == "any" else [w for w in want.split(",") if w]
cache = os.environ["SUB_CACHE"]

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3.0)
s.connect(sock_path)
rid = 0

def req(command):
    global rid
    rid += 1
    s.sendall((json.dumps({"command": command, "request_id": rid}) + "\n").encode())
    buf, t0 = "", time.time()
    while time.time() - t0 < 3.0:
        buf += s.recv(1 << 16).decode(errors="replace")
        *lines, buf = buf.split("\n")
        for line in lines:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("request_id") == rid:
                return d.get("data")
    return None

def score(lang):
    best = None
    for i, w in enumerate(wants):
        sc = i * 2 if lang == w else (i * 2 + 1 if lang.startswith(w + "-") else None)
        if sc is not None and (best is None or sc < best):
            best = sc
    return best

tracks = [t for t in (req(["get_property", "track-list"]) or [])
          if isinstance(t, dict) and t.get("type") == "sub"]
if not tracks:
    sys.exit(0)

def url_of(t):
    # delay_open EDL: edl://!no_clip;!delay_open,media_type=sub;%<len>%<url>
    # NB: match the %<len>% prefix, NOT the last "%" — the URL itself holds
    # %2C-style escapes, so rsplit("%") returns garbage.
    f = t.get("external-filename") or ""
    m = re.search(r"%\d+%(https?://.*)$", f)
    if m:
        f = m.group(1)
    return f if f.startswith(("http://", "https://")) else None

pick, best = None, None
for t in tracks:
    sc = score((t.get("lang") or "").lower())
    if sc is not None and (best is None or sc < best):
        best, pick = sc, t
if pick is None and not wants:
    pick = tracks[0]
if pick is None:
    sys.exit(0)

# Prefer an already-added LOCAL twin of the same lang (from a previous run).
for t in tracks:
    fn = t.get("external-filename") or ""
    if fn.startswith(cache) and (t.get("lang") or "").lower() == (pick.get("lang") or "").lower():
        req(["set_property", "sid", t["id"]])
        sys.exit(0)

def cached_ok(path):
    # Reject Google's bot-block HTML — caching it would wedge the lang forever.
    if not (os.path.exists(path) and os.path.getsize(path) > 8):
        return False
    with open(path, "rb") as f:
        return not f.read(64).lstrip().lower().startswith(b"<html")

def fetch_caption(vid, lang, path):
    # Plain curl on timedtext URLs gets captcha-walled ("Sorry..." page) —
    # captions need the same authenticated fetch as everything else: yt-dlp
    # with live browser cookies. Writes cap.<lang>.<ext> into a temp dir.
    tmp = tempfile.mkdtemp(prefix="subsel.", dir=cache)
    try:
        args = ["yt-dlp", "--skip-download", "--no-warnings", "--no-playlist",
                "--write-subs", "--write-auto-subs", "--sub-langs", lang,
                "--sub-format", "srt/vtt/best", "-o", os.path.join(tmp, "cap"),
                f"https://www.youtube.com/watch?v={vid}"]
        prof = sorted(glob.glob(os.path.expanduser("~/.config/zen/*/cookies.sqlite")))
        if prof:
            args[1:1] = ["--cookies-from-browser", "firefox:" + os.path.dirname(prof[0])]
        subprocess.run(args, check=True, timeout=60,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        got = sorted(glob.glob(os.path.join(tmp, "cap.*")))
        if got:
            shutil.move(got[0], path)
    except Exception:
        pass
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

url = url_of(pick)
opened = (pick.get("codec") or "null") != "null"
if url and not opened:
    # mpv/ffmpeg can't open these URLs itself — feed it a local file instead.
    q = parse_qs(urlparse(url).query)
    vid = (q.get("v") or [""])[0]
    lang = (pick.get("lang") or "").strip()
    path = os.path.join(cache, f"{vid}.{lang}.sub")
    if vid and lang:
        if not cached_ok(path):
            try:
                os.remove(path)   # clear a poisoned/partial cache entry
            except OSError:
                pass
            fetch_caption(vid, lang, path)
        if cached_ok(path):
            req(["sub-add", path, "select", pick.get("title") or "", lang])
            sys.exit(0)
    # download failed → fall through to plain selection (better than nothing)

req(["set_property", "sid", pick["id"]])
PY
