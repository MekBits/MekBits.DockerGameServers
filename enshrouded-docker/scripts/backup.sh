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

    local lock_dir="${BACKUP_DIR}/.backup.lock"
    if ! mkdir "${lock_dir}" 2>/dev/null; then
        echo "[backup] another backup is already running, skipping."
        return 0
    fi

    local tmp="${out}.tmp"
    trap '[[ -n "${tmp:-}" && -f "${tmp}" ]] && rm -f -- "${tmp}"; rmdir "${lock_dir}" 2>/dev/null || true' RETURN

    if ! tar -czf "${tmp}" "${SAVE_DIRECTORY}"; then
        echo "[backup] tar failed; no archive written."
        return 1
    fi
    mv -f "${tmp}" "${out}"
    tmp=""
    echo "[backup] wrote ${out}"

    # Prune oldest beyond BACKUP_KEEP
    mapfile -t old < <(ls -1t "${BACKUP_DIR}"/savegame-*.tar.gz 2>/dev/null | tail -n +"$((BACKUP_KEEP + 1))")
    for f in "${old[@]}"; do
        rm -f -- "${f}" && echo "[backup] pruned ${f}"
    done

    trap - RETURN
    rmdir "${lock_dir}" 2>/dev/null || true
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
