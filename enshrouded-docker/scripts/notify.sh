#!/usr/bin/env bash
# Discord webhook notifier.  Usage: notify.sh <event> <message>
# No-op (success) if DISCORD_WEBHOOK_URL is unset.
set -euo pipefail

: "${DISCORD_WEBHOOK_URL:=}"
[[ -z "${DISCORD_WEBHOOK_URL}" ]] && exit 0

event="${1:-info}"
message="${2:-}"

case "${event}" in
    start)  emoji=":green_circle:" ;;
    stop)   emoji=":white_circle:" ;;
    crash)  emoji=":red_circle:"   ;;
    backup) emoji=":floppy_disk:"  ;;
    *)      emoji=":information_source:" ;;
esac

payload=$(jq -n \
    --arg content "${emoji} ${message}" \
    '{username: "Enshrouded", content: $content}')

# Fire and forget; never let a webhook failure take down the server.
curl -fsS -X POST -H 'Content-Type: application/json' \
     --max-time 5 \
     -d "${payload}" "${DISCORD_WEBHOOK_URL}" >/dev/null || true
