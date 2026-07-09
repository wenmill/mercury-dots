# Movies widget — backend

Everything behind `movies/MovieWidget.qml` (the ~5.3k-line UI): where its data
comes from, how video plays, and how to extend it. The widget is pure QML; all
backend work is either **HTTP from QML** (metadata catalogs) or **CLI calls**
(video, comments, AI, integrations).

```
                    ┌──────────────────────── MovieWidget.qml ───────────────────────┐
   DATA PLANE       │  YouTube · Anime · TV · Movies · Music tabs + embedded player   │   PLAYBACK PLANE
   (HTTP from QML)  └───────┬───────────────────────────────────────────┬────────────┘
                            │ XMLHttpRequest                             │ Quickshell.execDetached
        ┌───────────────────┼───────────────────┐             ┌──────────┴───────────┐
        ▼                   ▼                   ▼             ▼   movies/video/video  │  (the ONLY video entry point)
  Cinemeta (mov/tv)   Kitsu (anime)     Subsonic (music)      │   play·search·load·ipc·popout·browse
  v3-cinemeta.strem   anime-kitsu.strem  navidrome_*          └──────────┬───────────┘
                                                                          ▼  providers/{youtube,anime,movie,tv,music,url}
                                                                          ▼  ../../pip transport (embedded mpv + IPC + shim)
```

Two planes:
- **Data plane** — catalogs/metadata/search, fetched over HTTP directly from QML.
- **Playback plane** — all video/audio goes through the **`video` CLI** (new),
  which fans out to pluggable providers and the shared mpv transport in `../pip/`.

---

## 1. Data sources (the tabs)

| Tab | Source | Endpoint | Notes |
|---|---|---|---|
| **Movies** | Cinemeta (Stremio, keyless) | `https://v3-cinemeta.strem.io/catalog/…`, `/meta/movie/…` | popular + search |
| **TV** | Cinemeta | `…/meta/series/<imdb>.json` | season/episode list from the series meta |
| **Anime** | Kitsu addon (keyless) | `https://anime-kitsu.strem.fun/catalog/anime/kitsu-anime-popular.json`, `…/kitsu-anime-list/search`, `…/meta/anime/kitsu:<id>.json` | chose Kitsu over TMDB self-host / Cinemeta "Animation" hack |
| **YouTube** | yt-dlp search | `video search youtube <q>` → `yt-dlp ytsearch24:` (TSV) | thumbnails derived in QML from the id; a configured YouTubio Stremio addon URL also lives in `youtubio_url.txt` (`localhost:7000`) |
| **Music** | Subsonic/Navidrome | `<navidrome_url>/rest/…` token-authed | needs `navidrome_url/user/pass` in config.json |

All catalog HTTP is done from QML with `XMLHttpRequest` + `node-cache`-style disk
caching under `paths.getCacheDir("movies")`. These are **metadata** only — none
of them resolves a playable stream; that's the playback plane's job.

---

## 2. Playback — the `video` CLI (start here)

**Every** video/audio operation the widget performs goes through one command:

```
video play    <kind> <query|id> [season] [ep]   # resolve + play in the PiP
video search  <kind> <query>                     # results (youtube: TSV)
video resolve <kind> <query|id> [s] [e]          # print stream JSON only
video load    <url> [mpv-flags…]                 # direct URL/file into the PiP
video ipc     '<json>'                           # raw mpv IPC (pause/seek/…)
video popout  <url> [start]                       # detach to a floating window
video browse  <kind> [query]                      # interactive terminal browser
video providers                                   # list kinds + capabilities
```

Lives at **`movies/video/`** (next to this file). `kind` ∈ the executables in
`video/providers/` — currently `youtube · anime · movie · tv · music · url`.
Adding a source is a **drop-in provider file, no QML change** — see
[`video/README.md`](video/README.md) for the provider contract and a 5-minute
walkthrough.

The QML calls it via the `videoCli` property, e.g. `playFromStart()` →
`video play <kind> <title> [s] [e]`, `playYouTube()` → `video play youtube <id>`,
the YouTube tab's search Process → `video search youtube <q>`, the PiP panel's
URL box → `video load <url>`, play/pause → `video ipc …`, pop-out → `video popout`.

### What each provider wraps
| kind | verb → tool |
|---|---|
| `youtube` | `search` → yt-dlp `ytsearch24`; `play` → youtube URL into PiP (mpv `ytdl` hook) |
| `anime` | `play` → `ani-cli -S 1 -e <ep>` headless; `browse` → interactive ani-cli |
| `movie` | `play` → `lobster -q 1080` (→ torrentio fallback); `browse` → interactive lobster |
| `tv` | `play` → `lobster` (S1E1 only) → `torrentio` for exact episodes |
| `music` | builds a Subsonic token stream URL from config, loads it into the PiP |
| `url` | loads an arbitrary direct URL/file (the minimal provider template) |

---

## 3. Playback transport (shared, in `../pip/`)

The provider layer is a facade; the actual player is one persistent embedded mpv
and is documented in full at [`../pip/BACKEND.md`](../pip/BACKEND.md). In short:

- The player is a locally-built Quickshell C++ plugin (`../pip/mpvplugin/`,
  `MpvItem`) embedded in the widget as `currentView === "player"`. On ready it
  opens `input-ipc-server = $XDG_RUNTIME_DIR/mpv-pip.sock` with
  `keep-open/idle/ytdl=yes`, `hwdec=auto-safe`.
- `../pip/pip_mpv.sh` writes `loadfile … replace` (plus referrer/header/sub
  options) to that socket — this is what `vid_load` calls.
- Headless scrapers (lobster/ani-cli) run with a **shim** dir first on PATH whose
  `mpv` → `pip_mpv.sh` and `fzf` → `auto_fzf.sh` (auto-pick), so they load into
  the one PiP and never prompt. `video`'s `vid_run_headless` builds this shim.
- **Whenever the widget is loaded, a JSON-IPC mpv is listening on the socket** —
  `video ipc '<json>'` (or writing to the socket) drives it.

Rebuild the plugin with `../pip/mpvplugin/build.sh` after mpvqt/Qt updates.

---

## 4. Comments, AI & integrations (CLI, in `../pip/` and here)

Not video, but part of the widget's backend:

| Feature | Script | Purpose |
|---|---|---|
| YouTube comments | `../pip/yt_comments.sh <vid>` | comments for the playing video |
| TV/movie comments | `../pip/trakt_comments.sh <kind> <imdb> [s] [e]` | Trakt discussion |
| Reddit threads | `../pip/reddit_comments.sh <title> [ep]` | matching Reddit discussion |
| AI summary / Q&A | `../pip/ai_parse.sh [--ask <q>] <kind> <arg>` | LLM summary + ask-about |
| Comics/manga | `kavita_fetch.py` | Kavita library (needs `kavita_api_key`) |
| Anime list status | `mal_set_status.py` | MyAnimeList (needs `mal_access_token`) |

These still hang off `window.pipDir`; they are intentionally **outside** the
`video` CLI (which is video/audio playback only).

---

## 5. Config keys (`~/.config/hypr/config.json`)

`navidrome_url` · `navidrome_user` · `navidrome_pass` (music) · `mal_access_token`
(MyAnimeList) · `kavita_api_key` (comics) · Trakt keys (Trakt comments). Secrets
should live in the keyring via `secrets.sh` where possible. `youtubio_url.txt`
holds the configured YouTubio addon manifest URL.

`vpn_enabled` · `vpn_proxy` — route ALL movie/tv/anime source traffic (scrapers
+ the stream itself) through the gluetun VPN container, **fail-closed**: if the
tunnel isn't verifiably up, playback is refused instead of touching the bare
network. See `video/README.md` § "VPN routing" for setup
(`~/.config/gluetun/gluetun.env` + `systemctl --user enable --now gluetun`).

---

## 6. Failure modes

- **Movies/TV won't play / "No source found":** lobster's scraper failed —
  ani-cli (anime) is more reliable. Check `$XDG_RUNTIME_DIR/video.log` and
  `$XDG_RUNTIME_DIR/video.log`. Scrapers are fragile/region-dependent; configure
  the torrentio backend (+ debrid key) as a fallback.
- **"VPN not connected — blocked (failsafe)":** `vpn_enabled` is on but the
  gluetun tunnel isn't up. `systemctl --user start gluetun` (credentials in
  `~/.config/gluetun/gluetun.env`); check `podman logs gluetun`. To bypass
  temporarily set `"vpn_enabled": false` in config.json.
- **Nothing loads at all:** the widget isn't loaded, so the mpv IPC socket
  doesn't exist; `vid_load` waits ~6 s then exits silently.
- **YouTube search empty:** yt-dlp missing → provider emits `__NOYTDLP__` and the
  UI shows an install hint.
- **Music silent:** `navidrome_*` not set → `music` provider and the widget's
  `subsonicReady` guard both no-op.

---

## 7. File map

```
movies/
├── MovieWidget.qml     UI (all tabs + embedded player) — calls `video` for playback
├── MoviesWindow.qml    the overlay window wrapper
├── BACKEND.md          ← this file
├── video/              the video CLI (see video/README.md)
│   ├── video · lib/common.sh · providers/{youtube,anime,movie,tv,music,url}
├── kavita_fetch.py     comics/manga integration
└── mal_set_status.py   MyAnimeList integration
../pip/                 shared transport: mpvplugin/ · pip_mpv.sh · pip_ipc.sh ·
                        pip_popout.sh · auto_fzf.sh · pip_anicli.sh · pip_lobster.sh ·
                        {yt,trakt,reddit}_comments.sh · ai_parse.sh · BACKEND.md
```

**To add a video source:** drop a provider in `video/providers/` (no QML change).
**To add a data-source tab:** add the catalog fetch + grid in `MovieWidget.qml`.
