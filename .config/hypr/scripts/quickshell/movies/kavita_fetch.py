#!/usr/bin/env python3
"""Kavita browse backend for the Quickshell movies widget.

Surfaces ONLY the manga + novels libraries (Kavita LibraryType 0=Manga,
2=Book, 4=LightNovel) — comics/images/etc. are intentionally hidden.

Reads `kavita_url` + `kavita_api_key` from ~/.config/hypr/config.json.

Usage:
  kavita_fetch.py series [search]   -> JSON array of series (default browse)
  kavita_fetch.py libraries         -> JSON array of the surfaced libraries

Each series row:
  { "id", "name", "libraryId", "libraryName", "type" ("manga"|"novel"),
    "pages", "format", "cover" (ready-to-use image URL with apiKey) }

On any failure prints "[]" (or an object with "error") and exits 0 so the
QML side degrades to a clean empty state.
"""
import json
import os
import sys
import urllib.request
import urllib.parse
import urllib.error

CONFIG = os.path.expanduser("~/.config/hypr/config.json")
PLUGIN = "Quickshell"

# Kavita LibraryType -> our front-end bucket. Only these are surfaced.
#   0 Manga, 1 Comic, 2 Book, 3 Images, 4 LightNovel, 5 ComicVine
ALLOWED = {0: "manga", 2: "novel", 4: "novel"}


def cfg():
    # secrets.sh getjson overlays keyring-held secrets (kavita_api_key lives
    # there, not in the plaintext file); fall back to the raw file if the
    # helper is unavailable.
    import subprocess
    d = {}
    helper = os.path.expanduser("~/.config/hypr/scripts/secrets.sh")
    try:
        out = subprocess.run(["bash", helper, "getjson"], capture_output=True,
                             text=True, timeout=10).stdout
        d = json.loads(out or "{}")
    except Exception:
        try:
            with open(CONFIG) as f:
                d = json.load(f)
        except Exception:
            d = {}
    url = (d.get("kavita_url") or "http://localhost:5000").rstrip("/")
    key = (d.get("kavita_api_key") or "").strip()
    return url, key


def req(url, method="GET", token=None, body=None, timeout=10):
    headers = {"Accept": "application/json"}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    r = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8", "replace")
    return json.loads(raw) if raw.strip() else None


def authenticate(url, key):
    q = urllib.parse.urlencode({"apiKey": key, "pluginName": PLUGIN})
    res = req(url + "/api/Plugin/authenticate?" + q, method="POST")
    # UserDto carries the JWT in "token".
    return (res or {}).get("token")


def libraries(url, token):
    # Newer Kavita: /api/Library/libraries ; older: /api/Library
    for path in ("/api/Library/libraries", "/api/Library"):
        try:
            res = req(url + path, token=token)
            if isinstance(res, list):
                return res
        except urllib.error.HTTPError:
            continue
    return []


def surfaced_libs(url, token):
    out = {}
    for lib in libraries(url, token):
        t = lib.get("type")
        if t in ALLOWED:
            out[lib.get("id")] = {"name": lib.get("name", ""), "bucket": ALLOWED[t]}
    return out


def all_series(url, token, search):
    # FilterV2: empty statements = everything; sort by name ascending.
    flt = {
        "statements": [],
        "combination": 1,
        "limitTo": 0,
        "sortOptions": {"sortField": 1, "isAscending": True},
    }
    if search:
        # Field 1 = SeriesName, comparison 0 = Equal/Contains for strings.
        flt["statements"] = [
            {"comparison": 4, "field": 1, "value": search}  # 4 = Contains
        ]
    series = []
    page = 1
    while page <= 20:  # hard cap ~ 20*200 = 4000 series
        q = urllib.parse.urlencode({"PageNumber": page, "PageSize": 200})
        try:
            res = req(url + "/api/Series/all-v2?" + q, method="POST",
                      token=token, body=flt)
        except urllib.error.HTTPError:
            break
        if not isinstance(res, list) or not res:
            break
        series.extend(res)
        if len(res) < 200:
            break
        page += 1
    return series


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "series"
    search = sys.argv[2].strip() if len(sys.argv) > 2 else ""
    url, key = cfg()
    if not key:
        print(json.dumps({"error": "no-key"}))
        return
    try:
        token = authenticate(url, key)
    except Exception as e:
        print(json.dumps({"error": "auth", "detail": str(e)}))
        return
    if not token:
        print(json.dumps({"error": "auth"}))
        return

    libs = surfaced_libs(url, token)

    if mode == "libraries":
        out = [{"id": lid, "name": v["name"], "bucket": v["bucket"]}
               for lid, v in libs.items()]
        print(json.dumps(out))
        return

    rows = []
    for s in all_series(url, token, search):
        lid = s.get("libraryId")
        if lid not in libs:
            continue  # hide anything outside manga/novel libraries
        sid = s.get("id")
        cover = (url + "/api/Image/series-cover?seriesId=" + str(sid)
                 + "&apiKey=" + urllib.parse.quote(key))
        rows.append({
            "id": sid,
            "name": s.get("name", ""),
            "libraryId": lid,
            "libraryName": libs[lid]["name"],
            "type": libs[lid]["bucket"],
            "pages": s.get("pages", 0),
            "pagesRead": s.get("pagesRead", 0),
            "format": s.get("format", 0),
            "cover": cover,
        })
    print(json.dumps(rows))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(json.dumps({"error": "fatal", "detail": str(e)}))
