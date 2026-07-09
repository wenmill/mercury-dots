#!/usr/bin/env bash
# Bring the keyring up, and move the Hermes API key into it — from inside a
# graphical session.
#
# The installer cannot do this reliably. With no wallet yet, the first
# `secret-tool store` triggers a wallet-creation prompt, which needs a desktop to
# display it. Run from a TTY, that either hangs forever or fails, and the
# installer's store used to swallow the failure silently: a keyring with zero
# secrets in it looked like a successful install, and every widget that reads
# hermes_token got nothing.
#
# Nothing is lost when that happens — the key is written to ~/.hermes/.env by the
# installer, and this script reads it back. Runs from autostart, is a no-op once
# the key is in the keyring (one lookup), and is safe to run repeatedly.
set -uo pipefail

SERVICE="qs-hypr"
KEY="hermes_token"
ENV_FILE="$HOME/.hermes/.env"
LOG="/tmp/keyring-init.log"

command -v secret-tool >/dev/null 2>&1 || exit 0

# Outside a session there is no way to answer a wallet prompt, and no point
# logging noise on every TTY login.
[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || exit 0

# Already stored? Then the keyring is up and unlocked. Nothing to do.
if timeout 10 secret-tool lookup service "$SERVICE" key "$KEY" </dev/null 2>/dev/null | grep -q .; then
    exit 0
fi

[ -f "$ENV_FILE" ] || exit 0

# API_SERVER_KEY=<value> — take the last assignment, strip optional quotes.
API_KEY="$(sed -n 's/^API_SERVER_KEY=//p' "$ENV_FILE" | tail -n1 | sed 's/^["'\'']//; s/["'\'']$//')"
[ -n "$API_KEY" ] || exit 0

# The Secret Service is D-Bus activated, so it may not be up in the first
# seconds of a session. Retry rather than racing it. Each attempt is bounded:
# a wallet prompt the user ignores must not leave a process wedged forever.
for _ in $(seq 1 6); do
    printf '%s' "$API_KEY" | timeout 20 secret-tool store --label="qs:$KEY" \
        service "$SERVICE" key "$KEY" >>"$LOG" 2>&1
    rc=${PIPESTATUS[1]}
    [ "$rc" -eq 0 ] && break
    sleep 5
done

if [ "${rc:-1}" -eq 0 ]; then
    notify-send "Keyring" "Hermes token stored — widgets can authenticate." 2>/dev/null || true
else
    notify-send -u critical "Keyring" \
        "Could not store the Hermes token (exit $rc). See $LOG" 2>/dev/null || true
fi
