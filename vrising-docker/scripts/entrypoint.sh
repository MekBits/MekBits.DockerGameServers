#!/usr/bin/env bash
# V Rising server entrypoint.
#   1. Install / optionally update server via SteamCMD
#   2. Seed default config files from the install if not present, then merge
#      env vars into ServerHostSettings.json / ServerGameSettings.json
#   3. Launch VRisingServer.exe under Wine (optionally xvfb-wrapped)
#   4. Optional: start background backup loop, fire Discord notifications
set -euo pipefail

# ------------------------------------------------------------------ defaults --
: "${UPDATE_ON_START:=false}"
: "${SERVER_NAME:=V Rising Server}"
: "${SERVER_DESCRIPTION:=}"
: "${SERVER_PASSWORD:=}"
: "${SAVE_NAME:=world1}"
: "${MAX_USERS:=40}"
: "${MAX_ADMINS:=4}"
: "${SERVER_FPS:=30}"
: "${GAME_PORT:=9876}"
: "${QUERY_PORT:=27015}"
: "${LIST_ON_STEAM:=true}"
: "${LIST_ON_EOS:=true}"
: "${SECURE:=true}"
: "${AUTO_SAVE_COUNT:=40}"
: "${AUTO_SAVE_INTERVAL:=120}"
: "${COMPRESS_SAVE_FILES:=true}"
: "${GAME_SETTINGS_PRESET:=}"
: "${GAME_DIFFICULTY_PRESET:=}"
: "${ADMIN_ONLY_DEBUG_EVENTS:=true}"
: "${DISABLE_DEBUG_EVENTS:=false}"
: "${RCON_ENABLED:=false}"
: "${RCON_PORT:=25575}"
: "${RCON_PASSWORD:=}"
: "${API_ENABLED:=false}"
: "${USE_XVFB:=true}"
: "${BACKUP_ENABLED:=false}"
: "${DISCORD_WEBHOOK_URL:=}"

INSTALL_MARKER="${SERVER_DIR}/.steamcmd-${VRISING_APPID}.complete"
BACKUP_PID=""

SETTINGS_DIR="${DATA_DIR}/Settings"
HOST_CFG="${SETTINGS_DIR}/ServerHostSettings.json"
GAME_CFG="${SETTINGS_DIR}/ServerGameSettings.json"

# Templates shipped inside the install (used to seed missing config files).
TEMPLATE_DIR="${SERVER_DIR}/VRisingServer_Data/StreamingAssets/Settings"

log() { printf '[entrypoint] %s\n' "$*"; }

# ------------------------------------------------------------- notifications --
notify() {
    local event="$1" msg="$2"
    [[ -n "${DISCORD_WEBHOOK_URL}" ]] && \
        /usr/local/bin/notify.sh "${event}" "${msg}" || true
}

# ------------------------------------------------------------------ install --
install_or_update() {
    local needs_install=false
    if [[ ! -f "${SERVER_DIR}/VRisingServer.exe" || ! -f "${INSTALL_MARKER}" ]]; then
        log "Server install is missing or incomplete — running SteamCMD."
        needs_install=true
    fi

    if [[ "${needs_install}" == "true" || "${UPDATE_ON_START,,}" == "true" ]]; then
        log "Running SteamCMD for app ${VRISING_APPID}..."
        rm -f "${INSTALL_MARKER}"
        "${STEAMCMD_DIR}/steamcmd.sh" \
            +@sSteamCmdForcePlatformType windows \
            +force_install_dir "${SERVER_DIR}" \
            +login anonymous \
            +app_update "${VRISING_APPID}" validate \
            +quit
        if [[ ! -f "${SERVER_DIR}/VRisingServer.exe" ]]; then
            log "ERROR: SteamCMD completed but VRisingServer.exe is still missing."
            return 1
        fi
        date -u +%Y-%m-%dT%H:%M:%SZ > "${INSTALL_MARKER}"
    else
        log "Skipping update (UPDATE_ON_START=${UPDATE_ON_START})."
    fi
}

# ----------------------------------------------------------- config merging --
seed_defaults() {
    mkdir -p "${SETTINGS_DIR}"
    # Seed from shipped templates only if the user has no file yet.
    if [[ ! -f "${HOST_CFG}" && -f "${TEMPLATE_DIR}/ServerHostSettings.json" ]]; then
        log "Seeding ServerHostSettings.json from template."
        cp "${TEMPLATE_DIR}/ServerHostSettings.json" "${HOST_CFG}"
    fi
    if [[ ! -f "${GAME_CFG}" && -f "${TEMPLATE_DIR}/ServerGameSettings.json" ]]; then
        log "Seeding ServerGameSettings.json from template."
        cp "${TEMPLATE_DIR}/ServerGameSettings.json" "${GAME_CFG}"
    fi
    # If for some reason the template is missing (older build), create an
    # empty object so jq merges have something to start from.
    [[ -f "${HOST_CFG}" ]] || echo '{}' > "${HOST_CFG}"
    [[ -f "${GAME_CFG}" ]] || echo '{}' > "${GAME_CFG}"
}

# Build a JSON object from env vars containing only the keys the user actually
# provided values for, then deep-merge it on top of the existing config (env
# always wins). The user can still hand-edit the file on the volume freely —
# any keys we don't override are preserved.
write_config() {
    log "Reconciling ServerHostSettings.json with environment overrides."

    local host_overrides game_overrides existing
    host_overrides=$(/usr/local/bin/merge-config.sh host)
    game_overrides=$(/usr/local/bin/merge-config.sh game)

    existing=$(cat "${HOST_CFG}")
    jq -s '.[0] * .[1]' <(echo "${existing}") <(echo "${host_overrides}") \
        > "${HOST_CFG}.tmp"
    mv "${HOST_CFG}.tmp" "${HOST_CFG}"

    existing=$(cat "${GAME_CFG}")
    jq -s '.[0] * .[1]' <(echo "${existing}") <(echo "${game_overrides}") \
        > "${GAME_CFG}.tmp"
    mv "${GAME_CFG}.tmp" "${GAME_CFG}"
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
    mkdir -p "${DATA_DIR}/Saves" "${DATA_DIR}/Logs"

    # Wine wants Windows-style paths; -persistentDataPath accepts forward
    # slashes too and Wine maps /home/... via the Z: drive.
    local data_win="Z:${DATA_DIR}"
    local log_file="Z:${DATA_DIR}/Logs/VRisingServer.log"

    local cmd=(wine VRisingServer.exe
        -persistentDataPath "${data_win}"
        -serverName "${SERVER_NAME}"
        -saveName "${SAVE_NAME}"
        -logFile "${log_file}"
        -batchmode -nographics)

    if [[ "${USE_XVFB,,}" == "true" ]]; then
        cmd=(xvfb-run -a --server-args="-screen 0 640x480x24" "${cmd[@]}")
    fi

    log "Launching: ${cmd[*]}"
    notify start "V Rising server starting: \`${SERVER_NAME}\`"

    "${cmd[@]}" &
    local server_pid=$!

    local rc=0 stopping=false
    forward() {
        stopping=true
        log "Received stop signal — forwarding to V Rising."
        kill -TERM "${server_pid}" 2>/dev/null || true
        pkill -TERM -P "${server_pid}" 2>/dev/null || true
    }
    trap forward INT TERM

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
        notify crash "V Rising server **exited with code ${rc}**."
    else
        notify stop "V Rising server stopped cleanly."
    fi
    return "${rc}"
}

# ============================================================================ #
install_or_update
seed_defaults
write_config
start_backup_loop
run_server
