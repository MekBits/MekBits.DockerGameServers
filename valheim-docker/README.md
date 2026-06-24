# Valheim Dedicated Server (Docker)

Unofficial, minimal-footprint Docker image for the Valheim dedicated server.
Unlike the V Rising / Enshrouded images in this repo, Valheim ships a **native
Linux build**, so there is **no Wine and no Xvfb** — the image just runs
`valheim_server.x86_64` directly. Inspired by `lloesche/valheim-server`, but
kept deliberately lean to match the other servers here.

## Design choices

| Choice | Why |
|---|---|
| `debian:trixie-slim` base | Explicit Debian release with realistic Steam runtime libraries. |
| **Native Linux server** (no Wine) | Valheim ships an x86_64 ELF binary; Wine would only add bloat. |
| Server files installed to the **install volume**, not baked into the image | Image stays small. Game updates do **not** require an image rebuild. |
| Two volumes: install + data | Lets you nuke and reinstall the game without touching worlds/saves. |
| Non-root user `steam` (uid 1000) | Standard hardening; matches most NAS/host conventions. |
| `tini` PID 1 + signal forwarding | Forwards SIGINT/SIGTERM to the server so it **saves the world before exit**. |
| Optional **BepInEx** mod loader | Opt-in download of the official Thunderstore pack; off by default. |
| Image + Compose healthchecks | UDP can't be probed traditionally; check process + bound query socket. |

## Quick start (Docker Compose)

```bash
cp .env.example .env       # edit values (set a real SERVER_PASSWORD!)
docker compose up -d --build
docker compose logs -f
```

First start performs the initial SteamCMD install (~1–2 GB into the volume).
Subsequent starts skip the update unless `UPDATE_ON_START=true`.
The entrypoint writes a SteamCMD completion marker after successful installs so
an interrupted first install is repaired on the next start.

> **Password rules:** Valheim requires a password of **at least 5 characters**
> for a public server, and the password must **not** be contained in the server
> name. A public server without a password will refuse to start.

## Environment variables

### Server identity / network

| Variable | Default | Notes |
|---|---|---|
| `UPDATE_ON_START` | `false` | Validate + update via SteamCMD on each start |
| `SERVER_NAME` | `Valheim Server` | Shown in the server browser |
| `WORLD_NAME` | `Dedicated` | World/save file name (under `worlds_local/`) |
| `SERVER_PASSWORD` | _(empty)_ | Min 5 chars; required when `SERVER_PUBLIC=true` |
| `SERVER_PUBLIC` | `true` | List on the community server browser |
| `SERVER_PORT` | `2456` | UDP game port; query port is `SERVER_PORT+1` |
| `SERVER_QUERY_PORT` | `2457` | UDP query port; keep this as `SERVER_PORT+1` |
| `CROSSPLAY` | `false` | Enable PlayFab/Xbox + Steam crossplay |

### Mods / advanced

| Variable | Default | Notes |
|---|---|---|
| `BEPINEX` | `false` | Install the BepInEx mod loader on start |
| `BEPINEX_DOWNLOAD_URL` | _(pinned Thunderstore URL)_ | Override to pin a different BepInEx version |
| `EXTRA_ARGS` | _(empty)_ | Extra raw launch flags, e.g. `-preset hard -modifier resources more` |

### Container behaviour

| Variable | Default | Notes |
|---|---|---|
| `BACKUP_ENABLED` | `false` | Background loop writing tar.gz snapshots of the world + lists |
| `BACKUP_INTERVAL` | `3600` | Seconds between backups |
| `BACKUP_KEEP` | `24` | Snapshots retained (older are pruned) |
| `DISCORD_WEBHOOK_URL` | _(empty)_ | If set, posts start/stop/crash/backup events |

Backups are live snapshots. Archive files are written to a temporary path and
renamed into place only after `tar` succeeds, but the game may still be writing
save data while a backup is taken.

## Admin / ban / permitted lists

Valheim has no config file — everything is a launch flag. Access control lives
in three plain-text files in the data volume (one SteamID64 per line), created
by the server on first run:

```
/home/steam/valheim-data/adminlist.txt
/home/steam/valheim-data/bannedlist.txt
/home/steam/valheim-data/permittedlist.txt
```

You can manage these two ways:

- **Edit the files directly** on the volume. They are preserved across restarts
  and included in backups. (Changes are picked up without a full restart.)
- **Drive them from env vars.** Set any of the variables below and the
  entrypoint **overwrites** the matching file on start. Leave a variable unset
  to keep whatever is already on disk.

| Variable | Writes | Notes |
|---|---|---|
| `ADMIN_IDS` | `adminlist.txt` | Comma/space/semicolon/newline separated SteamID64s |
| `BANNED_IDS` | `bannedlist.txt` | Same format |
| `PERMITTED_IDS` | `permittedlist.txt` | Same format (whitelist when used) |

```yaml
environment:
  ADMIN_IDS: "76561198000000000 76561198000000001"
```

> When an env var is set it is the source of truth for that list — any manual
> edits to the corresponding file are replaced on the next start. Mix and match
> freely (e.g. drive `ADMIN_IDS` from env while hand-editing `bannedlist.txt`).

## Mods (BepInEx)

Set `BEPINEX=true` to download and install the official
[`denikson-BepInExPack_Valheim`](https://thunderstore.io/c/valheim/p/denikson/BepInExPack_Valheim/)
into the install volume on start. After the first modded start you'll have:

```
/home/steam/valheim/BepInEx/plugins/    <- drop mod .dll files here
/home/steam/valheim/BepInEx/config/
```

Pin a specific version with `BEPINEX_DOWNLOAD_URL`. Clients must run the same
mods (use r2modman / Thunderstore Mod Manager) to avoid version-mismatch errors.

> The BepInEx pack is downloaded at runtime from Thunderstore (opt-in). If you
> prefer to vendor it yourself, mount it into `/home/steam/valheim` and leave
> `BEPINEX=true`; an existing install is detected and the download is skipped.

## Volumes & ports

- `/home/steam/valheim` — game install (recreatable via SteamCMD; also holds
  BepInEx when enabled).
- `/home/steam/valheim-data` — `worlds_local/`, admin/ban/permitted lists,
  `backups/`.
- Expose UDP `2456` (game) and `2457` (query). Forward both on your router for
  Steam connectivity. Crossplay uses a relay and does not require port
  forwarding.

## Build & run manually

```bash
docker build -t valheim-server:local .

docker run -d --name valheim \
  -p 2456:2456/udp -p 2457:2457/udp \
  -v valheim-install:/home/steam/valheim \
  -v valheim-data:/home/steam/valheim-data \
  -e SERVER_NAME="My Server" \
  -e WORLD_NAME="Midgard" \
  -e SERVER_PASSWORD="hunter2" \
  --restart unless-stopped \
  valheim-server:local
```

## Publishing to GHCR (GitHub Container Registry)

### One-off (local)

```bash
# Use a GitHub Personal Access Token with the write:packages scope.
echo "$GH_PAT" | docker login ghcr.io -u <your-github-username> --password-stdin
docker build -t ghcr.io/mekbits/games/valheim-server:0.1.0 -t ghcr.io/mekbits/games/valheim-server:latest .
docker push ghcr.io/mekbits/games/valheim-server:0.1.0
docker push ghcr.io/mekbits/games/valheim-server:latest
```

### Automated (GitHub Actions)

The root workflow `.github/workflows/docker-publish.yml` (in the repository
root, not this folder) builds all three images on push to
`main` and on `vX.Y.Z` tags, then pushes to
`ghcr.io/mekbits/games/valheim-server` using the built-in `GITHUB_TOKEN` — no
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
docker compose run --rm -e UPDATE_ON_START=true valheim /usr/local/bin/entrypoint.sh
# or simply: temporarily set UPDATE_ON_START=true and restart the service
```
