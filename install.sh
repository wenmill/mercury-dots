#!/usr/bin/env bash
# ==============================================================================
#  DE installer — Hyprland + Quickshell desktop
#  Derived from imperative-dots (ilyamiro) install.sh, rebuilt for this DE:
#    * package set updated to everything the current shell actually invokes
#      (scanned from QML exec sites, scripts and hypr configs — not a full
#      pacman -Qqe dump)
#    * native builds: obsidian-shell (layer-shell + WebEngine), pip mpvplugin
#    * hyprpm hyprbars plugin, uwsm session, keyring-backed secrets seeding
#    * telemetry removed
#
#  Run modes (auto-detected):
#    repo mode     — script sits in a dotfiles repo with .config/ next to it:
#                    deploys configs (with backup), then provisions.
#    in-place mode — script sits inside ~/.config/hypr on a machine that
#                    already has the configs: provisions packages/builds only.
# ==============================================================================
set -uo pipefail

RESET="\e[0m"; BOLD="\e[1m"; DIM="\e[2m"
C_BLUE="\e[34m"; C_CYAN="\e[36m"; C_GREEN="\e[32m"; C_YELLOW="\e[33m"; C_RED="\e[31m"

info()  { echo -e "${C_CYAN}[ INFO ]${RESET} $*"; }
ok()    { echo -e "  -> ${C_GREEN}$*${RESET}"; }
warn()  { echo -e "  -> ${C_YELLOW}$*${RESET}"; }
fail()  { echo -e "  -> ${C_RED}$*${RESET}"; }
ask()   { # ask "Question" "default(y/n)" -> 0 yes / 1 no
    local q="$1" d="${2:-y}" a
    read -r -p "$(echo -e "${C_YELLOW}::${RESET} ${q} $([ "$d" = y ] && echo '[Y/n]' || echo '[y/N]') ")" a
    a="${a:-$d}"; [[ "$a" =~ ^[Yy] ]]
}

# ── OS detection ──────────────────────────────────────────────────────────────
[ -f /etc/os-release ] || { echo "Cannot detect OS."; exit 1; }
DETECTED_OS=$(awk -F= '/^ID=/{gsub(/"/,"",$2); print $2}' /etc/os-release)
case "$DETECTED_OS" in
    arch|endeavouros|manjaro|cachyos|parch|garuda) ;;
    *) echo -e "${C_RED}Unsupported OS ($DETECTED_OS). Arch Linux derivatives only.${RESET}"; exit 1 ;;
esac

# Keep the console awake through long AUR builds
setterm -blank 0 -powerdown 0 2>/dev/null || true

# ── Mode detection ────────────────────────────────────────────────────────────
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ -d "$SCRIPT_DIR/.config/hypr" ]; then
    MODE="repo";     SRC_CFG="$SCRIPT_DIR/.config"; SRC_LOCAL="$SCRIPT_DIR/.local"
elif [ -d "$SCRIPT_DIR/scripts/quickshell" ]; then
    MODE="inplace";  SRC_CFG=""; SRC_LOCAL=""
else
    echo -e "${C_RED}Can't find the DE configs relative to this script.${RESET}"
    echo "Run it from the dotfiles repo root, or from ~/.config/hypr."
    exit 1
fi

TARGET_CONFIG_DIR="$HOME/.config"
HYPR_DIR="$TARGET_CONFIG_DIR/hypr"
BACKUP_DIR="$HOME/.config-backup-$(date +%Y%m%d_%H%M%S)"
FAILED_PKGS=()

echo -e "${BOLD}${C_BLUE}Hyprland + Quickshell DE installer${RESET}  ${DIM}(mode: $MODE)${RESET}\n"

# ── XDG dirs / wallpaper dir ──────────────────────────────────────────────────
USER_PICTURES_DIR="$(xdg-user-dir PICTURES 2>/dev/null || true)"
[[ -z "${USER_PICTURES_DIR:-}" || "$USER_PICTURES_DIR" == "$HOME" ]] && USER_PICTURES_DIR="$HOME/Pictures"
WALLPAPER_DIR="${USER_PICTURES_DIR%/}/Wallpapers"

# Respect an existing settings.json wallpaperDir
if [ -f "$HYPR_DIR/settings.json" ] && command -v jq &>/dev/null; then
    _wp=$(jq -r '.wallpaperDir // empty' "$HYPR_DIR/settings.json" 2>/dev/null)
    [ -n "$_wp" ] && WALLPAPER_DIR="${_wp%/}"
fi

# ── Bootstrap: TUI deps, multilib, AUR helper ─────────────────────────────────
if ! command -v fzf &>/dev/null || ! command -v jq &>/dev/null || ! command -v curl &>/dev/null || ! command -v lspci &>/dev/null; then
    info "Bootstrapping base tools (fzf, jq, curl, pciutils)..."
    sudo pacman -Sy --noconfirm --needed fzf jq curl pciutils
fi

if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
    info "Enabling multilib (32-bit driver/steam support)..."
    sudo sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' /etc/pacman.conf
    sudo pacman -Sy --noconfirm >/dev/null
fi

if command -v paru &>/dev/null; then          PKG_MANAGER="paru -S --noconfirm --needed"
elif command -v yay &>/dev/null; then         PKG_MANAGER="yay -S --noconfirm --needed"
else
    info "Installing 'paru' (AUR helper)..."
    sudo pacman -S --noconfirm --needed base-devel git
    git clone https://aur.archlinux.org/paru-bin.git /tmp/paru-bin
    (cd /tmp/paru-bin && makepkg -si --noconfirm)
    rm -rf /tmp/paru-bin
    PKG_MANAGER="paru -S --noconfirm --needed"
fi

# ── Package sets ──────────────────────────────────────────────────────────────
# Curated from a scan of every binary the DE's QML/scripts/configs invoke.
# NOT a full explicit-package dump — only what the shell needs to run.
CORE_PKGS=(
    # session / compositor
    hyprland hypridle uwsm hyprpolkitagent
    xdg-desktop-portal-hyprland xdg-desktop-portal-gtk xdg-user-dirs
    qt5-wayland qt6-wayland qt5ct qt6ct
    qt6-multimedia qt6-5compat qt6-websockets
    qt5-quickcontrols qt5-quickcontrols2 qt5-graphicaleffects
    # audio
    pipewire wireplumber pipewire-pulse pipewire-alsa pipewire-jack libpulse
    pavucontrol alsa-utils pamixer easyeffects lsp-plugins playerctl
    # network / bluetooth
    networkmanager bluez bluez-utils iw
    # terminal + core widget tools
    kitty cava fastfetch dolphin
    jq socat inotify-tools fd ripgrep bc acpi lm_sensors psmisc file wget git unzip fzf
    wl-clipboard cliphist libnotify brightnessctl power-profiles-daemon fcitx5
    # screenshot / recording / QR
    grim slurp satty zbar
    # media pipeline (movies widget video CLI, pip player, wallpapers)
    mpv mpvpaper ffmpeg yt-dlp imagemagick poppler
    # python + the Element/Matrix overlay host
    python python-websockets python-pyqt6 python-pyqt6-webengine
    # secrets (secrets.sh -> org.freedesktop.secrets, served by KWallet's
    # ksecretd; kwallet-pam auto-unlocks the wallet at login via the
    # pam_kwallet5 lines the sddm package already ships)
    libsecret kwallet kwallet-pam
    # native builds: obsidian-shell (layer-shell+WebEngine), pip mpvplugin, hyprpm
    cmake ninja meson cpio pkgconf base-devel
    layer-shell-qt qt6-webengine mpvqt
    # update/security widgets
    pacman-contrib arch-audit bat
    # mov-cli provider is installed as a uv tool
    uv
    # fonts not shipped in the repo
    noto-fonts-cjk
)
AUR_PKGS=(
    quickshell-git matugen-bin swayosd-git awww
    wl-screenrec gpu-screen-recorder ani-cli
)
PKGS=("${CORE_PKGS[@]}" "${AUR_PKGS[@]}")

# ── Optional stacks ───────────────────────────────────────────────────────────
OPT_CONTAINERS=false; OPT_STREAMING=false; OPT_STEAM=false; OPT_SDDM=false; OPT_WALLPAPERS=false
OPT_HERMES=false; OPT_ACCOUNTS=false
echo
info "Optional stacks (everything else works without them):"
ask "Containers (podman): element-web, dify, navidrome, searxng, freshrss, kavita, ...?" n && OPT_CONTAINERS=true
$OPT_CONTAINERS && { ask "Auto-provision app accounts (Dify/Kavita) with one shared password + API keys?" y && OPT_ACCOUNTS=true; }
ask "Hermes AI gateway (agent API for the widgets + autobrowse MCP)?" n && OPT_HERMES=true
ask "Game streaming (tailscale + Apollo/Sunshine fork)?" n && OPT_STREAMING=true
ask "Steam (games tab launcher)?" n && OPT_STEAM=true
ask "SDDM display manager (+ enable)?" n && OPT_SDDM=true
ask "Download a starter wallpaper pack?" n && OPT_WALLPAPERS=true

# Hermes needs podman for the autobrowse MCP container + openssl for secret gen.
$OPT_HERMES && OPT_CONTAINERS=true
$OPT_CONTAINERS && PKGS+=(podman podman-compose passt fuse-overlayfs)
$OPT_HERMES     && PKGS+=(openssl)
$OPT_STREAMING  && PKGS+=(tailscale apollo)
$OPT_STEAM      && PKGS+=(steam)
$OPT_SDDM       && PKGS+=(sddm)

# ── Keyboard layout ───────────────────────────────────────────────────────────
KB_LAYOUTS="us"
if [ -f "$HYPR_DIR/settings.json" ]; then
    _kb=$(jq -r '.language // empty' "$HYPR_DIR/settings.json" 2>/dev/null)
    [ -n "$_kb" ] && KB_LAYOUTS="$_kb"
fi
read -r -p "$(echo -e "${C_YELLOW}::${RESET} Keyboard layout(s), comma separated [${KB_LAYOUTS}]: ")" _in
KB_LAYOUTS="${_in:-$KB_LAYOUTS}"

# ── GPU drivers (compact) ─────────────────────────────────────────────────────
GPU_RAW=$(lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' || true)
DRIVER_PKGS=(); HAS_NVIDIA_PROPRIETARY=false
if echo "$GPU_RAW" | grep -qi nvidia; then
    if ask "NVIDIA GPU detected — install proprietary drivers (nvidia-dkms)?" y; then
        DRIVER_PKGS=(nvidia-dkms nvidia-utils lib32-nvidia-utils egl-wayland)
        HAS_NVIDIA_PROPRIETARY=true
    fi
elif echo "$GPU_RAW" | grep -qiE 'amd|radeon'; then
    if ask "AMD GPU detected — ensure Mesa/Vulkan stack?" y; then
        DRIVER_PKGS=(mesa vulkan-radeon lib32-mesa lib32-vulkan-radeon libva-mesa-driver)
    fi
fi
PKGS+=("${DRIVER_PKGS[@]}")

# ── Install packages ──────────────────────────────────────────────────────────
echo; info "Requesting sudo for installation..."; sudo -v

# Repo/AUR conflict cleanup (repo builds of these shadow the -git/-bin variants)
for cpkg in swayosd quickshell matugen go-yq; do
    if pacman -Qq "$cpkg" &>/dev/null; then
        warn "Removing conflicting package '$cpkg'..."
        sudo pacman -Rdd --noconfirm "$cpkg" >/dev/null 2>&1 || true
    fi
done
for jack_pkg in jack jack2 jack2-dbus; do
    pacman -Qq "$jack_pkg" &>/dev/null && sudo pacman -Rdd --noconfirm "$jack_pkg" >/dev/null 2>&1 || true
done

MISSING_PKGS=()
for pkg in "${PKGS[@]}"; do
    pacman -Q "$pkg" &>/dev/null || MISSING_PKGS+=("$pkg")
done

if [ ${#MISSING_PKGS[@]} -eq 0 ]; then
    ok "All ${#PKGS[@]} packages already installed."
else
    info "Installing ${#MISSING_PKGS[@]} missing packages (of ${#PKGS[@]} total)..."
    SAFE_JOBS=$(( $(nproc) / 2 )); (( SAFE_JOBS < 1 )) && SAFE_JOBS=1; (( SAFE_JOBS > 4 )) && SAFE_JOBS=4
    for pkg in "${MISSING_PKGS[@]}"; do
        echo -e "\n${C_BLUE}::${RESET} ${BOLD}Installing ${pkg}...${RESET}"
        if [ "$pkg" = "apollo" ]; then
            warn "Note: on non-NVIDIA boxes the apollo PKGBUILD may demand an old gcc"
            warn "because it derives _cuda_gcc_version from 'pacman -Si cuda'."
            warn "If the build fails, set _cuda_gcc_version=\"\" in its PKGBUILD."
        fi
        if yes "Y" | env CARGO_BUILD_JOBS="$SAFE_JOBS" MAKEFLAGS="-j$SAFE_JOBS" $PKG_MANAGER "$pkg"; then
            ok "Installed $pkg"
        else
            fail "FAILED: $pkg"; FAILED_PKGS+=("$pkg")
        fi
    done
fi

# NVIDIA Wayland modeset
if [ "$HAS_NVIDIA_PROPRIETARY" = true ]; then
    info "NVIDIA Wayland setup (nvidia-drm modeset/fbdev)..."
    echo "options nvidia-drm modeset=1 fbdev=1" | sudo tee /etc/modprobe.d/nvidia.conf >/dev/null
    if command -v mkinitcpio &>/dev/null; then sudo mkinitcpio -P >/dev/null 2>&1 && ok "initramfs rebuilt"
    elif command -v dracut &>/dev/null; then sudo dracut --force >/dev/null 2>&1 && ok "initramfs rebuilt"; fi
fi

# ── Deploy configs (repo mode only) ───────────────────────────────────────────
if [ "$MODE" = "repo" ]; then
    info "Deploying configurations (old ones backed up to $BACKUP_DIR)..."
    mkdir -p "$TARGET_CONFIG_DIR" "$BACKUP_DIR"

    # Preserve the live settings.json across the overwrite
    [ -f "$HYPR_DIR/settings.json" ] && { mkdir -p "$BACKUP_DIR/hypr"; cp "$HYPR_DIR/settings.json" "$BACKUP_DIR/hypr/"; }

    for folder in hypr kitty cava matugen swayosd zsh; do
        SRC="$SRC_CFG/$folder"; DST="$TARGET_CONFIG_DIR/$folder"
        [ -d "$SRC" ] || continue
        if [ -e "$DST" ] || [ -L "$DST" ]; then mv "$DST" "$BACKUP_DIR/$folder"; fi
        cp -r "$SRC" "$DST"
        ok "Copied $folder"
    done

    # Restore machine-local generated state the repo doesn't carry
    for f in hypr/scripts/quickshell/qs_colors.json hypr/scripts/quickshell/calendar/.env; do
        [ -f "$BACKUP_DIR/$f" ] && { mkdir -p "$(dirname "$TARGET_CONFIG_DIR/$f")"; cp "$BACKUP_DIR/$f" "$TARGET_CONFIG_DIR/$f"; }
    done
fi

# ── settings.json SSoT merge ──────────────────────────────────────────────────
info "Building settings.json (single source of truth)..."
SETTINGS_FILE="$HYPR_DIR/settings.json"
UPSTREAM_JSON="$HYPR_DIR/default_settings.json"
OLD_JSON="$UPSTREAM_JSON"
[ -f "$BACKUP_DIR/hypr/settings.json" ] && jq -e . "$BACKUP_DIR/hypr/settings.json" >/dev/null 2>&1 && OLD_JSON="$BACKUP_DIR/hypr/settings.json"
[ "$MODE" = "inplace" ] && [ -f "$SETTINGS_FILE" ] && jq -e . "$SETTINGS_FILE" >/dev/null 2>&1 && OLD_JSON="$SETTINGS_FILE"

if [ -f "$UPSTREAM_JSON" ]; then
    _tmp=$(mktemp)
    jq -n --slurpfile local "$OLD_JSON" --slurpfile up "$UPSTREAM_JSON" \
       --arg langs "$KB_LAYOUTS" --arg wpdir "$WALLPAPER_DIR" '
       $up[0] as $u |
       (if ($local | length > 0) then $local[0] else $u end) as $l |
       ($u + $l) |
       .language = $langs |
       .wallpaperDir = $wpdir |
       .keybinds = (
           ($l.keybinds // [] | map(((.mods // "") + "|" + (.key // "")))) as $lk |
           ($l.keybinds // [] | map(.command)) as $lc |
           (($u.keybinds // []) | map(select(
               (((.mods // "") + "|" + (.key // "")) as $k | ($lk | index($k)) == null) and
               (.command as $c | ($lc | index($c)) == null)))) as $new |
           (($l.keybinds // []) + $new)) |
       .startup = (
           ($l.startup // [] | map(.command)) as $ls |
           (($u.startup // []) | map(select(.command as $c | ($ls | index($c)) == null))) as $new |
           (($l.startup // []) + $new))
    ' > "$_tmp" && mv "$_tmp" "$SETTINGS_FILE"
    ok "settings.json merged"
else
    warn "default_settings.json missing — skipped SSoT merge"
fi

# ── Secrets & config.json ─────────────────────────────────────────────────────
info "Seeding service config (secrets live in the keyring, never in files)..."
if [ ! -f "$HYPR_DIR/config.json" ]; then
    if [ -f "$HYPR_DIR/config.json.example" ]; then
        cp "$HYPR_DIR/config.json.example" "$HYPR_DIR/config.json"
    else
        echo '{}' > "$HYPR_DIR/config.json"
    fi
    chmod 600 "$HYPR_DIR/config.json"
    ok "Created config.json from example (fill non-secret URLs as needed)"
else
    ok "config.json already present — left untouched"
fi
echo -e "  ${DIM}Store API tokens with: $HYPR_DIR/scripts/secrets.sh set <key> <value>${RESET}"
echo -e "  ${DIM}List known keys with:  $HYPR_DIR/scripts/secrets.sh list${RESET}"

# Weather (calendar widget) — optional
ENV_FILE="$HYPR_DIR/scripts/quickshell/calendar/.env"
if [ ! -f "$ENV_FILE" ] && ask "Configure OpenWeather API key for the calendar widget now?" n; then
    read -r -p "  API key: " _wk; read -r -p "  City ID: " _wc
    read -r -p "  Unit (metric/imperial) [metric]: " _wu; _wu="${_wu:-metric}"
    mkdir -p "$(dirname "$ENV_FILE")"
    printf 'OPENWEATHER_KEY=%s\nOPENWEATHER_CITY_ID=%s\nOPENWEATHER_UNIT=%s\n' "$_wk" "$_wc" "$_wu" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ok "Weather .env written (0600)"
fi

# ── Fonts ─────────────────────────────────────────────────────────────────────
info "Installing fonts..."
FONTS_DIR="$HOME/.local/share/fonts"; mkdir -p "$FONTS_DIR"
[ "$MODE" = "repo" ] && [ -d "$SRC_LOCAL/share/fonts" ] && cp -r "$SRC_LOCAL/share/fonts/." "$FONTS_DIR/" 2>/dev/null || true

if ! fc-list 2>/dev/null | grep -qi "Iosevka Nerd Font"; then
    info "Downloading Iosevka Nerd Font..."
    mkdir -p /tmp/iosevka-pack "$FONTS_DIR/IosevkaNerdFont"
    if curl -fLo /tmp/iosevka-pack/Iosevka.zip https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Iosevka.zip; then
        unzip -q -o /tmp/iosevka-pack/Iosevka.zip -d /tmp/iosevka-pack/
        mv /tmp/iosevka-pack/*.ttf "$FONTS_DIR/IosevkaNerdFont/" 2>/dev/null || true
    else
        warn "Iosevka download failed — install ttf-iosevka-nerd manually"
    fi
    rm -rf /tmp/iosevka-pack
fi
if ! fc-list 2>/dev/null | grep -qi "JetBrainsMono"; then
    $PKG_MANAGER ttf-jetbrains-mono >/dev/null 2>&1 || warn "JetBrains Mono not installed"
fi
if ! fc-list 2>/dev/null | grep -qiE '\bInter\b'; then
    $PKG_MANAGER inter-font >/dev/null 2>&1 || warn "Inter not installed"
fi
fc-cache -f "$FONTS_DIR" >/dev/null 2>&1 && ok "Font cache updated"

# ── Desktop defaults: Dolphin + kitty-as-terminal ─────────────────────────────
info "Setting file manager defaults..."
xdg-mime default org.kde.dolphin.desktop inode/directory 2>/dev/null || true
# Dolphin's "Open Terminal" (Shift+F4 / context menu) -> kitty. The embedded
# F4 terminal panel is a Konsole KPart and only exists if konsole is installed.
python3 - <<'PYEOF' 2>/dev/null || true
import configparser, os
p = os.path.expanduser("~/.config/kdeglobals")
c = configparser.ConfigParser(); c.optionxform = str
c.read(p)
if "General" not in c: c["General"] = {}
c["General"]["TerminalApplication"] = "kitty"
c["General"]["TerminalService"] = "kitty.desktop"
with open(p, "w") as f: c.write(f, space_around_delimiters=False)
PYEOF
ok "Dolphin handles directories; kitty is its external terminal"

# ── GTK / Qt theming (matugen-driven) ─────────────────────────────────────────
info "Configuring GTK/Qt theming..."
gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null || true
gsettings set org.gnome.desktop.interface gtk-theme 'adw-gtk3-dark' 2>/dev/null || true
mkdir -p "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-4.0" \
         "$HOME/.config/qt5ct/colors" "$HOME/.config/qt5ct/qss" \
         "$HOME/.config/qt6ct/colors" "$HOME/.config/qt6ct/qss"
echo '@import url("file://'"$HOME"'/.cache/matugen/colors-gtk.css");' > "$HOME/.config/gtk-3.0/gtk.css"
echo '@import url("file://'"$HOME"'/.cache/matugen/colors-gtk.css");' > "$HOME/.config/gtk-4.0/gtk.css"
printf '[Settings]\ngtk-application-prefer-dark-theme=1\ngtk-theme-name=adw-gtk3-dark\n' > "$HOME/.config/gtk-3.0/settings.ini"
printf '[Settings]\ngtk-application-prefer-dark-theme=1\n' > "$HOME/.config/gtk-4.0/settings.ini"
for v in qt5ct qt6ct; do
cat > "$HOME/.config/$v/$v.conf" <<EOF
[Appearance]
color_scheme_path=$HOME/.config/$v/colors/matugen.conf
custom_palette=true
standard_dialogs=default
style=Fusion
stylesheets=$HOME/.config/$v/qss/matugen-style.qss

[Interface]
stylesheets=$HOME/.config/$v/qss/matugen-style.qss
EOF
done
ok "matugen GTK & Qt hooks written"

# ── Native builds ─────────────────────────────────────────────────────────────
info "Building native components..."
OBS_BUILD="$HYPR_DIR/scripts/quickshell/floating/obsidian-shell/build.sh"
if [ -f "$OBS_BUILD" ]; then
    if bash "$OBS_BUILD" >/tmp/obsidian-shell-build.log 2>&1; then ok "obsidian-shell built"
    else fail "obsidian-shell build FAILED (see /tmp/obsidian-shell-build.log)"; FAILED_PKGS+=("obsidian-shell(build)"); fi
fi
PIP_BUILD="$HYPR_DIR/scripts/quickshell/pip/mpvplugin/build.sh"
if [ -f "$PIP_BUILD" ]; then
    if bash "$PIP_BUILD" >/tmp/mpvplugin-build.log 2>&1; then ok "pip mpvplugin built"
    else fail "mpvplugin build FAILED (see /tmp/mpvplugin-build.log)"; FAILED_PKGS+=("mpvplugin(build)"); fi
fi

# hyprbars plugin via hyprpm (float-mode title bars)
if command -v hyprpm &>/dev/null; then
    info "Installing hyprbars plugin (hyprpm)..."
    hyprpm update >/dev/null 2>&1 || true
    hyprpm list 2>/dev/null | grep -q hyprbars || hyprpm add https://github.com/hyprwm/hyprland-plugins >/dev/null 2>&1 || true
    if hyprpm enable hyprbars >/dev/null 2>&1; then ok "hyprbars enabled"
    else warn "hyprbars not enabled — run 'hyprpm update && hyprpm enable hyprbars' inside a Hyprland session"; fi
fi

# mov-cli (movies/tv provider for the video CLI) as a uv tool
if command -v uv &>/dev/null && ! command -v mov-cli &>/dev/null; then
    uv tool install mov-cli >/dev/null 2>&1 && ok "mov-cli installed (uv tool)" || warn "mov-cli install failed (optional)"
fi

# ── Wallpapers ────────────────────────────────────────────────────────────────
mkdir -p "$WALLPAPER_DIR"
if $OPT_WALLPAPERS && ! ls "$WALLPAPER_DIR" 2>/dev/null | grep -qiE '\.(jpg|png|jpeg|gif|webp)$'; then
    info "Downloading starter wallpapers..."
    git clone --depth 1 https://github.com/ilyamiro/shell-wallpapers.git /tmp/shell-wallpapers 2>/dev/null \
        && cp -r /tmp/shell-wallpapers/images/. "$WALLPAPER_DIR/" 2>/dev/null \
        && ok "Wallpapers installed to $WALLPAPER_DIR"
    rm -rf /tmp/shell-wallpapers
fi

# ── Services ──────────────────────────────────────────────────────────────────
info "Enabling services..."
sudo systemctl enable NetworkManager.service >/dev/null 2>&1 && ok "NetworkManager"
sudo systemctl enable bluetooth.service >/dev/null 2>&1 && ok "bluetooth"
sudo systemctl enable --now power-profiles-daemon.service >/dev/null 2>&1 && ok "power-profiles-daemon"
sudo systemctl enable --now swayosd-libinput-backend.service >/dev/null 2>&1 && ok "swayosd libinput backend"
systemctl --user enable easyeffects.service >/dev/null 2>&1 || true
sudo systemctl --global enable pipewire wireplumber pipewire-pulse >/dev/null 2>&1 || true

# KWallet Secret Service: ksecretd does NOT claim org.freedesktop.secrets
# unless kwalletrc enables the API, and kwallet ships no D-Bus activation
# file for that name — both must be provided or secrets.sh talks to nobody.
info "Enabling KWallet's Secret Service (ksecretd)..."
if ! grep -q 'apiEnabled=true' "$HOME/.config/kwalletrc" 2>/dev/null; then
    printf '[Wallet]\nEnabled=true\n\n[org.freedesktop.secrets]\napiEnabled=true\n' >> "$HOME/.config/kwalletrc"
fi
mkdir -p "$HOME/.local/share/dbus-1/services"
printf '[D-BUS Service]\nName=org.freedesktop.secrets\nExec=/usr/bin/ksecretd\n' \
    > "$HOME/.local/share/dbus-1/services/org.freedesktop.secrets.service"
ok "KWallet (ksecretd) will serve org.freedesktop.secrets"

# If gnome-keyring is also installed (e.g. as a github-desktop dependency),
# stop it from claiming the Secret Service.
if pacman -Q gnome-keyring &>/dev/null; then
    info "gnome-keyring present — stopping it from claiming the Secret Service..."
    mkdir -p "$HOME/.config/autostart"
    for f in gnome-keyring-secrets gnome-keyring-pkcs11; do
        printf '[Desktop Entry]\nType=Application\nName=%s\nHidden=true\n' "$f" > "$HOME/.config/autostart/$f.desktop"
    done
    systemctl --user mask gnome-keyring-daemon.service gnome-keyring-daemon.socket >/dev/null 2>&1 || true
    warn "Also remove the pam_gnome_keyring lines from /etc/pam.d/sddm (needs root)."
    ok "KWallet (ksecretd) is the Secret Service provider"
fi
if $OPT_CONTAINERS; then
    systemctl --user enable podman.socket >/dev/null 2>&1 && ok "podman user socket"
fi
if $OPT_STREAMING; then
    sudo systemctl enable --now tailscaled >/dev/null 2>&1 && ok "tailscaled (run 'sudo tailscale up' to auth)"
    warn "Apollo: enable its user service after first login; fence ports to the"
    warn "tailnet (ufw: allow in on tailscale0) before exposing the web UI."
fi
if $OPT_SDDM; then
    sudo systemctl enable sddm.service >/dev/null 2>&1 && ok "sddm enabled (pick the 'Hyprland (uwsm)' session)"
fi

# ── Hermes AI gateway ─────────────────────────────────────────────────────────
# Provisions the gateway service + autobrowse MCP container we built, with every
# secret generated FRESH on this machine (nothing secret ships in the repo).
if $OPT_HERMES; then
    info "Provisioning Hermes gateway (secrets generated per-machine)..."
    PROV="$HYPR_DIR/provisioning/hermes"
    if [ ! -d "$PROV" ]; then
        warn "provisioning/hermes missing — skipping Hermes."
    elif ! command -v hermes >/dev/null 2>&1 && [ ! -x /usr/local/lib/hermes-agent/venv/bin/hermes ]; then
        warn "Hermes agent not installed (expected at /usr/local/lib/hermes-agent)."
        warn "Install Hermes first, then re-run with the Hermes option — the units"
        warn "and generated secrets below are written regardless so it's ready."
    fi

    if [ -d "$PROV" ]; then
        gen() { openssl rand -hex "${1:-24}" 2>/dev/null || head -c "${1:-24}" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
        API_KEY="$(gen 24)"          # gateway API key == widget hermes_token
        AB_TOKEN="$(gen 24)"         # autobrowse AUTH_TOKEN == MCP_AUTOBROWSE_API_KEY
        TZ_VAL="$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"

        # 1) autobrowse quadlet (generated token)
        mkdir -p "$HOME/.config/containers/systemd"
        sed -e "s|__AUTOBROWSE_TOKEN__|$AB_TOKEN|g" -e "s|__TZ__|$TZ_VAL|g" \
            "$PROV/autobrowse.container.in" > "$HOME/.config/containers/systemd/autobrowse.container"

        # 2) gateway service (paths baked to this $HOME)
        sed -e "s|__HOME__|$HOME|g" \
            "$PROV/hermes-gateway.service.in" > "$HOME/.config/systemd/user/hermes-gateway.service"

        # 3) ~/.hermes/.env — non-secret template + generated secrets appended
        mkdir -p "$HOME/.hermes"
        {
            cat "$PROV/env.template"
            echo ""
            echo "# ── generated per-machine $(date +%F) — DO NOT COMMIT ──"
            echo "API_SERVER_KEY=$API_KEY"
            echo "MCP_AUTOBROWSE_API_KEY=$AB_TOKEN"
        } > "$HOME/.hermes/.env"
        chmod 600 "$HOME/.hermes/.env"

        # 4) widgets authenticate with the SAME key — store it in the keyring
        if command -v secret-tool >/dev/null 2>&1; then
            printf '%s' "$API_KEY" | secret-tool store --label="qs:hermes_token" service qs-hypr key hermes_token 2>/dev/null \
                && ok "hermes_token stored in keyring (matches API_SERVER_KEY)"
        fi

        systemctl --user daemon-reload 2>/dev/null || true
        systemctl --user enable autobrowse.service hermes-gateway.service >/dev/null 2>&1 || true
        ok "Hermes gateway + autobrowse provisioned (fresh secrets); starts on next login"
    fi
fi

# ── App accounts (one shared password) + API keys ─────────────────────────────
# Give Dify/Kavita a single admin password (prompted once, kept only in the
# keyring) and auto-mint their API keys into the keyring the widgets/bridge read.
# Runs against the just-started containers; harmless to re-run (idempotent).
if $OPT_ACCOUNTS; then
    ACCT="$HYPR_DIR/provisioning/accounts/provision-accounts.sh"
    if [ -x "$ACCT" ]; then
        info "Provisioning app accounts + API keys (waiting for services to answer)..."
        # give the freshly-started dify/kavita containers a moment to bind
        for svc in "http://127.0.0.1:5000/api/health" "http://127.0.0.1:8090/console/api/setup"; do
            for _ in $(seq 1 30); do curl -sf -m3 "$svc" >/dev/null 2>&1 && break; sleep 2; done
        done
        bash "$ACCT" || warn "Account provisioning had issues — re-run: $ACCT"
    else
        warn "provisioning/accounts/provision-accounts.sh missing — skipping account setup."
    fi
fi

# ── Compile templated configs ─────────────────────────────────────────────────
if [ -f "$HYPR_DIR/scripts/settings_watcher.sh" ]; then
    info "Compiling .conf files from templates..."
    chmod +x "$HYPR_DIR/scripts/settings_watcher.sh"
    bash "$HYPR_DIR/scripts/settings_watcher.sh" --compile && ok "Templates compiled"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${C_GREEN}Install complete.${RESET}\n"
if [ ${#FAILED_PKGS[@]} -ne 0 ]; then
    echo -e "${BOLD}${C_RED}These items failed — fix manually:${RESET}"
    for fp in "${FAILED_PKGS[@]}"; do echo -e "  - ${C_YELLOW}$fp${RESET}"; done
    echo
fi
[ -d "$BACKUP_DIR" ] && echo -e "Old configs backed up to: ${C_CYAN}$BACKUP_DIR${RESET}"
cat <<'EON'

Next steps:
  1. Log out, then start the session with uwsm:  TTY -> `uwsm start hyprland.desktop`
     (or via SDDM's "Hyprland (uwsm)" entry if you enabled it).
  2. Store your API tokens in the keyring:
       ~/.config/hypr/scripts/secrets.sh set <key> <value>
     (`secrets.sh list` shows every key the widgets look for. Files never
      hold secret values — config.json carries only URLs/paths.)
  3. Optional stacks (containers, AI services, Apollo streaming) have their
     own systemd user units — enable the ones you deploy.
EON
