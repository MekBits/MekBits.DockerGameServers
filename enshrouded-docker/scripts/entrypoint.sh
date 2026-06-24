#!/usr/bin/env bash
# Enshrouded server entrypoint.
#   1. Install / optionally update server via SteamCMD
#   2. Merge env vars into enshrouded_server.json (creating it if missing)
#   3. Launch enshrouded_server.exe under Wine (xvfb-wrapped)
#   4. Optional: start background backup loop, fire Discord notifications
set -euo pipefail

# ------------------------------------------------------------------ defaults --
: "${UPDATE_ON_START:=false}"
: "${SERVER_NAME:=Enshrouded Server}"
: "${SERVER_PASSWORD:=}"
: "${SERVER_SLOTS:=16}"
: "${GAME_PORT:=15636}"
: "${QUERY_PORT:=15637}"
: "${SERVER_IP:=0.0.0.0}"
: "${SAVE_DIRECTORY:=./savegame}"
: "${LOG_DIRECTORY:=./logs}"
: "${VOICE_CHAT_MODE:=Proximity}"
: "${ENABLE_VOICE_CHAT:=false}"
: "${ENABLE_TEXT_CHAT:=false}"
: "${GAME_SETTINGS_PRESET:=Default}"
: "${USE_XVFB:=true}"
: "${BACKUP_ENABLED:=false}"
: "${DISCORD_WEBHOOK_URL:=}"

CONFIG_FILE="${SERVER_DIR}/enshrouded_server.json"
INSTALL_MARKER="${SERVER_DIR}/.steamcmd-${ENSHROUDED_APPID}.complete"
BACKUP_PID=""

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
    if [[ ! -f "${SERVER_DIR}/enshrouded_server.exe" || ! -f "${INSTALL_MARKER}" ]]; then
        log "Server install is missing or incomplete — running SteamCMD."
        needs_install=true
    fi

    if [[ "${needs_install}" == "true" || "${UPDATE_ON_START,,}" == "true" ]]; then
        log "Running SteamCMD for app ${ENSHROUDED_APPID}..."
        rm -f "${INSTALL_MARKER}"
        "${STEAMCMD_DIR}/steamcmd.sh" \
            +@sSteamCmdForcePlatformType windows \
            +force_install_dir "${SERVER_DIR}" \
            +login anonymous \
            +app_update "${ENSHROUDED_APPID}" validate \
            +quit
        if [[ ! -f "${SERVER_DIR}/enshrouded_server.exe" ]]; then
            log "ERROR: SteamCMD completed but enshrouded_server.exe is still missing."
            return 1
        fi
        date -u +%Y-%m-%dT%H:%M:%SZ > "${INSTALL_MARKER}"
    else
        log "Skipping update (UPDATE_ON_START=${UPDATE_ON_START})."
    fi
}

# ----------------------------------------------------------- config merging --
# Build a JSON object from env vars containing only the keys the user actually
# provided values for, then deep-merge it on top of any existing config (env
# wins). If no file exists, defaults + env-derived values produce a fresh one.
write_config() {
    log "Reconciling enshrouded_server.json with environment overrides."

    local defaults overrides existing
    defaults=$(jq -n \
        --arg name        "${SERVER_NAME}" \
        --arg password    "${SERVER_PASSWORD}" \
        --arg saveDir     "${SAVE_DIRECTORY}" \
        --arg logDir      "${LOG_DIRECTORY}" \
        --arg ip          "${SERVER_IP}" \
        --argjson gPort   "${GAME_PORT}" \
        --argjson qPort   "${QUERY_PORT}" \
        --argjson slots   "${SERVER_SLOTS}" \
        --arg voiceMode   "${VOICE_CHAT_MODE}" \
        --argjson voiceEn "${ENABLE_VOICE_CHAT}" \
        --argjson textEn  "${ENABLE_TEXT_CHAT}" \
        --arg preset      "${GAME_SETTINGS_PRESET}" \
        '{
            name: $name,
            password: $password,
            saveDirectory: $saveDir,
            logDirectory: $logDir,
            ip: $ip,
            gamePort: $gPort,
            queryPort: $qPort,
            slotCount: $slots,
            voiceChatMode: $voiceMode,
            enableVoiceChat: $voiceEn,
            enableTextChat: $textEn,
            gameSettingsPreset: $preset,
            gameSettings: {},
            userGroups: []
         }')

    overrides=$(/usr/local/bin/merge-config.sh)  # only-set env keys

    if [[ -f "${CONFIG_FILE}" ]]; then
        existing=$(cat "${CONFIG_FILE}")
        # existing < env-overrides   (env always wins on provided keys)
        jq -s '.[0] * .[1]' <(echo "${existing}") <(echo "${overrides}") \
            > "${CONFIG_FILE}.tmp"
    else
        # defaults < env-overrides
        jq -s '.[0] * .[1]' <(echo "${defaults}") <(echo "${overrides}") \
            > "${CONFIG_FILE}.tmp"
    fi
    mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
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
    mkdir -p "${SAVE_DIRECTORY}" "${LOG_DIRECTORY}"

    local cmd=(wine enshrouded_server.exe)
    if [[ "${USE_XVFB,,}" == "true" ]]; then
        cmd=(xvfb-run -a --server-args="-screen 0 640x480x24" "${cmd[@]}")
    fi

    log "Launching: ${cmd[*]}"
    notify start "Enshrouded server starting: \`${SERVER_NAME}\`"

    "${cmd[@]}" &
    local server_pid=$!

    local rc=0 stopping=false
    forward() {
        stopping=true
        log "Received stop signal — forwarding to Enshrouded."
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
        notify crash "Enshrouded server **exited with code ${rc}**."
    else
        notify stop "Enshrouded server stopped cleanly."
    fi
    return "${rc}"
}

# ============================================================================ #
install_or_update
write_config
start_backup_loop
run_server
