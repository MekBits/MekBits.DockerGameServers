# MekBits Docker Game Servers

A small collection of unofficial, minimal-footprint Docker images for
self-hosting dedicated game servers. Each image follows the same conventions —
SteamCMD-based install onto a volume, a non-root `steam` user, `tini` as PID 1,
env-driven configuration, optional backups, and Discord notifications — so once
you know one, you know them all.

## Servers

| Server | Folder | Runtime | Steam AppID | Default ports (UDP) | Notes |
|---|---|---|---|---|---|
| **Valheim** | [`valheim-docker/`](valheim-docker) | Native Linux | `896660` | `2456` game, `2457` query | Optional BepInEx mods, crossplay, env-driven access lists |
| **V Rising** | [`vrising-docker/`](vrising-docker) | Debian + Wine (x64) | `1829350` | `9876` game, `27015` query | Optional RCON/API, JSON config merge |
| **Enshrouded** | [`enshrouded-docker/`](enshrouded-docker) | Debian + Wine (x64) | `2278520` | `15636` game, `15637` query | JSON config merge |

> V Rising and Enshrouded are Windows-only binaries run under 64-bit Wine.

## Shared design

| Choice | Why |
|---|---|
| `debian:trixie-slim` base | Explicit Debian release with realistic runtime libraries for Steam and Wine. |
| Server files installed to a **volume**, not baked into the image | Image stays small; game updates don't require an image rebuild. |
| Non-root user `steam` (uid 1000) | Standard hardening; matches most NAS/host conventions. |
| `tini` as PID 1 + explicit forwarding | Reaps zombies and gives the game process a clean stop path. |
| Env-driven config via Compose interpolation | Edit `.env`; Compose passes those values into the container. |
| Image + Compose healthchecks | UDP can't be probed traditionally; check the process and a bound socket. |
| Optional backups + Discord notifications | Background tar.gz snapshots with atomic archive writes and start/stop/crash webhooks. |

## Quick start

Pick a server folder and use Docker Compose:

```bash
cd valheim-docker          # or vrising-docker / enshrouded-docker
cp .env.example .env       # edit values (set a real password!)
docker compose up -d --build
docker compose logs -f
```

The first start runs the initial SteamCMD install into the volume. Subsequent
starts skip the update unless `UPDATE_ON_START=true`. See each folder's
`README.md` for the full environment-variable reference, volume layout, and
port-forwarding details.

Backups are best-effort live snapshots of game save data. They avoid partial
archive files, but they do not replace offline backups or game-native save/flush
mechanisms where a specific title exposes one.

## Repository layout

```
.
├── .github/workflows/    # CI: build & push all images to GHCR
├── valheim-docker/        # Valheim dedicated server (native Linux)
├── vrising-docker/        # V Rising dedicated server (Wine)
├── enshrouded-docker/     # Enshrouded dedicated server (Wine)
└── LICENSE
```

Each server folder contains:

```
Dockerfile
docker-compose.yml
.env.example
.dockerignore
README.md
scripts/                 # entrypoint, backup, healthcheck, notify, ...
```

## Publishing

The root workflow `.github/workflows/docker-publish.yml` builds all three
images (matrix) on push to `main` and on `vX.Y.Z` tags, then pushes to the
GitHub Container Registry under
`ghcr.io/mekbits/games/<game>-server` using the built-in `GITHUB_TOKEN` — no
Docker Hub account or extra secrets required.
Published images include BuildKit provenance and SBOM attestations.

| Image | Registry path |
|---|---|
| Valheim | `ghcr.io/mekbits/games/valheim-server` |
| V Rising | `ghcr.io/mekbits/games/vrising-server` |
| Enshrouded | `ghcr.io/mekbits/games/enshrouded-server` |

To publish under a different path, set the optional `IMAGE_NAME` repository
variable in each repo/folder.

## Disclaimer

These images are unofficial and not affiliated with or endorsed by the
respective game developers or publishers. Game content is downloaded at runtime
via SteamCMD under your own Steam licence terms. Provided as-is.

## License

Licensed under the [Apache License 2.0](LICENSE).
