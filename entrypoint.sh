#!/usr/bin/env bash
set -euo pipefail

USER_NAME="claude"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"

# Mount check (see 'ccd'): the host config dir must actually arrive at ~/.claude. If the
# token is missing, the daemon resolved our bind-mount paths on a different filesystem and
# handed us empty directories — stop before generating keys or logging in into nowhere.
if [ -n "${CCD_MOUNT_TOKEN:-}" ]; then
  seen="$(cat "$USER_HOME/.claude/.ccd-mount-check" 2>/dev/null || true)"
  if [ "$seen" != "$CCD_MOUNT_TOKEN" ]; then
    cat >&2 <<EOF
ccd: the config directory did not arrive in the container.
  host path : ${CCD_HOST_CONFIG_DIR:-?}
  expected  : $USER_HOME/.claude/.ccd-mount-check with this run's token

Bind mounts are resolved by the Docker daemon on *its own* filesystem. This daemon
(${CCD_DOCKER_HOST_HINT:-the local socket}) does not see that path, so it
created empty directories instead — login, SSH key and /workdir would all be wrong.

Fix: make that path available to the daemon at the *same* location. For a dind sidecar
in docker compose: mount the volume that holds it into the dind service as well, at the
same path as in your own container (e.g. '- <home-volume>:/home/<you>').
EOF
    exit 1
  fi
fi

# Optional: map the container user to the host uid/gid so that bind mounts (Linux)
# get the right owner. 'ccd' only sets these on Linux; empty => keep the image uid.
TARGET_UID="${HOST_UID:-}"
TARGET_GID="${HOST_GID:-}"

if [ -n "$TARGET_GID" ] && [ "$TARGET_GID" != "$(id -g "$USER_NAME")" ]; then
  groupmod -o -g "$TARGET_GID" "$USER_NAME"
fi

if [ -n "$TARGET_UID" ] && [ "$TARGET_UID" != "$(id -u "$USER_NAME")" ]; then
  usermod -o -u "$TARGET_UID" "$USER_NAME"
  # Home (incl. ~/.sdkman, …) back to the new owner. A bind-mounted ~/.m2 is skipped:
  # those files already belong to the host user, and a Maven repository is big enough
  # that a recursive chown on every start would be noticeable.
  if grep -q " $USER_HOME/.m2 " /proc/mounts 2>/dev/null; then
    find "$USER_HOME" -path "$USER_HOME/.m2" -prune -o \
      -exec chown -h "$TARGET_UID:${TARGET_GID:-$TARGET_UID}" {} +
  else
    chown -R "$TARGET_UID:${TARGET_GID:-$TARGET_UID}" "$USER_HOME"
  fi
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

# DooD over TCP (ccd --docker with DOCKER_HOST=tcp://...): 'ccd' passes the client TLS certs
# as base64 env vars. Write them where the docker CLI and testcontainers look by default
# (~/.docker) and drop the variables so the private key doesn't linger in claude's env.
if [ -n "${CCD_DOCKER_TLS_CA:-}${CCD_DOCKER_TLS_CERT:-}${CCD_DOCKER_TLS_KEY:-}" ]; then
  CERT_DIR="$USER_HOME/.docker"
  install -d -m 700 -o "$USER_NAME" -g "$(id -g "$USER_NAME")" "$CERT_DIR"
  for pair in ca:CCD_DOCKER_TLS_CA cert:CCD_DOCKER_TLS_CERT key:CCD_DOCKER_TLS_KEY; do
    var="${pair#*:}"
    val="${!var:-}"
    [ -n "$val" ] || continue
    printf '%s' "$val" | base64 -d > "$CERT_DIR/${pair%%:*}.pem"
    chmod 600 "$CERT_DIR/${pair%%:*}.pem"
    chown "$USER_NAME:$(id -g "$USER_NAME")" "$CERT_DIR/${pair%%:*}.pem"
  done
  export DOCKER_CERT_PATH="$CERT_DIR"
  unset CCD_DOCKER_TLS_CA CCD_DOCKER_TLS_CERT CCD_DOCKER_TLS_KEY
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

# ---------------------------------------------------------------------------
# Clipboard bridge (image paste)
# ---------------------------------------------------------------------------
# Claude Code reads images off the clipboard by running 'xclip'. There is no clipboard in
# here, so we install a shim that forwards the request over a bind-mounted directory to
# the poller 'ccd' runs on the host (see the clip_* functions there). Installed
# unconditionally: without a bridge the shim just hands over to the real xclip, which is
# exactly what you want when someone passes a DISPLAY into the container instead.
CLIP_BRIDGE="${CCD_CLIP_BRIDGE:-/run/ccd-clipboard}"
if [ -d "$CLIP_BRIDGE" ]; then
  chown "$(id -u "$USER_NAME"):$(id -g "$USER_NAME")" "$CLIP_BRIDGE" 2>/dev/null || true
  chmod 700 "$CLIP_BRIDGE" 2>/dev/null || true
fi

cat > /usr/local/bin/xclip <<'CCD_XCLIP_SHIM'
#!/bin/sh
# ccd clipboard shim — see entrypoint.sh. Handles the image calls Claude Code makes:
#   xclip -selection clipboard -t TARGETS   -o     -> "image/png" when the host has an image
#   xclip -selection clipboard -t image/png -o     -> the bytes on stdout
#   xclip -selection clipboard -t image/png -i FILE-> put FILE on the host clipboard
# Everything else falls through to the real xclip.
BRIDGE="${CCD_CLIP_BRIDGE:-/run/ccd-clipboard}"
REAL=/usr/bin/xclip

fallback() {
  [ -x "$REAL" ] && exec "$REAL" "$@"
  echo "xclip: no clipboard available in this container" >&2
  exit 1
}

[ -d "$BRIDGE" ] || fallback "$@"

# Scan the arguments without consuming them, so fallback() can still pass on the original
# command line untouched.
mode=out
target=""
file=""
want=""
for a in "$@"; do
  if [ -n "$want" ]; then
    [ "$want" = t ] && target="$a"
    want=""
    continue
  fi
  case "$a" in
    -t|-target|--target)                   want=t ;;
    -sel|-select|-selection|--selection)   want=s ;;
    -d|-display|--display)                 want=s ;;
    -o|-out|--out)                         mode=out ;;
    -i|-in|--in)                           mode=in ;;
    -*)                                    ;;
    *)                                     file="$a" ;;
  esac
done

case "$mode/$target" in
  out/TARGETS|out/targets) op=targets ;;
  out/image/*)             op=read ;;
  in/image/*)              op=write ;;
  *)                       fallback "$@" ;;
esac

id="$BRIDGE/$$-$(date +%s%N 2>/dev/null || date +%s)"
cleanup() { rm -f "$id.op" "$id.req" "$id.out" "$id.rc" "$id.payload" 2>/dev/null; }
trap 'cleanup; exit 1' INT TERM

if [ "$op" = write ]; then
  if [ -n "$file" ]; then
    cp "$file" "$id.payload" 2>/dev/null || { cleanup; exit 1; }
  else
    cat > "$id.payload" || { cleanup; exit 1; }
  fi
fi

# The .req marker goes last: the poller only starts reading once everything else is
# written, so it can never pick up a half-finished request.
printf '%s\n' "$op" > "$id.op" || { cleanup; exit 1; }
: > "$id.req"

# The host answers within a poll interval (100ms) plus however long its clipboard command
# takes. The timeout is only there so a bridge that died can't hang the session.
waited=0
limit=$(( ${CCD_CLIP_TIMEOUT:-10} * 20 ))
while [ ! -f "$id.rc" ]; do
  waited=$(( waited + 1 ))
  if [ "$waited" -gt "$limit" ]; then
    cleanup
    exit 1
  fi
  sleep 0.05
done

rc="$(cat "$id.rc" 2>/dev/null || echo 1)"
[ "$rc" = 0 ] && [ -s "$id.out" ] && cat "$id.out"
cleanup
exit "$rc"
CCD_XCLIP_SHIM
chmod 0755 /usr/local/bin/xclip

# Open a URL in the *host* browser, over the same bridge (op 'url'; see url_open in 'ccd').
# Only http(s) gets through on the host side; we check here too, for a clear error.
cat > /usr/local/bin/ccd-open-url <<'CCD_OPEN_URL'
#!/bin/sh
# ccd host-browser shim — see entrypoint.sh. Usage: ccd-open-url URL
BRIDGE="${CCD_CLIP_BRIDGE:-/run/ccd-clipboard}"
url="$1"
case "$url" in
  http://?*|https://?*) ;;
  *) echo "ccd-open-url: only http(s) URLs can be opened on the host: $url" >&2; exit 1 ;;
esac
if [ ! -d "$BRIDGE" ]; then
  echo "ccd-open-url: no bridge to the host — open this URL yourself: $url" >&2
  exit 1
fi

id="$BRIDGE/$$-$(date +%s%N 2>/dev/null || date +%s)"
cleanup() { rm -f "$id.op" "$id.req" "$id.out" "$id.rc" "$id.payload" 2>/dev/null; }
trap 'cleanup; exit 1' INT TERM

printf '%s\n' "$url" > "$id.payload" || { cleanup; exit 1; }
printf 'url\n' > "$id.op" || { cleanup; exit 1; }
: > "$id.req"

waited=0
limit=$(( ${CCD_CLIP_TIMEOUT:-10} * 20 ))
while [ ! -f "$id.rc" ]; do
  waited=$(( waited + 1 ))
  if [ "$waited" -gt "$limit" ]; then
    cleanup
    echo "ccd-open-url: the host did not answer — open this URL yourself: $url" >&2
    exit 1
  fi
  sleep 0.05
done

rc="$(cat "$id.rc" 2>/dev/null || echo 1)"
cleanup
[ "$rc" = 0 ] || echo "ccd-open-url: the host could not open the URL — open it yourself: $url" >&2
exit "$rc"
CCD_OPEN_URL
chmod 0755 /usr/local/bin/ccd-open-url

# Vibe's terminal UI (vibe-rs) doesn't look at $BROWSER: it runs 'xdg-open URL' itself.
# This shim sits in front of the real xdg-open (if any) on PATH and sends a single http(s)
# URL to the host — but only when the entrypoint switched that on for this session (see
# CCD_OPEN_URL_VIA_HOST below). Everything else goes to the real xdg-open, or fails, after
# which Vibe shows the URL to copy.
cat > /usr/local/bin/xdg-open <<'CCD_XDG_OPEN'
#!/bin/sh
# ccd xdg-open shim — see entrypoint.sh.
if [ "${CCD_OPEN_URL_VIA_HOST:-}" = 1 ] && [ $# -eq 1 ]; then
  case "$1" in
    http://?*|https://?*) exec /usr/local/bin/ccd-open-url "$1" ;;
  esac
fi
[ -x /usr/bin/xdg-open ] && exec /usr/bin/xdg-open "$@"
echo "xdg-open: no browser available in this container: $*" >&2
exit 1
CCD_XDG_OPEN
chmod 0755 /usr/local/bin/xdg-open

# Which agent to start: Claude Code by default, Mistral Vibe when ccd was invoked as 'vibed'
# (it passes CCD_AGENT=vibe). A whitelist, not "run whatever the variable says".
case "${CCD_AGENT:-claude}" in
  claude) AGENT_CMD=claude ;;
  vibe)   AGENT_CMD=vibe ;;
  *)      echo "ccd: unknown CCD_AGENT '${CCD_AGENT}' (expected 'claude' or 'vibe')." >&2
          exit 1 ;;
esac

# Vibe signs in by opening a URL: its terminal UI through 'xdg-open' (the shim above), its
# Python side through the webbrowser module, which honours $BROWSER. Only when ccd found a
# way to open URLs on the host (CCD_BROWSER_BRIDGE), and only for Vibe (whose sign-in polls Mistral, so no callback has to reach the container):
# whether Claude Code's /login would survive a host browser — an OAuth redirect to
# localhost lands on the host, not here — is untested, so its current flow stays as is.
if [ "$AGENT_CMD" = vibe ] && [ "${CCD_BROWSER_BRIDGE:-}" = 1 ] && [ -z "${BROWSER:-}" ]; then
  export BROWSER=/usr/local/bin/ccd-open-url
fi
if [ "$AGENT_CMD" = vibe ] && [ "${CCD_BROWSER_BRIDGE:-}" = 1 ]; then
  export CCD_OPEN_URL_VIA_HOST=1
fi

# Drop privileges to 'claude' and start the agent
# (login shell so SDKMAN/Java/Maven are on PATH)
exec gosu "$USER_NAME" bash -lc 'exec "$0" "$@"' "$AGENT_CMD" "$@"
