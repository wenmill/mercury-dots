#!/usr/bin/env bash
# Move every qs-hypr secret from gnome-keyring into KWallet, in one process.
#
# Two Secret Service providers cannot both own org.freedesktop.secrets, so this
# cannot be done by "start the new one, copy across". The old provider must
# release the bus name before ksecretd can take it, and the moment it does, the
# secrets become unreadable. So: read them all first, into memory, then hand the
# bus over, then write them back.
#
# Secret VALUES never touch disk. They live in shell variables for the seconds
# between read and write, and the script never prints or logs one. Only key
# NAMES are ever displayed.
#
#   keyring_migrate.sh --dry-run    list what would move; change nothing
#   keyring_migrate.sh              do it (asks first)
#
# Run this from inside a graphical session, BEFORE logging out after the
# installer disables pam_gnome_keyring — once you log out, gnome-keyring no
# longer starts and the old secrets are unreachable without re-enabling it.
set -uo pipefail

SERVICE="qs-hypr"
DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

die() { echo "error: $1" >&2; exit 1; }

command -v secret-tool >/dev/null 2>&1 || die "secret-tool (libsecret) is not installed."
[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || die "No D-Bus session bus — run this inside your desktop session."

provider() { busctl --user list 2>/dev/null | awk '$1=="org.freedesktop.secrets"{print $3}'; }

echo "Current Secret Service owner: $(provider || echo none)"

# The canonical key list lives in secrets.sh — read it rather than duplicating.
SECRETS_SH="$(dirname "$(readlink -f "$0")")/secrets.sh"
[ -f "$SECRETS_SH" ] || die "secrets.sh not found next to this script."
mapfile -t KEYS < <(sed -n '/^SECRET_KEYS=(/,/^)/p' "$SECRETS_SH" | tr ' ' '\n' \
    | grep -vE '^\(|^\)|SECRET_KEYS=|^$' | tr -d '"' | grep -E '^[a-z0-9_]+$')
[ "${#KEYS[@]}" -gt 0 ] || die "Could not parse SECRET_KEYS from secrets.sh."

# Phase 1 — read everything the CURRENT provider holds. Names to screen, values
# to an associative array and nowhere else.
declare -A VALUES=()
FOUND=()
for k in "${KEYS[@]}"; do
    v="$(timeout 10 secret-tool lookup service "$SERVICE" key "$k" </dev/null 2>/dev/null)" || true
    if [ -n "$v" ]; then VALUES["$k"]="$v"; FOUND+=("$k"); fi
done

if [ "${#FOUND[@]}" -eq 0 ]; then
    echo "No qs-hypr secrets found. Nothing to migrate."
    exit 0
fi

echo "Secrets to migrate (${#FOUND[@]}):"
printf '  %s\n' "${FOUND[@]}"

if [ "$DRY_RUN" = true ]; then
    echo
    echo "Dry run — nothing changed. Would then:"
    echo "  1. stop and mask gnome-keyring-daemon (releases org.freedesktop.secrets)"
    echo "  2. let ksecretd activate; KWallet asks once for a wallet password"
    echo "  3. re-store the ${#FOUND[@]} secrets above"
    echo "  4. read each one back to prove it survived"
    exit 0
fi

echo
echo "This stops gnome-keyring. Apps holding secrets through it (browsers,"
echo "network manager) lose access until you log out and back in."
read -rp "Continue? [y/N] " yn
[[ "$yn" =~ ^[Yy]$ ]] || { echo "Aborted; nothing changed."; exit 0; }

# Phase 2 — hand over the bus name.
systemctl --user mask --now gnome-keyring-daemon.service gnome-keyring-daemon.socket >/dev/null 2>&1 || true
pkill -x gnome-keyring-d 2>/dev/null || true
for _ in $(seq 1 10); do
    [ -z "$(provider)" ] && break
    sleep 1
done
[ -z "$(provider)" ] || die "gnome-keyring still owns the bus name; aborting with secrets untouched."

# Phase 3 — write them back. The first store activates ksecretd, which prompts
# once to create the wallet. Bounded, so an ignored prompt cannot wedge this.
FAILED=()
for k in "${FOUND[@]}"; do
    printf '%s' "${VALUES[$k]}" | timeout 60 secret-tool store --label="qs:$k" \
        service "$SERVICE" key "$k" >/dev/null 2>&1 || FAILED+=("$k")
done

# Phase 4 — prove it. A migration that reports success without reading the
# secrets back is a migration that quietly lost them.
LOST=()
for k in "${FOUND[@]}"; do
    got="$(timeout 10 secret-tool lookup service "$SERVICE" key "$k" </dev/null 2>/dev/null)" || true
    [ "$got" = "${VALUES[$k]}" ] || LOST+=("$k")
done

echo
echo "New Secret Service owner: $(provider || echo none)"
if [ "${#LOST[@]}" -eq 0 ]; then
    echo "All ${#FOUND[@]} secrets verified in KWallet."
else
    echo "NOT verified (${#LOST[@]}): ${LOST[*]}"
    echo "gnome-keyring is masked but its data is intact. To go back:"
    echo "  systemctl --user unmask gnome-keyring-daemon.service gnome-keyring-daemon.socket"
    echo "  sudo sed -i 's/^# disabled by mercury-dots[^:]*: //' /etc/pam.d/sddm"
    exit 1
fi
