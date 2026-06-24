# syntax=docker/dockerfile:1.7
#
# Valheim Dedicated Server — Debian slim, Linux-native (no Wine)
#
# Design goals:
#   - Small image: server files are installed to the install volume on first
#     run via SteamCMD, not baked into the image.
#   - Native Linux build (valheim_server.x86_64) — no Wine / Xvfb needed.
#   - Non-root runtime user.
#   - Optional BepInEx mod loader (toggle at runtime, opt-in).
#
FROM debian:stable-slim

ARG STEAM_UID=1000
ARG STEAM_GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    STEAM_HOME=/home/steam \
    SERVER_DIR=/home/steam/valheim \
    DATA_DIR=/home/steam/valheim-data \
    STEAMCMD_DIR=/home/steam/steamcmd \
    VALHEIM_APPID=896660 \
    VALHEIM_STEAMAPPID=892970

# --- System deps -------------------------------------------------------------
# SteamCMD needs 32-bit glibc/gcc (lib32gcc-s1). The native server binary needs
# 64-bit runtime libs (libatomic1, libpulse0, libsdl2). unzip is for BepInEx.
RUN set -eux; \
    dpkg --add-architecture i386; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        jq \
        procps \
        iproute2 \
        tini \
        unzip \
        locales \
        bash \
        lib32gcc-s1 \
        libatomic1 \
        libpulse0 \
        libsdl2-2.0-0 \
    ; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# --- Create unprivileged steam user ------------------------------------------
RUN set -eux; \
    groupadd --gid "${STEAM_GID}" steam; \
    useradd  --uid "${STEAM_UID}" --gid "${STEAM_GID}" \
             --home-dir "${STEAM_HOME}" --create-home --shell /bin/bash steam

# --- Install SteamCMD as the steam user --------------------------------------
USER steam
WORKDIR ${STEAM_HOME}

RUN set -eux; \
    mkdir -p "${STEAMCMD_DIR}" "${SERVER_DIR}" "${DATA_DIR}"; \
    curl -fsSL https://media.steampowered.com/installer/steamcmd_linux.tar.gz \
        | tar -xz -C "${STEAMCMD_DIR}"; \
    # Trigger first-run self-update so it caches its bootstrap files
    "${STEAMCMD_DIR}/steamcmd.sh" +quit || true

# --- Scripts -----------------------------------------------------------------
USER root
COPY --chmod=0755 scripts/ /usr/local/bin/

# Two volumes: the server install (re-creatable via SteamCMD) and the
# persistent save tree (worlds_local/, adminlist.txt, bannedlist.txt, ...).
VOLUME ["/home/steam/valheim", "/home/steam/valheim-data"]

# Game (UDP) + Steam query port (game port + 1, UDP).
EXPOSE 2456/udp 2457/udp

USER steam
WORKDIR ${SERVER_DIR}

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
