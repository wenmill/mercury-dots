# `backends/` — pluggable streaming sources

This is where you add your own video **sources**. The `movie` / `tv` / `anime`
providers are thin — they just dispatch to a backend here. Drop a new executable
in this folder and it's available; no QML, no provider changes.

```
video/backends/
├── lobster              # movies + TV via lobster-git
├── anicli               # anime via ani-cli
├── torrentio            # LAST-RESORT: movies/TV/anime via Torrentio + debrid
└── jellyfin.example     # WORKED TEMPLATE — cp to `jellyfin`, fill in, enable
```

## Selecting a backend

Per-kind, in `~/.config/hypr/config.json`:

```jsonc
"movie_backend": "lobster",     // unset → default chain below
"tv_backend":    "torrentio",
"anime_backend": "anicli"
```

Each kind has a **fallback chain**: the configured backend is tried first, then
the built-in defaults, so a dead source cascades to the next one:

| kind | default chain |
|---|---|
| movie | `lobster → torrentio` |
| tv | `lobster → torrentio` |
| anime | `anicli → torrentio` |

Setting `"movie_backend": "jellyfin"` makes the chain `jellyfin → lobster → torrentio`.

### torrentio — the safety net

Sits at the **end** of every chain: the scrapers (lobster, ani-cli)
serve everything normally, and torrentio only runs once they've all failed —
which is what happens when a scraper's site changes and it rots. It self-skips
in ~10ms unless configured, so an unconfigured install pays nothing for it.

It resolves the title to a catalog id — IMDb via Cinemeta for movies/TV, Kitsu
for anime (absolute episode numbering, `kitsu:<id>:<ep>`) — and asks the
Torrentio Stremio addon for sources; with a **debrid** account the cached
entries carry direct HTTPS urls that stream straight into the PiP. Anime
sub/dub is whatever the release carries, so the series page's Sub/Dub toggle
doesn't apply on this fallback path.

Configure with:

```jsonc
"torrentio_url":    "https://torrentio.strem.fun",
"torrentio_debrid": "realdebrid",   // or alldebrid | premiumize | torbox | offcloud
"torrentio_opts":   ""              // e.g. "sort=qualitysize|qualityfilter=cam,scr"
```

```sh
~/.config/hypr/scripts/secrets.sh set torrentio_debrid_key <your-debrid-api-key>
```

All of its traffic (catalog lookup, Torrentio, and the stream itself) rides the
gluetun proxy under the same fail-closed VPN guard as every other movie/tv/
anime backend — the debrid service always sees the VPN exit IP. Without a
debrid key Torrentio only yields raw infohashes, which can't be forced through
the HTTP proxy, so the backend refuses them rather than leak outside the
tunnel. Being last in the chain, that refusal simply means "no source found",
exactly as before it existed.

## The backend contract

A backend is **any executable** here. It's called as `backends/<name> <verb> …`:

| Verb | Args | Must do |
|---|---|---|
| `capabilities` | — | Print the space-separated **kinds** it serves, e.g. `movie tv`. |
| `play` | `<kind> <title> [season] [ep]` | Start playback in the PiP. **Exit non-zero on failure** (no match / source down) so the dispatcher falls through to the next backend. |
| `browse` | `<kind> [query]` | Optional: launch an interactive picker into the PiP. `exec` it (it's the first capable backend that runs). |

Helpers you get from `source "$VIDEO_DIR/lib/common.sh"`:

- `vid_load <url> [mpv-flags…]` — load a direct URL into the PiP (for API sources
  like Jellyfin that already have a stream URL — no shim needed).
- `vid_run_headless <cmd…>` — run a scraper CLI (its `mpv`/`fzf` are shimmed to the
  PiP + auto-pick). Fire-and-forget; ignores the CLI's exit code.
- `vid_run_checked '<fail-regex>' <cmd…>` — same, but **captures output and returns
  failure** when the regex matches (many scrapers exit 0 even on "no results").
- `vid_cfg <key>` — read a key from `config.json` (your server URL, token, …).
- `vlog` / `vnotify` — log / desktop-notify.

## Add a Jellyfin (or any) source in a few minutes

`jellyfin.example` is a complete, commented starting point — it talks to the
Jellyfin REST API and hands mpv a direct-play URL (no scraper needed):

```bash
cd movies/video/backends
cp jellyfin.example jellyfin && chmod +x jellyfin
# then in ~/.config/hypr/config.json:
#   "jellyfin_url": "http://server:8096",
#   "jellyfin_token": "<Dashboard → API Keys>",
#   "movie_backend": "jellyfin"
video play movie "Dune"      # streams from Jellyfin; falls back if it's not there
```

Minimal skeleton for a brand-new source:

```bash
#!/usr/bin/env bash
set -uo pipefail
: "${VIDEO_DIR:=$(cd "$(dirname "$0")/.." && pwd)}"
source "$VIDEO_DIR/lib/common.sh"
verb="${1:-}"; kind="${2:-}"; shift 2 2>/dev/null || true
case "$verb" in
  capabilities) echo "movie tv" ;;
  play)
    title="${1:?}"
    url="$(my_lookup "$title")" || { vlog "mysrc: no match"; exit 1; }  # exit≠0 → fall through
    vid_load "$url" ;;
  browse) : ;;   # optional
  *) exit 2 ;;
esac
```
