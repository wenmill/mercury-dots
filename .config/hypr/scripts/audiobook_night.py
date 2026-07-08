#!/usr/bin/env python3
"""Unattended nightly audiobook generation from the Kavita library.

For every ebook in ~/Books that has no matching .m4b in ~/Books/Audiobooks, drive
Alexandria's pipeline (upload -> LLM script -> single narrator voice -> Qwen3-TTS
-> M4B) and save the audiobook back into the Kavita volume. Runs ONLY when idle
(night window + low load + GPU quiet) and re-checks the gate between books, so it
never fights a game or your daytime work.

Pipeline/task names verified against Alexandria's API; the FULL flow is not yet
end-to-end tested (needs the ~3.5GB Qwen3-TTS model downloaded on first TTS call
and at least one ebook present) — validate one book supervised before trusting
the timer:  python3 audiobook_night.py --now --force

Tunables (env): AUDIOBOOK_VOICE (built-in voice, default Ryan), AUDIOBOOK_NIGHT_START/END
(hours), AUDIOBOOK_MAX_LOAD (1-min loadavg), AUDIOBOOK_MAX_GPU (% busy).
"""
import glob, io, json, mimetypes, os, sys, time, urllib.request

ALEX = os.environ.get("ALEXANDRIA_URL", "http://127.0.0.1:4200").rstrip("/")
BOOKS = os.path.expanduser("~/Books")
OUT = os.path.expanduser("~/Books/Audiobooks")
VOICE = os.environ.get("AUDIOBOOK_VOICE", "Ryan")
NIGHT_START = int(os.environ.get("AUDIOBOOK_NIGHT_START", "1"))
NIGHT_END = int(os.environ.get("AUDIOBOOK_NIGHT_END", "8"))
MAX_LOAD = float(os.environ.get("AUDIOBOOK_MAX_LOAD", "3.0"))
MAX_GPU = int(os.environ.get("AUDIOBOOK_MAX_GPU", "25"))
FORCE = "--force" in sys.argv          # skip the idle gate (for supervised testing)


def api(path, method="GET", data=None, raw=False, timeout=120):
    body = json.dumps(data).encode() if data is not None else None
    hdrs = {"Content-Type": "application/json"} if body else {}
    req = urllib.request.Request(ALEX + path, body, hdrs, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read() if raw else json.loads(r.read() or b"null")


def upload(path):
    """multipart/form-data POST /api/upload (stdlib, no requests dep)."""
    boundary = "----athenabook" + str(int(time.time()))
    fn = os.path.basename(path)
    ctype = mimetypes.guess_type(fn)[0] or "application/octet-stream"
    buf = io.BytesIO()
    buf.write(f"--{boundary}\r\n".encode())
    buf.write(f'Content-Disposition: form-data; name="file"; filename="{fn}"\r\n'.encode())
    buf.write(f"Content-Type: {ctype}\r\n\r\n".encode())
    with open(path, "rb") as f:
        buf.write(f.read())
    buf.write(f"\r\n--{boundary}--\r\n".encode())
    req = urllib.request.Request(ALEX + "/api/upload", buf.getvalue(),
                                 {"Content-Type": f"multipart/form-data; boundary={boundary}"}, method="POST")
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.loads(r.read())


def poll(task, timeout=48 * 3600, interval=5):
    t0 = time.time()
    while time.time() - t0 < timeout:
        st = api(f"/api/status/{task}")
        if not (st or {}).get("running", False):
            return st
        time.sleep(interval)
    raise TimeoutError(f"task {task} timed out")


def idle():
    if FORCE:
        return True, "forced"
    h = time.localtime().tm_hour
    in_window = (NIGHT_START <= h < NIGHT_END) if NIGHT_START < NIGHT_END else (h >= NIGHT_START or h < NIGHT_END)
    if not in_window:
        return False, f"outside night window {NIGHT_START}-{NIGHT_END}h"
    if os.getloadavg()[0] > MAX_LOAD:
        return False, f"load {os.getloadavg()[0]:.1f} > {MAX_LOAD}"
    for f in glob.glob("/sys/class/drm/card*/device/gpu_busy_percent"):
        try:
            if int(open(f).read().strip()) > MAX_GPU:
                return False, "GPU busy"
        except Exception:
            pass
    return True, "idle"


def pending():
    done = {os.path.splitext(os.path.basename(p))[0] for p in glob.glob(OUT + "/*.m4b")}
    books = []
    for ext in ("*.epub", "*.txt"):
        for p in glob.glob(os.path.join(BOOKS, "**", ext), recursive=True):
            if os.path.realpath(OUT) in os.path.realpath(p):
                continue
            name = os.path.splitext(os.path.basename(p))[0]
            if name not in done:
                books.append((name, p))
    return sorted(set(books))


def generate(name, path):
    print(f"[{name}] upload", flush=True)
    upload(path)
    print(f"[{name}] script (LLM annotate)…", flush=True)
    api("/api/generate_script", "POST", {})
    poll("script")
    chunks = api("/api/chunks") or []
    chunks = chunks.get("chunks", chunks) if isinstance(chunks, dict) else chunks
    speakers = sorted({(c.get("speaker") or "Narrator") for c in chunks}) or ["Narrator"]
    cfg = {sp: {"type": "custom", "voice": VOICE, "seed": "-1",
                "character_style": "", "description": ""} for sp in speakers}
    api("/api/save_voice_config", "POST", cfg)
    print(f"[{name}] TTS {len(chunks)} chunks, voice={VOICE}…", flush=True)
    api("/api/generate_batch_fast", "POST", {"indices": list(range(len(chunks)))})
    poll("audio")
    print(f"[{name}] merge M4B…", flush=True)
    api("/api/merge_m4b", "POST", {"title": name, "narrator": VOICE})
    poll("m4b_export", timeout=2 * 3600)
    m4b = api("/api/audiobook_m4b", raw=True, timeout=600)
    os.makedirs(OUT, exist_ok=True)
    dest = os.path.join(OUT, name + ".m4b")
    with open(dest, "wb") as f:
        f.write(m4b)
    print(f"[{name}] done -> {dest} ({len(m4b)//1_000_000} MB)", flush=True)


def main():
    os.makedirs(OUT, exist_ok=True)
    todo = pending()
    if not todo:
        print("no pending books.")
        return
    print(f"{len(todo)} book(s) pending.")
    for name, path in (todo[:1] if "--now" in sys.argv else todo):
        ok, why = idle()
        if not ok:
            print("stopping (not idle):", why)
            break
        try:
            generate(name, path)
        except Exception as e:
            print(f"[{name}] FAILED: {e}")


if __name__ == "__main__":
    main()
