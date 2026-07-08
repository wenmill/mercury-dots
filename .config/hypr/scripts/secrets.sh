#!/usr/bin/env bash
# =============================================================================
# secrets.sh — Secret Service helper for the Hyprland / Quickshell tools.
# -----------------------------------------------------------------------------
# Keeps API tokens and the matrix login OUT of the plaintext config files by
# storing them in the system keyring (the freedesktop Secret Service). It is
# provider-agnostic: it works with gnome-keyring today and KWallet later — both
# implement org.freedesktop.secrets, so swapping the daemon needs NO change here
# (just re-run `secrets.sh migrate` to re-store the values in the new wallet).
#
# Subcommands:
#   get KEY            print one secret value (empty if unset)
#   set KEY VALUE      store one secret value
#   getjson [FILE]     print FILE's JSON with secret keys overlaid from the
#                      keyring (non-secret settings come straight from FILE).
#                      This is what the QML tools call instead of `cat FILE`.
#   matrixcreds        print {homeserver,user,password,token} from the keyring
#   migrate            read secrets out of the plaintext config files and store
#                      them in the keyring (idempotent; safe to re-run)
#   strip              blank the secret VALUES in the plaintext config files
#                      (run only AFTER migrate + verify)
#   list               show which secret keys are set in the keyring
# =============================================================================
set -uo pipefail

SERVICE="qs-hypr"
CONFIG="$HOME/.config/hypr/config.json"
AICONFIG="$HOME/.config/hypr/ai_config.json"

# Keys treated as secrets (migrated out of the plaintext files into the keyring).
SECRET_KEYS=(
  hermes_token ollama_api_key lichess_token kavita_api_key autobrowse_token
  matrix_homeserver matrix_user matrix_password matrix_token
  screenpipe_token dify_dataset_key dify_app_key apollo_web_user apollo_web_password
  mal_access_token navidrome_pass
)
# NOTE: `app_admin_password` (the one shared password for the self-hosted app
# accounts, set by provisioning/accounts/provision-accounts.sh) is stored in the
# SAME keyring/service but is deliberately NOT listed above: it must never be
# overlaid into config.json by `getjson` (widgets don't need the master password
# and it should not enter any widget's JS context). Read it directly when needed:
#   secret-tool lookup service qs-hypr key app_admin_password

_lookup() { secret-tool lookup service "$SERVICE" key "$1" 2>/dev/null; }
_store()  { printf '%s' "$2" | secret-tool store --label="qs:$1" service "$SERVICE" key "$1" 2>/dev/null; }
_clear()  { secret-tool clear service "$SERVICE" key "$1" 2>/dev/null; }

cmd="${1:-}"
case "$cmd" in
  get)
    _lookup "${2:?key required}"
    ;;

  set)
    _store "${2:?key required}" "${3-}"
    ;;

  getjson)
    file="${2:-$CONFIG}"
    base="$(cat "$file" 2>/dev/null)"; [ -z "$base" ] && base='{}'
    # Overlay only the secret keys that actually exist in the keyring; everything
    # else (urls, paths, policies) passes through untouched from the file.
    args=(); filter='.'; i=0
    for k in "${SECRET_KEYS[@]}"; do
      v="$(_lookup "$k")"
      if [ -n "$v" ]; then
        args+=(--arg "k$i" "$k" --arg "v$i" "$v")
        filter="$filter | .[\$k$i]=\$v$i"
        i=$((i+1))
      fi
    done
    printf '%s' "$base" | jq -c "${args[@]}" "$filter" 2>/dev/null || printf '%s' "$base"
    ;;

  matrixcreds)
    jq -nc \
      --arg hs "$(_lookup matrix_homeserver)" \
      --arg us "$(_lookup matrix_user)" \
      --arg pw "$(_lookup matrix_password)" \
      --arg tk "$(_lookup matrix_token)" \
      '{homeserver:$hs, user:$us, password:$pw, token:$tk}'
    ;;

  migrate)
    for f in "$CONFIG" "$AICONFIG"; do
      [ -f "$f" ] || continue
      for k in "${SECRET_KEYS[@]}"; do
        v="$(jq -r --arg k "$k" '.[$k] // empty' "$f" 2>/dev/null)"
        if [ -n "$v" ] && [ "$v" != "null" ]; then
          _store "$k" "$v" && echo "stored $k (from $(basename "$f"))"
        fi
      done
    done
    ;;

  strip)
    for f in "$CONFIG" "$AICONFIG"; do
      [ -f "$f" ] || continue
      tmp="$(mktemp)"
      keys_json="$(printf '%s\n' "${SECRET_KEYS[@]}" | jq -R . | jq -sc .)"
      if jq --argjson ks "$keys_json" \
            'reduce $ks[] as $k (.; if has($k) then .[$k]="" else . end)' \
            "$f" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$f"; chmod 600 "$f"; echo "stripped secrets from $(basename "$f")"
      else
        rm -f "$tmp"; echo "skip $(basename "$f") (parse error)"
      fi
    done
    ;;

  list)
    for k in "${SECRET_KEYS[@]}"; do
      v="$(_lookup "$k")"
      printf '%-18s %s\n' "$k" "$([ -n "$v" ] && echo '<set>' || echo '-')"
    done
    ;;

  *)
    echo "usage: secrets.sh {get KEY|set KEY VAL|getjson [FILE]|matrixcreds|migrate|strip|list}" >&2
    exit 1
    ;;
esac
