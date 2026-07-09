# `video` — the movies widget's video CLI

One command for every video operation the widget performs, backed by **pluggable
providers** so adding a new source is a drop-in file — no QML changes. The
QML widget (`../MovieWidget.qml`) calls **only** `video`; it never invokes
lobster / ani-cli / yt-dlp / mpv directly.

```
movies/video/
├── video              # the dispatcher (this is what QML calls)
├── lib/common.sh      # shared helpers + the transport wrappers
└── providers/         # one executable per "kind" — the pluggable part
    ├── youtube  ├── anime  ├── movie  ├── tv  ├── music  └── url
```

## Commands

| Command | What it does |
|---|---|
| `video play <kind> <query\|id> [season] [ep]` | Resolve **and** play into the embedded PiP (fire-and-forget). |
| `video resolve <kind> <query\|id> [s] [e]` | Print a stream `{"url":…}` JSON without playing. |
| `video search <kind> <query>` | Print results in the provider's format (youtube: TSV `id⇥title⇥channel⇥dur`). |
| `video episodes <kind> <id>` | List episodes (if the provider supports it). |
| `video browse <kind> [query]` | Open an interactive terminal browser that streams into the PiP. |
| `video load <url> [mpv-flags…]` | Load a direct URL/file into the PiP (kind-agnostic transport). |
| `video ipc '<json>'` | Send a raw mpv JSON-IPC command to the PiP. |
| `video popout <url> [start]` | Pop the stream out into a standalone floating window. |
| `video providers` | List installed providers and their capabilities. |

`kind` is simply the name of an executable in `providers/`.

## The provider contract

A provider is **any executable** (bash, python, whatever) named after its kind.
The dispatcher calls it as `providers/<kind> <verb> [args…]`. Implement the verbs
you support; always implement `capabilities`:

| Verb (argv[1]) | Args | Must do |
|---|---|---|
| `capabilities` | — | Print the space-separated verbs you support, e.g. `search play resolve`. |
| `play` | `<query\|id> [s] [e]` | Start playback in the PiP. Return immediately. |
| `resolve` | `<query\|id> [s] [e]` | Print `{"url":"…","referrer":"…","headers":"…"}` (only `url` required). |
| `search` | `<query>` | Print results (choose a format; document it). |
| `episodes` | `<id>` | Print the episode list. |
| `browse` | `[query]` | Launch an interactive browser (optional). |

Providers `source ../lib/common.sh` and get the transport helpers for free:

- `vid_load <url> [mpv-flags…]` — load into the running PiP over its IPC socket.
- `vid_ipc '<json>'` — raw mpv IPC.
- `vid_run_headless <cmd…>` — run a scraper CLI with a shim `mpv`/`fzf` first on
  PATH so it loads into the PiP and auto-picks instead of opening its own window
  or prompting. (Fire-and-forget; ignores the CLI's exit code.)
- `vid_run_checked '<fail-regex>' <cmd…>` — same, but captures output and returns
  **failure** when the regex matches (scrapers exit 0 even on "no results").
- `vid_cfg <key>` — read a key from `~/.config/hypr/config.json`.
- `vlog` / `vnotify` — log to `$XDG_RUNTIME_DIR/video.log` / desktop notify.
- `vid_headless_shim` — echo the shim dir.
- `vid_backend_chain <kind>` / `vid_dispatch <kind> <verb> …` — resolve and run
  the pluggable backends (below).

## Movie / TV / anime backends — add your own source

The `movie` / `tv` / `anime` providers are thin: they **dispatch to a pluggable
backend** in [`backends/`](backends/README.md) (lobster, ani-cli, torrentio,
or your own — e.g. Jellyfin). Pick one per kind in
`~/.config/hypr/config.json`:

```jsonc
"movie_backend": "lobster",   // "tv_backend", "anime_backend" — unset = defaults
```

Each kind has a **fallback chain** (config first, then defaults: movie/tv =
`lobster → torrentio`, anime = `anicli → torrentio`), so a dead source
cascades to the next. The scrapers lead; `torrentio` (Stremio addon + debrid)
is the last-resort safety net for when they rot, and self-skips unless a debrid
account is configured. Add a new source by dropping one file in `backends/` —
see **`backends/README.md`** and the ready-to-copy **`backends/jellyfin.example`**.

Notes: lobster's fzf uses `--expect`, so `../../pip/auto_fzf.sh` emits a blank key
line when `--expect` is present (ani-cli unaffected). lobster can't target an exact
TV episode headlessly (defers non-S1E1 → falls through to torrentio, which needs a
debrid account).

**Resilience:** lobster scrapes `flixhq.to`, whose domain drifts / goes down; the
chain then falls through to torrentio. (If both are dead — flixhq down *and* no
debrid key — nothing plays until one is restored: `paru -S lobster-git`, a working
flixhq mirror in lobster's config `base=`, or a debrid key in the keyring.)

## VPN routing (gluetun) — movie/tv/anime only

With `"vpn_enabled": true` in `~/.config/hypr/config.json`, **all movie/tv/anime
source traffic** — the scraper lookups *and* the resolved stream the embedded PiP
fetches — is routed through a [gluetun](https://github.com/qdm12/gluetun) VPN
container's HTTP proxy (`vpn_proxy`, default `http://127.0.0.1:8889`).
YouTube / music / books are deliberately not routed.

**Failsafe (fail-closed):** before any backend is launched, `vid_vpn_guard`
demands a working fetch *through the tunnel* (gluetun's internal firewall drops
all non-tunnel egress, so a working proxy proves the tunnel is up). If that
check fails, playback is **refused with a notification** — nothing ever falls
back to the bare network. The stream itself is proxied per-load via mpv's
`http-proxy` file option (see `pip_mpv.sh`), so a later YouTube load is
naturally unproxied.

Setup: fill `~/.config/gluetun/gluetun.env` with your provider's credentials
(templates inside), then `systemctl --user daemon-reload && systemctl --user
enable --now gluetun` (quadlet: `~/.config/containers/systemd/gluetun.container`,
control server on `127.0.0.1:8018`). Note: catalog *metadata* (Cinemeta/Kitsu
posters and titles, fetched by the QML widget itself) is not routed — only the
content traffic is.

## Wire in a new source in ~5 minutes

`providers/url` is the minimal template. To add, say, a Twitch provider:

```bash
cat > providers/twitch <<'SH'
#!/usr/bin/env bash
set -uo pipefail
: "${VIDEO_DIR:=$(cd "$(dirname "$0")/.." && pwd)}"
source "$VIDEO_DIR/lib/common.sh"
verb="${1:-}"; shift 2>/dev/null || true
case "$verb" in
  capabilities) echo "play resolve" ;;
  resolve) printf '{"url":"https://twitch.tv/%s"}\n' "$1" ;;   # mpv's ytdl hook handles it
  play)    vid_load "https://twitch.tv/$1" ;;
  *) exit 2 ;;
esac
SH
chmod +x providers/twitch
video providers          # twitch now shows up
video play twitch somestreamer
```

That's the whole wiring. It's live immediately (`video providers` auto-discovers
it); the QML side only needs a change if you want a *button* for it.

## Where the transport lives

The low-level playback machinery (the embedded mpv Quickshell plugin, the IPC
loader `pip_mpv.sh`, the shim, the pop-out window) still lives in `../../pip/`
and is shared with the rest of the shell. `video` is a facade over it — see
[`../BACKEND.md`](../BACKEND.md) for the full backend and `../../pip/BACKEND.md`
for the transport internals.
