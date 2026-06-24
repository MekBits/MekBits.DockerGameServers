# V Rising Dedicated Server (Docker)

Unofficial, minimal-footprint Docker image for the Windows-only V Rising
dedicated server, running on Debian slim under 64-bit Wine.

## Design choices

| Choice | Why |
|---|---|
| `debian:stable-slim` base | Wine on Alpine/musl is unreliable for Steam/Unity games; Debian is the realistic minimum. |
| Wine **64-bit only** (no i386 multiarch) | Server binary is x64. Skipping i386 saves ~300 MB. |
| Server files installed to the **install volume**, not baked into the image | Image stays small. Game updates do **not** require an image rebuild. |
| Two volumes: install + data | Lets you nuke and reinstall the game without touching saves/configs. |
| WineHQ stable from official repo | Reproducible, signed with pinned keyring. |
| Non-root user `steam` (uid 1000) | Standard hardening; matches most NAS/host conventions. |
| `tini` PID 1 | Reaps zombies and forwards signals to Wine for clean shutdown. |
| `xvfb-run` wrapper (toggle `USE_XVFB`) | V Rising is a Unity headless build but Wine still occasionally pokes a display; Xvfb avoids the most common quirks. |
| Healthcheck = process + UDP listen | UDP can't be probed traditionally; check process + bound socket. |

## Quick start (Docker Compose)

```bash
cp .env.example .env       # edit values
docker compose up -d --build
docker compose logs -f
```

First start performs the initial SteamCMD install (~3 GB into the volume).
Subsequent starts skip the update unless `UPDATE_ON_START=true`.

## Environment variables

### Server identity / network

| Variable | Default | Notes |
|---|---|---|
| `UPDATE_ON_START` | `false` | Validate + update via SteamCMD on each start |
| `SERVER_NAME` | `V Rising Server` | |
| `SERVER_DESCRIPTION` | _(empty)_ | |
| `SERVER_PASSWORD` | _(empty)_ | Empty = no password |
| `SAVE_NAME` | `world1` | Folder name under `Saves/v3/` |
| `MAX_USERS` | `40` | |
| `MAX_ADMINS` | `4` | |
| `SERVER_FPS` | `30` | |
| `GAME_PORT` | `9876` | UDP |
| `QUERY_PORT` | `27015` | UDP |
| `LIST_ON_STEAM` | `true` | |
| `LIST_ON_EOS` | `true` | |
| `SECURE` | `true` | VAC |

### Persistence / gameplay

| Variable | Default | Notes |
|---|---|---|
| `AUTO_SAVE_COUNT` | `40` | |
| `AUTO_SAVE_INTERVAL` | `120` | seconds |
| `COMPRESS_SAVE_FILES` | `true` | |
| `GAME_SETTINGS_PRESET` | _(empty)_ | e.g. `StandardPvP`, `DuoPvP`, `Solo` |
| `GAME_DIFFICULTY_PRESET` | _(empty)_ | e.g. `Hard` |
| `ADMIN_ONLY_DEBUG_EVENTS` | `true` | |
| `DISABLE_DEBUG_EVENTS` | `false` | |

### RCON / API

| Variable | Default | Notes |
|---|---|---|
| `RCON_ENABLED` | `false` | If true, also publish `RCON_PORT` on the host |
| `RCON_PORT` | `25575` | TCP |
| `RCON_PASSWORD` | _(empty)_ | Required if RCON enabled |
| `API_ENABLED` | `false` | Built-in HTTP API |

### Container behaviour

| Variable | Default | Notes |
|---|---|---|
| `USE_XVFB` | `true` | Wrap Wine in `xvfb-run` |
| `BACKUP_ENABLED` | `false` | Background loop writing tar.gz snapshots of `Saves/` + `Settings/` |
| `BACKUP_INTERVAL` | `3600` | Seconds between backups |
| `BACKUP_KEEP` | `24` | Snapshots retained (older are pruned) |
| `DISCORD_WEBHOOK_URL` | _(empty)_ | If set, posts start/stop/crash events |

### Config merging rules

On every start the entrypoint reconciles two files in the data volume:
`Settings/ServerHostSettings.json` and `Settings/ServerGameSettings.json`.

1. **No file present** → seed from the shipped templates inside the install
   (`VRisingServer_Data/StreamingAssets/Settings/`).
2. **File present** → keep all existing keys, then overlay any env vars that
   are set (env always wins for the keys you explicitly provide).

Only `ServerHostSettings.json` is steered by env vars. `ServerGameSettings.json`
is left for you to hand-edit on the volume (the game-settings surface is huge
and not worth mirroring as flat env vars). Use `GAME_SETTINGS_PRESET` /
`GAME_DIFFICULTY_PRESET` for the common cases.

`adminlist.txt` and `banlist.txt` belong in `Settings/` next to the JSON files
and are preserved across restarts.

## Volumes & ports

- `/home/steam/vrising` — game install (recreatable via SteamCMD).
- `/home/steam/vrising-data` — `Settings/`, `Saves/`, `Logs/`, `backups/`.
- Expose UDP `9876` (game) and `27015` (query). Forward both on your router.
- Expose TCP `25575` only if RCON is enabled.

## Build & run manually

```bash
docker build -t vrising-server:local .

docker run -d --name vrising \
  -p 9876:9876/udp -p 27015:27015/udp \
  -v vrising-install:/home/steam/vrising \
  -v vrising-data:/home/steam/vrising-data \
  -e SERVER_NAME="My Server" \
  -e SERVER_PASSWORD="hunter2" \
  --restart unless-stopped \
  vrising-server:local
```

## Publishing to GHCR (GitHub Container Registry)

### One-off (local)

```bash
# Use a GitHub Personal Access Token with the write:packages scope.
echo "$GH_PAT" | docker login ghcr.io -u <your-github-username> --password-stdin
docker build -t ghcr.io/mekbits/games/vrising-server:0.1.0 -t ghcr.io/mekbits/games/vrising-server:latest .
docker push ghcr.io/mekbits/games/vrising-server:0.1.0
docker push ghcr.io/mekbits/games/vrising-server:latest
```

### Automated (GitHub Actions)

The included workflow `.github/workflows/docker-publish.yml` builds on push to
`main` and on `vX.Y.Z` tags, then pushes to
`ghcr.io/mekbits/games/vrising-server` using the built-in `GITHUB_TOKEN` — no
extra secrets required. To publish under a different path, set the optional
`IMAGE_NAME` repository variable.

Tag a release with:

```bash
git tag v0.1.0
git push --tags
```

## Updating the game

```bash
docker compose stop
docker compose run --rm -e UPDATE_ON_START=true vrising /usr/local/bin/entrypoint.sh
# or simply: temporarily set UPDATE_ON_START=true and restart the service
```

## Backups

A manual backup at any time:

```bash
docker exec -it vrising /usr/local/bin/backup.sh --once
```

Backups land in `/home/steam/vrising-data/backups/` inside the data volume.

## Troubleshooting

- **Healthcheck failing for the first few minutes** — normal. The image gives
  a 180 s `start_period` so first-time installs aren't killed.
- **Stuck at install** — increase your disk space / bandwidth; SteamCMD logs
  are in the container stdout.
- **Wine errors about a display** — make sure `USE_XVFB=true`.
- **Ports already in use** — change `GAME_PORT` / `QUERY_PORT` *and* the
  host port mapping in `docker-compose.yml`.
- **Settings changes ignored** — env vars always win over the on-disk values
  for the keys they cover. To hand-edit a host setting, unset the
  corresponding env var (or comment it out in `.env`).

## Security notes

- Container runs as non-root (uid 1000).
- No 32-bit libraries installed.
- Only the WineHQ apt key and its signed repo are added.
- The game speaks UDP only; do **not** expose any TCP ports except RCON
  (and only when RCON is enabled with a strong password).
- Treat `SERVER_PASSWORD`, `RCON_PASSWORD`, and `DISCORD_WEBHOOK_URL` as
  secrets — prefer Docker secrets or an `.env` file outside of version control.

## Disclaimer

V Rising and SteamCMD are property of their respective owners. This image
is an unofficial community wrapper and ships no game content.
