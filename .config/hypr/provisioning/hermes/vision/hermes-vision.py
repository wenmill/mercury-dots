#!/usr/bin/env python3
"""
hermes-vision — event-driven, resource-frugal screen-memory feed for honcho.

Design (the "cheap gate → expensive digest" pattern):
  * TRIGGERS (when to even consider a shot):
      - Hyprland socket2 focus/workspace/fullscreen events (debounced) — a context
        switch is the highest-signal moment ("I started doing a new thing");
      - a slow heartbeat (default 75s) so long single-app sessions still leave a
        trail;
      - on-demand shots Hermes drops in the spool (vision-shot.sh).
  * GATES (skip the shot entirely, ~free):
      - idle (hypridle writes a flag), gaming/passthrough flag, fullscreen window
        (games), and the ignore-list (games by steam_app_<appid> + sensitive apps).
  * DEDUP (cheap): a perceptual dHash (via `magick`) — heartbeat shots whose screen
    hasn't meaningfully changed are dropped before gemma is ever called. Focus
    shots always describe (context changed by definition).
  * DIGEST (expensive, GPU): gemma vision → one factual line → honcho, then the
    image is DELETED. Retain-until-filed; nothing persists on disk.

Consolidation (hourly/daily rollups) lives in hermes-vision-consolidate.py.
Pure stdlib; single-threaded.
"""
import base64, fnmatch, glob, json, os, subprocess, sys, time, urllib.request, datetime, socket, select

HOME        = os.path.expanduser("~")
BIN         = os.path.join(HOME, ".hermes", "bin")
SPOOL       = os.path.join(HOME, ".hermes", "vision-spool")
IGNORE_FILE = os.path.join(HOME, ".hermes", "vision-ignore.txt")
IDLE_FLAG   = os.path.join(HOME, ".cache", "hermes-vision-idle")
GAMING_FLAG = os.path.join(HOME, ".cache", "qs_overlay_passthrough")
TICK        = 1.0
HEARTBEAT   = int(os.environ.get("HERMES_VISION_HEARTBEAT", "75"))   # s between shots if nothing else fires
DEBOUNCE    = float(os.environ.get("HERMES_VISION_DEBOUNCE", "2.5")) # s to let the screen settle after a focus event
PHASH_MINDIST = int(os.environ.get("HERMES_VISION_PHASH_DIST", "10")) # dHash hamming; below this = "same screen"
# Batch mode: instead of one gemma call per captured frame, buffer keyframes in
# MEMORY and send them as a single multi-image request every BATCH_WINDOW
# seconds. gemma's vision encoder amortises across images — measured on this
# box at 1280px: 1 frame 1.9s, 2 frames 3.5s, 4 frames 4.0s, 8 frames 4.8s. So
# eight frames cost 4.8s batched against ~15.2s one at a time.
#
# Frames are held as JPEG bytes in RAM and never written to disk (the PNG grim
# produces is deleted the moment it is encoded), so the "nothing persists"
# property that makes this preferable to screenpipe still holds.
#
# 0 disables batching and restores the original per-frame behaviour.
BATCH_WINDOW = int(os.environ.get("HERMES_VISION_BATCH_WINDOW", "0"))  # e.g. 900 = 15 min
BATCH_MAX    = int(os.environ.get("HERMES_VISION_BATCH_MAX", "8"))     # keyframes per batch
GEMMA_URL   = os.environ.get("HERMES_VISION_LLM", "http://127.0.0.1:11434/v1/chat/completions")
GEMMA_MODEL = os.environ.get("HERMES_VISION_MODEL", "gemma")
HONCHO      = os.environ.get("HONCHO_URL", "http://127.0.0.1:8000").rstrip("/")
WORKSPACE   = os.environ.get("HONCHO_WORKSPACE", "hermes")
PEER        = "screen"
TIMEOUT     = 90

os.makedirs(SPOOL, exist_ok=True)


# ── tiny http helpers ─────────────────────────────────────────────────────────
def _post(url, payload, timeout=TIMEOUT):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


# ── honcho ────────────────────────────────────────────────────────────────────
def ensure_honcho():
    try: _post(f"{HONCHO}/v3/workspaces/{WORKSPACE}/peers", {"id": PEER}, timeout=10)
    except Exception: pass

def session_id():
    return "screen-" + datetime.date.today().isoformat()

def file_to_honcho(text, app, title, reason):
    sid = session_id()
    try: _post(f"{HONCHO}/v3/workspaces/{WORKSPACE}/sessions", {"id": sid}, timeout=10)
    except Exception: pass
    stamp = datetime.datetime.now().strftime("%H:%M:%S")
    app_tag = f" · {app}" if app else ""
    content = f"[screen {stamp}{app_tag}] {text}"
    _post(f"{HONCHO}/v3/workspaces/{WORKSPACE}/sessions/{sid}/messages",
          {"messages": [{"peer_id": PEER, "content": content,
                         "metadata": {"kind": "screen_observation", "app": app,
                                      "title": title, "reason": reason}}]}, timeout=30)


# ── gemma vision ──────────────────────────────────────────────────────────────
def encode(path):
    """Path -> (base64, mime). Downscale to ~1280px wide JPEG before sending: a
    full 3440x1440 frame floods gemma's vision encoder with tokens (~64s/describe);
    1280px keeps the screen readable but drops that to ~2-3s. Falls back to the
    raw PNG if magick fails."""
    mime = "image/jpeg"
    try:
        raw = subprocess.run(["magick", path, "-resize", "1280x>", "-quality", "82", "jpg:-"],
                             capture_output=True, timeout=15).stdout
        if not raw:
            with open(path, "rb") as f: raw = f.read()
            mime = "image/png"
        return base64.b64encode(raw).decode(), mime
    except Exception:
        try:
            with open(path, "rb") as f:
                return base64.b64encode(f.read()).decode(), "image/png"
        except OSError:
            return None, None


def describe(path, title):
    b64, mime = encode(path)
    if b64 is None:
        return None
    hint = f' The focused window is titled "{title}".' if title else ""
    prompt = ("Describe what the user is doing on this screen in ONE concise, factual "
              "sentence for a personal activity log — name the app/site and the task." + hint +
              " No preamble.")
    payload = {
        "model": GEMMA_MODEL, "max_tokens": 90, "temperature": 0.2,
        # gemma-4 hides output in reasoning_content until it finishes thinking; disable it.
        "chat_template_kwargs": {"enable_thinking": False},
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": prompt},
            {"type": "image_url", "image_url": {"url": f"data:{mime};base64," + b64}}]}],
    }
    try:
        d = _post(GEMMA_URL, payload)
        return (d["choices"][0]["message"].get("content") or "").strip() or None
    except Exception as e:
        sys.stderr.write(f"[hermes-vision] describe failed: {e}\n")


# ── batch mode ────────────────────────────────────────────────────────────────
# Keyframes for the current window: [{"b64","mime","app","title","stamp","hash"}]
_batch = []
_batch_start = None


def describe_batch(frames):
    """One multi-image gemma call over the whole window. Returns text or None."""
    lines = "\n".join(f"{i+1}. {f['stamp']} — {f['app'] or '?'}"
                      + (f" — {f['title']}" if f["title"] else "")
                      for i, f in enumerate(frames))
    prompt = (f"These {len(frames)} screenshots were captured in chronological order "
              f"over the last {BATCH_WINDOW // 60} minutes. For reference:\n{lines}\n\n"
              "Summarise what the user was doing across the whole period, in 2-4 concise "
              "factual sentences for a personal activity log. Name the apps/sites and the "
              "tasks, and note any shift in what they were working on. No preamble.")
    content = [{"type": "text", "text": prompt}]
    for f in frames:
        content.append({"type": "image_url",
                        "image_url": {"url": f"data:{f['mime']};base64," + f["b64"]}})
    payload = {
        "model": GEMMA_MODEL, "max_tokens": 260, "temperature": 0.2,
        "chat_template_kwargs": {"enable_thinking": False},
        "messages": [{"role": "user", "content": content}],
    }
    # The window's images are already gone from disk; a transient server hiccup
    # must not silently drop 15 minutes of context. One retry, then fall back to
    # a text-only line so the window is recorded even if gemma never answers.
    for attempt in (1, 2):
        try:
            d = _post(GEMMA_URL, payload, timeout=max(TIMEOUT, 30 * len(frames)))
            text = (d["choices"][0]["message"].get("content") or "").strip()
            if text:
                return text
        except Exception as e:
            sys.stderr.write(f"[hermes-vision] batch describe attempt {attempt} failed: {e}\n")
            if attempt == 1:
                time.sleep(5)
    return None


def _redundancy(frames):
    """Index of the frame closest to its nearest neighbour — the least informative
    one to keep. Used to cap the buffer at BATCH_MAX without dropping the newest
    frame, which is usually the one that changed."""
    worst_i, worst_d = 0, 1 << 30
    for i, f in enumerate(frames):
        if f["hash"] is None:
            return i                       # unhashable: drop it first
        d = min((hamming(f["hash"], g["hash"])
                 for j, g in enumerate(frames) if j != i and g["hash"] is not None),
                default=1 << 30)
        if d < worst_d:
            worst_i, worst_d = i, d
    return worst_i


def buffer_frame(path, app, title, ph):
    """Encode into RAM, delete the file, keep at most BATCH_MAX distinct frames."""
    global _batch_start
    b64, mime = encode(path)
    try: os.remove(path)
    except OSError: pass
    if b64 is None:
        return
    if _batch_start is None:
        _batch_start = time.time()
    _batch.append({"b64": b64, "mime": mime, "app": app, "title": title,
                   "hash": ph, "stamp": datetime.datetime.now().strftime("%H:%M")})
    while len(_batch) > BATCH_MAX:
        _batch.pop(_redundancy(_batch))


def flush_batch():
    """Summarise the buffered window into a single honcho entry. Always clears."""
    global _batch_start
    frames, _batch[:] = list(_batch), []
    _batch_start = None
    if not frames:
        return
    text = describe_batch(frames)
    if not text:
        # No summary, but do not lose the window: record where the user was.
        seen = []
        for f in frames:
            tag = f["app"] or "?"
            if not seen or seen[-1] != tag:
                seen.append(tag)
        text = ("gemma unavailable; apps in this window, in order: " + " → ".join(seen))
    apps = [f["app"] for f in frames if f["app"]]
    app = max(set(apps), key=apps.count) if apps else ""
    try:
        file_to_honcho(text, app, frames[-1]["title"], "batch")
    except Exception as e:
        sys.stderr.write(f"[hermes-vision] honcho post failed: {e}\n")
        return None


# ── perceptual dHash via imagemagick (9x8 gray → 64-bit) ──────────────────────
def phash(path):
    try:
        raw = subprocess.run(["magick", path, "-resize", "9x8!", "-colorspace", "Gray",
                              "-depth", "8", "gray:-"], capture_output=True, timeout=10).stdout
    except Exception:
        return None
    if len(raw) < 72:
        return None
    bits = 0
    for r in range(8):
        for c in range(8):
            i = r * 9 + c
            bits = (bits << 1) | (1 if raw[i] > raw[i + 1] else 0)
    return bits

def hamming(a, b):
    return bin(a ^ b).count("1") if (a is not None and b is not None) else 999


# ── gates ─────────────────────────────────────────────────────────────────────
def _flag(path):
    try:
        with open(path) as f: return f.read().strip() == "1"
    except OSError: return False

def gaming(): return _flag(GAMING_FLAG)
def idle():   return _flag(IDLE_FLAG)

_ign_cache = {"mtime": 0, "globs": []}
def ignore_globs():
    try: m = os.path.getmtime(IGNORE_FILE)
    except OSError: return []
    if m != _ign_cache["mtime"]:
        try:
            lines = [l.strip().lower() for l in open(IGNORE_FILE)]
            _ign_cache["globs"] = [l for l in lines if l and not l.startswith("#")]
            _ign_cache["mtime"] = m
        except OSError:
            pass
    return _ign_cache["globs"]

def active_window():
    """Return (app, title, fullscreen, ignored)."""
    try:
        w = json.loads(subprocess.run(["hyprctl", "activewindow", "-j"],
                                      capture_output=True, timeout=5).stdout or "{}")
    except Exception:
        return ("", "", False, False)
    cls = w.get("class", "") or w.get("initialClass", "")
    title = w.get("title", "") or w.get("initialTitle", "")
    fs = bool(w.get("fullscreen"))
    fields = [str(x).lower() for x in (w.get("class"), w.get("initialClass"),
                                       w.get("title"), w.get("initialTitle")) if x]
    ign = any(fnmatch.fnmatch(f, g) for g in ignore_globs() for f in fields)
    return (cls, title, fs, ign)


# ── capture / spool ───────────────────────────────────────────────────────────
def grab(path):
    try:
        subprocess.run(["grim", path], check=True, timeout=15,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return os.path.exists(path)
    except Exception as e:
        sys.stderr.write(f"[hermes-vision] grim failed: {e}\n")
        return False

import re as _re
_last_desc = {"app": "", "text": ""}

def _words(s):
    return set(_re.sub(r"[^a-z0-9 ]", " ", s.lower()).split())

def _too_similar(a, b, thr=0.80):
    """Word-set Jaccard ≥ thr → 'basically the same observation'."""
    A, B = _words(a), _words(b)
    if not A or not B:
        return False
    return len(A & B) / len(A | B) >= thr

def ingest(path, app, title, reason):
    text = describe(path, title)
    if text:
        # Semantic dedup: minor visual churn (scroll/cursor) can beat the pixel
        # hash yet yield an identical description — don't spam honcho with it.
        # On-demand always posts (Hermes explicitly asked to look).
        if reason != "on_demand" and app == _last_desc["app"] and _too_similar(text, _last_desc["text"]):
            pass
        else:
            try:
                file_to_honcho(text, app, title, reason)
                _last_desc["app"], _last_desc["text"] = app, text
            except Exception as e:
                sys.stderr.write(f"[hermes-vision] honcho post failed: {e}\n")
    try: os.remove(path)
    except OSError: pass


# ── hyprland socket2 (non-blocking, auto-reconnect) ───────────────────────────
def open_socket2():
    his = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    cands = []
    if his:
        cands.append(os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/run/user/1000"),
                                  "hypr", his, ".socket2.sock"))
    cands += sorted(glob.glob(os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/run/user/1000"),
                                           "hypr", "*", ".socket2.sock")), key=os.path.getmtime, reverse=True)
    for p in cands:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(p); s.setblocking(False)
            return s
        except OSError:
            continue
    return None

EVENTS = ("activewindow>>", "activewindowv2>>", "workspace>>", "workspacev2>>", "fullscreen>>")


def main():
    ensure_honcho()
    try: subprocess.run(["bash", os.path.join(BIN, "vision-ignore-refresh.sh")], timeout=30,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception: pass
    mode = (f"batch every {BATCH_WINDOW}s, ≤{BATCH_MAX} keyframes/call"
            if BATCH_WINDOW > 0 else "one gemma call per frame")
    sys.stderr.write(f"[hermes-vision] up: event-driven + {HEARTBEAT}s heartbeat; "
                     f"gates=idle/gaming/fullscreen/ignore; dedup dHash<{PHASH_MINDIST}; "
                     f"{mode}\n")

    sock = open_socket2()
    buf = b""
    last_cap = 0.0
    last_hash = None
    focus_deadline = None
    last_refresh = time.time()

    while True:
        now = time.time()
        # 1) socket2 events → arm a debounced focus capture
        if sock is None:
            sock = open_socket2()
        if sock is not None:
            try:
                r, _, _ = select.select([sock], [], [], TICK)
            except Exception:
                r = []
            if r:
                try:
                    chunk = sock.recv(65536)
                    if chunk == b"":
                        sock.close(); sock = None
                    else:
                        buf += chunk
                        while b"\n" in buf:
                            line, buf = buf.split(b"\n", 1)
                            if any(line.startswith(e.encode()) for e in EVENTS):
                                focus_deadline = now + DEBOUNCE
                except OSError:
                    try: sock.close()
                    except OSError: pass
                    sock = None
        else:
            time.sleep(TICK)

        now = time.time()
        # 2) on-demand shots Hermes dropped — ingest + delete, always describe
        for p in sorted(glob.glob(os.path.join(SPOOL, "*.png"))):
            if os.path.basename(p).startswith("."):
                continue
            if gaming() or idle():
                try: os.remove(p)
                except OSError: pass
                continue
            app, title, _, _ = active_window()
            ingest(p, app, title, "on_demand")
            last_cap = now

        # 3) decide a timed/focus capture
        reason = None
        if focus_deadline is not None and now >= focus_deadline:
            reason = "focus"; focus_deadline = None
        elif now - last_cap >= HEARTBEAT:
            reason = "heartbeat"

        if reason:
            if gaming() or idle():
                last_cap = now
            else:
                app, title, fs, ign = active_window()
                if fs or ign:
                    last_cap = now                       # gated — don't hammer
                else:
                    tmp = os.path.join(SPOOL, ".tick.png")
                    if grab(tmp):
                        ph = phash(tmp)
                        # heartbeat on an unchanged screen → skip the gemma call
                        if reason == "heartbeat" and last_hash is not None and hamming(ph, last_hash) < PHASH_MINDIST:
                            try: os.remove(tmp)
                            except OSError: pass
                        elif BATCH_WINDOW > 0:
                            # Buffer instead of describing: one gemma call per
                            # window rather than one per frame. Capture, gates
                            # and dedup are unchanged and stay cheap.
                            buffer_frame(tmp, app, title, ph)
                            last_hash = ph
                        else:
                            ingest(tmp, app, title, reason)
                            last_hash = ph
                    last_cap = now

        # 3b) window elapsed → one multi-image summary for everything buffered
        if BATCH_WINDOW > 0 and _batch_start is not None and now - _batch_start >= BATCH_WINDOW:
            flush_batch()

        # 4) refresh the games/ignore list hourly (installs/removals)
        if now - last_refresh > 3600:
            last_refresh = now
            try: subprocess.run(["bash", os.path.join(BIN, "vision-ignore-refresh.sh")], timeout=30,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception: pass


def _flush_and_exit(signum, _frame):
    # systemctl restart sends SIGTERM. Without this the buffered window — which
    # exists only in RAM — dies with the process, losing up to BATCH_WINDOW
    # seconds of context on every restart or logout.
    sys.stderr.write(f"[hermes-vision] signal {signum}: flushing {len(_batch)} buffered frame(s)\n")
    try: flush_batch()
    except Exception as e:
        sys.stderr.write(f"[hermes-vision] flush on exit failed: {e}\n")
    sys.exit(0)


if __name__ == "__main__":
    import signal
    signal.signal(signal.SIGTERM, _flush_and_exit)
    signal.signal(signal.SIGINT, _flush_and_exit)
    try: main()
    except KeyboardInterrupt: pass
