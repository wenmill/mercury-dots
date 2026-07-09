# hypr-de

A Hyprland + Quickshell desktop environment for Arch-based systems. Started as a
fork of [imperative-dots](https://github.com/ilyamiro/imperative-dots) by
ilyamiro and has since been heavily rebuilt: every widget rewritten or
optimized for near-zero idle cost, secrets moved to the system keyring, a
pluggable media backend, and native companion apps.

## Highlights

- **Quickshell shell** — topbar plus a full set of popup widgets (calendar with
  vdir/ics events + weather, music/MPRIS, network, bluetooth/battery, movies,
  notifications, settings, toolhub, character sheet), all timer-gated so the
  idle desktop burns ~0% CPU.
- **Movies widget with a pluggable `video` CLI** — drop-in provider scripts for
  YouTube, anime (ani-cli), movies/TV (lobster, with a Torrentio+debrid fallback),
  music (Subsonic/Navidrome) and
  raw URLs, all playing through a native mpv picture-in-picture player
  (`scripts/quickshell/movies/BACKEND.md` documents the whole plane).
- **Element/Matrix overlay** — transparent Qt WebEngine window themed by
  matugen, with renderer discard when parked (~0 cost idle) and crash self-heal.
- **obsidian-shell** — standalone C++ layer-shell + WebEngine floating panel
  for Obsidian/web hubs.
- **Matugen theming end-to-end** — one wallpaper pick recolors the shell, GTK,
  Qt, kitty, swayosd, and the web overlays.
- **Keyring-backed secrets** — `scripts/secrets.sh` keeps every API token in
  the freedesktop Secret Service (KWallet by default); config files carry only
  URLs and paths.

## Install

```sh
git clone <this repo> && cd hypr-de
./install.sh
```

The installer is interactive and idempotent: it installs the curated package
set (repo + AUR via paru), deploys configs with a timestamped backup, builds
the native components (obsidian-shell, mpv PiP plugin, hyprbars via hyprpm),
installs fonts, wires theming, and enables services. Optional stacks
(podman containers, tailscale + Apollo game streaming, Steam, SDDM) are
prompted individually.

Run it from the repo root for a full deploy, or from `~/.config/hypr` on an
already-deployed machine to (re)provision packages and builds only.

After first login:

```sh
~/.config/hypr/scripts/secrets.sh list          # keys the widgets look for
~/.config/hypr/scripts/secrets.sh set KEY VALUE # store a token in the keyring
```

## Layout

```
install.sh                  installer (see above)
.config/hypr/               compositor config, scripts, quickshell widgets
.config/hypr/scripts/quickshell/   one directory per widget
.config/{kitty,cava,matugen,swayosd,zsh}/
.local/share/fonts/         JetBrains Mono (Iosevka Nerd is downloaded)
```

`settings.json` is generated on install (merged from
`default_settings.json` + your previous settings) and is the single source of
truth for keybinds, startup entries and shell options — edit it via the
in-shell Settings widget and the confs recompile automatically.

## Credits

- [ilyamiro/imperative-dots](https://github.com/ilyamiro/imperative-dots) — the
  original dotfiles this DE grew out of.
- Hyprland, Quickshell, matugen, and the rest of the stack listed in
  `install.sh`.
