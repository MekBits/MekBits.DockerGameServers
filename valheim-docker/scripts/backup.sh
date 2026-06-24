#!/usr/bin/env bash
# Savegame backup.
#   --once  : create a single timestamped tar.gz of the world + admin lists.
#   --loop  : run --once every BACKUP_INTERVAL seconds; prune to BACKUP_KEEP.
set -euo pipefail

: "${DATA_DIR:=/home/steam/valheim-data}"
: "${SAVE_DIR:=${DATA_DIR}}"
: "${BACKUP_DIR:=${DATA_DIR}/backups}"
: "${BACKUP_INTERVAL:=3600}"
: "${BACKUP_KEEP:=24}"

cd "${SAVE_DIR}"

do_once() {
    mkdir -p "${BACKUP_DIR}"
    local stamp
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    local out="${BACKUP_DIR}/valheim-${stamp}.tar.gz"

    # Archive the world data plus the admin/ban/permitted lists. Exclude the
    # backups dir itself so snapshots don't nest.
    local -a targets=()
    [[ -d "${SAVE_DIR}/worlds_local" ]] && targets+=("worlds_local")
    [[ -d "${SAVE_DIR}/worlds"       ]] && targets+=("worlds")
    for f in adminlist.txt bannedlist.txt permittedlist.txt; do
        [[ -f "${SAVE_DIR}/${f}" ]] && targets+=("${f}")
    done

    if [[ ${#targets[@]} -eq 0 ]]; then
        echo "[backup] nothing to back up yet, skipping."
        return 0
    fi

    local lock_dir="${BACKUP_DIR}/.backup.lock"
    if ! mkdir "${lock_dir}" 2>/dev/null; then
        echo "[backup] another backup is already running, skipping."
        return 0
    fi

    local tmp="${out}.tmp"
    trap '[[ -n "${tmp:-}" && -f "${tmp}" ]] && rm -f -- "${tmp}"; rmdir "${lock_dir}" 2>/dev/null || true' RETURN

    if ! tar -czf "${tmp}" "${targets[@]}"; then
        echo "[backup] tar failed; no archive written."
        return 1
    fi
    mv -f "${tmp}" "${out}"
    tmp=""
    echo "[backup] wrote ${out}"
    [[ -n "${DISCORD_WEBHOOK_URL:-}" ]] && \
        /usr/local/bin/notify.sh backup "Backup created: \`$(basename "${out}")\`" || true

    mapfile -t old < <(ls -1t "${BACKUP_DIR}"/valheim-*.tar.gz 2>/dev/null | tail -n +"$((BACKUP_KEEP + 1))")
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
