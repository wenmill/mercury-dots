#!/usr/bin/env python3
"""OpenAI /v1/audio/speech shim -> Alexandria (Qwen3-TTS), fully local.

Hermes' `openai` TTS provider (with tts.openai.base_url pointed here) POSTs
{model, voice, input, response_format} to /v1/audio/speech expecting mp3/opus
bytes. Alexandria is an audiobook studio whose one-shot text->wav call is
POST /api/voice_design/preview {description, sample_text}. We call that, fetch
the wav it serves, and transcode to the requested format with ffmpeg.

v1 caveat: voice_design uses a random seed, so the timbre varies a little per
call. A fixed reference-clone voice is a follow-up. Tune the voice via env
ATHENA_VOICE_DESC.

Env: SHIM_PORT (4230), ALEXANDRIA_URL (http://127.0.0.1:4200), ATHENA_VOICE_DESC.
"""
import json, os, subprocess, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ALEX = os.environ.get("ALEXANDRIA_URL", "http://127.0.0.1:4200").rstrip("/")
PORT = int(os.environ.get("SHIM_PORT", "4230"))
VOICE_DESC = os.environ.get(
    "ATHENA_VOICE_DESC",
    "A warm, calm, articulate female voice with a natural, friendly conversational "
    "tone; clear diction, neutral American accent, measured pace.",
)


def synth_wav(text: str) -> bytes:
    # Qwen3-TTS wants a language WORD (english/auto/…), not an ISO code like "en".
    body = json.dumps({"description": VOICE_DESC, "sample_text": text, "language": "english"}).encode()
    req = urllib.request.Request(ALEX + "/api/voice_design/preview", body,
                                 {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        audio_url = json.load(r)["audio_url"]
    with urllib.request.urlopen(ALEX + audio_url, timeout=120) as r:
        return r.read()


def transcode(wav: bytes, fmt: str) -> bytes:
    codec = {"mp3": ("mp3", "-f", "mp3"), "opus": ("opus", "-f", "opus"),
             "wav": ("wav", "-f", "wav"), "flac": ("flac", "-f", "flac"),
             "aac": ("aac", "-f", "adts"), "pcm": ("pcm", "-f", "s16le")}.get(fmt, ("mp3", "-f", "mp3"))
    p = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", "pipe:0",
                        codec[1], codec[2], "pipe:1"], input=wav, capture_output=True)
    return p.stdout or wav


CTYPE = {"mp3": "audio/mpeg", "opus": "audio/ogg", "wav": "audio/wav",
         "flac": "audio/flac", "aac": "audio/aac", "pcm": "audio/L16"}


class H(BaseHTTPRequestHandler):
    def _send(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            self._send(200, b'{"object":"list","data":[{"id":"alexandria-qwen3-tts","object":"model"}]}')
        else:
            self._send(200, b'{"status":"ok"}')

    def do_POST(self):
        if not self.path.endswith("/audio/speech"):
            self._send(404, b'{"error":"not found"}'); return
        try:
            n = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(n) or b"{}")
            text = (req.get("input") or "").strip()
            fmt = (req.get("response_format") or "mp3").lower()
            if not text:
                self._send(400, b'{"error":"empty input"}'); return
            audio = transcode(synth_wav(text), fmt)
            self._send(200, audio, CTYPE.get(fmt, "audio/mpeg"))
        except Exception as e:
            self._send(500, json.dumps({"error": str(e)}).encode())

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
