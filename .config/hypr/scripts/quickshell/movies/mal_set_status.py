#!/usr/bin/env python3
"""Set a MyAnimeList list status for an anime, from the movies widget.

The mal-better-stremio addon only serves read-only catalogs (it marks things
watched via a playback hack), so moving an entry between lists is done by
calling the MAL API v2 directly with the user's OAuth token.

Usage:  mal_set_status.py <mal_anime_id> <status> [num_watched_episodes]
  status ∈ watching | completed | on_hold | dropped | plan_to_watch

Reads `mal_access_token` from ~/.config/hypr/config.json (a token with the
`write` scope, e.g. the one mal-better-stremio uses).

Prints JSON: {"ok": true, "status": "..."} or {"ok": false, "error": "..."}.
Exits 0 either way so the QML side can show a notification without crashing.
"""
import json
import os
import sys
import urllib.request
import urllib.parse
import urllib.error

CONFIG = os.path.expanduser("~/.config/hypr/config.json")
API = "https://api.myanimelist.net/v2"
VALID = {"watching", "completed", "on_hold", "dropped", "plan_to_watch"}


def token():
    # Keyring first (secrets.sh get), then the plaintext file as fallback —
    # mal_access_token is migrated out of config.json.
    import subprocess
    helper = os.path.expanduser("~/.config/hypr/scripts/secrets.sh")
    try:
        t = subprocess.run(["bash", helper, "get", "mal_access_token"],
                           capture_output=True, text=True, timeout=10).stdout.strip()
        if t:
            return t
    except Exception:
        pass
    try:
        with open(CONFIG) as f:
            return (json.load(f).get("mal_access_token") or "").strip()
    except Exception:
        return ""


def main():
    if len(sys.argv) < 3:
        print(json.dumps({"ok": False, "error": "usage"}))
        return
    anime_id = str(sys.argv[1]).replace("mal_", "").strip()
    status = sys.argv[2].strip()
    episodes = sys.argv[3] if len(sys.argv) > 3 else None
    if status not in VALID or not anime_id.isdigit():
        print(json.dumps({"ok": False, "error": "bad-args"}))
        return
    tok = token()
    if not tok:
        print(json.dumps({"ok": False, "error": "no-token"}))
        return

    fields = {"status": status}
    if episodes and str(episodes).isdigit():
        fields["num_watched_episodes"] = str(episodes)
    data = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(
        API + "/anime/" + anime_id + "/my_list_status",
        data=data, method="PATCH",
        headers={
            "Authorization": "Bearer " + tok,
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()
        print(json.dumps({"ok": True, "status": status}))
    except urllib.error.HTTPError as e:
        code = e.code
        err = "auth" if code in (401, 403) else "http-" + str(code)
        print(json.dumps({"ok": False, "error": err}))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
