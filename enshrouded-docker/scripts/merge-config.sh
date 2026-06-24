#!/usr/bin/env bash
# Emit a JSON object containing ONLY keys whose corresponding env vars are set
# (non-empty). Used by entrypoint.sh to overlay user intent on top of either
# defaults or an existing enshrouded_server.json without clobbering keys the
# user never specified.
set -euo pipefail

obj='{}'

add_str() {
    local key="$1" val="${!2:-}"
    [[ -z "${val}" ]] && return 0
    obj=$(jq --arg k "${key}" --arg v "${val}" '. + {($k): $v}' <<<"${obj}")
}
add_num() {
    local key="$1" val="${!2:-}"
    [[ -z "${val}" ]] && return 0
    obj=$(jq --arg k "${key}" --argjson v "${val}" '. + {($k): $v}' <<<"${obj}")
}
add_bool() {
    local key="$1" val="${!2:-}"
    [[ -z "${val}" ]] && return 0
    obj=$(jq --arg k "${key}" --argjson v "${val}" '. + {($k): $v}' <<<"${obj}")
}

add_str  name               SERVER_NAME
add_str  password           SERVER_PASSWORD
add_str  saveDirectory      SAVE_DIRECTORY
add_str  logDirectory       LOG_DIRECTORY
add_str  ip                 SERVER_IP
add_num  gamePort           GAME_PORT
add_num  queryPort          QUERY_PORT
add_num  slotCount          SERVER_SLOTS
add_str  voiceChatMode      VOICE_CHAT_MODE
add_bool enableVoiceChat    ENABLE_VOICE_CHAT
add_bool enableTextChat     ENABLE_TEXT_CHAT
add_str  gameSettingsPreset GAME_SETTINGS_PRESET

printf '%s\n' "${obj}"
