#!/usr/bin/env bash
# Reboot into the other OS (the one that can run Valorant — Vanguard is a
# kernel driver and will not run under Linux or in a VM).
#
# Wired to the Valorant button in BatteryPopup.qml. It sets the UEFI BootNext
# variable, which the firmware consumes exactly once, then reboots. BootOrder is
# never touched: after that single boot the machine returns to booting Linux by
# itself, so a failed Windows boot can't strand you in the wrong OS.
#
# Privileges: writing an EFI variable needs root, but this desktop has no
# passwordless sudo, and a GUI button cannot answer a terminal password prompt.
# pkexec routes the request to the running polkit agent, which asks graphically.
# Reading efibootmgr, and `systemctl reboot`, both work unprivileged.
#
#   valorant.sh              pick the other OS, confirm, reboot
#   valorant.sh --dry-run    print what it would do, touch nothing
#   valorant.sh Boot0002     force a specific entry (skips detection)
#
# VALORANT_BOOT_ENTRY=Boot0002 overrides detection without an argument.
set -uo pipefail

DRY_RUN=false
FORCED="${VALORANT_BOOT_ENTRY:-}"
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) FORCED="$arg" ;;
        *) echo "usage: $0 [--dry-run] [BootXXXX]" >&2; exit 2 ;;
    esac
done

die() {   # message — tell the user on screen, not just in a log nobody reads
    notify-send -u critical "Boot to Windows" "$1" 2>/dev/null || true
    echo "$1" >&2
    exit 1
}

command -v efibootmgr >/dev/null 2>&1 || die "efibootmgr is not installed."
[ -d /sys/firmware/efi ] || die "Not a UEFI system — BootNext does not exist."

EFI_OUT="$(efibootmgr 2>/dev/null)" || die "Could not read EFI boot entries."
CURRENT="$(printf '%s\n' "$EFI_OUT" | sed -n 's/^BootCurrent: *\([0-9A-Fa-f]*\).*/\1/p')"

# Candidates: real, bootable, on-disk operating systems other than this one.
#
#   FvVol(/FvFile(          firmware-resident apps (setup, boot menu) — not an OS
#   MAC(/Uri(               PXE and HTTP network boot — not an OS
#   auto_created_boot_option firmware's generic fallback for a disk it found,
#                           which on a single-disk machine points straight back
#                           at the disk we are already booted from
#   BootXXXX without '*'    the entry is marked inactive
#
# Anything surviving that is a genuine other OS loader. Requiring exactly one is
# deliberate: guessing which of several to boot is not this script's business.
mapfile -t CANDIDATES < <(
    printf '%s\n' "$EFI_OUT" \
    | grep -E '^Boot[0-9A-Fa-f]{4}\*' \
    | grep -v "^Boot${CURRENT}\*" \
    | grep -vE 'FvVol\(|FvFile\(' \
    | grep -vE 'MAC\(|Uri\(' \
    | grep -v 'auto_created_boot_option'
)

if [ -n "$FORCED" ]; then
    TARGET_NUM="${FORCED#Boot}"
    TARGET_NAME="$(printf '%s\n' "$EFI_OUT" | sed -n "s/^Boot${TARGET_NUM}\** *\([^\t]*\).*/\1/p")"
    [ -n "$TARGET_NAME" ] || die "No such boot entry: $FORCED"
elif [ "${#CANDIDATES[@]}" -eq 0 ]; then
    die "No other OS to boot. Only this system, firmware menus and network boot were found."
elif [ "${#CANDIDATES[@]}" -gt 1 ]; then
    names="$(printf '%s\n' "${CANDIDATES[@]}" | sed 's/^\(Boot[0-9A-Fa-f]*\)\** *\([^\t]*\).*/  \1  \2/')"
    die "$(printf 'More than one other OS found; refusing to guess.\n%s\nRun: valorant.sh BootXXXX' "$names")"
else
    TARGET_NUM="$(printf '%s\n' "${CANDIDATES[0]}" | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p')"
    TARGET_NAME="$(printf '%s\n' "${CANDIDATES[0]}" | sed 's/^Boot[0-9A-Fa-f]*\** *//; s/\t.*//')"
fi

if [ "$DRY_RUN" = true ]; then
    printf 'current : Boot%s\n' "$CURRENT"
    printf 'target  : Boot%s (%s)\n' "$TARGET_NUM" "$TARGET_NAME"
    printf 'would run: pkexec efibootmgr --bootnext %s && systemctl reboot\n' "$TARGET_NUM"
    exit 0
fi

# Rebooting is not undoable and the button is one click away from a full-screen
# game. Ask, and default to No. If there is no way to ask, do not reboot: a
# missing dialog must fail closed, not silently take the machine down.
if command -v zenity >/dev/null 2>&1; then
    zenity --question --no-wrap --default-cancel \
        --title="Reboot into $TARGET_NAME?" \
        --text="$(printf 'Reboot now into <b>%s</b> to play Valorant?\n\nThis boot only — the next reboot returns to Linux.\nUnsaved work will be lost.' "$TARGET_NAME")" \
        2>/dev/null || exit 0
elif [ "${VALORANT_NO_CONFIRM:-0}" != "1" ]; then
    die "zenity is not installed, so the reboot cannot be confirmed. Install zenity, or set VALORANT_NO_CONFIRM=1 to skip the prompt."
fi

# BootNext, not BootOrder: consumed once by the firmware, then forgotten.
if ! pkexec efibootmgr --bootnext "$TARGET_NUM" >/dev/null 2>&1; then
    die "Could not set BootNext (authentication cancelled or failed)."
fi

notify-send "Boot to Windows" "Rebooting into $TARGET_NAME..." 2>/dev/null || true
sleep 1
systemctl reboot
