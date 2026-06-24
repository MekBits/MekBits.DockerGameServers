#!/usr/bin/env bash
# Healthcheck:
#   1. VRisingServer.exe must be a running process under wine
#   2. The configured UDP query port must be bound
# Exit 0 if healthy, 1 otherwise.
set -euo pipefail

: "${QUERY_PORT:=27015}"

if ! pgrep -f 'VRisingServer\.exe' >/dev/null 2>&1; then
    echo "unhealthy: VRisingServer.exe not running"
    exit 1
fi

if ! ss -lun "sport = :${QUERY_PORT}" | grep -q ":${QUERY_PORT}"; then
    echo "unhealthy: UDP/${QUERY_PORT} not listening"
    exit 1
fi

exit 0
