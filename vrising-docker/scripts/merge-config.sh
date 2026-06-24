#!/usr/bin/env bash
# Emit a JSON object containing ONLY keys whose corresponding env vars are set
# (non-empty). Used by entrypoint.sh to overlay user intent on top of the
# existing ServerHostSettings.json / ServerGameSettings.json without
# clobbering keys the user never specified.
#
# Usage: merge-config.sh host|game
set -euo pipefail

target="${1:-host}"
obj='{}'

# Shape an existing JSON object by setting (or extending) a single key.
set_str()  { local k="$1" v="${!2:-}"; [[ -z "$v" ]] && return 0
             obj=$(jq --arg k "$k" --arg v "$v"     '. + {($k): $v}' <<<"$obj"); }
set_num()  { local k="$1" v="${!2:-}"; [[ -z "$v" ]] && return 0
             obj=$(jq --arg k "$k" --argjson v "$v" '. + {($k): $v}' <<<"$obj"); }
set_bool() { local k="$1" v="${!2:-}"; [[ -z "$v" ]] && return 0
             obj=$(jq --arg k "$k" --argjson v "$v" '. + {($k): $v}' <<<"$obj"); }

# Like set_*, but assigns the value into a nested sub-object (e.g. Rcon.Port).
nest_str()  { local p="$1" k="$2" v="${!3:-}"; [[ -z "$v" ]] && return 0
              obj=$(jq --arg p "$p" --arg k "$k" --arg v "$v" \
                    '.[$p] = ((.[$p] // {}) + {($k): $v})' <<<"$obj"); }
nest_num()  { local p="$1" k="$2" v="${!3:-}"; [[ -z "$v" ]] && return 0
              obj=$(jq --arg p "$p" --arg k "$k" --argjson v "$v" \
                    '.[$p] = ((.[$p] // {}) + {($k): $v})' <<<"$obj"); }
nest_bool() { local p="$1" k="$2" v="${!3:-}"; [[ -z "$v" ]] && return 0
              obj=$(jq --arg p "$p" --arg k "$k" --argjson v "$v" \
                    '.[$p] = ((.[$p] // {}) + {($k): $v})' <<<"$obj"); }

case "${target}" in
    host)
        set_str  Name                  SERVER_NAME
        set_str  Description           SERVER_DESCRIPTION
        set_str  Password              SERVER_PASSWORD
        set_str  SaveName              SAVE_NAME
        set_num  Port                  GAME_PORT
        set_num  QueryPort             QUERY_PORT
        set_num  MaxConnectedUsers     MAX_USERS
        set_num  MaxConnectedAdmins    MAX_ADMINS
        set_num  ServerFps             SERVER_FPS
        set_bool ListOnSteam           LIST_ON_STEAM
        set_bool ListOnEOS             LIST_ON_EOS
        set_bool Secure                SECURE
        set_num  AutoSaveCount         AUTO_SAVE_COUNT
        set_num  AutoSaveInterval      AUTO_SAVE_INTERVAL
        set_bool CompressSaveFiles     COMPRESS_SAVE_FILES
        set_str  GameSettingsPreset    GAME_SETTINGS_PRESET
        set_str  GameDifficultyPreset  GAME_DIFFICULTY_PRESET
        set_bool AdminOnlyDebugEvents  ADMIN_ONLY_DEBUG_EVENTS
        set_bool DisableDebugEvents    DISABLE_DEBUG_EVENTS

        # Nested objects
        nest_bool Rcon Enabled  RCON_ENABLED
        nest_num  Rcon Port     RCON_PORT
        nest_str  Rcon Password RCON_PASSWORD
        nest_bool API  Enabled  API_ENABLED
        ;;
    game)
        # Game settings are intentionally hand-edited on the volume; we don't
        # surface them via env. Emit an empty object so the merge is a no-op.
        ;;
    *)
        echo "usage: $0 host|game" >&2
        exit 2
        ;;
esac

printf '%s\n' "${obj}"
