# Claude Code in Docker

Run [Claude Code](https://docs.claude.com/en/docs/claude-code) in a container, with `ccd` as a handy wrapper. The wrapper starts Docker automatically (colima / Docker Desktop / systemd), **builds the image locally from the `Dockerfile`** (so it works on arm64/macOS too), mounts your current directory and keeps your login between sessions.

## Supported environments

| Target | Shell | Docker runtime | Notes |
| --- | --- | --- | --- |
| **Linux** (x86_64 / arm64) | `bash`, `zsh`, `fish` | daemon via `systemd` (rootless works too) | the container takes over your host uid/gid, so bind-mounted files keep the right owner |
| **macOS** (Intel / Apple Silicon) | `bash`, `zsh`, `fish` | [colima](https://github.com/abiosoft/colima) or Docker Desktop | the image is built locally, so arm64 needs no prebuilt image |
| **Windows 10/11** | **Git Bash** only | Docker Desktop | started automatically; interactive sessions go through `winpty` — see [Windows / Git Bash](#windows--git-bash) |
| **WSL2** | `bash`, `zsh`, `fish` | Docker Desktop WSL integration, or a daemon in the distro | counts as Linux; run `ccd` from inside WSL, not from Git Bash |

PowerShell and `cmd` are not supported — on Windows use Git Bash.

## Quick start

Install (no clone needed) and run:

```bash
curl -fsSL https://raw.githubusercontent.com/ridiekel/symmetrical-enigma/main/install.sh | sh
```

Starting the container

```bash
ccd                 # interactive Claude Code session in the current directory
ccd -p "fix the failing test"
```

The installer puts `ccd` in `~/.local/bin` and adds that to your `PATH` — open a new shell
afterwards. The first `ccd` builds the image (that takes a while); after that `ccd`
[updates itself](#auto-update) from GitHub on every start and rebuilds only when the build
files changed. See [Installation](#installation) for options and the development setup.

## What's in the image

Based on `ubuntu:26.04`, including:

- **Claude Code** (`@anthropic-ai/claude-code`) + `yarn` / `pnpm`
- **Node.js LTS**, **Python 3** (`pip`, `venv`, `pipx`)
- **GraalVM 25** (full JDK + `native-image`) and **Maven** via SDKMAN
- Tooling: `git`, `git-lfs`, `ripgrep`, `fd`, `fzf`, `jq`, `build-essential`, …
- **Chromium** (headless) for screenshots, HTML/PDF rendering and e2e tests

The container runs as the non-root user `claude`. On Linux it automatically takes over your
host uid/gid (via `ccd`), so files in bind mounts get the right owner.

## Requirements

- **Docker** (CLI + daemon)
- `bash` plus `curl` or `wget` (for the installer and the auto-update)
- macOS: [colima](https://github.com/abiosoft/colima) (`brew install colima`) **or** Docker Desktop
- Linux: a Docker daemon (started via `systemd`)
- Windows: Docker Desktop, run from **Git Bash** (see below)

### Windows / Git Bash

`ccd` runs in Git Bash (MSYS); PowerShell and `cmd` are not supported. Two things are
worth knowing:

- **Docker Desktop** is the runtime. `ccd` starts it automatically when it isn't running
  yet — it looks in `%ProgramFiles%\\Docker\\Docker\\` and `%LOCALAPPDATA%\\Docker\\`. For a
  non-standard installation, point `CCD_DOCKER_DESKTOP` at `Docker Desktop.exe`.
- **`winpty`** (ships with Git for Windows) is used automatically for interactive
  sessions; without it Docker refuses the TTY with *"the input device is not a TTY"*.

Your project has to live on a drive Docker Desktop can share (the default `C:` is fine).
For repositories inside WSL, run `ccd` from WSL itself rather than from Git Bash.

## Installation

One line, no clone needed:

```bash
curl -fsSL https://raw.githubusercontent.com/ridiekel/symmetrical-enigma/main/install.sh | sh
```

(`| bash` works just as well — the installer is plain POSIX `sh`.)

It downloads `ccd`, `Dockerfile` and `entrypoint.sh` into `~/.local/share/ccd`, creates a
symlink at `~/.local/bin/ccd` and adds that directory to your `PATH` if needed (for `zsh`,
`bash` or `fish`). Open a new shell (or `source` your rc file) and `ccd` works everywhere.

From then on `ccd` [keeps itself up to date](#auto-update) — you never need the repo.

Want a different location or another source? Set the variables **on the `sh`**, not on
`curl` (the pipe doesn't carry the environment along):

```bash
curl -fsSL https://raw.githubusercontent.com/ridiekel/symmetrical-enigma/main/install.sh \
  | BIN_DIR=/usr/local/bin sh
```

| Variable | Default | Purpose |
| -------- | ------- | ------- |
| `CCD_HOME` | `~/.local/share/ccd` | where `ccd` + the build files land |
| `BIN_DIR` | `~/.local/bin` | where the `ccd` command is linked |
| `CCD_REPO` | `ridiekel/symmetrical-enigma` | install/update from a fork |
| `CCD_BRANCH` | `main` | install/update from another branch |
| `CCD_RAW_BASE` | raw GitHub URL of repo+branch | fetch from a completely different host (mirror, GitLab raw, `file://`) |

`CCD_REPO`/`CCD_BRANCH`/`CCD_RAW_BASE` are stored in `$CCD_HOME/.ccd-source`, so a fork
keeps updating itself from that fork.

### From a clone (development)

```bash
git clone https://github.com/ridiekel/symmetrical-enigma.git
cd symmetrical-enigma && ./install.sh
```

The same installer then notices the sources next to it and symlinks `ccd` straight to your
working copy. In a git checkout the auto-update stays **off**, so your own edits (and
`git pull`) stay in charge.

### Already installed from a clone?

Running the `curl | sh` line on top of it is safe: your clone is **not** touched — no file
in it is overwritten or deleted. The installer only repoints the symlink in `~/.local/bin`
at the managed copy in `~/.local/share/ccd` (and says so), and the `PATH` line in your rc
file is only added once. Going back is a `./install.sh` in your clone. Should a *real*
file (not a symlink) be sitting at `~/.local/bin/ccd`, it is moved aside as
`ccd.backup-<timestamp>` instead of being overwritten.

Do note that both installations share `~/.config/claude-docker` (login, SSH key, build
hash) and the image tag `claude-code:local`. So if your clone's `Dockerfile` differs from
the one on GitHub, every switch between the two triggers a rebuild.

### Auto-update

At every start `ccd` compares its own three files (`ccd`, `Dockerfile`, `entrypoint.sh`)
with the raw versions on GitHub and replaces whatever differs:

- changed `Dockerfile`/`entrypoint.sh` → the image is **rebuilt automatically** on this run
  (the build hash below covers exactly those two files);
- a changed `ccd` → the script restarts itself, so the new version handles this run.

The check fails soft: without a network, without `curl`/`wget` or with a GitHub hiccup you
simply keep running on what you already have. It is skipped in a git checkout.

| Turn off / adjust | Effect |
| ----------------- | ------ |
| `ccd --no-update` | skip the check for this run |
| `CCD_NO_UPDATE=1` | same, via the environment |
| `CCD_UPDATE_INTERVAL=86400` | check at most once per N seconds (default `0` = every start) |

## Usage

```bash
ccd                 # interactive Claude Code session in the current directory
ccd --version       # arguments are passed through to claude
ccd -p "fix the failing test"
```

`ccd` automatically:

1. Checks whether Docker is running and starts it otherwise.
2. Builds the image locally from the `Dockerfile` (only when needed — see below).
3. Mounts the current directory at `/workdir` in the container.
4. Keeps config/login in `~/.config/claude-docker` (mounted at `/home/claude/.claude`).

### Building the image

By default `ccd` builds the image `claude-code:local` from the `Dockerfile` next to the script
and runs it. Because we can't pull a ready-made image from the registry on `arm64`/macOS,
the build happens locally.

The build runs **only when needed**: when the image doesn't exist yet, or when
`Dockerfile`/`entrypoint.sh` have changed (checked via a hash in
`~/.config/claude-docker/.image-hash`). That keeps a repeated `ccd` fast.

**On an update:** when the auto-update pulls in a new `Dockerfile` or `entrypoint.sh`, the
hash changes and the image is rebuilt (cached) on that same run.

**Automatic refresh:** if the local image is older than **10 days**, `ccd` does a clean
rebuild (`--no-cache`) by itself so the latest Claude Code and base-image/apt updates get
pulled again — a cached rebuild would reuse the old `npm` layer and therefore refresh
nothing. Adjust the threshold with `CCD_IMAGE_MAX_AGE_DAYS` (e.g. `=30`), or set
`CCD_IMAGE_MAX_AGE_DAYS=0` to disable it.

Force a rebuild with the `--rebuild` flag (or the `CLAUDE_REBUILD` env var):

```bash
ccd --rebuild
CLAUDE_REBUILD=1 ccd   # same effect
```

`--rebuild` builds without cache (`--no-cache`) and afterwards cleans up the leftover
old images and unused build cache layers. **Volumes are left untouched**, so the
DinD image store (`claude-dind-data`) and your Claude config aren't lost.

### Authentication

Two options:

- **API key**: set `ANTHROPIC_API_KEY` in your environment; `ccd` only forwards it when it is set.
- **Login**: log in once inside the container — the credentials are kept in `~/.config/claude-docker` for later sessions.

### Persistent config

`ccd` mounts `~/.config/claude-docker` at `/home/claude/.claude` in the container.
Claude Code, however, stores its main config as `~/.claude.json` by default (a separate
file *in* the home directory), not *in* `~/.claude`. With a `--rm` run that file was
therefore lost ("configuration file not found"). That's why the image sets
`CLAUDE_CONFIG_DIR=/home/claude/.claude`, so `.claude.json` plus `projects/`,
`sessions/` and `backups/` all end up *in* the mounted directory and are kept between
sessions.

### SSH / git over SSH

`ccd` mounts a persistent, container-owned SSH directory
(`~/.config/claude-docker/ssh`) at `/home/claude/.ssh`. This keeps your
SSH key *and* `known_hosts` across `--rm` runs — separate from your host `~/.ssh`.

On the first run without a key, the container automatically generates an `ed25519` key
and prints the **public key**. Add it to GitLab/GitHub (Settings → SSH Keys) so you
can push. `known_hosts` is filled as soon as you accept the host fingerprint for the
first time (typing `yes`); after that it is kept.

Want to use your own key? Just put your private/public key in
`~/.config/claude-docker/ssh/` (e.g. `id_ed25519` + `id_ed25519.pub`); the container
then skips the automatic generation.

### Docker-in-Docker (testcontainers, docker compose)

Sometimes you run tests that start Docker containers themselves (e.g. [testcontainers](https://testcontainers.com/)
or `docker compose`). Because Claude Code already runs *in* a container, `ccd` offers two
modes for that via a startup flag. The `docker` CLI, the daemon binaries and the compose plugin
are already in the image.

Both modes are **opt-in per run**. Without a flag the container is unprivileged and has no
Docker access at all: no socket is mounted and no daemon runs, so the `docker` CLI in the
image has nothing to talk to.

| Flag | Mode | What it does |
| ---- | ---- | ------------ |
| `--docker` or `--docker=host` | **DooD** (Docker-outside-of-Docker) | Mounts the host Docker socket; testcontainers run as *siblings* on the host daemon. |
| `--docker=dind` or `--dind` | **DinD** (Docker-in-Docker) | Starts its own daemon *in* the container, fully separate from the host. |
| `--prune` | **DinD** + cleanup | Cleans up the DinD image store and exits (implies `--dind`). |
| `--rebuild` | build | Forces a clean rebuild (`--no-cache`) of the local image and cleans up old images/build cache (volumes are kept). |
| `--no-update` | update | Skips the auto-update check against GitHub for this run. |

The flag goes before the arguments for `claude`; everything else `ccd` passes through unchanged:

```bash
ccd --docker -p "run the integration tests"   # host daemon (DooD)
ccd --dind   -p "run the integration tests"   # own daemon (DinD)
```

> **Note (security): neither mode is a boundary against your machine.** DooD hands the
> container the host Docker socket, and with it the ability to start a privileged container
> on the host daemon. DinD needs `--privileged` because a real `dockerd` has to mount the
> overlay storage driver, write to `/sys/fs/cgroup`, set up `iptables`/bridge networking and
> reach an unmasked `/proc` — a default container is denied all four. Both are effectively
> root on the host, so choose a mode for **isolation**, not for safety:

| | DooD (`--docker`) | DinD (`--dind`) |
| --- | --- | --- |
| Image/container store | shared with the host — Claude can see, stop and prune the containers you are running yourself | separate, in the `claude-dind-data` volume |
| Speed and disk | reuses the host image cache | pulls every image again |
| Lifetime | containers outlive the `ccd` session | daemon and containers disappear with the session |

Removing `--privileged` from DinD doesn't make it safer — it stops working. `dockerd` fails
during startup, the entrypoint waits 30 seconds, dumps the daemon log and exits. Unprivileged
DinD would need rootless `dockerd` (`/dev/fuse`, cgroup delegation, unconfined
seccomp/apparmor) or the [sysbox](https://github.com/nestybox/sysbox) runtime on the host.

**DooD (`--docker`)** — fast, and shares images with the host:

1. Locates the host Docker socket and mounts it at `/var/run/docker.sock` in the container.
   - **Linux**: the real socket path comes from the active docker context
     (`docker context inspect`), with `$DOCKER_HOST` and `/var/run/docker.sock` as fallbacks —
     that way a rootless daemon on `$XDG_RUNTIME_DIR/docker.sock` works too.
   - **macOS (Docker Desktop / Colima)**: the daemon runs in a VM. We mount
     `/var/run/docker.sock`; both runtimes resolve that path inside the VM to the real
     daemon socket (the host path itself — e.g. Colima's `~/.colima/<profile>/docker.sock` —
     can't serve as a bind source).
2. The `entrypoint` puts `claude` in a group with the right gid so it can reach the socket
   (if the gid has no name in the container, that group is created).
3. **Linux**: adds `--network host`, so the ports testcontainers publishes are reachable via
   `localhost` and the Ryuk reaper works.
4. **macOS**: sets `TESTCONTAINERS_HOST_OVERRIDE=host.docker.internal`,
   so testcontainers finds the started containers via the host.

**DinD (`--dind`)** — fully isolated from the host Docker:

1. Runs the container with `--privileged` and starts its own `dockerd` in the `entrypoint`.
2. testcontainers connect via `localhost` inside the container — no extra network config needed.
3. Pulled images are kept in a named volume `claude-dind-data` (mounted at
   `/var/lib/docker`), so a next run doesn't have to download everything again.

Is that volume filling up? Clean it up with:

```bash
ccd --prune
```

`--prune` implies `--dind`: it briefly starts the internal daemon, runs
`docker system prune -a -f --volumes` (all images, stopped containers, build cache and
unused volumes in the store) and then exits — *no* Claude session is started.
The volume itself keeps existing (now empty). To remove it entirely, you can also run
`docker volume rm claude-dind-data` on the host.

> **Note:** DinD does *not* touch the host Docker. The internal daemon (and everything the
> tests start) disappears when the ccd session stops; only the image volume remains. See the
> security note above for why `--privileged` is needed.

> **Bind mounts from the tests (DooD only):** in DooD, containers run on the
> host daemon, so a bind mount to a path *in* the ccd container (e.g. `/workdir/...`)
> doesn't exist on the host. testcontainers' `MountableFile`/`withCopyFileToContainer`
> (copying) does work. In DinD this isn't an issue, since the daemon lives in the same container.

### Chromium / headless browser

The image contains a Chromium build (via Playwright, so it works on `arm64` too). Handy for
screenshotting a local dev server, rendering HTML to PDF or running e2e tests:

```bash
chromium --headless --screenshot=/workdir/shot.png --window-size=1280,900 http://localhost:3000
chromium --headless --print-to-pdf=/workdir/report.pdf file:///workdir/report.html
```

`chrome` and `google-chrome` point to the same wrapper, which adds `--no-sandbox` and
`--disable-dev-shm-usage` — in a container Chromium's own sandbox doesn't work and
`/dev/shm` is too small. Puppeteer and Playwright find the browser by themselves via
`PUPPETEER_EXECUTABLE_PATH` / `CHROME_PATH` (and `PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright`),
so an `npm install puppeteer` no longer downloads a second browser. For Playwright itself:

```js
await chromium.launch({ args: ['--no-sandbox', '--disable-dev-shm-usage'] });
```

Running without `--headless` is possible too, via the bundled `xvfb-run`. The `dbus` error
messages on stderr are harmless: there is no desktop session running in the container.

### Using an existing image (instead of building)

Want to run a ready-made image instead of building locally? Set `CLAUDE_IMAGE`.
`ccd` then skips the build step and uses that image directly:

```bash
CLAUDE_IMAGE=docker.io/your-user/claude-code:latest ccd
```

## Building the image yourself

You can also build manually (`ccd` does this automatically otherwise):

```bash
docker build -t claude-code:local .
```

A build in CI always produces the architecture of the runner, so on `arm64`/macOS you
build locally via `ccd` by default. Want to use a ready-made image anyway? Push it
yourself and point `CLAUDE_IMAGE` at it (see
[Using an existing image](#using-an-existing-image-instead-of-building)).

## Files

| File               | Purpose                                                     |
| ------------------ | ----------------------------------------------------------- |
| `Dockerfile`       | Builds the Claude Code image                                |
| `ccd`              | Wrapper that starts Docker and runs the container           |
| `install.sh`       | Installs `ccd` (via `curl \| sh` or from a clone) and puts it on your `PATH` |
| `entrypoint.sh`    | Container startup: uid/gid mapping, SSH, Docker mode, starts `claude` |

## Troubleshooting

- **`docker CLI not found`** — install Docker and make sure it is on your `PATH`.
- **macOS: no Docker runtime** — install colima (`brew install colima`) or Docker Desktop.
- **`Cannot connect to the Docker daemon` / `permission denied` on the socket** — run with
  `ccd --docker` or `ccd --dind` (see [Docker-in-Docker](#docker-in-docker-testcontainers-docker-compose)).
  On Linux `ccd` locates the socket via the docker context; if `docker context inspect`
  returns nothing usable, use `--dind` (own daemon in the container).
- **testcontainers: connection refused on the started container** — in DooD on Linux,
  `--network host` (automatic with `--docker`) provides localhost access; on macOS
  `TESTCONTAINERS_HOST_OVERRIDE` handles it. In DinD you connect via `localhost` anyway.
- **Linux: permission problems on mounted directories** — `ccd` passes your host uid/gid
  (`HOST_UID`/`HOST_GID`) and the container remaps itself to them. If you run the image
  *without* `ccd`, pass those env vars yourself. With a differing uid, `~` is `chown`ed
  once at startup — that can take a moment.
