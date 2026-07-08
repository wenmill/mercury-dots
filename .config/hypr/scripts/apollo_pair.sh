#!/usr/bin/env bash
# Submit a Moonlight pairing PIN to Apollo: apollo_pair.sh <PIN> [device-name]
# Auths with the web credentials stored in the keyring (secrets.sh).
set -uo pipefail
PIN="${1:?usage: apollo_pair.sh <PIN> [device-name]}"
NAME="${2:-moonlight-client}"
SEC="$HOME/.config/hypr/scripts/secrets.sh"
U="$(bash "$SEC" get apollo_web_user)"; P="$(bash "$SEC" get apollo_web_password)"
C="$(mktemp)"; trap 'rm -f "$C"' EXIT
curl -sk -c "$C" -o /dev/null -X POST https://localhost:47990/api/login \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$U\",\"password\":\"$P\"}"
curl -sk -b "$C" -X POST https://localhost:47990/api/pin \
    -H "Content-Type: application/json" \
    -d "{\"pin\":\"$PIN\",\"name\":\"$NAME\"}"
echo
