#!/usr/bin/env bash
set -euo pipefail

USER_NAME="claude"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"

# Optional: map the container user to the host uid/gid so that bind mounts (Linux)
# get the right owner. 'ccd' only sets these on Linux; empty => keep the image uid.
TARGET_UID="${HOST_UID:-}"
TARGET_GID="${HOST_GID:-}"

if [ -n "$TARGET_GID" ] && [ "$TARGET_GID" != "$(id -g "$USER_NAME")" ]; then
  groupmod -o -g "$TARGET_GID" "$USER_NAME"
fi

if [ -n "$TARGET_UID" ] && [ "$TARGET_UID" != "$(id -u "$USER_NAME")" ]; then
  usermod -o -u "$TARGET_UID" "$USER_NAME"
  # Home (incl. ~/.sdkman, ~/.m2, …) back to the new owner
  chown -R "$TARGET_UID:${TARGET_GID:-$TARGET_UID}" "$USER_HOME"
fi

# Persistent SSH directory (mounted at ~/.ssh by 'ccd'). Set the right owner/permissions
# so SSH accepts the key/known_hosts, and generate a container-owned key once.
SSH_DIR="$USER_HOME/.ssh"
if [ -d "$SSH_DIR" ]; then
  chown -R "$(id -u "$USER_NAME"):$(id -g "$USER_NAME")" "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  find "$SSH_DIR" -type f -exec chmod 600 {} + 2>/dev/null || true

  if ! ls "$SSH_DIR"/id_* >/dev/null 2>&1; then
    echo "No SSH key found — generating an ed25519 key once..."
    gosu "$USER_NAME" ssh-keygen -t ed25519 -N "" -f "$SSH_DIR/id_ed25519" -C "claude-code-container" >/dev/null
    echo "Add this public key to GitLab/GitHub (Settings → SSH Keys):"
    echo
    cat "$SSH_DIR/id_ed25519.pub"
    echo
  fi
fi

# DinD mode: start our own Docker daemon *in* the container (separate from the host Docker).
# 'ccd' then runs the container with --privileged and sets CCD_DOCKER_MODE=dind.
if [ "${CCD_DOCKER_MODE:-}" = "dind" ]; then
  # Create the 'docker' group so the socket gets a group gid that 'claude' can reach.
  getent group docker >/dev/null || groupadd docker
  usermod -aG docker "$USER_NAME"

  echo "Starting the internal Docker daemon (DinD)..."
  mkdir -p /var/lib/docker
  dockerd >/var/log/dockerd.log 2>&1 &

  ready=0
  for _ in $(seq 1 30); do
    if docker info >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
  done
  if [ "$ready" != "1" ]; then
    echo "The internal Docker daemon did not come up within the timeout. Last log lines:" >&2
    tail -n 20 /var/log/dockerd.log >&2 || true
    exit 1
  fi
  echo "Internal Docker daemon is up."

  # --prune: clean up the whole DinD store (all images, stopped containers, build cache,
  # unused volumes) and exit — no Claude session is started.
  if [ "${CCD_PRUNE:-}" = "1" ]; then
    echo "Cleaning up the DinD store..."
    docker system prune -a -f --volumes
    echo "Done."
    exit 0
  fi
fi

# Docker socket access: if the host socket is mounted (ccd --docker), make sure 'claude'
# can reach it. We look up the gid of the socket and put 'claude' in a group with that gid
# (the gid on the host rarely matches an existing group in the container).
DOCKER_SOCK=/var/run/docker.sock
if [ -S "$DOCKER_SOCK" ]; then
  SOCK_GID="$(stat -c %g "$DOCKER_SOCK" 2>/dev/null || echo 0)"
  if [ "$SOCK_GID" != "0" ]; then
    # getent exits non-zero when the gid has no name; under 'set -euo pipefail' that would
    # silently kill the entrypoint before 'exec claude'. '|| true' catches that, so GRP
    # simply stays empty and we create the group below.
    GRP="$(getent group "$SOCK_GID" | cut -d: -f1 || true)"
    if [ -z "$GRP" ]; then
      groupadd -o -g "$SOCK_GID" docker
      GRP=docker
    fi
    usermod -aG "$GRP" "$USER_NAME"
  else
    # gid 0 / undeterminable (e.g. Docker Desktop): make the socket directly accessible.
    chmod 666 "$DOCKER_SOCK" || true
  fi
fi

# Drop privileges to 'claude' and start Claude Code
# (login shell so SDKMAN/Java/Maven are on PATH)
exec gosu "$USER_NAME" bash -lc 'exec claude "$@"' -- "$@"
