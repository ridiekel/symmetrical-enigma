FROM ubuntu:26.04

ARG DEBIAN_FRONTEND=noninteractive

# Base + tooling that Claude Code often expects
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget ca-certificates gnupg \
    git git-lfs gh \
    ripgrep fd-find fzf jq \
    less vim nano \
    unzip zip tar \
    skopeo \
    python3 python3-pip python3-venv pipx \
    build-essential pkg-config \
    python3-yaml python3-requests python3-jinja2 python3-dateutil \
    python3-toml python3-bs4 python3-lxml python3-tabulate \
    python3-rich python3-pytest \
    python3-numpy python3-pandas python3-matplotlib \
    sudo openssh-client \
    bash-completion \
    gosu \
    iptables uidmap \
    && rm -rf /var/lib/apt/lists/*

# Ubuntu marks its Python as "externally managed" (PEP 668), which makes a plain
# 'pip install X' abort with an error instead of installing. In a throwaway container
# there is nothing to protect: we enable break-system-packages so Claude can install
# missing libraries itself.
RUN printf '[global]\nbreak-system-packages = true\n' > /etc/pip.conf

# fd is called 'fdfind' on Ubuntu -> alias it to 'fd'
RUN ln -s "$(which fdfind)" /usr/local/bin/fd

# uv/uvx: skills (BMAD among others) invoke scripts with 'uv run', which fails without uv
# and had to be rewritten to 'python3' by hand. Ubuntu doesn't package uv (yet), hence no
# apt line above; we pull it as a wheel from PyPI instead of via astral.sh's 'curl | sh'
# script. A root install lands in /usr/local/bin, so *every* user has it on PATH.
# Requires the break-system-packages setting from /etc/pip.conf above.
RUN pip3 install --root-user-action=ignore uv \
    && uv --version && uvx --version

# Docker binaries + compose plugin. Needed to run tests from inside the container that
# start containers themselves (testcontainers, docker compose, ...). We install both the
# client (for DooD mode with the host socket) and the daemon binaries dockerd/containerd/
# runc (for DinD mode with its own daemon in the container). The static binaries are
# independent of the Ubuntu codename in the Docker apt repo.
ARG DOCKER_VERSION=27.5.1
ARG COMPOSE_VERSION=2.32.4
RUN set -eux; \
    arch="$(uname -m)"; \
    curl -fsSL "https://download.docker.com/linux/static/stable/${arch}/docker-${DOCKER_VERSION}.tgz" -o /tmp/docker.tgz; \
    tar -xzf /tmp/docker.tgz -C /tmp; \
    install -m 0755 /tmp/docker/* /usr/local/bin/; \
    rm -rf /tmp/docker /tmp/docker.tgz; \
    mkdir -p /usr/local/lib/docker/cli-plugins; \
    curl -fsSL "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-${arch}" \
      -o /usr/local/lib/docker/cli-plugins/docker-compose; \
    chmod 0755 /usr/local/lib/docker/cli-plugins/docker-compose

# Node.js LTS (required for Claude Code)
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Claude Code + commonly used CLI helpers
RUN npm install -g @anthropic-ai/claude-code yarn pnpm \
    && npm cache clean --force

# Disable the auto-updater. Claude Code is installed globally as root here
# (/usr/lib/node_modules is owned by root), while the session runs as 'claude'
# — that user may not write in the npm prefix, which yields "Auto-update failed: no write
# permission to npm prefix". In a --rm container an update would be lost anyway;
# refresh the image with 'ccd --rebuild'.
ENV DISABLE_AUTOUPDATER=1

# ubuntu:26.04 already has an 'ubuntu' user on uid 1000 -> rename it to claude
RUN usermod -l claude -d /home/claude -m ubuntu \
    && groupmod -n claude ubuntu \
    && echo "claude ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Chromium for browser work in the container: screenshots of a local dev server,
# HTML/PDF rendering and e2e tests (Playwright/Puppeteer). Ubuntu ships chromium only as a
# snap stub (chromium-browser 2:1snap1), which doesn't work in a container; Google's
# google-chrome .deb in turn only exists for amd64, while this image is also built on arm64
# (Colima/Apple Silicon). Playwright does host Chromium builds for both architectures, and
# '--with-deps' installs the required system libs right away.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN set -eux; \
    npm install -g playwright; \
    apt-get update; \
    playwright install --with-deps chromium; \
    rm -rf /var/lib/apt/lists/*; \
    npm cache clean --force; \
    chown -R claude:claude "$PLAYWRIGHT_BROWSERS_PATH"

# Chromium's own sandbox doesn't work in this container (the user-namespace sandbox is
# blocked by the host's seccomp/AppArmor -> "No usable sandbox!") and /dev/shm is only
# 64 MB by default, which makes tabs crash at random. The wrapper sets those two flags for
# every invocation, so 'chromium' and everything following CHROME_PATH just works.
RUN set -eux; \
    chrome_bin="$(find "$PLAYWRIGHT_BROWSERS_PATH" -maxdepth 3 -type f -name chrome -path '*chrome-linux*' | head -n1)"; \
    test -n "$chrome_bin"; \
    printf '#!/bin/sh\nexec %s --no-sandbox --disable-dev-shm-usage "$@"\n' "$chrome_bin" > /usr/local/bin/chromium; \
    chmod 0755 /usr/local/bin/chromium; \
    ln -s /usr/local/bin/chromium /usr/local/bin/chrome; \
    ln -s /usr/local/bin/chromium /usr/local/bin/google-chrome; \
    chromium --headless --dump-dom about:blank > /dev/null

# This way Puppeteer/Playwright projects no longer have to download their own browser.
ENV CHROME_PATH=/usr/local/bin/chromium \
    CHROME_BIN=/usr/local/bin/chromium \
    PUPPETEER_EXECUTABLE_PATH=/usr/local/bin/chromium \
    PUPPETEER_SKIP_DOWNLOAD=1

USER claude
ENV HOME=/home/claude
# By default Claude stores its main config as ~/.claude.json (a separate file in the
# home directory), while 'ccd' only mounts ~/.claude. That made .claude.json get lost on
# every '--rm' run ("configuration file not found"). CLAUDE_CONFIG_DIR moves
# .claude.json (and projects/sessions/backups) *into* the mounted directory, so everything is persistent.
ENV CLAUDE_CONFIG_DIR="${HOME}/.claude"
ENV SDKMAN_DIR="${HOME}/.sdkman"

# Install SDKMAN
RUN curl -fsSL "https://get.sdkman.io?rcupdate=false" | bash

# GraalVM (full JDK + native-image) and Maven via SDKMAN
ENV GRAAL_MAJOR=25

# SDKMAN identifiers are parsed out of the last column of 'sdk list java'; a plain grep on
# the version number no longer works since GraalVM switched its scheme (JDK 21 was
# '21.0.12-graal', JDK 25 is '25.3.4+1.r25-graal'). The '-graal$' anchor keeps GraalVM CE
# ('-graalce') out of the list.
# We don't just take the newest version: it is sometimes listed but not (yet)
# installable for this platform ("... is not available"), which made the build fail.
# So we walk through all GraalVM candidates of this major version (newest first) and
# keep going until one installs successfully.
RUN bash -lc 'source "${SDKMAN_DIR}/bin/sdkman-init.sh" && \
    listing=$(sdk list java) && \
    candidates=$(printf "%s\n" "$listing" | sed -E "s/.*\| *//; s/ +$//" \
      | grep -E "^${GRAAL_MAJOR}[.+][^ ]*-graal$" | sort -Vru || true) && \
    echo "GraalVM candidates (newest first): $candidates" && \
    installed="" && \
    for v in $candidates; do \
      echo ">> Attempting to install $v" && \
      if sdk install java "$v"; then \
        installed="$v"; \
        echo ">> Succeeded: $v"; \
        break; \
      fi; \
      echo ">> $v not available, trying next candidate..."; \
    done && \
    if [ -z "$installed" ]; then \
      echo "!! No GraalVM $GRAAL_MAJOR version could be installed; graal entries seen:" >&2; \
      printf "%s\n" "$listing" | grep -i graal >&2 || true; \
      exit 1; \
    fi && \
    sdk default java "$installed" && \
    sdk flush archives && sdk flush temp'

RUN bash -lc 'source "${SDKMAN_DIR}/bin/sdkman-init.sh" && \
    echo "Installing: maven" && \
    sdk install maven && \
    sdk flush archives && sdk flush temp'

# Make sure the SDKMAN init is loaded in every *interactive* shell (for the 'sdk' function, among others).
RUN echo 'source "${SDKMAN_DIR}/bin/sdkman-init.sh"' >> "${HOME}/.bashrc"

# Put Java/Maven firmly on PATH via the image ENV. Normally SDKMAN only puts them on PATH via
# the ~/.bashrc line above, but Ubuntu's .bashrc bails out at the top with a guard
# (case $- in *i*) ;; *) return) for non-interactive shells. The entrypoint starts Claude
# with 'bash -lc' (login, but NOT interactive) and Claude Code runs its Bash tool
# non-interactively too — in both cases the SDKMAN init is never reached, which meant
# 'java'/'mvn'/'native-image' weren't found ("no local Maven/JDK"). Via the
# 'current' symlinks (which SDKMAN creates for the default candidate) *every* process now
# inherits them, regardless of which shell init runs.
ENV JAVA_HOME="${SDKMAN_DIR}/candidates/java/current"
ENV MAVEN_HOME="${SDKMAN_DIR}/candidates/maven/current"
ENV PATH="${JAVA_HOME}/bin:${MAVEN_HOME}/bin:${PATH}"

# The entrypoint runs as root, maps 'claude' to the host uid/gid (if provided)
# and then drops privileges with gosu.
USER root

# Clipboard tools for the clipboard bridge (see entrypoint.sh). Only the *fallback* path
# needs these — the bridge itself talks to the host, so this is for the case where someone
# passes a real DISPLAY into the container instead. Kept in its own late layer rather than
# in the apt block at the top: touching that first RUN invalidates the whole cache, and a
# rebuild of this image means downloading GraalVM and Chromium all over again.
RUN apt-get update && apt-get install -y --no-install-recommends \
    xclip wl-clipboard \
    && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workdir
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
