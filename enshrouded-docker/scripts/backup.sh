#!/usr/bin/env bash
# Savegame backup.
#   --once  : create a single timestamped tar.gz of the savegame dir.
#   --loop  : run --once every BACKUP_INTERVAL seconds; prune to BACKUP_KEEP.
set -euo pipefail

: "${SAVE_DIRECTORY:=./savegame}"
: "${BACKUP_DIR:=/home/steam/enshrouded/backups}"
: "${BACKUP_INTERVAL:=3600}"   # seconds between backups in loop mode
: "${BACKUP_KEEP:=24}"         # how many archives to retain

cd "${SERVER_DIR:-/home/steam/enshrouded}"

do_once() {
    mkdir -p "${BACKUP_DIR}"
    local stamp
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    local out="${BACKUP_DIR}/savegame-${stamp}.tar.gz"
    if [[ ! -d "${SAVE_DIRECTORY}" ]]; then
        echo "[backup] save dir '${SAVE_DIRECTORY}' missing, skipping."
        return 0
    fi
    tar -czf "${out}" "${SAVE_DIRECTORY}"
    echo "[backup] wrote ${out}"

    # Prune oldest beyond BACKUP_KEEP
    mapfile -t old < <(ls -1t "${BACKUP_DIR}"/savegame-*.tar.gz 2>/dev/null | tail -n +"$((BACKUP_KEEP + 1))")
    for f in "${old[@]}"; do
        rm -f -- "${f}" && echo "[backup] pruned ${f}"
    done
}

case "${1:-}" in
    --loop)
        while true; do
            sleep "${BACKUP_INTERVAL}"
            do_once || echo "[backup] cycle failed (continuing)"
        done
        ;;
    --once|"")
        do_once
        ;;
    *)
        echo "usage: $0 [--once|--loop]" >&2
        exit 2
        ;;
esac
