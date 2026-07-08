#!/usr/bin/env bash
#
# Enumerate INSTALLED Steam games from local files only (no login / web API), and
# resolve the best local cover art for each. Emits a JSON array on stdout:
#
#   [{"appid":"...","name":"...","art":"file:///... or https://...","hero":"file:///... or ""}]
#
# The game list is 100% local (appmanifest_*.acf across all library folders).
# Cover art prefers local Steam art cache; only if nothing local exists does it
# fall back to Steam's public CDN capsule URL so tiles aren't blank.
#
python3 - "$@" <<'PY'
import os, re, json, glob, sys

HOME = os.path.expanduser("~")
ROOTS = [
    os.path.join(HOME, ".local/share/Steam"),
    os.path.join(HOME, ".steam/steam"),
    os.path.join(HOME, ".var/app/com.valvesoftware.Steam/.local/share/Steam"),
]
STEAM = next((r for r in ROOTS if os.path.isdir(r)), None)
if not STEAM:
    print("[]"); sys.exit(0)

# Tools / runtimes / redistributables that are not games.
SKIP_IDS = {"228980", "1493710", "1070560", "1391110", "1628350", "4183110",
            "1887720", "2348590", "1161040"}
SKIP_RE = re.compile(r"proton|steam\s*linux\s*runtime|steamworks|redistributable|"
                     r"soundtrack|dedicated server|steamvr|benchmark|\bserver\b", re.I)

def kv(text, key):
    m = re.search(r'"%s"\s*"([^"]*)"' % re.escape(key), text, re.I)
    return m.group(1) if m else ""

def appinfo_names(steam_root):
    """Map appid(str) -> game name from Steam's LOCAL appcache/appinfo.vdf.
    Installed games get their name from the appmanifest .acf, but OWNED-but-not-
    installed games (surfaced from the library art cache below) have no .acf, so
    without this they showed blank tiles. appinfo.vdf holds every owned app's name
    locally (no login / web call). Handles the v29 string-table format; any other
    version or parse error just yields {} and names fall back gracefully."""
    import struct
    path = os.path.join(steam_root, "appcache", "appinfo.vdf")
    try:
        data = open(path, "rb").read()
    except OSError:
        return {}
    if len(data) < 16 or struct.unpack_from("<I", data, 0)[0] != 0x07564429:
        return {}   # only the v29 string-table format is parsed here
    try:
        str_off = struct.unpack_from("<q", data, 8)[0]
        cnt = struct.unpack_from("<I", data, str_off)[0]
        strings, p = [], str_off + 4
        for _ in range(cnt):
            e = data.index(b"\x00", p); strings.append(data[p:e].decode("utf-8", "replace")); p = e + 1
    except Exception:
        return {}
    def read_kv(p):
        d = {}
        while True:
            t = data[p]; p += 1
            if t == 0x08:
                return d, p
            ki = struct.unpack_from("<I", data, p)[0]; p += 4
            k = strings[ki] if ki < len(strings) else ""
            if t == 0x00:
                v, p = read_kv(p); d[k] = v
            elif t == 0x01:
                e = data.index(b"\x00", p); d[k] = data[p:e].decode("utf-8", "replace"); p = e + 1
            elif t == 0x02:
                d[k] = struct.unpack_from("<i", data, p)[0]; p += 4
            elif t == 0x07:
                d[k] = struct.unpack_from("<Q", data, p)[0]; p += 8
            elif t == 0x03:
                d[k] = struct.unpack_from("<f", data, p)[0]; p += 4
            else:
                raise ValueError("bad type")
    names, p = {}, 16
    while p + 8 <= len(data):
        appid = struct.unpack_from("<I", data, p)[0]
        if appid == 0:
            break
        size = struct.unpack_from("<I", data, p + 4)[0]
        try:                                    # +68 = past the 60-byte fixed entry header
            tree, _ = read_kv(p + 68)
            root = tree.get("appinfo", tree)
            nm = (root.get("common") or {}).get("name")
            if nm:
                names[str(appid)] = nm
        except Exception:
            pass
        p = p + 8 + size
    return names

# All library folders that hold steamapps.
libs = set()
for vdf in (os.path.join(STEAM, "steamapps/libraryfolders.vdf"),
            os.path.join(STEAM, "config/libraryfolders.vdf")):
    try:
        t = open(vdf, encoding="utf-8", errors="ignore").read()
        for p in re.findall(r'"path"\s*"([^"]+)"', t):
            libs.add(p.replace("\\\\", "/"))
    except OSError:
        pass
libs.add(STEAM)

cache = os.path.join(STEAM, "appcache/librarycache")
APPNAMES = appinfo_names(STEAM)   # appid -> name, for games with no local .acf

def local_art(appid):
    """Best local art file for appid, or '' if none. Returns a filesystem path.
    Steam caches tiny (32x32, <1KB) placeholder jpgs for art it hasn't fetched —
    reject those via a size floor so we fall back to the CDN capsule instead."""
    cands = [
        os.path.join(cache, appid, "library_600x900.jpg"),
        os.path.join(cache, "%s_library_600x900.jpg" % appid),
        os.path.join(cache, appid, "library_capsule.jpg"),
        os.path.join(cache, appid, "header.jpg"),
        os.path.join(cache, "%s_header.jpg" % appid),
        os.path.join(cache, appid, "library_hero.jpg"),
    ]
    for c in cands:
        if os.path.isfile(c) and os.path.getsize(c) > 3000:
            return c
    # any real-sized jpg in the per-app folder (hashed capsule), skipping placeholders
    d = os.path.join(cache, appid)
    if os.path.isdir(d):
        jpgs = [(os.path.getsize(os.path.join(d, f)), os.path.join(d, f))
                for f in os.listdir(d) if f.lower().endswith(".jpg")]
        jpgs = [j for j in jpgs if j[0] > 12000]
        if jpgs:
            return max(jpgs)[1]
    return ""

def local_hero(appid):
    for c in (os.path.join(cache, appid, "library_hero.jpg"),
              os.path.join(cache, "%s_library_hero.jpg" % appid)):
        if os.path.isfile(c) and os.path.getsize(c) > 0:
            return c
    return ""

def to_uri(p):
    return "file://" + p if p else ""

games, seen = [], set()
for lib in libs:
    for acf in glob.glob(os.path.join(lib, "steamapps", "appmanifest_*.acf")):
        try:
            t = open(acf, encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        appid = kv(t, "appid"); name = kv(t, "name") or APPNAMES.get(appid, "")
        if not appid or appid in seen:
            continue
        if appid in SKIP_IDS or (name and SKIP_RE.search(name)):
            continue
        flags = kv(t, "StateFlags")
        try:
            if flags and not (int(flags) & 4):   # 4 = fully installed
                continue
        except ValueError:
            pass
        seen.add(appid)
        art = to_uri(local_art(appid))
        if not art:
            art = "https://steamcdn-a.akamaihd.net/steam/apps/%s/library_600x900.jpg" % appid
        games.append({
            "appid": appid,
            "name": name or ("App " + appid),
            "art": art,
            "hero": to_uri(local_hero(appid)),
        })

# Also surface OWNED games that have a local portrait card (library_600x900) even if not
# currently installed — that's the Big-Picture library look, and gives every tile a real
# title card. The capsule art has the title baked in, so no separate name is needed;
# clicking installs/launches it through Steam all the same.
def owned_card(appid):
    for c in (os.path.join(cache, appid, "library_600x900.jpg"),
              os.path.join(cache, "%s_library_600x900.jpg" % appid),
              os.path.join(cache, appid, "library_capsule.jpg")):
        if os.path.isfile(c) and os.path.getsize(c) > 3000:
            return c
    return ""

if os.path.isdir(cache):
    for appid in os.listdir(cache):
        appid = appid.split("_")[0]
        if not appid.isdigit() or appid in seen or appid in SKIP_IDS:
            continue
        card = owned_card(appid)
        if not card:
            continue
        nm = APPNAMES.get(appid, "")
        if nm and SKIP_RE.search(nm):     # now that names resolve, drop demos/servers/benchmarks/tools
            continue
        seen.add(appid)
        games.append({"appid": appid, "name": nm, "art": to_uri(card), "hero": to_uri(local_hero(appid))})

# Named (installed) games first, alphabetical; then card-only owned games by appid.
games.sort(key=lambda g: (0 if g["name"] else 1, g["name"].lower(), int(g["appid"])))
print(json.dumps(games))
PY
