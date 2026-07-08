#!/usr/bin/env bash
# =============================================================================
# provision-accounts.sh — one shared password for every self-hosted app account,
# and auto-generated API keys stashed in the keyring.
# -----------------------------------------------------------------------------
# On a fresh machine each app (Dify, Kavita, …) wants its own admin account and
# its own API key, which the widgets/bridge then need. This script unifies that:
#
#   * ONE password (stored in the keyring as `app_admin_password`) is used for
#     every app account. On first run it prompts once — type your LOGIN password
#     so there's a single password to remember (it is NOT read from the system;
#     you enter it, and it's kept only in the Secret Service, never in a file).
#   * Each app's account is created (first-run) or logged into (already set up)
#     with that password, then its API key is fetched/minted and stored in the
#     keyring under the key secrets.sh already knows: `kavita_api_key`,
#     `dify_dataset_key`, `dify_app_key`.
#
# Idempotent: re-running re-uses the stored password, logs in, and refreshes any
# missing keys. Safe to run from install.sh or by hand. Needs curl + jq.
#
# Env overrides (optional): APP_EMAIL, APP_USER, KAVITA_URL, DIFY_URL.
# =============================================================================
set -uo pipefail

SERVICE="qs-hypr"
KAVITA_URL="${KAVITA_URL:-http://127.0.0.1:5000}"
DIFY_URL="${DIFY_URL:-http://127.0.0.1:8090}"
# Standard identity for every self-hosted app account (override per-run if
# needed). No personal defaults ship — user comes from the system, email is
# prompted when not provided via APP_EMAIL.
APP_USER="${APP_USER:-$USER}"
APP_EMAIL="${APP_EMAIL:-}"
if [ -z "$APP_EMAIL" ]; then
  read -rp "  App account email (used for the self-hosted app logins): " APP_EMAIL
  [ -z "$APP_EMAIL" ] && { echo "  ! an email is required"; exit 1; }
fi

# minimal colour/log helpers (standalone; install.sh has its own)
c() { printf '%s' "${2:-}"; }
info() { printf '  \033[36m•\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

command -v jq   >/dev/null || { warn "jq not found — skipping account provisioning"; exit 0; }
command -v curl >/dev/null || { warn "curl not found — skipping account provisioning"; exit 0; }
command -v secret-tool >/dev/null || { warn "secret-tool not found — no keyring, skipping"; exit 0; }

kset() { printf '%s' "$2" | secret-tool store --label="qs:$1" service "$SERVICE" key "$1" 2>/dev/null; }
kget() { secret-tool lookup service "$SERVICE" key "$1" 2>/dev/null; }

# ── the one shared password ──────────────────────────────────────────────────
APP_PW="$(kget app_admin_password)"
if [ -z "$APP_PW" ]; then
  echo
  info "No shared app password stored yet."
  info "Enter a password for the app accounts (Dify, Kavita). Tip: use your LOGIN"
  info "password so you only remember one. It is stored only in the keyring."
  read -rsp "  App account password: " APP_PW; echo
  read -rsp "  Confirm: " APP_PW2; echo
  if [ -z "$APP_PW" ] || [ "$APP_PW" != "$APP_PW2" ]; then
    warn "Empty or mismatched password — skipping account provisioning."
    exit 0
  fi
  kset app_admin_password "$APP_PW" && ok "Shared app password stored (keyring: app_admin_password)"
fi

info "Accounts: user=$APP_USER  email=$APP_EMAIL"

# ── Kavita ───────────────────────────────────────────────────────────────────
# First run: /api/account/register makes the FIRST user an admin. Already set up:
# /api/account/login. Either returns a UserDto carrying `apiKey`; if absent we
# GET /api/account. Kavita must be reachable (container up) or we skip.
provision_kavita() {
  curl -sf -m5 "$KAVITA_URL/api/health" >/dev/null 2>&1 || { warn "Kavita not reachable at $KAVITA_URL — skipping"; return; }
  local resp token apikey
  resp="$(curl -s -m15 -X POST "$KAVITA_URL/api/account/register" -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg u "$APP_USER" --arg e "$APP_EMAIL" --arg p "$APP_PW" \
              '{username:$u,email:$e,password:$p}')" 2>/dev/null)"
  token="$(printf '%s' "$resp" | jq -r '.token // empty' 2>/dev/null)"
  if [ -z "$token" ]; then                       # already registered → log in
    resp="$(curl -s -m15 -X POST "$KAVITA_URL/api/account/login" -H 'Content-Type: application/json' \
          -d "$(jq -nc --arg u "$APP_USER" --arg p "$APP_PW" '{username:$u,password:$p}')" 2>/dev/null)"
    token="$(printf '%s' "$resp" | jq -r '.token // empty' 2>/dev/null)"
  fi
  [ -z "$token" ] && { warn "Kavita: auth failed for '$APP_USER' (wrong password, or a different admin username exists)"; return; }
  apikey="$(printf '%s' "$resp" | jq -r '.apiKey // empty' 2>/dev/null)"
  [ -z "$apikey" ] && apikey="$(curl -s -m10 "$KAVITA_URL/api/account" -H "Authorization: Bearer $token" 2>/dev/null | jq -r '.apiKey // empty' 2>/dev/null)"
  if [ -n "$apikey" ]; then kset kavita_api_key "$apikey" && ok "Kavita account ok, kavita_api_key stored"
  else warn "Kavita: authenticated but no apiKey in the response"; fi
}

# ── Dify ─────────────────────────────────────────────────────────────────────
# First run: POST /console/api/setup makes the admin. Then login → access_token.
# Dataset service key → dify_dataset_key (push: vault → KB). A "AI Brain
# Writeback" chat app + its service key → dify_app_key (pull: answers → vault
# Inbox). Reuses existing app/keys when present.
provision_dify() {
  curl -sf -m5 "$DIFY_URL/console/api/setup" >/dev/null 2>&1 || { warn "Dify console not reachable at $DIFY_URL — skipping"; return; }
  local step at appid dk ak
  step="$(curl -s -m10 "$DIFY_URL/console/api/setup" 2>/dev/null | jq -r '.step // empty' 2>/dev/null)"
  if [ "$step" = "not_started" ]; then
    curl -s -m20 -X POST "$DIFY_URL/console/api/setup" -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg e "$APP_EMAIL" --arg n "$APP_USER" --arg p "$APP_PW" \
            '{email:$e,name:$n,password:$p}')" >/dev/null 2>&1
    ok "Dify admin account created"
  fi
  at="$(curl -s -m20 -X POST "$DIFY_URL/console/api/login" -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg e "$APP_EMAIL" --arg p "$APP_PW" '{email:$e,password:$p}')" 2>/dev/null \
      | jq -r '.data.access_token // .access_token // empty' 2>/dev/null)"
  [ -z "$at" ] && { warn "Dify: login failed for $APP_EMAIL (wrong password, or a different admin email exists)"; return; }
  local AUTH=(-H "Authorization: Bearer $at")

  # dataset service key (push direction) — reuse newest, else mint
  dk="$(curl -s -m10 "${AUTH[@]}" "$DIFY_URL/console/api/datasets/api-keys" 2>/dev/null | jq -r '.data[0].token // empty' 2>/dev/null)"
  [ -z "$dk" ] && dk="$(curl -s -m10 -X POST "${AUTH[@]}" "$DIFY_URL/console/api/datasets/api-keys" 2>/dev/null | jq -r '.token // empty' 2>/dev/null)"
  [ -n "$dk" ] && { kset dify_dataset_key "$dk" && ok "Dify dataset key stored (dify_dataset_key)"; }

  # writeback chat app (pull direction) — find "AI Brain Writeback", else create
  appid="$(curl -s -m10 "${AUTH[@]}" "$DIFY_URL/console/api/apps?page=1&limit=100" 2>/dev/null \
         | jq -r '.data[]? | select(.name=="AI Brain Writeback") | .id' 2>/dev/null | head -1)"
  if [ -z "$appid" ]; then
    appid="$(curl -s -m20 -X POST "${AUTH[@]}" -H 'Content-Type: application/json' "$DIFY_URL/console/api/apps" \
           -d '{"name":"AI Brain Writeback","mode":"chat","icon_type":"emoji","icon":"🧠","icon_background":"#E4FBCC","description":"Answers written back to the AI Brain vault Inbox by the ai-obsidian bridge"}' 2>/dev/null \
           | jq -r '.id // empty' 2>/dev/null)"
    [ -n "$appid" ] && ok "Dify 'AI Brain Writeback' chat app created"
  fi
  if [ -n "$appid" ]; then
    ak="$(curl -s -m10 "${AUTH[@]}" "$DIFY_URL/console/api/apps/$appid/api-keys" 2>/dev/null | jq -r '.data[0].token // empty' 2>/dev/null)"
    [ -z "$ak" ] && ak="$(curl -s -m10 -X POST "${AUTH[@]}" "$DIFY_URL/console/api/apps/$appid/api-keys" 2>/dev/null | jq -r '.token // empty' 2>/dev/null)"
    [ -n "$ak" ] && { kset dify_app_key "$ak" && ok "Dify app key stored (dify_app_key) — vault Inbox writeback enabled"; }
  else
    warn "Dify: no writeback app id — skipping app key"
  fi
}

provision_kavita
provision_dify
echo
ok "Account provisioning done. Keys live in the keyring (see: secrets.sh list)."
