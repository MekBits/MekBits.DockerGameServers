#!/usr/bin/env bash
# Healthcheck:
#   1. enshrouded_server.exe must be a running process under wine
#   2. The configured UDP query port must be in LISTEN state
# Exit 0 if healthy, 1 otherwise.
set -euo pipefail

: "${QUERY_PORT:=15637}"

# 1) Process check (wine wraps the .exe; pgrep -f matches the cmdline)
if ! pgrep -f 'enshrouded_server\.exe' >/dev/null 2>&1; then
    echo "unhealthy: enshrouded_server.exe not running"
    exit 1
fi

# 2) UDP port bound? (ss is in iproute2)
if ! ss -lun "sport = :${QUERY_PORT}" | grep -q ":${QUERY_PORT}"; then
    echo "unhealthy: UDP/${QUERY_PORT} not listening"
    exit 1
fi

exit 0
