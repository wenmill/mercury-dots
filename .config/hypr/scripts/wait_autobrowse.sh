#!/usr/bin/env bash
# Block until the autobrowse MCP endpoint is actually answering, so
# hermes-gateway doesn't race the container's slow browser boot.
#
# The quadlet reports the unit "started" as soon as conmon is up, but the
# camoufox browser inside needs ~90s before the MCP server on :8080 accepts
# requests. Hermes' own MCP client only retries for ~7s then gives up for the
# whole gateway lifetime — so at boot autobrowse was permanently missing.
# An unauthenticated GET returns 401 the moment the server is live (vs. a
# connection refusal while it's still booting); either a real HTTP status or a
# timeout counts as "up enough to hand off to Hermes' retry logic".
URL="${AUTOBROWSE_MCP_URL:-http://localhost:8080/mcp/}"
DEADLINE=$(( $(date +%s) + ${AUTOBROWSE_WAIT_SECS:-150} ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$URL" 2>/dev/null)
    # 000 = connection refused / no response yet; anything else = server is up.
    [ "$code" != "000" ] && exit 0
    sleep 3
done
# Don't fail the gateway if autobrowse never came up — it degrades gracefully
# (the MCP server is simply absent). Exit 0 so ExecStartPre never blocks boot.
exit 0
