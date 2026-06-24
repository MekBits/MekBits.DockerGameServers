#!/usr/bin/env bash
# Valheim server entrypoint.
#   1. Install / optionally update server via SteamCMD
#   2. Optionally install the BepInEx mod loader (opt-in)
#   3. Launch valheim_server.x86_64 (native Linux) with env-derived flags
#   4. Optional: start background backup loop, fire Discord notifications
#
# Valheim has no config file — every option is a launch flag. adminlist.txt /
# bannedlist.txt / permittedlist.txt live in the save dir and are hand-edited.
set -euo pipefail

# ------------------------------------------------------------------ defaults --
: "${UPDATE_ON_START:=false}"
: "${SERVER_NAME:=Valheim Server}"
: "${WORLD_NAME:=Dedicated}"
: "${SERVER_PASSWORD:=}"
: "${SERVER_PORT:=2456}"
: "${SERVER_PUBLIC:=true}"
: "${CROSSPLAY:=false}"
: "${SAVE_DIR:=${DATA_DIR}}"
: "${EXTRA_ARGS:=}"

# Access-control lists (SteamID64s). When set, the env var OVERWRITES the
# matching file on disk; when unset/empty the on-disk file is left untouched.
# Accepts comma, space, semicolon or newline separated IDs.
: "${ADMIN_IDS:=}"
: "${BANNED_IDS:=}"
: "${PERMITTED_IDS:=}"

# BepInEx (mod loader) — opt-in. Pinned to the official Thunderstore package.
: "${BEPINEX:=false}"
: "${BEPINEX_DOWNLOAD_URL:=https://thunderstore.io/package/download/denikson/BepInExPack_Valheim/5.4.2333/}"

: "${BACKUP_ENABLED:=false}"
: "${DISCORD_WEBHOOK_URL:=}"

SERVER_BIN="valheim_server.x86_64"
INSTALL_MARKER="${SERVER_DIR}/.steamcmd-${VALHEIM_APPID}.complete"
BACKUP_PID=""

log() { printf '[entrypoint] %s\n' "$*"; }

# Normalise a boolean-ish env var to 0/1.
as01() { [[ "${1,,}" =~ ^(1|true|yes|on)$ ]] && echo 1 || echo 0; }

# ------------------------------------------------------------- notifications --
notify() {
    local event="$1" msg="$2"
    [[ -n "${DISCORD_WEBHOOK_URL}" ]] && \
        /usr/local/bin/notify.sh "${event}" "${msg}" || true
}

# ------------------------------------------------------------------ install --
install_or_update() {
    local needs_install=false
    if [[ ! -f "${SERVER_DIR}/${SERVER_BIN}" || ! -f "${INSTALL_MARKER}" ]]; then
        log "Server install is missing or incomplete — running SteamCMD."
        needs_install=true
    fi

    if [[ "${needs_install}" == "true" || "${UPDATE_ON_START,,}" == "true" ]]; then
        log "Running SteamCMD for app ${VALHEIM_APPID}..."
        rm -f "${INSTALL_MARKER}"
        "${STEAMCMD_DIR}/steamcmd.sh" \
            +force_install_dir "${SERVER_DIR}" \
            +login anonymous \
            +app_update "${VALHEIM_APPID}" validate \
            +quit
        if [[ ! -f "${SERVER_DIR}/${SERVER_BIN}" ]]; then
            log "ERROR: SteamCMD completed but ${SERVER_BIN} is still missing."
            return 1
        fi
        date -u +%Y-%m-%dT%H:%M:%SZ > "${INSTALL_MARKER}"
    else
        log "Skipping update (UPDATE_ON_START=${UPDATE_ON_START})."
    fi
}

# ------------------------------------------------------------------ BepInEx --
# Downloads the official BepInExPack_Valheim from Thunderstore and lays it down
# in the server directory if not already present. Opt-in via BEPINEX=true.
install_bepinex() {
    [[ "$(as01 "${BEPINEX}")" == "1" ]] || return 0

    if [[ -f "${SERVER_DIR}/BepInEx/core/BepInEx.Preloader.dll" ]]; then
        log "BepInEx already installed — skipping download."
        return 0
    fi

    log "Installing BepInEx from ${BEPINEX_DOWNLOAD_URL}"
    local tmp
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '${tmp}'" RETURN

    if ! curl -fsSL "${BEPINEX_DOWNLOAD_URL}" -o "${tmp}/bepinex.zip"; then
        log "WARNING: BepInEx download failed — continuing without mods."
        return 0
    fi
    unzip -q "${tmp}/bepinex.zip" -d "${tmp}/extract"

    # Thunderstore zips nest the payload under BepInExPack_Valheim/.
    local src="${tmp}/extract"
    [[ -d "${tmp}/extract/BepInExPack_Valheim" ]] && src="${tmp}/extract/BepInExPack_Valheim"

    cp -rf "${src}/." "${SERVER_DIR}/"
    chmod +x "${SERVER_DIR}/start_server_bepinex.sh" 2>/dev/null || true
    log "BepInEx installed. Drop plugins into ${SERVER_DIR}/BepInEx/plugins/"
}

# ------------------------------------------------------- access-control lists --
# Write one SteamID64 per line to <list>.txt, overwriting whatever is on disk.
# Called only for lists whose env var is non-empty.
write_list() {
    local file="$1" raw="$2"
    mkdir -p "${SAVE_DIR}"
    local out="${SAVE_DIR}/${file}"
    # Split on comma/semicolon/whitespace, drop blanks, de-duplicate (stable).
    printf '%s' "${raw}" \
        | tr ',;' '  ' \
        | tr -s '[:space:]' '\n' \
        | grep -v '^$' \
        | awk '!seen[$0]++' \
        > "${out}.tmp"
    mv "${out}.tmp" "${out}"
    log "Wrote ${file} from environment ($(wc -l < "${out}") entr$( [[ $(wc -l < "${out}") -eq 1 ]] && echo y || echo ies ))."
}

write_access_lists() {
    [[ -n "${ADMIN_IDS}"     ]] && write_list adminlist.txt     "${ADMIN_IDS}"
    [[ -n "${BANNED_IDS}"    ]] && write_list bannedlist.txt    "${BANNED_IDS}"
    [[ -n "${PERMITTED_IDS}" ]] && write_list permittedlist.txt "${PERMITTED_IDS}"
    return 0
}

# --------------------------------------------------------------- backup loop --
start_backup_loop() {
    [[ "${BACKUP_ENABLED,,}" == "true" ]] || return 0
    log "Backup loop enabled (interval=${BACKUP_INTERVAL:-3600}s)."
    /usr/local/bin/backup.sh --loop &
    BACKUP_PID=$!
}

stop_backup_loop() {
    [[ -n "${BACKUP_PID}" ]] || return 0
    kill "${BACKUP_PID}" 2>/dev/null || true
    wait "${BACKUP_PID}" 2>/dev/null || true
    BACKUP_PID=""
}

# ----------------------------------------------------------- run the server --
run_server() {
    cd "${SERVER_DIR}"
    mkdir -p "${SAVE_DIR}"

    local public01 crossplay01
    public01=$(as01 "${SERVER_PUBLIC}")
    crossplay01=$(as01 "${CROSSPLAY}")

    # Password sanity: Valheim refuses to start a public server without a
    # password of at least 5 chars, and the password must not appear in the
    # server name. Warn loudly rather than fail silently.
    if [[ -n "${SERVER_PASSWORD}" && ${#SERVER_PASSWORD} -lt 5 ]]; then
        log "WARNING: SERVER_PASSWORD is shorter than 5 characters; Valheim will reject it."
    fi
    if [[ "${public01}" == "1" && -z "${SERVER_PASSWORD}" ]]; then
        log "WARNING: SERVER_PUBLIC=1 but no password set; the server may refuse to start."
    fi

    # Native Steam runtime needs the bundled libs and the client app id.
    export SteamAppId="${VALHEIM_STEAMAPPID}"
    export LD_LIBRARY_PATH="./linux64:${LD_LIBRARY_PATH:-}"

    local args=(
        -name "${SERVER_NAME}"
        -port "${SERVER_PORT}"
        -world "${WORLD_NAME}"
        -savedir "${SAVE_DIR}"
        -public "${public01}"
        -batchmode
        -nographics
    )
    [[ -n "${SERVER_PASSWORD}" ]] && args+=(-password "${SERVER_PASSWORD}")
    [[ "${crossplay01}" == "1" ]] && args+=(-crossplay)
    # Free-form passthrough for advanced flags (e.g. -preset, -modifier, -setkey).
    # shellcheck disable=SC2206
    [[ -n "${EXTRA_ARGS}" ]] && args+=(${EXTRA_ARGS})

    # Choose launcher: BepInEx wrapper (sets doorstop env) or the raw binary.
    local launcher
    if [[ "$(as01 "${BEPINEX}")" == "1" && -f "${SERVER_DIR}/start_server_bepinex.sh" ]]; then
        log "Launching with BepInEx mod loader."
        launcher="./start_server_bepinex.sh"
    else
        launcher="./${SERVER_BIN}"
    fi

    local -a log_args=("${args[@]}")
    local i
    for ((i = 0; i < ${#log_args[@]}; i++)); do
        if [[ "${log_args[$i]}" == "-password" && $((i + 1)) -lt ${#log_args[@]} ]]; then
            log_args[$((i + 1))]='<redacted>'
        fi
    done

    log "Launching: ${launcher} ${log_args[*]}"
    notify start "Valheim server starting: \`${SERVER_NAME}\` (world: ${WORLD_NAME})"

    # Run in the background and forward shutdown signals so Valheim can save the
    # world cleanly before exiting (it saves on SIGINT/SIGTERM).
    "${launcher}" "${args[@]}" &
    local server_pid=$!

    local rc=0 stopping=false
    forward() { stopping=true; log "Received stop signal — asking Valheim to save & quit."; kill -INT "${server_pid}" 2>/dev/null || true; }
    trap forward INT TERM

    # wait may return early when interrupted by the trap; loop until the
    # process is actually gone.
    while kill -0 "${server_pid}" 2>/dev/null; do
        wait "${server_pid}" && rc=0 || rc=$?
    done
    trap - INT TERM
    stop_backup_loop

    if [[ "${stopping}" == "true" && ${rc} -ge 128 ]]; then
        rc=0
    fi

    log "Server exited with code ${rc}."
    if [[ ${rc} -ne 0 ]]; then
        notify crash "Valheim server **exited with code ${rc}**."
    else
        notify stop "Valheim server stopped cleanly."
    fi
    return "${rc}"
}

# ============================================================================ #
install_or_update
install_bepinex
write_access_lists
start_backup_loop
run_server
