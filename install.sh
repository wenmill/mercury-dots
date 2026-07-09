#!/usr/bin/env bash

# ==============================================================================
# mercury-dots — Hyprland + Quickshell DE installer
#
# Layout/structure adapted from wenmill/imperative-dots install.sh (itself
# derived from ilyamiro/imperative-dots), rebuilt for this DE. Changes vs that
# base:
#   - No telemetry (kept from the base's own de-telemetry rework)
#   - Package set replaced with a scan of everything THIS shell actually
#     invokes (QML exec sites, scripts, hypr configs) — not a pacman -Qqe dump
#   - Dual run modes: repo (deploy configs + provision) / in-place (provision
#     only, for a machine that already carries the configs)
#   - Native builds: obsidian-shell (layer-shell + WebEngine), pip mpvplugin,
#     hyprbars via hyprpm
#   - Keyring-first secrets: KWallet ksecretd serves org.freedesktop.secrets,
#     secrets.sh stores every token; config files never hold secret values
#   - New optional stacks: app containers (podman quadlets), one-password app
#     account provisioning, Hermes gateway (per-machine generated secrets),
#     gluetun VPN egress for the movies/tv/anime scrapers, game streaming
#     (tailscale + Apollo), Steam
#   - screenpipe section removed (retired upstream of this DE; the bundled
#     hermes-vision service replaces it)
# ==============================================================================

# ==============================================================================
# Script Versioning & Initialization
# ==============================================================================
DOTS_VERSION="3.0.0-mercury"
VERSION_FILE="$HOME/.local/state/mercury-dots-version"

# ==============================================================================
# Terminal UI Colors & Formatting
# ==============================================================================
RESET="\e[0m"
BOLD="\e[1m"
DIM="\e[2m"
C_BLUE="\e[34m"
C_CYAN="\e[36m"
C_GREEN="\e[32m"
C_YELLOW="\e[33m"
C_RED="\e[31m"
C_MAGENTA="\e[35m"

# ==============================================================================
# Early Distro Detection
# ==============================================================================
if [ -f /etc/os-release ]; then
    DETECTED_OS=$(awk -F= '/^ID=/{gsub(/"/, "", $2); print $2}' /etc/os-release)
else
    echo -e "${C_RED}Cannot detect OS. /etc/os-release not found.${RESET}"
    exit 1
fi

case "$DETECTED_OS" in
    arch|endeavouros|manjaro|cachyos|parch|garuda)
        OS="$DETECTED_OS"
        ;;
    *)
        echo -e "${C_RED}Unsupported OS ($DETECTED_OS). This script supports Arch and derivatives only.${RESET}"
        exit 1
        ;;
esac

# Refuse to run as root — installs go to $HOME
if [ "$(id -u)" -eq 0 ]; then
    echo -e "${C_RED}Don't run as root. The script installs to your normal user's \$HOME.${RESET}"
    exit 1
fi

# Prevent the TTY from sleeping during long builds
setterm -blank 0 -powerdown 0 2>/dev/null || true
printf '\033[9;0]' 2>/dev/null || true

# ==============================================================================
# Global Variables & Initial States
# ==============================================================================
USER_PICTURES_DIR=""

if [ -f "$HOME/.config/user-dirs.dirs" ]; then
    USER_PICTURES_DIR=$(grep '^XDG_PICTURES_DIR' "$HOME/.config/user-dirs.dirs" | cut -d= -f2 | tr -d '"' | sed "s|\$HOME|$HOME|g")
fi
[[ -z "$USER_PICTURES_DIR" || "$USER_PICTURES_DIR" == "$HOME" ]] && USER_PICTURES_DIR="$(xdg-user-dir PICTURES 2>/dev/null)"
[[ -z "$USER_PICTURES_DIR" || "$USER_PICTURES_DIR" == "$HOME" ]] && USER_PICTURES_DIR="$HOME/Pictures"
USER_PICTURES_DIR="${USER_PICTURES_DIR%/}"

WALLPAPER_DIR="$USER_PICTURES_DIR/Wallpapers"
WEATHER_API_KEY=""
WEATHER_CITY_ID=""
WEATHER_UNIT=""
FAILED_PKGS=()

HEADLESS=false

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --headless) HEADLESS=true; shift ;;
        *) shift ;;
    esac
done

if [[ "$HEADLESS" == "true" ]]; then
    echo -e "${C_YELLOW}[!] HEADLESS MODE — interactive prompts will use defaults${RESET}"
fi

# Optional stacks (toggled in the options menu)
OPT_SDDM=false
OPT_ZSH=false
OPT_WALLPAPERS=false
OPT_AI=false            # inference (Ollama / vLLM-TurboQuant) + SearXNG + Honcho
OPT_HERMES=false        # Hermes agent + gateway + autobrowse MCP (implies containers)
OPT_CONTAINERS=false    # podman + app quadlets (Kavita) + gluetun VPN scaffolding
OPT_ACCOUNTS=false      # one-password app account provisioning (Dify/Kavita)
OPT_STREAMING=false     # tailscale + Apollo game streaming
OPT_STEAM=false
OPT_VPN=false           # gluetun egress for the movies/tv/anime scrapers
OPT_OVERRIDE_KEYBINDS=false
OPT_OVERRIDE_STARTUPS=false

INSTALL_ZSH=false
INSTALL_SDDM=false
REPLACE_DM=false
SETUP_SDDM_THEME=false
SDDM_WAYLAND=false

DRIVER_CHOICE="None (Skipped)"
DRIVER_PKGS=()
HAS_NVIDIA_PROPRIETARY=false
KEEP_OLD_ENV=true

VISITED_PKGS=false
VISITED_OVERVIEW=false
VISITED_WEATHER=false
VISITED_DRIVERS=false
VISITED_KEYBOARD=false

KB_LAYOUTS="us"
KB_LAYOUTS_DISPLAY="English (US)"
KB_OPTIONS="grp:alt_shift_toggle"

mkdir -p "$(dirname "$VERSION_FILE")"

if [ -f "$VERSION_FILE" ] && [ -s "$VERSION_FILE" ]; then
    source "$VERSION_FILE"
    if [ -n "${LOCAL_VERSION:-}" ] && [ "$LOCAL_VERSION" != "Not Installed" ]; then
        [ -n "$KB_LAYOUTS" ] && VISITED_KEYBOARD=true
        [ -n "$WEATHER_API_KEY" ] && VISITED_WEATHER=true
        [[ "$DRIVER_CHOICE" != "None (Skipped)" && -n "$DRIVER_CHOICE" ]] && VISITED_DRIVERS=true
    fi
else
    LOCAL_VERSION="Not Installed"
fi

# ==============================================================================
# Package list — pacman + AUR mixed (the AUR helper handles both).
# Curated from a scan of every binary the DE's QML/scripts/configs invoke.
# The correct Ollama variant (ollama / ollama-cuda) is appended dynamically
# after GPU detection when OPT_AI=true; optional stacks append theirs too.
# ==============================================================================
ARCH_PKGS=(
    # Core compositor + portals + session management
    "hyprland" "hypridle" "uwsm" "hyprpolkitagent"
    "xdg-desktop-portal-hyprland" "xdg-desktop-portal-gtk" "xdg-user-dirs"
    "qt5-wayland" "qt6-wayland" "qt5ct" "qt6ct"
    "qt6-multimedia" "qt6-5compat" "qt6-websockets"
    "qt5-quickcontrols" "qt5-quickcontrols2" "qt5-graphicaleffects"
    # libxcb + xcb-util-cursor: Qt's xcb fallback probes these at startup even
    # under QT_QPA_PLATFORM=wayland; missing deps crash some Qt apps.
    "libxcb" "xcb-util-cursor"
    # Audio
    "pipewire" "wireplumber" "pipewire-pulse" "pipewire-alsa" "pipewire-jack" "libpulse"
    "pavucontrol" "alsa-utils" "pamixer" "easyeffects" "lsp-plugins" "playerctl"
    # Network / bluetooth
    "networkmanager" "bluez" "bluez-utils" "iw"
    # Terminal + core widget tools
    "kitty" "cava" "fastfetch" "dolphin"
    "jq" "socat" "inotify-tools" "fd" "ripgrep" "bc" "acpi" "lm_sensors" "psmisc"
    "file" "wget" "git" "unzip" "fzf"
    "wl-clipboard" "cliphist" "libnotify" "brightnessctl" "power-profiles-daemon" "fcitx5"
    # Screenshot / recording / QR
    "grim" "slurp" "satty" "zbar"
    # Folder chooser for "download to…" (right-click a ⭳ button). kdialog is
    # preferred when present; zenity is the portable fallback.
    "zenity"
    # Media pipeline (movies widget video CLI, pip player, wallpapers)
    "mpv" "mpvpaper" "ffmpeg" "yt-dlp" "imagemagick" "poppler"
    # Python + the Element/Matrix overlay host
    "python" "python-websockets" "python-pyqt6" "python-pyqt6-webengine"
    # Secrets: secrets.sh -> org.freedesktop.secrets, served by KWallet's
    # ksecretd; kwallet-pam auto-unlocks the wallet at login.
    "libsecret" "kwallet" "kwallet-pam"
    # Native builds: obsidian-shell (layer-shell+WebEngine), pip mpvplugin, hyprpm
    "cmake" "ninja" "meson" "cpio" "pkgconf" "base-devel"
    "layer-shell-qt" "qt6-webengine" "mpvqt"
    # System-maintenance "update" button in the battery popup:
    #   pacman-contrib -> checkupdates + paccache; arch-audit -> CVE check
    "pacman-contrib" "arch-audit" "bat"
    # AI stack prerequisites (harmless without the stack)
    "python-pip" "nodejs" "npm" "openssl"
    # Theming
    "adw-gtk-theme"
    # Required for the SDDM Astronaut theme
    "qt6-svg" "qt6-declarative" "qt6-virtualkeyboard"
    # Fonts not shipped in the repo
    "noto-fonts-cjk"
    # AUR
    "quickshell-git" "matugen-bin" "swayosd-git" "awww"
    # Streaming backends for the movies widget's video CLI: lobster (movies/TV)
    # + ani-cli (anime). Torrentio (addon + debrid) needs no package.
    "wl-screenrec" "gpu-screen-recorder" "ani-cli" "lobster-git"
)

PKGS=("${ARCH_PKGS[@]}")

# ==============================================================================
# TUI bootstrap
# ==============================================================================
if ! command -v fzf &> /dev/null || ! command -v lspci &> /dev/null || ! command -v jq &> /dev/null || ! command -v curl &> /dev/null; then
    echo -e "${C_CYAN}Bootstrapping TUI dependencies (fzf, pciutils, jq, curl)...${RESET}"
    sudo pacman -Sy --noconfirm --needed fzf pciutils jq curl > /dev/null 2>&1
fi

if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
    echo -e "${C_CYAN}Enabling multilib repository for 32-bit driver support...${RESET}"
    sudo sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' /etc/pacman.conf
fi

# --- CRITICAL: Full system upgrade BEFORE any package install ---
# Arch is rolling; AUR packages built against newer libraries WILL fail on a
# partially-upgraded system ("installing libelf (X) breaks dependency ...").
# Done AFTER enabling multilib so the upgrade pulls both repos in lockstep.
echo -e "${C_CYAN}Performing full system upgrade (required before AUR installs)...${RESET}"
echo -e "${DIM}  This may take a while on stale systems. Skipping this step on Arch${RESET}"
echo -e "${DIM}  causes 'libelf breaks dependency' / 'partial upgrade' failures later.${RESET}"

if ! sudo pacman -Syu --noconfirm; then
    echo -e "${C_RED}Full system upgrade failed.${RESET}"
    echo -e "${C_YELLOW}Common causes:${RESET}"
    echo -e "  1. Stale pacman mirrors — try: ${BOLD}sudo pacman-mirrors --fasttrack${RESET}"
    echo -e "  2. Keyring out of date — try: ${BOLD}sudo pacman -S archlinux-keyring && sudo pacman -Syu${RESET}"
    echo -e "  3. Kernel was updated and modules are mid-rebuild — reboot and retry"
    echo -e "  4. Disk space — ${BOLD}df -h /var/cache/pacman/pkg /${RESET}"
    echo -e "${C_YELLOW}Re-run this script after fixing.${RESET}"
    exit 1
fi

sudo pacman -S --noconfirm --needed archlinux-keyring > /dev/null 2>&1 || true

# AUR helper: paru (Rust). Sanity-check the PKGBUILD before building it.
if ! command -v paru &> /dev/null; then
    echo -e "${C_CYAN}Installing 'paru' (AUR helper, Rust-based)...${RESET}"
    sudo pacman -S --noconfirm --needed base-devel git rust
    tmpdir=$(mktemp -d)
    git clone https://aur.archlinux.org/paru.git "$tmpdir/paru" > /dev/null 2>&1

    if ! grep -q '^pkgname=paru$' "$tmpdir/paru/PKGBUILD" 2>/dev/null; then
        rm -rf "$tmpdir"
        echo -e "${C_RED}paru PKGBUILD doesn't look right. Refusing to build.${RESET}"
        exit 1
    fi

    (cd "$tmpdir/paru" && makepkg -si --noconfirm > /dev/null 2>&1)
    rm -rf "$tmpdir"
fi

if command -v paru &> /dev/null; then
    # --sudoloop keeps sudo alive during long AUR builds; --skipreview skips
    # the PKGBUILD prompt (paru itself was sanity-checked above).
    PKG_MANAGER="paru -S --noconfirm --needed --sudoloop"
else
    PKG_MANAGER="sudo pacman -S --noconfirm --needed"
fi

# ==============================================================================
# Run-mode detection
#   repo mode     — script sits in the dotfiles repo with .config/ next to it:
#                   deploys configs (with backup), then provisions.
#   in-place mode — script sits inside ~/.config/hypr on a machine that
#                   already carries the configs: provisions only.
# ==============================================================================
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ -d "$SCRIPT_DIR/.config/hypr" ]; then
    MODE="repo"
    REPO_DIR="$SCRIPT_DIR"
elif [ -d "$SCRIPT_DIR/scripts/quickshell" ]; then
    MODE="inplace"
    REPO_DIR=""
else
    echo -e "${C_RED}Can't find the DE configs relative to this script.${RESET}"
    echo "Run it from the cloned repo root, or from ~/.config/hypr."
    exit 1
fi

TARGET_CONFIG_DIR="$HOME/.config"
HYPR_DIR="$TARGET_CONFIG_DIR/hypr"

# ==============================================================================
# Hardware detection
# ==============================================================================
USER_NAME=$USER
OS_NAME=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
CPU_INFO=$(grep -m 1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)

GPU_RAW=$(lspci -nn | grep -iE 'vga|3d|display')
GPU_INFO=$(echo "$GPU_RAW" | cut -d: -f3 | sed -E 's/ \(rev [0-9a-f]+\)//g' | xargs)
[[ -z "$GPU_INFO" ]] && GPU_INFO="Unknown / Virtual Machine"

GPU_VENDOR="Unknown / Generic VM"
if echo "$GPU_INFO" | grep -qi "nvidia"; then
    GPU_VENDOR="NVIDIA"
elif echo "$GPU_INFO" | grep -qi "amd\|radeon\|navi"; then
    GPU_VENDOR="AMD"
elif echo "$GPU_INFO" | grep -qi "intel"; then
    GPU_VENDOR="INTEL"
elif echo "$GPU_INFO" | grep -qi "vmware\|virtualbox\|qxl\|virtio\|bochs"; then
    GPU_VENDOR="VM"
fi

# ==============================================================================
# Select inference backend based on GPU vendor.
#   ollama-cuda               — NVIDIA
#   ollama                    — Intel / VM / unknown (CPU)
#   vLLM-TurboQuant container — AMD (outperforms ollama-rocm on Radeon;
#                               TurboQuant KV-cache ~3-6x effective context)
# ==============================================================================
USE_VLLM_TURBOQUANT=false
OLLAMA_PKG=""
case "$GPU_VENDOR" in
    "NVIDIA") OLLAMA_PKG="ollama-cuda" ;;
    "AMD")    USE_VLLM_TURBOQUANT=true ;;
    "INTEL")  OLLAMA_PKG="ollama" ;;
    *)        OLLAMA_PKG="ollama" ;;
esac

# Respect settings.json (SSoT) from a previous install
EXISTING_SETTINGS="$HYPR_DIR/settings.json"
if [ -f "$EXISTING_SETTINGS" ] && command -v jq &>/dev/null; then
    _sj_lang=$(jq -r 'if has("language") then (.language // "") else "IGNORE_ME" end' "$EXISTING_SETTINGS" 2>/dev/null)
    _sj_kbopt=$(jq -r 'if has("kbOptions") then (.kbOptions // "") else "IGNORE_ME" end' "$EXISTING_SETTINGS" 2>/dev/null)
    _sj_wpdir=$(jq -r 'if has("wallpaperDir") then (.wallpaperDir // "") else "IGNORE_ME" end' "$EXISTING_SETTINGS" 2>/dev/null)

    if [[ "$_sj_lang" != "IGNORE_ME" && -n "$_sj_lang" ]]; then
        KB_LAYOUTS="$_sj_lang"
        [ -z "$KB_LAYOUTS_DISPLAY" ] && KB_LAYOUTS_DISPLAY="$_sj_lang"
        VISITED_KEYBOARD=true
    fi
    [[ "$_sj_kbopt" != "IGNORE_ME" ]] && KB_OPTIONS="$_sj_kbopt"
    if [[ "$_sj_wpdir" != "IGNORE_ME" && -n "$_sj_wpdir" ]]; then
        _sj_wpdir="${_sj_wpdir%/}"
        WALLPAPER_DIR="$_sj_wpdir"
        USER_PICTURES_DIR="$(dirname "$_sj_wpdir")"
    fi
fi

draw_header() {
    clear
    printf "${BOLD}${C_CYAN}"
    cat << "EOF"
 ██╗    ██╗███████╗███╗   ██╗███╗   ███╗██╗██╗
 ██║    ██║██╔════╝████╗  ██║████╗ ████║██║██║
 ██║ █╗ ██║█████╗  ██╔██╗ ██║██╔████╔██║██║██║
 ██║███╗██║██╔══╝  ██║╚██╗██║██║╚██╔╝██║██║██║
 ╚███╔███╔╝███████╗██║ ╚████║██║ ╚═╝ ██║██║███████╗
  ╚══╝╚══╝ ╚══════╝╚═╝  ╚═══╝╚═╝     ╚═╝╚═╝╚══════╝
EOF
    printf "${RESET}\n"

    printf "\033[K${C_BLUE} -----------------------------------------------------------------${RESET}\n"
    printf "\033[K${BOLD} User:           ${RESET} %s\n" "$USER_NAME"
    printf "\033[K${BOLD} OS:             ${RESET} %s\n" "$OS_NAME"
    printf "\033[K${BOLD} CPU:            ${RESET} %s\n" "$CPU_INFO"
    printf "\033[K${BOLD} GPU:            ${RESET} %s ${DIM}(%s)${RESET}\n" "$GPU_INFO" "$GPU_VENDOR"
    printf "\033[K${BOLD} Mode:           ${RESET} %s\n" "$MODE"
    if [ "$USE_VLLM_TURBOQUANT" = true ]; then
        printf "\033[K${BOLD} Inference:      ${RESET} vLLM-TurboQuant (ROCm container)\n"
    else
        printf "\033[K${BOLD} Inference:      ${RESET} Ollama (%s)\n" "$OLLAMA_PKG"
    fi
    printf "\033[K${C_BLUE} -----------------------------------------------------------------${RESET}\n"
    printf "\033[K${BOLD} Server Version: ${RESET} %s\n" "$DOTS_VERSION"
    printf "\033[K${BOLD} Local Version:  ${RESET} %s\n" "${LOCAL_VERSION:-Not Installed}"
    printf "\033[K${C_BLUE} =================================================================${RESET}\n\n"
}

manage_packages() {
    while true; do
        draw_header
        local action
        action=$(echo -e "1. View Packages to be Installed\n2. Add Custom Packages\n3. Back to Main Menu" | fzf \
            --layout=reverse --border=rounded --margin=1,2 --height=15 \
            --prompt=" Package Manager > " --pointer=">" \
            --header=" Use ARROW KEYS and ENTER ")

        case "$action" in
            *"1"*)
                echo "${PKGS[@]}" | tr ' ' '\n' | fzf \
                    --layout=reverse --border=rounded --margin=1,2 --height=25 \
                    --prompt=" Current Packages > " --pointer=">" \
                    --header=" Press ESC or ENTER to return to menu "
                ;;
            *"2"*)
                echo -e "${C_CYAN}Enter package names (separated by space) ${BOLD}[Empty to cancel]${RESET}${C_CYAN}:${RESET}"
                read -r new_pkgs
                if [ -n "$new_pkgs" ]; then
                    PKGS+=($new_pkgs)
                    echo -e "${C_GREEN}Packages added!${RESET}"
                    sleep 1
                fi
                ;;
            *"3"*) VISITED_PKGS=true; break ;;
            *) VISITED_PKGS=true; break ;;
        esac
    done
}

manage_drivers() {
    while true; do
        draw_header
        echo -e "${BOLD}${C_CYAN}=== Hardware Driver Configuration ===${RESET}"
        echo -e "${BOLD}${C_RED}=================== EXPERIMENTAL WARNING ===================${RESET}"
        echo -e "${C_RED}This automated driver installer is highly experimental and${RESET}"
        echo -e "${C_RED}can be unreliable across different kernel/distro variations.${RESET}"
        echo -e "${C_RED}It is strongly recommended to SKIP this and install your${RESET}"
        echo -e "${C_RED}graphics drivers manually according to your distro's wiki.${RESET}"
        echo -e "${BOLD}${C_RED}============================================================${RESET}\n"
        echo -e "Detected GPU Vendor: ${BOLD}${C_YELLOW}$GPU_VENDOR${RESET}\n"

        # RDNA4 detection (RX 9070, 9060 XT)
        if echo "$GPU_INFO" | grep -qiE "navi 4|rx 90[67]0|rx 9060"; then
            echo -e "${C_YELLOW}[!] RDNA4 (Navi 4x) detected — needs kernel 6.12+ and Mesa 25.0+${RESET}"
            kernel_ver=$(uname -r | cut -d. -f1,2)
            echo -e "${C_YELLOW}[!] Current kernel: $(uname -r)${RESET}"
            if [ "$(printf '%s\n' "6.12" "$kernel_ver" | sort -V | head -1)" != "6.12" ]; then
                echo -e "${C_RED}[!] Kernel may be too old. Consider: sudo pacman -S linux${RESET}"
            fi
            echo
        fi

        local current_driver="None"
        if command -v lsmod &> /dev/null; then
            if lsmod | grep -wq nvidia; then current_driver="nvidia"
            elif lsmod | grep -wq nouveau; then current_driver="nouveau"
            elif lsmod | grep -Ewq "amdgpu|radeon"; then current_driver="amd"
            elif lsmod | grep -Ewq "i915|xe"; then current_driver="intel"
            fi
        fi

        local options=""
        case "$GPU_VENDOR" in
            "NVIDIA")
                if [[ "$current_driver" == "nouveau" ]]; then
                    echo -e "${C_YELLOW}[!] Notice: Open-source 'nouveau' drivers are currently loaded.${RESET}"
                    echo -e "${C_RED}[!] Proprietary installation is locked out to prevent initramfs conflicts.${RESET}\n"
                    options="1. Update/Keep Nouveau (Open Source)\n2. Skip Driver Installation"
                elif [[ "$current_driver" == "nvidia" ]]; then
                    echo -e "${C_YELLOW}[!] Notice: Proprietary 'nvidia' drivers are currently loaded.${RESET}"
                    echo -e "${C_RED}[!] Open-source installation is locked out to prevent conflicts.${RESET}\n"
                    options="1. Update/Keep Proprietary NVIDIA Drivers\n2. Skip Driver Installation"
                else
                    options="1. Install Proprietary NVIDIA Drivers (Recommended for Gaming/Wayland)\n2. Install Nouveau (Open Source, Better VM compat)\n3. Skip Driver Installation"
                fi
                ;;
            "AMD") options="1. Install AMD Mesa & Vulkan Drivers (RADV)\n2. Skip Driver Installation" ;;
            "INTEL") options="1. Install Intel Mesa & Vulkan Drivers (ANV)\n2. Skip Driver Installation" ;;
            *) options="1. Install Generic Mesa Drivers (For VMs / Software Rendering)\n2. Skip Driver Installation" ;;
        esac

        local choice
        choice=$(echo -e "$options\nBack to Main Menu" | fzf \
            --ansi --layout=reverse --border=rounded --margin=1,2 --height=15 \
            --prompt=" Drivers > " --pointer=">" \
            --header=" Select the graphics drivers to install ")

        if [[ "$choice" == *"Back"* ]]; then break; fi

        if [[ "$choice" != *"Skip"* ]]; then
            echo -e "\n${BOLD}${C_RED}=================== ACTION REQUIRED ===================${RESET}"
            echo -e "${C_YELLOW}You have selected to AUTOMATICALLY install/configure drivers.${RESET}"
            echo -e "${C_YELLOW}If your system already has working drivers, this might break boot.${RESET}"
            echo -n -e "Are you ${BOLD}${C_RED}100% sure${RESET} you want to proceed? (y/n): "
            read -r confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo -e "\n${C_RED}Driver setup aborted. Returning to menu...${RESET}"
                sleep 1.2
                continue
            fi
        fi

        DRIVER_PKGS=()
        HAS_NVIDIA_PROPRIETARY=false

        if [[ "$choice" == *"Proprietary NVIDIA"* ]]; then
            DRIVER_CHOICE="NVIDIA Proprietary"
            HAS_NVIDIA_PROPRIETARY=true
            DRIVER_PKGS+=("nvidia-dkms" "nvidia-utils" "lib32-nvidia-utils" "linux-headers" "egl-wayland")
        elif [[ "$choice" == *"Nouveau"* ]]; then
            DRIVER_CHOICE="NVIDIA Nouveau"
            DRIVER_PKGS+=("mesa" "vulkan-nouveau" "lib32-mesa")
        elif [[ "$choice" == *"AMD"* ]]; then
            DRIVER_CHOICE="AMD Drivers"
            DRIVER_PKGS+=("mesa" "vulkan-radeon" "lib32-vulkan-radeon" "lib32-mesa" "libva-mesa-driver" "linux-firmware")
        elif [[ "$choice" == *"Intel"* ]]; then
            DRIVER_CHOICE="Intel Drivers"
            DRIVER_PKGS+=("mesa" "vulkan-intel" "lib32-vulkan-intel" "lib32-mesa" "intel-media-driver")
        elif [[ "$choice" == *"Generic"* ]]; then
            DRIVER_CHOICE="Generic / VM"
            # virglrenderer + libva-mesa = best chance of a working render node
            # inside a VM. Still requires the HOST to enable virtio-gl.
            DRIVER_PKGS+=("mesa" "lib32-mesa" "virglrenderer" "libva-mesa-driver" "mesa-vdpau")
        elif [[ "$choice" == *"Skip"* ]]; then
            DRIVER_CHOICE="Skipped"
            DRIVER_PKGS=()
        fi

        echo -e "\n${C_GREEN}Driver configuration saved!${RESET}"
        sleep 1.2
        VISITED_DRIVERS=true
        break
    done
}

manage_keyboard() {
    local available_layouts=(
        "us - English (US)" "ca - English/French (Canada)" "ca-multix - Canadian Multilingual"
        "latam - Spanish (Latin America)" "br - Portuguese (Brazil)"
        "gb - English (UK)" "ie - English (Ireland)"
        "fr - French" "be - Belgian" "ch - Swiss" "de - German" "at - Austrian"
        "nl - Dutch" "lu - Luxembourgish" "es - Spanish" "pt - Portuguese"
        "it - Italian" "se - Swedish" "no - Norwegian" "dk - Danish" "fi - Finnish"
        "pl - Polish" "cz - Czech" "sk - Slovak" "hu - Hungarian"
        "ru - Russian" "ua - Ukrainian" "by - Belarusian" "ro - Romanian" "bg - Bulgarian"
        "rs - Serbian" "hr - Croatian" "si - Slovenian" "gr - Greek"
        "ee - Estonian" "lv - Latvian" "lt - Lithuanian"
        "cn - Chinese" "jp - Japanese" "kr - Korean" "tw - Taiwanese"
        "in - Indian" "th - Thai" "vn - Vietnamese"
        "il - Hebrew" "ara - Arabic" "ir - Persian (Farsi)"
        "us-intl - US International" "dvorak - US Dvorak" "colemak - US Colemak"
    )

    local selected_codes=()
    local selected_names=()

    if [[ -n "$KB_LAYOUTS" ]]; then
        IFS=',' read -ra tmp_codes <<< "$KB_LAYOUTS"
        for code in "${tmp_codes[@]}"; do selected_codes+=("$(echo "$code" | xargs)"); done
    else
        selected_codes=("us")
    fi
    if [[ -n "$KB_LAYOUTS_DISPLAY" ]]; then
        IFS=',' read -ra tmp_names <<< "$KB_LAYOUTS_DISPLAY"
        for name in "${tmp_names[@]}"; do selected_names+=("$(echo "$name" | xargs)"); done
    else
        selected_names=("English (US)")
    fi

    while true; do
        draw_header
        echo -e "${BOLD}${C_CYAN}=== Keyboard Layout Configuration ===${RESET}\n"

        if [ ${#selected_codes[@]} -gt 0 ]; then
            echo -e "Currently added: ${C_GREEN}$(IFS=', '; echo "${selected_names[*]}")${RESET}\n"
        fi

        local choice
        choice=$(printf "%s\n" "Done (Finish Selection)" "Reset (Clear All Except US)" "${available_layouts[@]}" | fzf \
            --layout=reverse --border=rounded --margin=1,2 --height=20 \
            --prompt=" Add Layout > " --pointer=">" \
            --header=" Select a language to add, or select Done ")

        if [[ -z "$choice" || "$choice" == *"Done"* ]]; then break; fi

        if [[ "$choice" == *"Reset"* ]]; then
            selected_codes=("us")
            selected_names=("English (US)")
            continue
        fi

        local code=$(echo "$choice" | awk '{print $1}')
        local name=$(echo "$choice" | cut -d'-' -f2- | sed 's/^ //')

        local duplicate=false
        for existing in "${selected_codes[@]}"; do
            [[ "$existing" == "$code" ]] && duplicate=true && break
        done
        if [ "$duplicate" = false ]; then
            selected_codes+=("$code")
            selected_names+=("$name")
        fi
    done

    while true; do
        draw_header
        echo -e "${BOLD}${C_CYAN}=== Keyboard Layout Configuration ===${RESET}\n"
        echo -e "Currently added: ${C_GREEN}$(IFS=', '; echo "${selected_names[*]}")${RESET}\n"
        echo -e "${C_CYAN}Choose a key combination to switch between layouts:${RESET}"

        local options="1. Alt + Shift (grp:alt_shift_toggle)\n"
        options+="2. Win + Space (grp:win_space_toggle)\n"
        options+="3. Caps Lock (grp:caps_toggle)\n"
        options+="4. Ctrl + Shift (grp:ctrl_shift_toggle)\n"
        options+="5. Ctrl + Alt (grp:ctrl_alt_toggle)\n"
        options+="6. Right Alt (grp:toggle)\n"
        options+="7. No Toggle (Single Layout)"

        local choice
        choice=$(echo -e "$options" | fzf \
            --ansi --layout=reverse --border=rounded --margin=1,2 --height=15 \
            --prompt=" Toggle Keybind > " --pointer=">" \
            --header=" Select layout switching method ")

        local kb_opt=""
        case "$choice" in
            *"1"*) kb_opt="grp:alt_shift_toggle" ;;
            *"2"*) kb_opt="grp:win_space_toggle" ;;
            *"3"*) kb_opt="grp:caps_toggle" ;;
            *"4"*) kb_opt="grp:ctrl_shift_toggle" ;;
            *"5"*) kb_opt="grp:ctrl_alt_toggle" ;;
            *"6"*) kb_opt="grp:toggle" ;;
            *"7"*) kb_opt="" ;;
            *) kb_opt="grp:alt_shift_toggle" ;;
        esac

        KB_LAYOUTS=$(IFS=','; echo "${selected_codes[*]}")
        KB_LAYOUTS_DISPLAY=$(IFS=', '; echo "${selected_names[*]}")
        KB_OPTIONS="$kb_opt"

        echo -e "\n${C_GREEN}Keyboard configured: Layouts = $KB_LAYOUTS_DISPLAY | Switch = ${KB_OPTIONS:-None}${RESET}"
        sleep 1.5
        VISITED_KEYBOARD=true
        break
    done
}

show_overview() {
    draw_header
    echo -e "${BOLD}${C_MAGENTA}=== System Overview & Keybinds ===${RESET}\n"
    echo -e "Hyprland + Quickshell DE, structured after ${BOLD}${C_CYAN}imperative-dots${RESET}.\n"

    print_kb() {
        printf "  ${C_CYAN}[${RESET} ${BOLD}%-17s${RESET} ${C_CYAN}]${RESET}  ${C_YELLOW}➜${RESET}  %s\n" "$1" "$2"
    }

    echo -e "${BOLD}${C_BLUE}--- Applications ---${RESET}"
    print_kb "SUPER + RETURN" "Terminal (kitty)"
    print_kb "SUPER + F" "Browser"
    print_kb "SUPER + E" "File Manager (dolphin)"
    print_kb "SUPER + D / C" "ToolHub (launcher, clipboard, tools)"
    print_kb "ALT + F4" "Close window (PiP/player-aware)"
    print_kb "SUPER + L" "Lock"
    echo ""
    echo -e "${BOLD}${C_BLUE}--- Quickshell Widgets ---${RESET}"
    print_kb "SUPER + P" "Movies / TV / Anime / YouTube / Music hub"
    print_kb "SUPER + Q" "Music popup"
    print_kb "SUPER + B" "Battery / system maintenance"
    print_kb "SUPER + W" "Wallpaper picker"
    print_kb "SUPER + S" "Calendar + weather"
    print_kb "SUPER + N" "Network / Bluetooth"
    print_kb "SUPER + U" "Character sheet (Life-OS HUD)"
    print_kb "SUPER + O" "Notes (obsidian-shell)"
    print_kb "SUPER + H" "Guide"
    print_kb "SUPER + SHIFT + T" "FocusTime"
    print_kb "SUPER + SHIFT + S" "System Settings"
    echo ""
    echo -e "${BOLD}${C_BLUE}--- AI / Services (optional stacks) ---${RESET}"
    if [ "$USE_VLLM_TURBOQUANT" = true ]; then
        print_kb "vLLM-TurboQuant" "http://localhost:8000 (AMD ROCm container)"
    else
        print_kb "Ollama" "http://localhost:11434 (GPU-aware local models)"
    fi
    print_kb "SearXNG" "http://localhost:8888 (private metasearch, JSON)"
    print_kb "autobrowse" "http://localhost:8080 (Camoufox stealth MCP)"
    print_kb "Honcho" "http://localhost:8000 (Hermes cross-session memory)"
    print_kb "Hermes" "Agent gateway for the widgets"
    print_kb "Kavita" "http://localhost:5000 (reading server)"
    print_kb "secrets.sh" "All tokens live in the keyring, never in files"
    echo ""
    echo -e "${BOLD}${C_GREEN}Press ENTER to return to the Main Menu...${RESET}"
    read -r
    VISITED_OVERVIEW=true
}

set_weather_api() {
    while true; do
        draw_header
        echo -e "${BOLD}${C_CYAN}=== OpenWeatherMap Setup ===${RESET}"

        ENV_FILE="$HYPR_DIR/scripts/quickshell/calendar/.env"

        if [ -f "$ENV_FILE" ] || [[ -n "$WEATHER_API_KEY" && "$WEATHER_API_KEY" != "Skipped" ]]; then
            echo -e "${C_GREEN}Existing config detected. Press ENTER without typing to KEEP it.${RESET}\n"
        else
            echo -e "${C_MAGENTA}Get a free API key at https://openweathermap.org/${RESET}\n"
        fi

        read -p "OpenWeather API Key (or Enter to skip/keep): " input_key

        if [[ -z "$input_key" ]]; then
            if [ -f "$ENV_FILE" ] || [[ -n "$WEATHER_API_KEY" && "$WEATHER_API_KEY" != "Skipped" ]]; then
                KEEP_OLD_ENV=true
                VISITED_WEATHER=true
                break
            else
                WEATHER_API_KEY="Skipped"
                KEEP_OLD_ENV=false
                VISITED_WEATHER=true
                break
            fi
        fi

        WEATHER_API_KEY="$(echo "$input_key" | tr -d ' ')"
        read -p "City ID (number from openweathermap.org URL): " input_id
        if [[ -z "$input_id" || ! "$input_id" =~ ^[0-9]+$ ]]; then
            echo -e "${C_RED}Invalid City ID.${RESET}"
            sleep 1
            continue
        fi
        WEATHER_CITY_ID="$input_id"

        unit_choice=$(echo -e "metric (Celsius)\nimperial (Fahrenheit)\nstandard (Kelvin)" | fzf \
            --layout=reverse --border=rounded --margin=1,2 --height=12 \
            --prompt=" Unit > " --pointer=">" --header=" Choose unit ")
        WEATHER_UNIT=$(echo "$unit_choice" | awk '{print $1}')
        [[ -z "$WEATHER_UNIT" ]] && WEATHER_UNIT="metric"

        KEEP_OLD_ENV=false
        VISITED_WEATHER=true
        break
    done
}

manage_ai_stack() {
    while true; do
        draw_header
        echo -e "${BOLD}${C_CYAN}=== AI Stack Configuration ===${RESET}\n"
        echo -e "Installs and wires together:"
        if [ "$USE_VLLM_TURBOQUANT" = true ]; then
            echo -e "  ${C_GREEN}vLLM-TurboQuant${RESET} — ROCm inference container (port 8000)"
        else
            echo -e "  ${C_GREEN}Ollama${RESET}     — local model server (port 11434, ${BOLD}$OLLAMA_PKG${RESET})"
        fi
        echo -e "  ${C_GREEN}SearXNG${RESET}    — private metasearch, JSON-only (port 8888)"
        echo -e "  ${C_GREEN}Honcho${RESET}     — cross-session memory for Hermes (port 8000)"
        echo -e "\n${DIM}The Hermes gateway + autobrowse MCP are a separate toggle in the"
        echo -e "options menu (they generate per-machine secrets). The retired"
        echo -e "screenpipe recorder is NOT installed — the DE's own hermes-vision"
        echo -e "service covers screen context.${RESET}\n"

        local current="$( [ "$OPT_AI" = true ] && echo -e "${C_GREEN}ENABLED${RESET}" || echo -e "${DIM}DISABLED${RESET}" )"
        echo -e "Current: ${BOLD}$current${RESET}\n"

        local action
        action=$(echo -e "1. Enable AI Stack\n2. Disable AI Stack\n3. Back" | fzf \
            --layout=reverse --border=rounded --margin=1,2 --height=12 \
            --prompt=" AI Stack > " --pointer=">" --header=" ")

        case "$action" in
            *"1"*) OPT_AI=true; break ;;
            *"2"*) OPT_AI=false; break ;;
            *) break ;;
        esac
    done
}

prompt_optional_features_menu() {
    DM_SERVICES=("gdm" "gdm3" "lightdm" "sddm" "lxdm" "lxdm-gtk3" "ly")
    CURRENT_DM=""
    for dm in "${DM_SERVICES[@]}"; do
        if systemctl is-enabled "$dm.service" &>/dev/null || systemctl is-active "$dm.service" &>/dev/null; then
            CURRENT_DM="$dm"
            break
        fi
    done

    local DM_LABEL="Display Manager Integration (SDDM + Astronaut)"
    if [[ "$CURRENT_DM" == "sddm" ]]; then
        DM_LABEL="Configure SDDM Astronaut Theme"
    elif [[ -n "$CURRENT_DM" ]]; then
        DM_LABEL="Replace $CURRENT_DM with SDDM (Astronaut theme)"
    fi

    local HAS_HISTORY=false
    if [ "$LOCAL_VERSION" != "Not Installed" ] && [ -n "$LOCAL_VERSION" ]; then
        HAS_HISTORY=true
    fi

    while true; do
        draw_header
        echo -e "${BOLD}${C_CYAN}=== Optional Component Setup ===${RESET}\n"

        local S_SDDM=$( [ "$OPT_SDDM" = true ] && echo -e "${C_GREEN}[✓]${RESET}" || echo -e "${DIM}[ ]${RESET}" )
        local S_ZSH=$( [ "$OPT_ZSH" = true ] && echo -e "${C_GREEN}[✓]${RESET}" || echo -e "${DIM}[ ]${RESET}" )
        local S_WP=$( [ "$OPT_WALLPAPERS" = true ] && echo -e "${C_GREEN}[✓]${RESET}" || echo -e "${DIM}[ ]${RESET}" )
        local S_AI=$( [ "$OPT_AI" = true ] && echo -e "${C_GREEN}[✓]${RESET}" || echo -e "${DIM}[ ]${RESET}" )
        local S_CT=$( [ "$OPT_CONTAINERS" = true ] && echo -e "${C_GREEN}[✓]${RESET}" || echo -e "${DIM}[ ]${RESET}" )
        local S_HM=$( [ "$OPT_HERMES" = true ] && echo -e "${C_GREEN}[✓]${RESET}" || echo -e "${DIM}[ ]${RESET}" )
        local S_AC=$( [ "$OPT_ACCOUNTS" = true ] && echo -e "${C_GREEN}[✓]${RESET}" || echo -e "${DIM}[ ]${RESET}" )
        local S_ST=$( [ "$OPT_STREAMING" = true ] && echo -e "${C_GREEN}[✓]${RESET}" || echo -e "${DIM}[ ]${RESET}" )
        local S_SG=$( [ "$OPT_STEAM" = true ] && echo -e "${C_GREEN}[✓]${RESET}" || echo -e "${DIM}[ ]${RESET}" )
        local S_VPN=$( [ "$OPT_VPN" = true ] && echo -e "${C_GREEN}[✓]${RESET}" || echo -e "${DIM}[ ]${RESET}" )

        local MENU_ITEMS="1. $S_SDDM $DM_LABEL\n"
        MENU_ITEMS+="2. $S_ZSH Zsh Shell Setup\n"
        MENU_ITEMS+="3. $S_WP Download FULL Wallpaper Pack (Unchecked = 3 Random)\n"
        MENU_ITEMS+="4. $S_AI AI Stack (inference + SearXNG + Honcho)\n"
        MENU_ITEMS+="5. $S_HM Hermes gateway + autobrowse MCP (per-machine secrets)\n"
        MENU_ITEMS+="6. $S_CT App containers (podman: Kavita reading server, quadlets)\n"
        MENU_ITEMS+="7. $S_AC Provision app accounts (one shared password + API keys)\n"
        MENU_ITEMS+="8. $S_VPN VPN egress for movies/tv/anime scrapers (gluetun)\n"
        MENU_ITEMS+="9. $S_ST Game streaming (tailscale + Apollo)\n"
        MENU_ITEMS+="10. $S_SG Steam (games tab launcher)\n"

        if [ "$HAS_HISTORY" = true ]; then
            local S_KB_OVR=$( [ "$OPT_OVERRIDE_KEYBINDS" = true ] && echo -e "${C_GREEN}[✓]${RESET}" || echo -e "${DIM}[ ]${RESET}" )
            local S_STARTUPS_OVR=$( [ "$OPT_OVERRIDE_STARTUPS" = true ] && echo -e "${C_GREEN}[✓]${RESET}" || echo -e "${DIM}[ ]${RESET}" )
            MENU_ITEMS+="11. $S_KB_OVR Reset local keybinds to upstream defaults\n"
            MENU_ITEMS+="12. $S_STARTUPS_OVR Overwrite Local Startups\n"
            MENU_ITEMS+="13. ${BOLD}${C_GREEN}Proceed with Installation / Update${RESET}\n"
            MENU_ITEMS+="14. ${DIM}Back to Main Menu${RESET}"
        else
            OPT_OVERRIDE_KEYBINDS=false
            OPT_OVERRIDE_STARTUPS=false
            MENU_ITEMS+="11. ${BOLD}${C_GREEN}Proceed with Installation / Update${RESET}\n"
            MENU_ITEMS+="12. ${DIM}Back to Main Menu${RESET}"
        fi

        local choice
        choice=$(echo -e "$MENU_ITEMS" | fzf \
            --ansi --layout=reverse --border=rounded --margin=1,2 --height=22 \
            --prompt=" Options > " --pointer=">" \
            --header=" ENTER to toggle. Select Proceed when ready. ")

        local break_and_proceed=false

        # Match on the LEADING number (fzf lines start with "N. ...") — the
        # base's *"1."* substring patterns misfire once the menu passes 9
        # ("11." contains "1.").
        local sel="${choice%%.*}"
        sel="$(echo "$sel" | tr -dc '0-9')"

        case "$sel" in
            1)  OPT_SDDM=$([ "$OPT_SDDM" = true ] && echo false || echo true) ;;
            2)  OPT_ZSH=$([ "$OPT_ZSH" = true ] && echo false || echo true) ;;
            3)  OPT_WALLPAPERS=$([ "$OPT_WALLPAPERS" = true ] && echo false || echo true) ;;
            4)  OPT_AI=$([ "$OPT_AI" = true ] && echo false || echo true) ;;
            5)  OPT_HERMES=$([ "$OPT_HERMES" = true ] && echo false || echo true) ;;
            6)  OPT_CONTAINERS=$([ "$OPT_CONTAINERS" = true ] && echo false || echo true) ;;
            7)  OPT_ACCOUNTS=$([ "$OPT_ACCOUNTS" = true ] && echo false || echo true) ;;
            8)  OPT_VPN=$([ "$OPT_VPN" = true ] && echo false || echo true) ;;
            9)  OPT_STREAMING=$([ "$OPT_STREAMING" = true ] && echo false || echo true) ;;
            10) OPT_STEAM=$([ "$OPT_STEAM" = true ] && echo false || echo true) ;;
            11)
                if [ "$HAS_HISTORY" = true ]; then
                    OPT_OVERRIDE_KEYBINDS=$([ "$OPT_OVERRIDE_KEYBINDS" = true ] && echo false || echo true)
                else
                    break_and_proceed=true
                fi
                ;;
            12)
                if [ "$HAS_HISTORY" = true ]; then
                    OPT_OVERRIDE_STARTUPS=$([ "$OPT_OVERRIDE_STARTUPS" = true ] && echo false || echo true)
                else
                    return 1
                fi
                ;;
            13) [ "$HAS_HISTORY" = true ] && break_and_proceed=true ;;
            14) [ "$HAS_HISTORY" = true ] && return 1 ;;
            *) ;;
        esac

        if [ "$break_and_proceed" = true ]; then
            # ── Resolve package additions from the final toggle state ──
            if [ "$OPT_SDDM" = true ]; then
                if [[ -z "$CURRENT_DM" ]]; then
                    INSTALL_SDDM=true
                    SETUP_SDDM_THEME=true
                    PKGS+=("sddm")
                elif [[ "$CURRENT_DM" == "sddm" ]]; then
                    SETUP_SDDM_THEME=true
                else
                    INSTALL_SDDM=true
                    REPLACE_DM=true
                    SETUP_SDDM_THEME=true
                    PKGS+=("sddm")
                fi

                clear
                draw_header
                echo -e "${BOLD}${C_CYAN}=== SDDM Configuration ===${RESET}\n"
                echo -e "Force SDDM to run natively on Wayland?"
                echo -e "${DIM}(Default No — safer for NVIDIA setups.)${RESET}"
                read -p "Wayland backend? (y/N): " sddm_wayland
                [[ "$sddm_wayland" =~ ^[Yy]$ ]] && SDDM_WAYLAND=true || SDDM_WAYLAND=false
            fi
            [ "$OPT_ZSH" = true ] && { INSTALL_ZSH=true; PKGS+=("zsh"); }

            # Hermes needs podman (autobrowse container) — force containers on.
            [ "$OPT_HERMES" = true ] && OPT_CONTAINERS=true
            # Accounts provisioning targets the containers — force them on.
            [ "$OPT_ACCOUNTS" = true ] && OPT_CONTAINERS=true
            # gluetun runs as a podman quadlet.
            [ "$OPT_VPN" = true ] && OPT_CONTAINERS=true
            # SearXNG/Honcho/Kavita quadlets need podman too.
            [ "$OPT_AI" = true ] && OPT_CONTAINERS=true

            [ "$OPT_CONTAINERS" = true ] && PKGS+=("podman" "podman-compose" "passt" "fuse-overlayfs")
            [ "$OPT_STREAMING" = true ]  && PKGS+=("tailscale" "apollo")
            [ "$OPT_STEAM" = true ]      && PKGS+=("steam")

            # GPU-appropriate Ollama variant (skipped on AMD — vLLM container).
            if [ "$OPT_AI" = true ] && [ -n "$OLLAMA_PKG" ]; then
                PKGS+=("$OLLAMA_PKG")
            fi
            return 0
        fi
    done
}

# ==============================================================================
# Headless mode shortcut — skip interactive menus, use defaults
# ==============================================================================
if [ "$HEADLESS" = "true" ]; then
    VISITED_KEYBOARD=true
    OPT_AI=false
    OPT_SDDM=true
    INSTALL_SDDM=true
    SETUP_SDDM_THEME=true
    PKGS+=("sddm")
    DRIVER_CHOICE="Skipped (headless)"
    KEEP_OLD_ENV=true
    WEATHER_API_KEY="Skipped"
fi

# ==============================================================================
# Main Menu Loop (skipped in --headless)
# ==============================================================================
if [ "$HEADLESS" = "false" ]; then
while true; do
    draw_header

    S_PKG=$( [ "$VISITED_PKGS" = true ] && echo -e "${C_GREEN}[✓]${RESET}" || echo -e "${C_YELLOW}[-]${RESET}" )
    S_OVW=$( [ "$VISITED_OVERVIEW" = true ] && echo -e "${C_GREEN}[✓]${RESET}" || echo -e "${C_YELLOW}[-]${RESET}" )
    S_WTH=$( [ "$VISITED_WEATHER" = true ] && echo -e "${C_GREEN}[✓]${RESET}" || echo -e "${C_YELLOW}[-]${RESET}" )
    S_DRV=$( [ "$VISITED_DRIVERS" = true ] && echo -e "${C_GREEN}[✓]${RESET}" || echo -e "${C_YELLOW}[-]${RESET}" )
    S_KBD=$( [ "$VISITED_KEYBOARD" = true ] && echo -e "${C_GREEN}[✓]${RESET}" || echo -e "${C_RED}[ ]${RESET}" )
    S_AI=$(  [ "$OPT_AI" = true ] && echo -e "${C_GREEN}[ON]${RESET}" || echo -e "${DIM}[OFF]${RESET}" )

    if [[ -z "$WEATHER_API_KEY" ]]; then
        if [ -f "$HYPR_DIR/scripts/quickshell/calendar/.env" ]; then
            API_DISPLAY="Set (from .env file)"
        else
            API_DISPLAY="Not Set"
        fi
    elif [[ "$WEATHER_API_KEY" == "Skipped" ]]; then API_DISPLAY="Skipped"
    else API_DISPLAY="Set ($WEATHER_UNIT, ID: $WEATHER_CITY_ID)"; fi

    if [ "$LOCAL_VERSION" != "Not Installed" ] && [ -n "$LOCAL_VERSION" ]; then
        INSTALL_LABEL="UPDATE"
    else
        INSTALL_LABEL="START"
    fi

    MENU_ITEMS="1. $S_PKG ${C_GREEN}Manage Packages${RESET} [${#PKGS[@]} queued, Optional]\n"
    MENU_ITEMS+="2. $S_OVW ${C_CYAN}Overview & Keybinds${RESET} [Optional]\n"
    MENU_ITEMS+="3. $S_WTH ${C_YELLOW}Set Weather API Key${RESET} [${API_DISPLAY}, Optional]\n"
    MENU_ITEMS+="4. $S_DRV ${C_RED}[ DRIVERS ] Setup${RESET} [${DRIVER_CHOICE}, Optional]\n"
    MENU_ITEMS+="5. $S_KBD ${C_BLUE}Keyboard Layout Setup${RESET} [${KB_LAYOUTS_DISPLAY:-$KB_LAYOUTS}]\n"
    MENU_ITEMS+="6. $S_AI ${C_MAGENTA}AI Stack Settings${RESET}\n"
    MENU_ITEMS+="7. ${BOLD}${C_MAGENTA}${INSTALL_LABEL}${RESET}\n"
    MENU_ITEMS+="8. ${DIM}Exit${RESET}"

    MENU_OPTION=$(echo -e "$MENU_ITEMS" | fzf \
        --ansi --layout=reverse --border=rounded --margin=1,2 --height=17 \
        --prompt=" Main Menu > " --pointer=">" \
        --header=" Navigate with ARROWS. Select with ENTER. ")

    case "$MENU_OPTION" in
        *"1."*) manage_packages ;;
        *"2."*) show_overview ;;
        *"3."*) set_weather_api ;;
        *"4."*) manage_drivers ;;
        *"5."*) manage_keyboard ;;
        *"6."*) manage_ai_stack ;;
        *"7."*)
            if [ "$VISITED_KEYBOARD" = false ]; then
                echo -e "\n${C_RED}[!] Configure your Keyboard Layouts first.${RESET}"
                sleep 2.5
                continue
            fi
            if prompt_optional_features_menu; then break; else continue; fi
            ;;
        *"8."*) clear; exit 0 ;;
        *) exit 0 ;;
    esac
done
fi

# ==============================================================================
# Installation Process
# ==============================================================================
clear
draw_header
echo -e "${BOLD}${C_BLUE}::${RESET} ${BOLD}Starting Installation Process...${RESET}\n"

echo -e "${C_CYAN}[ INFO ]${RESET} Requesting sudo privileges..."
sudo -v

# Sudo keepalive
( while true; do sudo -n true 2>/dev/null; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_PID=$!
trap 'kill $SUDO_PID 2>/dev/null || true' EXIT

# --- 0. Resolve Package Conflicts ---
echo -e "\n${C_CYAN}[ INFO ]${RESET} Resolving potential package conflicts..."

for jack_pkg in jack jack2 jack2-dbus; do
    if pacman -Qq "$jack_pkg" &>/dev/null; then
        echo -e "  -> Removing conflicting package '$jack_pkg'..."
        sudo pacman -Rdd --noconfirm "$jack_pkg" 2>/dev/null || true
    fi
done
yes "Y" | $PKG_MANAGER pipewire-jack > /dev/null 2>&1 || true

CONFLICTING_PKGS=("swayosd" "quickshell" "matugen" "go-yq")
for cpkg in "${CONFLICTING_PKGS[@]}"; do
    if pacman -Qq | grep -qx "$cpkg"; then
        echo -e "  -> ${C_YELLOW}Removing conflicting package '$cpkg'...${RESET}"
        systemctl --user stop "$cpkg" 2>/dev/null || true
        sudo systemctl stop "$cpkg" 2>/dev/null || true

        if ! sudo pacman -Rns --noconfirm "$cpkg" > /dev/null 2>&1; then
            sudo pacman -Rdd --noconfirm "$cpkg" > /dev/null 2>&1
        fi
    fi
done

# Resolve ollama-* variant conflicts before install (switching variants needs
# the old one removed first; AMD/vLLM removes all of them).
if [ "$OPT_AI" = true ]; then
    for variant in ollama ollama-cuda ollama-rocm; do
        if pacman -Qq "$variant" &>/dev/null && [ "$variant" != "$OLLAMA_PKG" ]; then
            if [ "$USE_VLLM_TURBOQUANT" = true ]; then
                echo -e "  -> ${C_YELLOW}Removing Ollama '$variant' (switching to vLLM-TurboQuant)...${RESET}"
            else
                echo -e "  -> ${C_YELLOW}Removing old Ollama variant '$variant' (replacing with $OLLAMA_PKG)...${RESET}"
            fi
            sudo systemctl stop ollama.service 2>/dev/null || true
            sudo systemctl disable ollama.service 2>/dev/null || true
            sudo pacman -Rns --noconfirm "$variant" > /dev/null 2>&1 || true
        fi
    done
fi

ALL_PKGS=("${PKGS[@]}" "${DRIVER_PKGS[@]}")
MISSING_PKGS=()

echo -e "\n${C_CYAN}[ INFO ]${RESET} Checking for already installed packages..."
for pkg in "${ALL_PKGS[@]}"; do
    [[ -z "$pkg" ]] && continue
    pacman -Q "$pkg" &>/dev/null || MISSING_PKGS+=("$pkg")
done

# --- 1. Install Dependencies & Drivers ---
if [ ${#MISSING_PKGS[@]} -eq 0 ]; then
    echo -e "  -> ${C_GREEN}All packages already installed!${RESET}\n"
else
    echo -e "  -> ${C_YELLOW}Found ${#MISSING_PKGS[@]} missing packages.${RESET}"
    echo -e "\n${C_CYAN}[ INFO ]${RESET} Installing System Packages & Drivers...\n"

    for pkg in "${MISSING_PKGS[@]}"; do
        echo -e "\n${C_CYAN}=================================================================${RESET}"
        echo -e "${C_BLUE}::${RESET} ${BOLD}Installing ${pkg}...${RESET}"
        echo -e "${C_CYAN}=================================================================${RESET}"

        if [ "$pkg" = "apollo" ]; then
            echo -e "  -> ${C_YELLOW}Note: on non-NVIDIA boxes the apollo PKGBUILD may demand an old gcc${RESET}"
            echo -e "  -> ${C_YELLOW}because it derives _cuda_gcc_version from 'pacman -Si cuda'.${RESET}"
            echo -e "  -> ${C_YELLOW}If the build fails, set _cuda_gcc_version=\"\" in its PKGBUILD.${RESET}"
        fi

        SAFE_JOBS=$(( $(nproc) / 2 ))
        [[ $SAFE_JOBS -lt 1 ]] && SAFE_JOBS=1
        [[ $SAFE_JOBS -gt 4 ]] && SAFE_JOBS=4

        # Capture output to diagnose the classic failure modes.
        pkg_log=$(mktemp)
        if yes "Y" | env CARGO_BUILD_JOBS="$SAFE_JOBS" MAKEFLAGS="-j$SAFE_JOBS" \
                $PKG_MANAGER "$pkg" 2>&1 | tee "$pkg_log"; then
            echo -e "\n${C_GREEN}[ OK ] Successfully installed ${pkg}${RESET}"
        else
            echo -e "\n${C_RED}[ FAILED ] Failed to install ${pkg}${RESET}"

            if grep -qE "breaks dependency.*lib32-|installing .* breaks dependency" "$pkg_log"; then
                broken_dep=$(grep -oE "'[a-z0-9-]+=[0-9.]+' required by [a-z0-9-]+" "$pkg_log" | head -1)
                echo -e "${C_YELLOW}  → Partial-upgrade conflict detected: $broken_dep${RESET}"
                echo -e "${C_YELLOW}  → Multilib repo is out of sync with main. Options:${RESET}"
                echo -e "    1. Wait 24h for multilib to catch up, then re-run this script"
                echo -e "    2. Run ${BOLD}sudo pacman -Syu${RESET} again manually and retry"
                echo -e "    3. Temporarily remove the lib32-* package, install $pkg, then reinstall lib32-*"
            elif grep -qE "signature.*unknown trust|key.*could not be looked up" "$pkg_log"; then
                echo -e "${C_YELLOW}  → Signature/keyring issue. Try:${RESET}"
                echo -e "    ${BOLD}sudo pacman -S archlinux-keyring && sudo pacman -Syu${RESET}"
            elif grep -qE "unable to lock database|could not lock database" "$pkg_log"; then
                echo -e "${C_YELLOW}  → Pacman database is locked (another pacman/paru running?).${RESET}"
                echo -e "    Wait for the other process to finish, or if none exists:"
                echo -e "    ${BOLD}sudo rm /var/lib/pacman/db.lck${RESET}"
            elif grep -qE "out of memory|cannot allocate memory|Killed" "$pkg_log"; then
                echo -e "${C_YELLOW}  → Build ran out of memory. Reduce parallel jobs or add swap.${RESET}"
            fi

            FAILED_PKGS+=("$pkg")
        fi
        rm -f "$pkg_log"
        sleep 0.5
    done
fi

# Hyprland is non-negotiable
if ! pacman -Q hyprland &>/dev/null; then
    echo -e "${C_RED}[ ERR ] Hyprland did not install. Cannot continue.${RESET}"
    exit 1
fi

# --- 1.5. NVIDIA Initialization ---
if [ "$HAS_NVIDIA_PROPRIETARY" = true ]; then
    echo -e "\n${C_CYAN}[ INFO ]${RESET} Performing NVIDIA Initialization for Wayland..."
    echo -e "options nvidia-drm modeset=1 fbdev=1" | sudo tee /etc/modprobe.d/nvidia.conf > /dev/null

    if command -v mkinitcpio &> /dev/null; then
        sudo mkinitcpio -P >/dev/null 2>&1
        printf "  -> Mkinitcpio rebuild successful %-9s ${C_GREEN}[ OK ]${RESET}\n" ""
    elif command -v dracut &> /dev/null; then
        sudo dracut --force >/dev/null 2>&1
        printf "  -> Dracut rebuild successful %-14s ${C_GREEN}[ OK ]${RESET}\n" ""
    fi
fi

# --- 2. Display Manager Cleanup ---
if [[ "$INSTALL_SDDM" == true || "$SETUP_SDDM_THEME" == true || "$REPLACE_DM" == true ]]; then
    echo -e "\n${C_CYAN}[ INFO ]${RESET} Configuring Display Manager..."
fi

if [[ "$REPLACE_DM" == true ]]; then
    DMS=("lightdm" "gdm" "gdm3" "lxdm" "lxdm-gtk3" "ly")
    for dm in "${DMS[@]}"; do
        if systemctl is-enabled "$dm.service" &>/dev/null || systemctl is-active "$dm.service" &>/dev/null; then
            echo "  -> Disabling conflicting Display Manager: $dm"
            sudo systemctl disable "$dm.service" 2>/dev/null || true
            sudo pacman -Rns --noconfirm "$dm" > /dev/null 2>&1 || true
        fi
    done
fi

if [[ "$INSTALL_SDDM" == true ]]; then
    sudo systemctl enable sddm.service -f
    printf "  -> SDDM enabled successfully %-14s ${C_GREEN}[ OK ]${RESET}\n" ""
fi

# --- 3. Wallpapers ---
echo -e "\n${C_CYAN}[ INFO ]${RESET} Fetching wallpapers..."
mkdir -p "$WALLPAPER_DIR"

WALLPAPER_REPO_URL="https://github.com/ilyamiro/shell-wallpapers.git"
WALLPAPER_REPO_TMP="$(mktemp -d)/shell-wallpapers"

if [ -n "$(find "$WALLPAPER_DIR" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.webp' \) -print -quit 2>/dev/null)" ]; then
    echo -e "  -> ${C_GREEN}Wallpapers already present.${RESET} Skipping download."
else
    echo "  -> Cloning $WALLPAPER_REPO_URL (depth 1)..."
    if git clone --depth 1 "$WALLPAPER_REPO_URL" "$WALLPAPER_REPO_TMP" >/dev/null 2>&1; then
        if [ ! -d "$WALLPAPER_REPO_TMP/images" ]; then
            printf "  -> Repo layout unexpected (no images/ dir) %-1s ${C_YELLOW}[WARN]${RESET}\n" ""
            echo "  -> Add wallpapers manually to $WALLPAPER_DIR"
        elif [ "$OPT_WALLPAPERS" = true ]; then
            cp "$WALLPAPER_REPO_TMP/images/"*.{jpg,jpeg,png,gif,webp} "$WALLPAPER_DIR/" 2>/dev/null || true
            count=$(find "$WALLPAPER_DIR" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.jpeg' -o -iname '*.gif' -o -iname '*.webp' \) | wc -l)
            printf "  -> Copied full wallpaper pack (%d files) %-1s ${C_GREEN}[ OK ]${RESET}\n" "$count"
        else
            mapfile -t _wps < <(find "$WALLPAPER_REPO_TMP/images" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.jpeg' -o -iname '*.gif' -o -iname '*.webp' \) | shuf -n 3)
            for w in "${_wps[@]}"; do
                cp "$w" "$WALLPAPER_DIR/" 2>/dev/null || true
            done
            printf "  -> Copied 3 random wallpapers %-13s ${C_GREEN}[ OK ]${RESET}\n" ""
        fi
        rm -rf "$(dirname "$WALLPAPER_REPO_TMP")"
    else
        printf "  -> Could not clone wallpaper repo %-13s ${C_YELLOW}[WARN]${RESET}\n" ""
        echo "  -> Add wallpapers manually to: $WALLPAPER_DIR"
    fi
fi

# --- 4. Copying Dotfiles & Backups (repo mode only) ---
BACKUP_DIR="$HOME/.config-backup-$(date +%Y%m%d_%H%M%S)"

if [ "$MODE" = "repo" ]; then
    echo -e "\n${C_CYAN}[ INFO ]${RESET} Applying configurations & backing up old ones..."
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"

    CONFIG_FOLDERS=("cava" "hypr" "kitty" "matugen" "zsh" "swayosd")
    mkdir -p "$TARGET_CONFIG_DIR"

    for folder in "${CONFIG_FOLDERS[@]}"; do
        TARGET_PATH="$TARGET_CONFIG_DIR/$folder"
        SOURCE_PATH="$REPO_DIR/.config/$folder"

        if [ -d "$SOURCE_PATH" ]; then
            if [ -e "$TARGET_PATH" ] || [ -L "$TARGET_PATH" ]; then
                mv "$TARGET_PATH" "$BACKUP_DIR/$folder"
            fi
            cp -r "$SOURCE_PATH" "$TARGET_PATH"
            printf "  -> Copied %-31s ${C_GREEN}[ OK ]${RESET}\n" "$folder"
        fi
    done

    # Mark our scripts executable (bounded — only known dirs)
    KNOWN_SCRIPT_DIRS=(
        "$HYPR_DIR/scripts"
        "$HYPR_DIR/scripts/quickshell"
    )
    for d in "${KNOWN_SCRIPT_DIRS[@]}"; do
        [ -d "$d" ] || continue
        find "$d" -maxdepth 1 -type f -name "*.sh" -exec chmod +x {} \;
    done

    # Restore machine-local generated state the repo doesn't carry
    for f in hypr/scripts/quickshell/qs_colors.json hypr/scripts/quickshell/calendar/.env; do
        [ -f "$BACKUP_DIR/$f" ] && { mkdir -p "$(dirname "$TARGET_CONFIG_DIR/$f")"; cp "$BACKUP_DIR/$f" "$TARGET_CONFIG_DIR/$f"; }
    done
else
    echo -e "\n${C_CYAN}[ INFO ]${RESET} In-place mode — configs already live, skipping deploy."
fi

# --- 4.5 Bake Hardware Variables into Template (if the template carries the slot) ---
if [ -f "$HYPR_DIR/templates/env.conf.template" ] && grep -q "{{HARDWARE_ENV}}" "$HYPR_DIR/templates/env.conf.template"; then
    echo "  -> Baking hardware environment variables into template..."
    if [ "$GPU_VENDOR" == "NVIDIA" ]; then
        NVIDIA_VARS="env = ELECTRON_OZONE_PLATFORM_HINT,auto\nenv = __NV_PRIME_RENDER_OFFLOAD,1\nenv = __GLX_VENDOR_LIBRARY_NAME,nvidia\nenv = LIBVA_DRIVER_NAME,nvidia"
        sed -i "s|{{HARDWARE_ENV}}|$NVIDIA_VARS|g" "$HYPR_DIR/templates/env.conf.template"
    else
        sed -i "s|{{HARDWARE_ENV}}||g" "$HYPR_DIR/templates/env.conf.template"
    fi
fi

# --- 4.6 Ensure Qt Wayland env vars are set (Quickshell crash fix) ---
ENV_CONF="$HYPR_DIR/config/env.conf"
if [ -f "$ENV_CONF" ]; then
    if ! grep -q "QT_QPA_PLATFORM,wayland" "$ENV_CONF"; then
        echo "  -> Appending Qt Wayland env vars to env.conf..."
        cat >> "$ENV_CONF" <<'EOF'

# Qt Wayland enforcement (prevents Quickshell from trying xcb plugin)
env = QT_QPA_PLATFORM,wayland
env = QT_WAYLAND_DISABLE_WINDOWDECORATION,1
env = XDG_CURRENT_DESKTOP,Hyprland
env = XDG_SESSION_TYPE,wayland
env = XDG_SESSION_DESKTOP,Hyprland
env = GDK_BACKEND,wayland,x11
env = SDL_VIDEODRIVER,wayland
env = MOZ_ENABLE_WAYLAND,1
env = _JAVA_AWT_WM_NONREPARENTING,1
EOF
        printf "  -> Qt Wayland env vars appended %-19s ${C_GREEN}[ OK ]${RESET}\n" ""
    else
        printf "  -> Qt Wayland env vars already set %-17s ${C_GREEN}[ OK ]${RESET}\n" ""
    fi
fi

# ==============================================================================
# Settings.json SSoT
# ==============================================================================
UPSTREAM_JSON="$HYPR_DIR/default_settings.json"
[ "$MODE" = "repo" ] && UPSTREAM_JSON="$REPO_DIR/.config/hypr/default_settings.json"

if [ -f "$UPSTREAM_JSON" ]; then
    echo -e "\n${C_CYAN}[ INFO ]${RESET} Establishing settings.json SSoT..."
    SETTINGS_FILE="$HYPR_DIR/settings.json"
    mkdir -p "$(dirname "$SETTINGS_FILE")"

    if [ -f "$BACKUP_DIR/hypr/settings.json" ] && jq -e . "$BACKUP_DIR/hypr/settings.json" >/dev/null 2>&1; then
        OLD_JSON="$BACKUP_DIR/hypr/settings.json"
    elif [ "$MODE" = "inplace" ] && [ -f "$SETTINGS_FILE" ] && jq -e . "$SETTINGS_FILE" >/dev/null 2>&1; then
        OLD_JSON="$SETTINGS_FILE"
    else
        OLD_JSON="$UPSTREAM_JSON"
    fi

    _tmp_settings=$(mktemp)
    jq -n --slurpfile local "$OLD_JSON" --slurpfile up "$UPSTREAM_JSON" \
       --arg langs "$KB_LAYOUTS" --arg wpdir "$WALLPAPER_DIR" --arg kbopt "$KB_OPTIONS" \
       --arg ovr_kb "$OPT_OVERRIDE_KEYBINDS" --arg ovr_su "$OPT_OVERRIDE_STARTUPS" '
       $up[0] as $u |
       (if ($local | length > 0) then $local[0] else $u end) as $l |
       ($u + $l) |
       .language = $langs | .wallpaperDir = $wpdir | .kbOptions = $kbopt |
       .keybinds = (if $ovr_kb == "true" then $u.keybinds else
           ($l.keybinds // [] | map(((.mods // "") + "|" + (.key // "")))) as $local_keys |
           ($l.keybinds // [] | map(.command)) as $local_cmds |
           ($u.keybinds // [] | map(select(
               (((.mods // "") + "|" + (.key // "")) as $k | ($local_keys | index($k)) == null) and
               (.command as $cmd | ($local_cmds | index($cmd)) == null)
           ))) as $new_upstream |
           (($l.keybinds // []) + $new_upstream)
       end) |
       .startup = (if $ovr_su == "true" then $u.startup else
           ($l.startup // [] | map(.command)) as $local_startups |
           ($u.startup // [] | map(select(.command as $cmd | ($local_startups | index($cmd)) == null))) as $new |
           (($l.startup // []) + $new)
       end)
    ' > "$_tmp_settings" && mv "$_tmp_settings" "$SETTINGS_FILE"

    printf "  -> settings.json built %-25s ${C_GREEN}[ OK ]${RESET}\n" ""
fi

# Weather Configuration
ENV_TARGET_DIR="$HYPR_DIR/scripts/quickshell/calendar"
OLD_ENV_IN_BACKUP="$BACKUP_DIR/hypr/scripts/quickshell/calendar/.env"

if [[ "$KEEP_OLD_ENV" == true ]] && [ -f "$OLD_ENV_IN_BACKUP" ]; then
    mkdir -p "$ENV_TARGET_DIR"
    cp "$OLD_ENV_IN_BACKUP" "$ENV_TARGET_DIR/.env"
    chmod 600 "$ENV_TARGET_DIR/.env"
    printf "  -> Restored Weather config %-21s ${C_GREEN}[ OK ]${RESET}\n" ""
elif [[ -n "$WEATHER_API_KEY" && "$WEATHER_API_KEY" != "Skipped" ]]; then
    mkdir -p "$ENV_TARGET_DIR"
    cat <<EOF > "$ENV_TARGET_DIR/.env"
OPENWEATHER_KEY=${WEATHER_API_KEY}
OPENWEATHER_CITY_ID=${WEATHER_CITY_ID}
OPENWEATHER_UNIT=${WEATHER_UNIT}
EOF
    chmod 600 "$ENV_TARGET_DIR/.env"
    printf "  -> Saved Weather config (mode 600) %-13s ${C_GREEN}[ OK ]${RESET}\n" ""
fi

# Zsh Dynamism
if [ "$INSTALL_ZSH" = true ] && command -v zsh &> /dev/null; then
    if [ -f "$HOME/.zshrc" ]; then
        mkdir -p "$TARGET_CONFIG_DIR/zsh"
        grep "^alias " "$HOME/.zshrc" > "$TARGET_CONFIG_DIR/zsh/user_aliases.zsh" || true
        [ -s "$TARGET_CONFIG_DIR/zsh/user_aliases.zsh" ] || rm -f "$TARGET_CONFIG_DIR/zsh/user_aliases.zsh"
    fi
    cp "$TARGET_CONFIG_DIR/zsh/.zshrc" "$HOME/.zshrc" 2>/dev/null || true
    chsh -s $(which zsh) "$USER"
    if [ -f "$TARGET_CONFIG_DIR/zsh/user_aliases.zsh" ]; then
        sed -i '/# Load User Aliases/d' "$HOME/.zshrc"
        echo -e "\n# Load User Aliases" >> "$HOME/.zshrc"
        echo "source $TARGET_CONFIG_DIR/zsh/user_aliases.zsh" >> "$HOME/.zshrc"
    fi
    printf "  -> Zsh set as default shell %-19s ${C_GREEN}[ OK ]${RESET}\n" ""
fi

ZSH_RC="$HOME/.zshrc"
if [ -f "$ZSH_RC" ]; then
    sed -i '/# Dynamic System Paths/d' "$ZSH_RC"
    sed -i '/export WALLPAPER_DIR=/d' "$ZSH_RC"
    sed -i '/export SCRIPT_DIR=/d' "$ZSH_RC"
    echo -e "\n# Dynamic System Paths" >> "$ZSH_RC"
    echo "export WALLPAPER_DIR=\"$WALLPAPER_DIR\"" >> "$ZSH_RC"
    echo "export SCRIPT_DIR=\"$HOME/.config/hypr/scripts\"" >> "$ZSH_RC"
    sed -i "s/OS_LOGO_PLACEHOLDER/${OS}_small/g" "$ZSH_RC"
fi

# --- GTK and Qt Theming (matugen-driven) ---
echo -e "\n${C_CYAN}[ INFO ]${RESET} Configuring GTK and Qt theming..."
gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null || true
gsettings set org.gnome.desktop.interface gtk-theme 'adw-gtk3-dark' 2>/dev/null || true

mkdir -p "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-4.0"
echo '@import url("file://'"$HOME"'/.cache/matugen/colors-gtk.css");' > "$HOME/.config/gtk-3.0/gtk.css"
echo '@import url("file://'"$HOME"'/.cache/matugen/colors-gtk.css");' > "$HOME/.config/gtk-4.0/gtk.css"

cat <<EOF > "$HOME/.config/gtk-3.0/settings.ini"
[Settings]
gtk-application-prefer-dark-theme=1
gtk-theme-name=adw-gtk3-dark
EOF
cat <<EOF > "$HOME/.config/gtk-4.0/settings.ini"
[Settings]
gtk-application-prefer-dark-theme=1
EOF

mkdir -p "$HOME/.config/qt5ct/colors" "$HOME/.config/qt5ct/qss"
mkdir -p "$HOME/.config/qt6ct/colors" "$HOME/.config/qt6ct/qss"

for v in qt5ct qt6ct; do
cat <<EOF > "$HOME/.config/$v/$v.conf"
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

printf "  -> Matugen GTK & Qt initialized %-18s ${C_GREEN}[ OK ]${RESET}\n" ""

# --- Desktop defaults: Dolphin + kitty-as-terminal ---
xdg-mime default org.kde.dolphin.desktop inode/directory 2>/dev/null || true
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
printf "  -> Dolphin handles dirs; kitty is its terminal %-3s ${C_GREEN}[ OK ]${RESET}\n" ""

# ==============================================================================
# Secrets: keyring-first. KWallet's ksecretd serves org.freedesktop.secrets;
# secrets.sh stores/reads every token. config.json carries only URLs/paths.
# ==============================================================================
echo -e "\n${C_CYAN}[ INFO ]${RESET} Configuring keyring-backed secrets..."

if [ ! -f "$HYPR_DIR/config.json" ]; then
    if [ -f "$HYPR_DIR/config.json.example" ]; then
        cp "$HYPR_DIR/config.json.example" "$HYPR_DIR/config.json"
    else
        echo '{}' > "$HYPR_DIR/config.json"
    fi
    chmod 600 "$HYPR_DIR/config.json"
    printf "  -> config.json created from example %-12s ${C_GREEN}[ OK ]${RESET}\n" ""
else
    chmod 600 "$HYPR_DIR/config.json" 2>/dev/null || true
    printf "  -> config.json present (untouched) %-13s ${C_GREEN}[ OK ]${RESET}\n" ""
fi

# ksecretd does NOT claim org.freedesktop.secrets unless kwalletrc enables the
# API, and kwallet ships no D-Bus activation file for that name — provide both.
if ! grep -q 'apiEnabled=true' "$HOME/.config/kwalletrc" 2>/dev/null; then
    printf '[Wallet]\nEnabled=true\n\n[org.freedesktop.secrets]\napiEnabled=true\n' >> "$HOME/.config/kwalletrc"
fi
mkdir -p "$HOME/.local/share/dbus-1/services"
printf '[D-BUS Service]\nName=org.freedesktop.secrets\nExec=/usr/bin/ksecretd\n' \
    > "$HOME/.local/share/dbus-1/services/org.freedesktop.secrets.service"
printf "  -> KWallet (ksecretd) serves the Secret Service %-1s ${C_GREEN}[ OK ]${RESET}\n" ""

# If gnome-keyring is also installed, stop it from claiming the Secret Service.
if pacman -Q gnome-keyring &>/dev/null; then
    mkdir -p "$HOME/.config/autostart"
    for f in gnome-keyring-secrets gnome-keyring-pkcs11; do
        printf '[Desktop Entry]\nType=Application\nName=%s\nHidden=true\n' "$f" > "$HOME/.config/autostart/$f.desktop"
    done
    systemctl --user mask gnome-keyring-daemon.service gnome-keyring-daemon.socket >/dev/null 2>&1 || true
    echo -e "  -> ${C_YELLOW}gnome-keyring demoted. Also remove pam_gnome_keyring lines from /etc/pam.d/sddm.${RESET}"
fi
echo -e "  ${DIM}Store API tokens with: $HYPR_DIR/scripts/secrets.sh set <key> <value>${RESET}"
echo -e "  ${DIM}List known keys with:  $HYPR_DIR/scripts/secrets.sh list${RESET}"

# --- Fonts ---
echo -e "\n${C_CYAN}[ INFO ]${RESET} Installing fonts..."
TARGET_FONTS_DIR="$HOME/.local/share/fonts"
mkdir -p "$TARGET_FONTS_DIR"

if [ "$MODE" = "repo" ] && [ -d "$REPO_DIR/.local/share/fonts" ]; then
    cp -r "$REPO_DIR/.local/share/fonts/"* "$TARGET_FONTS_DIR/" 2>/dev/null || true
fi

if [ -d "$TARGET_FONTS_DIR/IosevkaNerdFont" ] && [ "$(ls -A "$TARGET_FONTS_DIR/IosevkaNerdFont" 2>/dev/null | grep -i "\.ttf")" ]; then
    echo -e "  -> ${C_GREEN}Iosevka already installed.${RESET}"
else
    mkdir -p /tmp/iosevka-pack "$TARGET_FONTS_DIR/IosevkaNerdFont"
    if curl -fLo /tmp/iosevka-pack/Iosevka.zip https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Iosevka.zip; then
        unzip -q -o /tmp/iosevka-pack/Iosevka.zip -d /tmp/iosevka-pack/
        mv /tmp/iosevka-pack/*.ttf "$TARGET_FONTS_DIR/IosevkaNerdFont/" 2>/dev/null || true
    else
        printf "  -> Iosevka download failed — install ttf-iosevka-nerd manually %-1s ${C_YELLOW}[WARN]${RESET}\n" ""
    fi
    rm -rf /tmp/iosevka-pack
fi
if ! fc-list 2>/dev/null | grep -qi "JetBrainsMono"; then
    yes "Y" | $PKG_MANAGER ttf-jetbrains-mono >/dev/null 2>&1 || true
fi
if ! fc-list 2>/dev/null | grep -qiE '\bInter\b'; then
    yes "Y" | $PKG_MANAGER inter-font >/dev/null 2>&1 || true
fi

find "$TARGET_FONTS_DIR" -type f -exec chmod 644 {} \; 2>/dev/null
find "$TARGET_FONTS_DIR" -type d -exec chmod 755 {} \; 2>/dev/null
fc-cache -f "$TARGET_FONTS_DIR" > /dev/null 2>&1
printf "  -> Font cache updated %-25s ${C_GREEN}[ OK ]${RESET}\n" ""

# ==============================================================================
# Native builds — obsidian-shell, pip mpvplugin, hyprbars
# ==============================================================================
echo -e "\n${C_CYAN}[ INFO ]${RESET} Building native components..."

OBS_BUILD="$HYPR_DIR/scripts/quickshell/floating/obsidian-shell/build.sh"
if [ -f "$OBS_BUILD" ]; then
    if bash "$OBS_BUILD" >/tmp/obsidian-shell-build.log 2>&1; then
        printf "  -> obsidian-shell built %-24s ${C_GREEN}[ OK ]${RESET}\n" ""
    else
        printf "  -> obsidian-shell build FAILED %-16s ${C_RED}[FAIL]${RESET}\n" ""
        echo -e "  -> ${DIM}See /tmp/obsidian-shell-build.log${RESET}"
        FAILED_PKGS+=("obsidian-shell(build)")
    fi
fi

PIP_BUILD="$HYPR_DIR/scripts/quickshell/pip/mpvplugin/build.sh"
if [ -f "$PIP_BUILD" ]; then
    if bash "$PIP_BUILD" >/tmp/mpvplugin-build.log 2>&1; then
        printf "  -> pip mpvplugin built %-25s ${C_GREEN}[ OK ]${RESET}\n" ""
    else
        printf "  -> mpvplugin build FAILED %-21s ${C_RED}[FAIL]${RESET}\n" ""
        echo -e "  -> ${DIM}See /tmp/mpvplugin-build.log${RESET}"
        FAILED_PKGS+=("mpvplugin(build)")
    fi
fi

# hyprbars plugin via hyprpm (float-mode title bars)
if command -v hyprpm &>/dev/null; then
    hyprpm update >/dev/null 2>&1 || true
    hyprpm list 2>/dev/null | grep -q hyprbars || hyprpm add https://github.com/hyprwm/hyprland-plugins >/dev/null 2>&1 || true
    if hyprpm enable hyprbars >/dev/null 2>&1; then
        printf "  -> hyprbars enabled (hyprpm) %-19s ${C_GREEN}[ OK ]${RESET}\n" ""
    else
        printf "  -> hyprbars pending %-28s ${C_YELLOW}[WARN]${RESET}\n" ""
        echo -e "  -> ${DIM}Run 'hyprpm update && hyprpm enable hyprbars' inside a Hyprland session${RESET}"
    fi
fi

# (mov-cli retired — upstream deprecated. Movies/TV use lobster, with the
#  torrentio + debrid backend as the fallback for both movies/TV and anime.)

# --- Core services ---
echo -e "\n${C_CYAN}[ INFO ]${RESET} Enabling core services..."
sudo systemctl enable NetworkManager.service >/dev/null 2>&1 || true
printf "  -> NetworkManager enabled %-23s ${C_GREEN}[ OK ]${RESET}\n" ""
sudo systemctl enable --now power-profiles-daemon.service 2>/dev/null || true
printf "  -> Power Profiles Daemon enabled %-13s ${C_GREEN}[ OK ]${RESET}\n" ""
sudo systemctl enable --now bluetooth.service 2>/dev/null || true
printf "  -> Bluetooth enabled %-29s ${C_GREEN}[ OK ]${RESET}\n" ""
sudo systemctl enable --now swayosd-libinput-backend.service 2>/dev/null || true
printf "  -> SwayOSD libinput backend enabled %-12s ${C_GREEN}[ OK ]${RESET}\n" ""
sudo systemctl --global enable pipewire wireplumber pipewire-pulse 2>/dev/null || true
systemctl --user enable easyeffects.service 2>/dev/null || true

# ==============================================================================
# Containers (podman) — socket, lingering, Kavita quadlet, gluetun VPN
# ==============================================================================
QUADLET_DIR="$HOME/.config/containers/systemd"

if [ "$OPT_CONTAINERS" = true ]; then
    echo -e "\n${C_CYAN}[ INFO ]${RESET} Setting up containers (podman quadlets)..."
    mkdir -p "$QUADLET_DIR"

    systemctl --user enable podman.socket >/dev/null 2>&1 && \
        printf "  -> podman user socket enabled %-17s ${C_GREEN}[ OK ]${RESET}\n" ""

    # User lingering — user services persist across login/logout
    if ! loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
        sudo loginctl enable-linger "$USER" 2>/dev/null && \
            printf "  -> User lingering enabled %-21s ${C_GREEN}[ OK ]${RESET}\n" "" || true
    fi

    # ── Kavita (reading server for the books tab) ──
    KAVITA_QUADLET="$QUADLET_DIR/kavita.container"
    KAVITA_LIBRARY="$HOME/Books"
    mkdir -p "$KAVITA_LIBRARY"

    if command -v podman &>/dev/null; then
        echo "  -> Pulling Kavita image (jvmilazz0/kavita:latest)..."
        podman pull docker.io/jvmilazz0/kavita:latest 2>&1 | tail -1 || true
    fi

    cat > "$KAVITA_QUADLET" <<EOF
[Unit]
Description=Kavita reading server
After=network-online.target

[Container]
Image=docker.io/jvmilazz0/kavita:latest
ContainerName=kavita
PublishPort=127.0.0.1:5000:5000
Environment=TZ=$(timedatectl show -p Timezone --value 2>/dev/null || echo "UTC")
Volume=kavita-config:/kavita/config
Volume=$KAVITA_LIBRARY:/library:Z
AutoUpdate=registry

[Service]
Restart=always
TimeoutStartSec=120

[Install]
WantedBy=default.target
EOF
    chmod 644 "$KAVITA_QUADLET"
    systemctl --user daemon-reload
    systemctl --user enable --now kavita.service 2>/dev/null \
        && printf "  -> kavita.service enabled %-21s ${C_GREEN}[ OK ]${RESET}\n" "" \
        || printf "  -> kavita.service pending (first login) %-6s ${C_YELLOW}[WARN]${RESET}\n" ""
    echo "  -> ${C_CYAN}Kavita:${RESET} http://localhost:5000  (library: $KAVITA_LIBRARY)"
fi

# ── gluetun (VPN egress for the movies/tv/anime scrapers) ──
if [ "$OPT_VPN" = true ]; then
    echo -e "\n${C_CYAN}[ INFO ]${RESET} Setting up gluetun VPN egress..."
    GLUETUN_SRC="$HYPR_DIR/provisioning/gluetun"
    if [ -d "$GLUETUN_SRC" ]; then
        mkdir -p "$QUADLET_DIR" "$HOME/.config/gluetun"
        cp "$GLUETUN_SRC/gluetun.container" "$QUADLET_DIR/gluetun.container"
        if [ ! -f "$HOME/.config/gluetun/gluetun.env" ]; then
            cp "$GLUETUN_SRC/gluetun.env.example" "$HOME/.config/gluetun/gluetun.env"
            chmod 600 "$HOME/.config/gluetun/gluetun.env"
            printf "  -> gluetun.env seeded from example %-13s ${C_YELLOW}[EDIT]${RESET}\n" ""
            echo -e "  -> ${C_YELLOW}Fill YOUR VPN credentials into ~/.config/gluetun/gluetun.env${RESET}"
            echo -e "  -> ${DIM}then: systemctl --user daemon-reload && systemctl --user start gluetun${RESET}"
        else
            printf "  -> gluetun.env already present %-17s ${C_GREEN}[ OK ]${RESET}\n" ""
        fi
        systemctl --user daemon-reload
        echo -e "  -> ${DIM}The movies video CLI is fail-closed: with vpn_enabled=true in"
        echo -e "     config.json, movie/tv/anime traffic refuses to run untunnelled.${RESET}"
    else
        printf "  -> provisioning/gluetun missing %-16s ${C_YELLOW}[WARN]${RESET}\n" ""
    fi
fi

# ==============================================================================
# AI stack: SearXNG → inference (Ollama | vLLM-TurboQuant) → Honcho
# ==============================================================================
if [ "$OPT_AI" = true ] || [ "$OPT_HERMES" = true ]; then
    mkdir -p "$QUADLET_DIR"
    # Reuse tokens from a previous install (sourced from VERSION_FILE); else mint.
    [ -z "${SEARXNG_AI_SECRET:-}" ] && SEARXNG_AI_SECRET="$(openssl rand -hex 32)"
fi

if [ "$OPT_AI" = true ]; then
    # ── SearXNG (private metasearch, JSON-only) ──
    echo -e "\n${C_CYAN}[ INFO ]${RESET} Setting up SearXNG (private metasearch)..."

    SEARXNG_CFG_DIR="$HOME/.config/searxng-ai"
    SEARXNG_QUADLET="$QUADLET_DIR/searxng-ai.container"
    mkdir -p "$SEARXNG_CFG_DIR"

    cat > "$SEARXNG_CFG_DIR/settings.yml" <<'YAMLEOF'
# SearXNG settings for the AI-facing instance: JSON output only, limiter off,
# text-heavy engines. The secret is injected via the quadlet's Environment=.
use_default_settings: true
general:
    debug: false
    instance_name: "searxng-ai"
    privacypolicy_url: false
    donation_url: false
    contact_url: false
server:
    secret_key: "${SEARXNG_AI_SECRET}"
    base_url: http://searxng-ai:8080/
    image_proxy: false
    method: "POST"
    public_instance: false
    limiter: false
    default_http_headers:
        X-Content-Type-Options: nosniff
        X-Robots-Tag: noindex, nofollow
ui:
    static_use_hash: true
    default_theme: simple
    infinite_scroll: false
search:
    safe_search: 0
    autocomplete: ""
    formats:
        - json
outgoing:
    request_timeout: 15.0
    max_request_timeout: 30.0
    pool_connections: 50
    pool_maxsize: 25
    enable_http2: false
engines:
    - name: duckduckgo
      disabled: false
      timeout: 10.0
    - name: brave
      disabled: false
      timeout: 10.0
    - name: wikipedia
      disabled: false
    - name: wikidata
      disabled: false
    - name: github
      disabled: false
    - name: stackoverflow
      disabled: false
    - name: arxiv
      disabled: false
    - name: docker hub
      disabled: false
      shortcut: dh
    - name: google
      disabled: true
    - name: bing
      disabled: true
doi_resolvers:
    'oadoi.org': 'https://oadoi.org/'
    'doi.org': 'https://doi.org/'
default_doi_resolver: 'oadoi.org'
YAMLEOF
    chmod 600 "$SEARXNG_CFG_DIR/settings.yml"

    command -v podman &>/dev/null && podman pull docker.io/searxng/searxng:latest 2>&1 | tail -1 || true

    cat > "$SEARXNG_QUADLET" <<EOF
[Unit]
Description=SearXNG private metasearch (AI-facing instance)
After=network-online.target

[Container]
Image=docker.io/searxng/searxng:latest
ContainerName=searxng-ai
PublishPort=127.0.0.1:8888:8080
Environment=SEARXNG_AI_SECRET=$SEARXNG_AI_SECRET
Environment=SEARXNG_BASE_URL=http://localhost:8888/
Volume=$SEARXNG_CFG_DIR/settings.yml:/etc/searxng/settings.yml:Z,ro
AutoUpdate=registry

[Service]
Restart=always
TimeoutStartSec=120

[Install]
WantedBy=default.target
EOF
    chmod 644 "$SEARXNG_QUADLET"
    systemctl --user daemon-reload
    systemctl --user enable --now searxng-ai.service 2>/dev/null \
        && printf "  -> searxng-ai.service enabled %-17s ${C_GREEN}[ OK ]${RESET}\n" "" \
        || printf "  -> searxng-ai.service pending %-17s ${C_YELLOW}[WARN]${RESET}\n" ""
    echo "  -> ${C_CYAN}JSON query:${RESET} http://localhost:8888/search?q=hello&format=json"

    # ── Inference: vLLM-TurboQuant (AMD) or Ollama (everyone else) ──
    if [ "$USE_VLLM_TURBOQUANT" = true ]; then
        echo -e "\n${C_CYAN}[ INFO ]${RESET} Setting up vLLM-TurboQuant (ROCm inference container)..."

        VLLM_QUADLET="$QUADLET_DIR/vllm-turboquant.container"
        VLLM_MODEL="${VLLM_MODEL:-Qwen/Qwen2.5-7B-Instruct}"
        VLLM_IMAGE="docker.io/rocm/vllm:latest"

        if [ ! -e /dev/kfd ] || ! ls /dev/dri/renderD* &>/dev/null; then
            echo -e "  -> ${C_YELLOW}/dev/kfd or /dev/dri/renderD* missing — install AMD drivers first${RESET}"
        fi

        command -v podman &>/dev/null && { echo "  -> Pulling vLLM ROCm image (multi-GB, be patient)..."; podman pull "$VLLM_IMAGE" 2>&1 | tail -1 || true; }

        cat > "$VLLM_QUADLET" <<EOF
[Unit]
Description=vLLM-TurboQuant inference server (ROCm, OpenAI-compatible at :8000)
After=network-online.target

[Container]
Image=$VLLM_IMAGE
ContainerName=vllm-turboquant
PublishPort=127.0.0.1:8000:8000
AddDevice=/dev/kfd
AddDevice=/dev/dri
GroupAdd=keep-groups
GroupAdd=render
GroupAdd=video
SecurityLabelDisable=true
ShmSize=8g
Volume=vllm-hf-cache:/root/.cache/huggingface
Environment=HF_HUB_ENABLE_HF_TRANSFER=1
Environment=VLLM_ROCM_USE_AITER=1
Exec=--model $VLLM_MODEL --host 0.0.0.0 --port 8000 --kv-cache-dtype turboquant_4bit_nc --gpu-memory-utilization 0.85 --max-model-len 8192 --enable-auto-tool-choice --tool-call-parser hermes
AutoUpdate=registry

[Service]
Restart=always
TimeoutStartSec=600

[Install]
WantedBy=default.target
EOF
        chmod 644 "$VLLM_QUADLET"
        systemctl --user daemon-reload
        systemctl --user enable --now vllm-turboquant.service 2>/dev/null \
            && printf "  -> vllm-turboquant.service enabled %-13s ${C_GREEN}[ OK ]${RESET}\n" "" \
            || printf "  -> vllm-turboquant.service pending %-12s ${C_YELLOW}[WARN]${RESET}\n" ""
        echo -e "  -> ${C_CYAN}OpenAI API:${RESET} http://localhost:8000/v1  (model: ${BOLD}$VLLM_MODEL${RESET})"
        echo -e "  -> ${DIM}First start downloads weights: journalctl --user -fu vllm-turboquant${RESET}"
    else
        echo -e "\n${C_CYAN}[ INFO ]${RESET} Setting up Ollama (variant: ${BOLD}$OLLAMA_PKG${RESET})..."
        if command -v ollama &>/dev/null; then
            # Lock Ollama to localhost via a drop-in (survives package updates).
            sudo mkdir -p /etc/systemd/system/ollama.service.d
            sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null <<'OLLAMAEOF'
[Service]
Environment=OLLAMA_HOST=127.0.0.1:11434
OLLAMAEOF
            sudo systemctl daemon-reload
            sudo systemctl enable --now ollama 2>/dev/null \
                && printf "  -> ollama.service running (localhost only) %-4s ${C_GREEN}[ OK ]${RESET}\n" "" \
                || printf "  -> ollama.service failed %-22s ${C_YELLOW}[WARN]${RESET}\n" ""
            echo -e "  -> ${C_CYAN}Pull a model with:${RESET} ${BOLD}ollama pull qwen2.5:7b${RESET}"
        else
            printf "  -> ollama not installed (variant: $OLLAMA_PKG) %-3s ${C_YELLOW}[WARN]${RESET}\n" ""
        fi
    fi

    # ── Honcho (cross-session memory for Hermes) — interactive, third-party ──
    if [ "$HEADLESS" != "true" ]; then
        echo -e "\n${C_CYAN}[ INFO ]${RESET} Honcho (cross-session memory for Hermes)..."
        HONCHO_DIR="$HOME/honcho"
        HONCHO_REPO="https://github.com/plastic-labs/honcho.git"

        HONCHO_COMPOSE=""
        if command -v docker &>/dev/null && docker compose version &>/dev/null; then
            HONCHO_COMPOSE="docker compose"
        elif command -v podman-compose &>/dev/null; then
            HONCHO_COMPOSE="podman-compose"
        fi

        if [ -z "$HONCHO_COMPOSE" ]; then
            printf "  -> Honcho needs docker/podman compose %-8s ${C_YELLOW}[WARN]${RESET}\n" ""
        else
            echo -e "  -> ${C_YELLOW}Honcho is third-party (plastic-labs, AGPL-3.0).${RESET}"
            read -rp "  Install & start Honcho now? [y/N] " yn
            if [[ "$yn" =~ ^[Yy]$ ]]; then
                if [ ! -d "$HONCHO_DIR/.git" ]; then
                    git clone --depth 1 "$HONCHO_REPO" "$HONCHO_DIR" >/dev/null 2>&1 \
                        && printf "  -> Honcho cloned to ~/honcho %-18s ${C_GREEN}[ OK ]${RESET}\n" ""
                else
                    ( cd "$HONCHO_DIR" && git pull --ff-only >/dev/null 2>&1 ) || true
                fi
                if [ -d "$HONCHO_DIR" ]; then
                    [ -f "$HONCHO_DIR/docker-compose.yml" ] || cp "$HONCHO_DIR/docker-compose.yml.example" "$HONCHO_DIR/docker-compose.yml" 2>/dev/null
                    if [ ! -f "$HONCHO_DIR/.env" ] && [ -f "$HONCHO_DIR/.env.template" ]; then
                        cp "$HONCHO_DIR/.env.template" "$HONCHO_DIR/.env"
                        {
                            echo ""
                            echo "# --- Local inference (added by mercury-dots installer) ---"
                            echo "LLM_OPENAI_COMPATIBLE_BASE_URL=http://localhost:11434/v1"
                            echo "LLM_OPENAI_COMPATIBLE_API_KEY=ollama"
                        } >> "$HONCHO_DIR/.env"
                    fi
                    echo "  -> Building & starting Honcho stack (first build takes minutes)..."
                    ( cd "$HONCHO_DIR" && $HONCHO_COMPOSE up -d --build ) >/dev/null 2>&1 \
                        && printf "  -> Honcho stack up %-28s ${C_GREEN}[ OK ]${RESET}\n" "" \
                        || printf "  -> Honcho stack failed to start %-15s ${C_YELLOW}[WARN]${RESET}\n" ""
                fi
            else
                echo "  -> Skipped Honcho install"
            fi
        fi
    fi
fi

# ==============================================================================
# Hermes gateway + autobrowse MCP — per-machine generated secrets.
# Everything secret is minted FRESH here; nothing secret ships in the repo.
# ==============================================================================
if [ "$OPT_HERMES" = true ]; then
    echo -e "\n${C_CYAN}[ INFO ]${RESET} Provisioning Hermes gateway (secrets generated per-machine)..."
    PROV="$HYPR_DIR/provisioning/hermes"

    if ! command -v hermes >/dev/null 2>&1 && [ ! -x /usr/local/lib/hermes-agent/venv/bin/hermes ]; then
        if [ "$HEADLESS" != "true" ]; then
            HERMES_INSTALL_URL="https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh"
            echo -e "  -> ${C_YELLOW}Hermes agent is third-party (NousResearch).${RESET}"
            echo -e "  -> ${DIM}Installer: $HERMES_INSTALL_URL (curl | sudo bash -s -- --skip-setup)${RESET}"
            read -rp "  Install Hermes Agent now? [y/N] " yn
            if [[ "$yn" =~ ^[Yy]$ ]]; then
                curl -fsSL "$HERMES_INSTALL_URL" | sudo bash -s -- --skip-setup \
                    && printf "  -> Hermes installed %-27s ${C_GREEN}[ OK ]${RESET}\n" "" \
                    || printf "  -> Hermes install failed %-22s ${C_YELLOW}[WARN]${RESET}\n" ""
            fi
        fi
    fi

    if [ ! -d "$PROV" ]; then
        printf "  -> provisioning/hermes missing — skipping %-5s ${C_YELLOW}[WARN]${RESET}\n" ""
    else
        gen() { openssl rand -hex "${1:-24}" 2>/dev/null || head -c "${1:-24}" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
        API_KEY="$(gen 24)"          # gateway API key == widget hermes_token
        AB_TOKEN="$(gen 24)"         # autobrowse AUTH_TOKEN == MCP_AUTOBROWSE_API_KEY
        TZ_VAL="$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"

        # 1) autobrowse quadlet (generated token)
        mkdir -p "$QUADLET_DIR"
        sed -e "s|__AUTOBROWSE_TOKEN__|$AB_TOKEN|g" -e "s|__TZ__|$TZ_VAL|g" \
            "$PROV/autobrowse.container.in" > "$QUADLET_DIR/autobrowse.container"

        # 2) gateway service (paths baked to this $HOME)
        mkdir -p "$HOME/.config/systemd/user"
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
                && printf "  -> hermes_token stored in keyring %-13s ${C_GREEN}[ OK ]${RESET}\n" ""
        fi

        systemctl --user daemon-reload 2>/dev/null || true
        systemctl --user enable autobrowse.service hermes-gateway.service >/dev/null 2>&1 || true
        printf "  -> Hermes gateway + autobrowse provisioned %-4s ${C_GREEN}[ OK ]${RESET}\n" ""
        echo -e "  -> ${DIM}Fresh secrets minted; services start on next login.${RESET}"
    fi
fi

# ==============================================================================
# App accounts (one shared password) + API keys — Dify/Kavita
# ==============================================================================
if [ "$OPT_ACCOUNTS" = true ]; then
    ACCT="$HYPR_DIR/provisioning/accounts/provision-accounts.sh"
    if [ -x "$ACCT" ] || [ -f "$ACCT" ]; then
        echo -e "\n${C_CYAN}[ INFO ]${RESET} Provisioning app accounts + API keys (waiting for services)..."
        for svc in "http://127.0.0.1:5000/api/health" "http://127.0.0.1:8090/console/api/setup"; do
            for _ in $(seq 1 30); do curl -sf -m3 "$svc" >/dev/null 2>&1 && break; sleep 2; done
        done
        bash "$ACCT" || echo -e "  -> ${C_YELLOW}Account provisioning had issues — re-run: $ACCT${RESET}"
    else
        printf "  -> provision-accounts.sh missing — skipping %-3s ${C_YELLOW}[WARN]${RESET}\n" ""
    fi
fi

# ==============================================================================
# Game streaming (tailscale + Apollo)
# ==============================================================================
if [ "$OPT_STREAMING" = true ]; then
    echo -e "\n${C_CYAN}[ INFO ]${RESET} Setting up game streaming..."
    sudo systemctl enable --now tailscaled >/dev/null 2>&1 \
        && printf "  -> tailscaled enabled %-25s ${C_GREEN}[ OK ]${RESET}\n" ""
    echo -e "  -> ${C_YELLOW}Run 'sudo tailscale up' to authenticate the tailnet.${RESET}"
    echo -e "  -> ${C_YELLOW}Apollo: enable its user service after first login; fence its ports${RESET}"
    echo -e "  -> ${C_YELLOW}to the tailnet (ufw: allow in on tailscale0) before exposing :47990.${RESET}"
fi

# ==============================================================================
# SDDM Astronaut theme
# ==============================================================================
if [[ "$SETUP_SDDM_THEME" == true ]]; then
    echo -e "\n${C_CYAN}[ INFO ]${RESET} Installing SDDM Astronaut theme..."

    THEME_DIR="/usr/share/sddm/themes/sddm-astronaut-theme"
    THEME_VARIANT="astronaut"
    THEME_REPO="https://github.com/Keyitdev/sddm-astronaut-theme.git"

    if [ -d "$THEME_DIR" ]; then
        sudo git -C "$THEME_DIR" fetch --quiet origin master 2>/dev/null || true
        sudo git -C "$THEME_DIR" reset --hard origin/master 2>/dev/null || true
        printf "  -> Astronaut theme updated %-19s ${C_GREEN}[ OK ]${RESET}\n" ""
    else
        if sudo git clone --depth 1 -b master "$THEME_REPO" "$THEME_DIR" 2>&1 | tail -2; then
            printf "  -> Astronaut theme cloned %-21s ${C_GREEN}[ OK ]${RESET}\n" ""
        else
            printf "  -> Astronaut clone failed %-21s ${C_YELLOW}[WARN]${RESET}\n" ""
        fi
    fi

    if [ -d "$THEME_DIR/Fonts" ]; then
        sudo cp -rn "$THEME_DIR/Fonts/"* /usr/share/fonts/ 2>/dev/null || true
        sudo fc-cache -f /usr/share/fonts >/dev/null
    fi

    if [ -f "$THEME_DIR/Themes/${THEME_VARIANT}.conf" ]; then
        sudo sed -i "s|^ConfigFile=.*|ConfigFile=Themes/${THEME_VARIANT}.conf|" "$THEME_DIR/metadata.desktop" 2>/dev/null
        VARIANT_CONF="$THEME_DIR/Themes/${THEME_VARIANT}.conf"
        sudo sed -i "s|^HideSessions=.*|HideSessions=false|" "$VARIANT_CONF" 2>/dev/null || true
        sudo sed -i "s|^ShowSessionsButton=.*|ShowSessionsButton=true|" "$VARIANT_CONF" 2>/dev/null || true
        printf "  -> Variant set: $THEME_VARIANT %-25s ${C_GREEN}[ OK ]${RESET}\n" ""
    elif [ -d "$THEME_DIR/Themes" ]; then
        first=$(ls "$THEME_DIR/Themes/" 2>/dev/null | grep '\.conf$' | head -1 | sed 's/\.conf$//')
        if [ -n "$first" ]; then
            sudo sed -i "s|^ConfigFile=.*|ConfigFile=Themes/${first}.conf|" "$THEME_DIR/metadata.desktop" 2>/dev/null
        fi
    fi

    sudo mkdir -p /etc/sddm.conf.d
    sudo tee /etc/sddm.conf >/dev/null <<'EOF'
[Theme]
Current=sddm-astronaut-theme
EOF

    if [[ "$SDDM_WAYLAND" == true ]]; then
        sudo tee /etc/sddm.conf.d/10-wayland.conf >/dev/null <<'EOF'
[General]
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_DISABLE_WINDOWDECORATION=1
EOF
    fi

    sudo tee /etc/sddm.conf.d/virtualkbd.conf >/dev/null <<'EOF'
[General]
InputMethod=qtvirtualkeyboard
EOF
    printf "  -> SDDM Astronaut configured %-18s ${C_GREEN}[ OK ]${RESET}\n" ""
fi

# Hyprland session check
HYPR_SESSION="/usr/share/wayland-sessions/hyprland.desktop"
if [ -f "$HYPR_SESSION" ]; then
    if ! pacman -Qo "$HYPR_SESSION" &>/dev/null; then
        sudo rm -f "$HYPR_SESSION"
        sudo pacman -S --needed --noconfirm hyprland 2>/dev/null
    fi
elif pacman -Q hyprland &>/dev/null; then
    sudo pacman -S --needed --noconfirm hyprland
fi
if [ -f /usr/share/wayland-sessions/hyprland-uwsm.desktop ]; then
    printf "  -> Hyprland-uwsm session available %-13s ${C_GREEN}[ OK ]${RESET}\n" ""
fi

# Trigger Template Compilation
if [ -f "$HYPR_DIR/scripts/settings_watcher.sh" ]; then
    chmod +x "$HYPR_DIR/scripts/settings_watcher.sh"
    bash "$HYPR_DIR/scripts/settings_watcher.sh" --compile 2>/dev/null || true
fi

# --- Persist version state ---
cat <<EOF > "$VERSION_FILE"
LOCAL_VERSION="$DOTS_VERSION"
WEATHER_API_KEY="$WEATHER_API_KEY"
WEATHER_CITY_ID="$WEATHER_CITY_ID"
WEATHER_UNIT="$WEATHER_UNIT"
DRIVER_CHOICE="$DRIVER_CHOICE"
KB_LAYOUTS="$KB_LAYOUTS"
KB_LAYOUTS_DISPLAY="$KB_LAYOUTS_DISPLAY"
KB_OPTIONS="$KB_OPTIONS"
WALLPAPER_DIR="$WALLPAPER_DIR"
OLLAMA_PKG="$OLLAMA_PKG"
USE_VLLM_TURBOQUANT="$USE_VLLM_TURBOQUANT"
VLLM_MODEL="${VLLM_MODEL:-}"
SEARXNG_AI_SECRET="${SEARXNG_AI_SECRET:-}"
EOF
chmod 600 "$VERSION_FILE"
printf "  -> Configuration saved %-25s ${C_GREEN}[ OK ]${RESET}\n" ""

# ==============================================================================
# Optional security hardening (informational)
# ==============================================================================
echo -e "\n${C_CYAN}[ INFO ]${RESET} Optional security hardening..."

if command -v ufw &>/dev/null; then
    if ! sudo ufw status 2>/dev/null | grep -q "active"; then
        printf "  -> ${BOLD}ufw is installed but inactive${RESET}\n"
        printf "     Run: ${C_GREEN}sudo ufw default deny incoming && sudo ufw default allow outgoing && sudo ufw enable${RESET}\n"
    else
        printf "  -> ufw active %-33s ${C_GREEN}[ OK ]${RESET}\n" ""
    fi
else
    printf "  -> ${C_YELLOW}No firewall configured.${RESET} Consider: ${BOLD}sudo pacman -S ufw && sudo systemctl enable --now ufw${RESET}\n"
fi

# ==============================================================================
# Final Output
# ==============================================================================
echo -e "\n${BOLD}${C_GREEN}"
cat << "EOF"
 ___ _  _ ___ _____ _   _    _      _ _____ ___ ___  _  _    ___ ___  __  __ ___ _    ___ _____ ___
|_ _| \| / __|_   _/_\ | |  | |    /_\_   _|_ _/ _ \| \| |  / __/ _ \ | \/  | _ \ |  | __|_   _| __|
 | || .` \__ \ | |/ _ \| |__| |__ / _ \| |  | | (_) | .` | | (_| (_) | |\/| |  _/ |__| _|  | | | _|
|___|_|\_|___/ |_/_/ \_\____|____/_/ \_\_| |___\___/|_|\_|  \___\___/|_|  |_|_| |____|___| |_| |___|

EOF
echo -e "${RESET}\n"

if [ ${#FAILED_PKGS[@]} -ne 0 ]; then
    echo -e "${BOLD}${C_RED}The following items failed — fix manually:${RESET}"
    for fp in "${FAILED_PKGS[@]}"; do
        echo -e "  - ${C_YELLOW}$fp${RESET}"
    done
    echo ""
fi

if [ "$OPT_AI" = true ]; then
    echo -e "${BOLD}AI Stack Summary:${RESET}"
    if [ "$USE_VLLM_TURBOQUANT" = true ]; then
        echo -e "  ${BOLD}vLLM-TurboQuant:${RESET} ${C_GREEN}http://localhost:8000/v1${RESET}  (model: ${BOLD}${VLLM_MODEL:-Qwen/Qwen2.5-7B-Instruct}${RESET})"
    else
        echo -e "  ${BOLD}Ollama:${RESET}     ${C_GREEN}http://localhost:11434${RESET}  (variant: ${BOLD}$OLLAMA_PKG${RESET})"
    fi
    echo -e "  ${BOLD}SearXNG:${RESET}    ${C_GREEN}http://localhost:8888${RESET}   (JSON: /search?q=...&format=json)"
    [ "$OPT_CONTAINERS" = true ] && echo -e "  ${BOLD}Kavita:${RESET}     ${C_GREEN}http://localhost:5000${RESET}"
fi

[ "$MODE" = "repo" ] && echo -e "Old configurations backed up to: ${C_CYAN}$BACKUP_DIR${RESET}"

# Render node check — Hyprland's aquamarine backend needs a working DRM render node.
if [ "$GPU_VENDOR" = "VM" ]; then
    if ! ls /dev/dri/renderD* &>/dev/null; then
        echo -e "\n${BOLD}${C_YELLOW}⚠ VM render node missing (/dev/dri/renderD128)${RESET}"
        echo -e "${C_YELLOW}Hyprland will FAIL with 'no matching devices found' in aquamarine.${RESET}"
        echo -e "${C_YELLOW}On the Proxmox host: qm set <vmid> --vga virtio-gl,memory=128${RESET}"
    fi
fi

echo -e "\nNext steps:"
echo -e "  1. Log out, then start the session with uwsm: TTY -> ${C_GREEN}uwsm start hyprland.desktop${RESET}"
echo -e "     (or via SDDM's 'Hyprland (uwsm)' entry if you enabled it)."
echo -e "  2. Store your API tokens in the keyring:"
echo -e "       ${C_GREEN}~/.config/hypr/scripts/secrets.sh set <key> <value>${RESET}"
echo -e "     (${DIM}secrets.sh list shows every key the widgets look for. Files never"
echo -e "      hold secret values — config.json carries only URLs/paths.${RESET})"
if [ "$OPT_AI" = true ] && [ "$USE_VLLM_TURBOQUANT" = false ]; then
    echo -e "  3. ${C_GREEN}ollama pull qwen2.5:7b${RESET}  (or whichever model you want as the default)"
fi
if [ "$OPT_VPN" = true ]; then
    echo -e "  4. Fill VPN credentials into ${C_GREEN}~/.config/gluetun/gluetun.env${RESET}, then:"
    echo -e "     ${C_GREEN}systemctl --user daemon-reload && systemctl --user start gluetun${RESET}"
fi
if [ "$OPT_STREAMING" = true ]; then
    echo -e "  5. ${C_GREEN}sudo tailscale up${RESET} to join your tailnet (Apollo web UI on :47990)"
fi
echo -e "  6. ${C_GREEN}sudo reboot${RESET} if you enabled SDDM"
