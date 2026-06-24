# syntax=docker/dockerfile:1
#
# Enshrouded Dedicated Server — Debian slim + Wine (stable, 64-bit only)
#
# Design goals:
#   - Small image: server files are installed to the data volume on first run,
#     not baked into the image.
#   - WINEARCH=win64 runtime; i386 arch is enabled only because the WineHQ
#     packages hard-depend on their i386 component.
#   - Non-root runtime user.
#   - Reproducible: pinned WineHQ apt source, minimal recommended packages.
#
FROM debian:trixie-slim

ARG STEAM_UID=1000
ARG STEAM_GID=1000
ARG WINEHQ_BRANCH=stable

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    WINEDEBUG=-all \
    WINEPREFIX=/home/steam/.wine \
    WINEARCH=win64 \
    STEAM_HOME=/home/steam \
    SERVER_DIR=/home/steam/enshrouded \
    STEAMCMD_DIR=/home/steam/steamcmd \
    ENSHROUDED_APPID=2278520

# --- System deps + WineHQ repo -----------------------------------------------
# WineHQ's win64 packages depend on their i386 counterparts, so i386 must be
# enabled even though the server runs under WINEARCH=win64.
RUN set -eux; \
    dpkg --add-architecture i386; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        jq \
        xvfb \
        procps \
        iproute2 \
        tini \
        lib32gcc-s1 \
        libfreetype6 \
        locales \
        bash \
    ; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://dl.winehq.org/wine-builds/winehq.key \
        | gpg --dearmor -o /etc/apt/keyrings/winehq-archive.gpg; \
    . /etc/os-release; \
    echo "deb [signed-by=/etc/apt/keyrings/winehq-archive.gpg] https://dl.winehq.org/wine-builds/debian/ ${VERSION_CODENAME} main" \
        > /etc/apt/sources.list.d/winehq.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends "winehq-${WINEHQ_BRANCH}"; \
    # cleanup
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
    mkdir -p "${STEAMCMD_DIR}" "${SERVER_DIR}"; \
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors \
        -o /tmp/steamcmd.tar.gz \
        https://media.steampowered.com/installer/steamcmd_linux.tar.gz; \
    tar -xzf /tmp/steamcmd.tar.gz -C "${STEAMCMD_DIR}"; \
    rm -f /tmp/steamcmd.tar.gz; \
    # Trigger first-run self-update so it caches its bootstrap files
    "${STEAMCMD_DIR}/steamcmd.sh" +quit || true

# --- Scripts -----------------------------------------------------------------
USER root
COPY --chmod=0755 scripts/ /usr/local/bin/

# Volumes: server install + savegames/config (single tree — Enshrouded keeps
# its savegame under SERVER_DIR by default).
VOLUME ["/home/steam/enshrouded"]

# Game + query ports (UDP). Override via env at runtime if you change them.
EXPOSE 15636/udp 15637/udp

USER steam
WORKDIR ${SERVER_DIR}

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
