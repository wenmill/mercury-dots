#!/usr/bin/env python3
"""
hermes-vision-consolidate — roll raw screen observations up into a narrative.

The per-shot observations are the episodic layer; recall ("what was I doing this
afternoon?") comes from consolidation. This reads the recent screen_observation
rows from honcho, asks gemma (text) to compress them into a short factual
summary, and writes it back as a higher-level memory:

    hourly  (default):  last 60 min  -> "[hour 14:00–15:00] <summary>"
    daily   (arg "day"): today       -> "[day 2026-07-06] <summary>"

Written to session screen-summary-<date>, peer "screen", so honcho + Hermes can
retrieve the digest instead of trawling hundreds of raw rows.
"""
import json, os, sys, urllib.request, datetime

HONCHO    = os.environ.get("HONCHO_URL", "http://127.0.0.1:8000").rstrip("/")
WORKSPACE = os.environ.get("HONCHO_WORKSPACE", "hermes")
GEMMA_URL = os.environ.get("HERMES_VISION_LLM", "http://127.0.0.1:11434/v1/chat/completions")
GEMMA_MODEL = os.environ.get("HERMES_VISION_MODEL", "gemma")
PEER      = "screen"
MODE      = (sys.argv[1] if len(sys.argv) > 1 else "hour").lower()


def _post(url, payload, timeout=60):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def parse_ts(s):
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone()
    except Exception:
        return None


def fetch_today():
    sid = "screen-" + datetime.date.today().isoformat()
    try:
        d = _post(f"{HONCHO}/v3/workspaces/{WORKSPACE}/sessions/{sid}/messages/list", {})
    except Exception as e:
        sys.stderr.write(f"[consolidate] fetch failed: {e}\n"); return []
    return d.get("items", [])


def summarize(observations, span_label):
    joined = "\n".join(observations)
    prompt = (f"Below are timestamped one-line notes of what a user did on their computer "
              f"during {span_label}. Write a concise 1–3 sentence summary of what they worked "
              f"on and accomplished, grouping related activity. Be factual; no preamble.\n\n{joined}")
    payload = {"model": GEMMA_MODEL, "max_tokens": 220, "temperature": 0.3,
               "chat_template_kwargs": {"enable_thinking": False},
               "messages": [{"role": "user", "content": prompt}]}
    try:
        d = _post(GEMMA_URL, payload, timeout=120)
        return (d["choices"][0]["message"].get("content") or "").strip() or None
    except Exception as e:
        sys.stderr.write(f"[consolidate] gemma failed: {e}\n"); return None


def write_summary(text, label):
    sid = "screen-summary-" + datetime.date.today().isoformat()
    try: _post(f"{HONCHO}/v3/workspaces/{WORKSPACE}/sessions", {"id": sid})
    except Exception: pass
    _post(f"{HONCHO}/v3/workspaces/{WORKSPACE}/sessions/{sid}/messages",
          {"messages": [{"peer_id": PEER, "content": f"[{label}] {text}",
                         "metadata": {"kind": "screen_%s" % MODE}}]})


def main():
    now = datetime.datetime.now().astimezone()
    if MODE == "day":
        start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        label = "day " + now.date().isoformat()
        span = "the whole day"
    else:
        start = (now - datetime.timedelta(hours=1)).replace(minute=0, second=0, microsecond=0)
        end = start + datetime.timedelta(hours=1)
        label = f"hour {start.strftime('%H:%M')}–{end.strftime('%H:%M')}"
        span = "one hour"

    obs = []
    for m in fetch_today():
        if (m.get("metadata") or {}).get("kind") != "screen_observation":
            continue
        ts = parse_ts(m.get("created_at", ""))
        if ts is None or ts < start:
            continue
        if MODE != "day":
            if ts >= start + datetime.timedelta(hours=1):
                continue
        obs.append(m.get("content", ""))

    if len(obs) < 2:
        sys.stderr.write(f"[consolidate] {label}: only {len(obs)} observations, skipping\n")
        return
    s = summarize(obs, span)
    if s:
        write_summary(s, label)
        sys.stderr.write(f"[consolidate] wrote {label} summary ({len(obs)} obs)\n")


if __name__ == "__main__":
    main()
