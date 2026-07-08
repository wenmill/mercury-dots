#!/usr/bin/env python3
"""Pull the latest articles out of FreshRSS and write the Quickshell news cache.

FreshRSS already does the hard part (fetching feeds, dedup, storage, scheduling),
so this just talks to its Google Reader-compatible API, normalises each item to a
flat schema, and atomically writes ~/.cache/qs_news.json. The QML News module
polls that file — it never does HTTP or feed parsing itself (same pattern as
weather.sh -> weatherData).

Config (either env vars or ~/.config/hypr/news.env, see news.env.example):
    FRESHRSS_URL           e.g. http://127.0.0.1:8110
    FRESHRSS_USER          your FreshRSS username
    FRESHRSS_API_PASSWORD  the API password (Settings ▸ Profile), NOT the login one
    NEWS_LIMIT             optional, max items to keep (default 40)

Output schema (stable contract with the QML — keep AI + RSS items in one array):
    {"generated": <epoch>, "items": [
        {"id","title","summary","source","url","ts","image","tags","ai":false}
    ]}

Exit non-zero on failure; the last-good cache is left untouched so the UI keeps
showing something (only writes an error stub if no cache exists yet).
"""

import html
import json
import os
import re
import sys
import time
import hashlib
import urllib.parse
import urllib.request

HOME = os.path.expanduser("~")
ENV_FILE = os.path.join(HOME, ".config/hypr/news.env")
CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.join(HOME, ".cache")),
                     "qs_news.json")
TIMEOUT = 20

_TAG_RE = re.compile(r"<[^>]+>")
_IMG_RE = re.compile(r'<img[^>]+src=["\']([^"\']+)["\']', re.I)
_WS_RE = re.compile(r"\s+")


def load_env():
    """Merge ~/.config/hypr/news.env into the environment (env vars win)."""
    if not os.path.exists(ENV_FILE):
        return
    with open(ENV_FILE, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            os.environ.setdefault(key.strip(), val.strip().strip('"').strip("'"))


def cfg(key, default=None, required=False):
    val = os.environ.get(key, default)
    if required and not val:
        sys.exit(f"news_fetch: missing required config '{key}' "
                 f"(set it in {ENV_FILE} or the environment)")
    return val


def strip_html(raw, limit=240):
    text = html.unescape(_TAG_RE.sub(" ", raw or ""))
    text = _WS_RE.sub(" ", text).strip()
    return (text[: limit - 1].rstrip() + "…") if len(text) > limit else text


def greader_login(base, user, password):
    """ClientLogin -> auth token used as `Authorization: GoogleLogin auth=...`."""
    url = f"{base}/api/greader.php/accounts/ClientLogin"
    data = urllib.parse.urlencode({"Email": user, "Passwd": password}).encode()
    with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=TIMEOUT) as r:
        body = r.read().decode("utf-8", "replace")
    for line in body.splitlines():
        if line.startswith("Auth="):
            return line[5:].strip()
    raise RuntimeError("FreshRSS ClientLogin returned no Auth token "
                       "(check FRESHRSS_USER / FRESHRSS_API_PASSWORD and that "
                       "'Allow API access' is enabled)")


def fetch_items(base, token, limit):
    stream = "user/-/state/com.google/reading-list"
    qs = urllib.parse.urlencode({"output": "json", "n": limit})
    url = f"{base}/api/greader.php/reader/api/0/stream/contents/{stream}?{qs}"
    req = urllib.request.Request(url, headers={"Authorization": f"GoogleLogin auth={token}"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.loads(r.read().decode("utf-8", "replace")).get("items", [])


def pick_url(item):
    for key in ("canonical", "alternate"):
        for link in item.get(key) or []:
            if link.get("href"):
                return link["href"]
    return ""


def pick_image(item, summary_html):
    for enc in item.get("enclosure") or []:
        if str(enc.get("type", "")).startswith("image") and enc.get("href"):
            return enc["href"]
    m = _IMG_RE.search(summary_html or "")
    return m.group(1) if m else ""


def pick_tags(item):
    out = []
    for cat in item.get("categories") or []:
        # Drop GReader system labels (user/-/state/..., user/-/label/ prefixes).
        if isinstance(cat, str) and "/state/" not in cat and "/label/" not in cat:
            out.append(cat)
        elif isinstance(cat, str) and "/label/" in cat:
            out.append(cat.rsplit("/", 1)[-1])
    return out[:4]


def normalize(item):
    summary_html = (item.get("summary") or {}).get("content", "") \
        or (item.get("content") or {}).get("content", "")
    url = pick_url(item)
    ts = int(item.get("published") or item.get("updated")
             or (int(item.get("crawlTimeMsec", "0")) // 1000) or 0)
    return {
        "id": hashlib.sha1((url or item.get("id", "")).encode()).hexdigest()[:16],
        "title": html.unescape(item.get("title", "")).strip() or "(untitled)",
        "summary": strip_html(summary_html, 240),
        "body": strip_html(summary_html, 2000),
        "source": (item.get("origin") or {}).get("title", ""),
        "url": url,
        "ts": ts,
        "image": pick_image(item, summary_html),
        "tags": pick_tags(item),
        "ai": False,
    }


def atomic_write(payload):
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    tmp = CACHE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False)
    os.replace(tmp, CACHE)


def main():
    load_env()
    base = cfg("FRESHRSS_URL", "http://127.0.0.1:8110").rstrip("/")
    user = cfg("FRESHRSS_USER", required=True)
    password = cfg("FRESHRSS_API_PASSWORD", required=True)
    limit = int(cfg("NEWS_LIMIT", "40"))

    try:
        token = greader_login(base, user, password)
        raw = fetch_items(base, token, limit)
    except Exception as exc:  # noqa: BLE001 — any failure: keep last-good cache
        sys.stderr.write(f"news_fetch: {exc}\n")
        if not os.path.exists(CACHE):
            atomic_write({"generated": int(time.time()), "error": str(exc), "items": []})
        return 1

    items = [normalize(i) for i in raw]
    items.sort(key=lambda x: x["ts"], reverse=True)
    atomic_write({"generated": int(time.time()), "items": items})
    sys.stderr.write(f"news_fetch: wrote {len(items)} items to {CACHE}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
