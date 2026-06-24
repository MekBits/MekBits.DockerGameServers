# Enshrouded Dedicated Server (Docker)

Unofficial, minimal-footprint Docker image for the Windows-only Enshrouded
dedicated server, running on Debian slim under 64-bit Wine.

## Design choices

| Choice | Why |
|---|---|
| `debian:stable-slim` base | Wine on Alpine/musl is unreliable for Steam games; Debian is the realistic minimum. |
| Wine **64-bit only** (no i386 multiarch) | Server binary is x64. Skipping i386 saves ~300 MB. |
| Server files installed to the **volume**, not baked into the image | Image stays tiny (~700 MB-ish). Game updates do **not** require a rebuild. |
| WineHQ stable from official repo | Reproducible, signed with pinned keyring. |
| Non-root user `steam` (uid 1000) | Standard hardening; matches most NAS/host conventions. |
| `tini` PID 1 | Reaps zombies and forwards signals to Wine for clean shutdown. |
| `xvfb-run` wrapper (toggle `USE_XVFB`) | Solves the most common Wine headless quirks. |
| Healthcheck = process + UDP listen | UDP can't be probed traditionally; check process + bound socket. |

## Quick start (Docker Compose)

```bash
cp .env.example .env       # edit values
docker compose up -d --build
docker compose logs -f
```

First start performs the initial SteamCMD install (~1–2 GB into the volume).
Subsequent starts skip the update unless `UPDATE_ON_START=true`.

## Environment variables

| Variable | Default | Notes |
|---|---|---|
| `UPDATE_ON_START` | `false` | Validate + update via SteamCMD on each start |
| `SERVER_NAME` | `Enshrouded Server` | |
| `SERVER_PASSWORD` | _(empty)_ | Empty = no password |
| `SERVER_SLOTS` | `16` | |
| `SERVER_IP` | `0.0.0.0` | Bind address inside the container |
| `GAME_PORT` | `15636` | UDP |
| `QUERY_PORT` | `15637` | UDP |
| `VOICE_CHAT_MODE` | `Proximity` | |
| `ENABLE_VOICE_CHAT` | `false` | |
| `ENABLE_TEXT_CHAT` | `false` | |
| `GAME_SETTINGS_PRESET` | `Default` | |
| `USE_XVFB` | `true` | Set `false` to launch wine without xvfb |
| `BACKUP_ENABLED` | `false` | Background loop writing tar.gz snapshots |
| `BACKUP_INTERVAL` | `3600` | Seconds between backups |
| `BACKUP_KEEP` | `24` | Snapshots retained (older are pruned) |
| `DISCORD_WEBHOOK_URL` | _(empty)_ | If set, posts start/stop/crash events |

### Config merging rules

On every start the entrypoint reconciles `enshrouded_server.json`:

1. **No file present** → write defaults, then overlay any env vars that are set.
2. **File present** → keep all existing keys, then overlay any env vars that
   are set (env always wins for the keys you explicitly provide).

This lets you hand-edit advanced fields (`gameSettings`, `userGroups`, …) on
the volume without them being clobbered, while still steering common knobs
through environment variables.

## Volumes & ports

- Volume mount: `/home/steam/enshrouded` — holds the install, savegames,
  logs, and backups (under `backups/`).
- Expose UDP: `15636` (game) and `15637` (query). Forward both on your router.

## Build & run manually

```bash
docker build -t enshrouded-server:local .

docker run -d --name enshrouded \
  -p 15636:15636/udp -p 15637:15637/udp \
  -v enshrouded-data:/home/steam/enshrouded \
  -e SERVER_NAME="My Server" \
  -e SERVER_PASSWORD="hunter2" \
  --restart unless-stopped \
  enshrouded-server:local
```

## Publishing to GHCR (GitHub Container Registry)

### One-off (local)

```bash
# Use a GitHub Personal Access Token with the write:packages scope.
echo "$GH_PAT" | docker login ghcr.io -u <your-github-username> --password-stdin
docker build -t ghcr.io/mekbits/games/enshrouded-server:0.1.0 -t ghcr.io/mekbits/games/enshrouded-server:latest .
docker push ghcr.io/mekbits/games/enshrouded-server:0.1.0
docker push ghcr.io/mekbits/games/enshrouded-server:latest
```

### Automated (GitHub Actions)

The included workflow `.github/workflows/docker-publish.yml` builds on push to
`main` and on `vX.Y.Z` tags, then pushes to
`ghcr.io/mekbits/games/enshrouded-server` using the built-in `GITHUB_TOKEN` — no
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
docker compose run --rm -e UPDATE_ON_START=true enshrouded /usr/local/bin/entrypoint.sh
# or simply: temporarily set UPDATE_ON_START=true and restart the service
```

## Backups

A simple manual backup at any time:

```bash
docker exec -it enshrouded /usr/local/bin/backup.sh --once
```

Backups land in `/home/steam/enshrouded/backups/` inside the volume.

## Troubleshooting

- **Healthcheck failing for the first 2 minutes** — normal. The image gives a
  120 s `start_period` so first-time installs aren't killed.
- **Stuck at install** — increase your disk space / bandwidth; SteamCMD logs
  are in the container stdout.
- **Wine errors about a display** — make sure `USE_XVFB=true`.
- **Ports already in use** — change `GAME_PORT` / `QUERY_PORT` *and* the
  host port mapping in `docker-compose.yml`.

## Security notes

- Container runs as non-root (uid 1000).
- No 32-bit libraries installed.
- Only the WineHQ apt key and its signed repo are added.
- The server speaks UDP only; do **not** expose any TCP ports.
- Treat `SERVER_PASSWORD` and `DISCORD_WEBHOOK_URL` as secrets — prefer
  Docker secrets or an `.env` file outside of version control.

## Disclaimer

Enshrouded and SteamCMD are property of their respective owners. This image
is an unofficial community wrapper and ships no game content.
