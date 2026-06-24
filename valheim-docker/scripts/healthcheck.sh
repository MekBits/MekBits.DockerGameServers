#!/usr/bin/env bash
# Healthcheck:
#   1. valheim_server.x86_64 must be a running process
#   2. The Steam query UDP port (SERVER_PORT + 1) must be bound
# Exit 0 if healthy, 1 otherwise.
set -euo pipefail

: "${SERVER_PORT:=2456}"
: "${SERVER_QUERY_PORT:=$((SERVER_PORT + 1))}"

if ! pgrep -f 'valheim_server' >/dev/null 2>&1; then
    echo "unhealthy: valheim_server not running"
    exit 1
fi

if ! ss -lun "sport = :${SERVER_QUERY_PORT}" | grep -q ":${SERVER_QUERY_PORT}"; then
    echo "unhealthy: UDP/${SERVER_QUERY_PORT} not listening"
    exit 1
fi

exit 0
