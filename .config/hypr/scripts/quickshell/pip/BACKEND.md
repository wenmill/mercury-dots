# Movies / TV / Anime playback backend (mov-cli + ani-cli)

How the Quickshell movies widget plays **movies and TV (via mov-cli)** and **anime
(via ani-cli)** into its embedded mpv player, fully headlessly (no terminal, no
prompts). YouTube and music do **not** use this path (YouTube → `pip_mpv.sh` with a
`youtube.com/watch?v=` URL; music → Subsonic stream URL → `pip_mpv.sh`).

All paths are under `~/.config/hypr/scripts/quickshell/pip/`.

---

## 1. Architecture at a glance

```
QML (MovieWidget.qml)                    one persistent mpv (the PiP)
  playFromStart(kind,title,season,ep)      MpvItem.cpp (Quickshell C++ plugin)
        │ execDetached                      input-ipc-server = $XDG_RUNTIME_DIR/mpv-pip.sock
        ▼                                   keep-open=yes  idle=yes  ytdl=yes  hwdec=auto-safe
  pip_play.sh kind title [s] [e]                         ▲
        │  PATH=shim-auto:$PATH   (fake mpv + fzf)        │ JSON IPC: loadfile <url> replace
        ▼                                                 │
  mov-cli / ani-cli   ──resolves stream──►  calls `mpv <url> …flags…`
        │  (fzf auto-picks first result)                  │
        ▼                                                 │
  shim `mpv`  ──exec──►  pip_mpv.sh <url> …flags… ────────┘  (writes to the socket)
```

The key idea: the CLIs think they're launching a normal `mpv` window, but `mpv`
on their `PATH` is a **shim** that forwards the resolved stream URL (and headers)
to the one already-running embedded mpv over its IPC socket. There is never a
second mpv window.

---

## 2. The contract: the mpv IPC socket (the "server")

The embedded player is `pip/mpvplugin/MpvItem.cpp` (a libmpv/mpvqt `MpvObject`
exposed to QML as `MpvItem`). At construction it sets, among others:

| mpv property        | value                                  |
|---------------------|----------------------------------------|
| `input-ipc-server`  | `$XDG_RUNTIME_DIR/mpv-pip.sock`         |
| `keep-open`         | `yes`  (pauses on EOF; `eof-reached`)  |
| `idle`              | `yes`  (stays alive with no file)      |
| `ytdl`              | `yes`  (yt-dlp hook for YouTube etc.)  |
| `hwdec`             | `auto-safe`                            |
| `osc` / `terminal`  | `no`                                   |

So **whenever the movies widget is loaded, a JSON-IPC mpv is listening on
`$XDG_RUNTIME_DIR/mpv-pip.sock`.** Anything that can write mpv JSON commands to
that socket controls playback. QML controls it directly via
`embeddedMpv.setProperty/getProperty/command`; the shell scripts control it via
the socket.

---

## 3. Entry point: `playFromStart(kind, title, season, ep)` (QML)

In `movies/MovieWidget.qml`:

```js
function playFromStart(kind, title, season, ep) {
    // (watch-limit gate omitted)
    window.currentYtId = ""            // mark this as a non-youtube source
    window.playerKind  = kind          // "movie" | "tv" | "anime"
    window.playerSeason = season
    window.playerEpisode = ep
    refreshPlayerComments()
    var args = ["bash", pipDir + "/pip_play.sh", kind, title]
    if (kind === "tv")    { args.push(String(season)); args.push(String(ep)) }
    else if (kind === "anime") { args.push(String(ep)) }
    Quickshell.execDetached(args)      // fire-and-forget
}
```

`pipDir = ~/.config/hypr/scripts/quickshell/pip`. The caller has already shown the
player view (`enterPlayer()`), so the socket is up by the time the script runs.

---

## 4. `pip_play.sh` — the headless resolver

```
pip_play.sh movie "<title>"
pip_play.sh tv    "<title>" <season> <episode>
pip_play.sh anime "<title>" <episode>
```

Steps:

1. **Build an auto-shim dir** `pip/shim-auto/` containing two executables:
   - `mpv`  → `exec bash pip/pip_mpv.sh "$@"`   (load into the PiP, return immediately)
   - `fzf`  → `exec bash pip/auto_fzf.sh "$@"`   (auto-pick, never block)
   It's regenerated every run so the embedded absolute `DIR` path is current.

2. **Prepend the shim to `PATH`** for the CLI invocation only
   (`PATH="$SHIM:$PATH" mov-cli …`), so the CLI's `mpv`/`fzf` resolve to the shims.

3. **Invoke the CLI non-interactively** with stdin redirected from `/dev/null`,
   stdout/stderr appended to `$XDG_RUNTIME_DIR/pip_play.log`:

   | kind  | command |
   |-------|---------|
   | movie | `mov-cli -c 1 --player mpv "<title>"` |
   | tv    | `mov-cli -c 1 -ep "<ep>:<season>" --player mpv "<title>"` |
   | anime | `ani-cli -S 1 -e "<ep>" "<title>"` |

   - `mov-cli -c 1` auto-selects the **first** search result (`-c` = choice).
   - `mov-cli -ep <ep>:<season>` selects the episode (note order: **episode first**).
   - `ani-cli -S 1` auto-selects the first result; `-e <ep>` the episode.
   - `--player mpv` makes mov-cli spawn `mpv` (→ the shim).

4. The CLI scrapes a provider, resolves a direct stream URL, then "plays" it by
   running `mpv <url> [--referrer=… --http-header-fields=… --force-media-title=… …]`
   — which is the shim → `pip_mpv.sh`.

**mov-cli binary preference:** uses `~/.local/bin/mov-cli` (a `uv tool` install
with a working scraper + Node runtime) if present, else `mov-cli` on PATH. The
system mov-cli historically has no usable scraper.

`notify-send "PiP" "<msg>"` is used for "X is not installed" errors.

---

## 5. `pip_mpv.sh` — the loader (shim target & universal router)

```
pip_mpv.sh [mpv-style flags...] <URL_OR_FILE>
```

- Parses **mpv-style argv** and keeps only what matters, mapping flags → mpv option
  keys: `--http-header-fields=` , `--referrer=` , `--user-agent=` ,
  `--force-media-title=` , `--audio-file=` (mov-cli split audio) , `--sub-file=` ,
  `--sub-files=`. All other `--flags` are ignored. First positional arg = the media.
- Connects to `$XDG_RUNTIME_DIR/mpv-pip.sock` (retries for ~6 s for the socket to appear).
- Sends, as JSON lines:
  ```json
  {"command": ["loadfile", "<url>", "replace", 0, "<opts>"]}
  {"command": ["set_property", "pause", false]}
  ```
  where `<opts>` is `key=%<bytelen>%<value>` per-file options (mpv's length-prefixed
  escaping so commas/colons/spaces in headers survive). `replace` swaps the current
  file; the unpause clears any keep-open EOF pause.

This is also how **YouTube** and **music** play — QML calls
`pip_mpv.sh https://www.youtube.com/watch?v=<id>` or `pip_mpv.sh <subsonic-stream-url>`
directly (no mov-cli/ani-cli). The embedded mpv's `ytdl=yes` resolves the YouTube URL.

---

## 6. `auto_fzf.sh` — the non-interactive picker

Drop-in `fzf` replacement used while a CLI runs headlessly. Reads candidate lines
on stdin and prints exactly one:

- If the list looks like ani-cli's **post-playback menu** (`next/replay/previous
  episode`, `quit`, `exit`) → prints nothing → the CLI reads that as escape/quit
  and exits cleanly (so a single episode doesn't hang waiting for a menu choice).
- Otherwise → prints the **first** line (top search result, or first quality/source).

All real fzf flags are ignored.

---

## 7. Interactive anime variant: `pip_anicli.sh`

For browsing anime interactively (menus), `pip_anicli.sh ["search terms"]` opens a
**terminal** (`$TERMINAL` or kitty) running real `ani-cli`, but with a `pip/shim/`
dir first on `PATH` whose `mpv` → `pip_mpv.sh`. So you navigate ani-cli's fzf menus
yourself, and each episode you pick loads into the same PiP (with ani-cli's
Referer/title headers). Picking "next episode" just swaps the PiP source. This is
the only interactive path; `pip_play.sh` is the headless one the widget uses.

---

## 8. Failure modes & notes

- **Nothing plays / "No source found":** mov-cli's scraper failed or returned no
  result. The widget shows `"No source found.\nAnime uses ani-cli (works); movies/TV
  need a working mov-cli scraper plugin."` Check `$XDG_RUNTIME_DIR/pip_play.log`.
- **mov-cli scrapers are fragile / region-dependent**; ani-cli is more reliable.
  The episode-number arg order differs (`mov-cli -ep <ep>:<season>` vs `ani-cli -e <ep>`).
- **Socket missing:** if the movies widget isn't loaded, the socket doesn't exist;
  `pip_mpv.sh` waits ~6 s then exits silently.
- **Single PiP:** there is only ever one embedded mpv; every load is `loadfile …
  replace`. There is no per-stream window.
- **Title for the player UI** comes from the QML side (`selectedTitle`), not the
  CLI; mov-cli/ani-cli only supply the stream URL + headers.

---

## 9. For another AI: how to use / extend this

- **Play any direct media in the PiP:** `bash pip/pip_mpv.sh "<url-or-file>"`
  (optionally `--referrer= --http-header-fields= --user-agent= --sub-file=`). It
  loads into the running embedded mpv over the IPC socket. Requires the movies
  widget to be loaded (socket present).
- **Trigger a headless title resolve:** `bash pip/pip_play.sh movie|tv|anime
  "<title>" [season] [episode]`.
- **Drive playback directly** (from QML or any IPC client) by writing mpv JSON to
  `$XDG_RUNTIME_DIR/mpv-pip.sock`, e.g.
  `{"command":["loadfile","<url>","replace"]}`,
  `{"command":["set_property","pause",true]}`,
  `{"command":["seek","30","absolute"]}`,
  `{"command":["get_property","time-pos"]}`.
- **Add a new source provider:** wrap it in a resolver that ends by calling
  `pip/pip_mpv.sh <resolved-url> [--headers…]`, and (if it uses fzf/mpv internally
  and must stay headless) run it with `PATH="$PIP/shim-auto:$PATH"` so its `mpv`
  and `fzf` are the shims. Mirror the `pip_play.sh` `case` block.
- **Swap mov-cli/ani-cli for something else** (e.g. a different scraper): only
  `pip_play.sh`'s `case "$KIND"` block needs to change — keep emitting a final
  `mpv <url>` call (which the shim routes to `pip_mpv.sh`), and the rest of the
  stack (socket, QML, comments, up-next) is unaffected.
