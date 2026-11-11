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
vibed               # the same container, but with Mistral Vibe instead of Claude Code
```

The installer puts `ccd` (and `vibed`, see [Mistral Vibe](#mistral-vibe-vibed)) in `~/.local/bin` and adds that to your `PATH` — open a new shell
afterwards. The first `ccd` builds the image (that takes a while); after that `ccd`
[updates itself](#auto-update) from GitHub on every start and rebuilds only when the build
files changed. See [Installation](#installation) for options and the development setup.

## What's in the image

Based on `ubuntu:26.04`, including:

- **Claude Code** (`@anthropic-ai/claude-code`) + `yarn` / `pnpm`
- **Mistral Vibe** (`mistral-vibe`), started with [`vibed`](#mistral-vibe-vibed)
- **Node.js LTS**, **Python 3** (`pip`, `venv`, `pipx`)
- **GraalVM 25** (full JDK + `native-image`) and **Maven** via SDKMAN
- Tooling: `git`, `git-lfs`, `ripgrep`, `fd`, `fzf`, `jq`, `gitleaks`, `build-essential`, …
- **Chromium** (headless) for screenshots, HTML/PDF rendering and e2e tests
- `xclip` / `wl-clipboard`, used by the [clipboard bridge](#pasting-images-clipboard-bridge) that makes image paste work

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
| `CCD_RAW_BASE` | raw GitHub URL of the branch's latest commit | fetch from a completely different host (mirror, GitLab raw, `file://`) |

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

At every start `ccd` asks GitHub which commit the branch points at (`git ls-remote`, with
the GitHub API as fallback). Same commit as last time (`$CCD_HOME/.ccd-sha`) → nothing is
downloaded. A new commit → `ccd` fetches its three files (`ccd`, `Dockerfile`,
`entrypoint.sh`) *at that commit* and replaces whatever differs:

- changed `Dockerfile`/`entrypoint.sh` → the image is **rebuilt automatically** on this run
  (the build hash below covers exactly those two files);
- a changed `ccd` → the script restarts itself, so the new version handles this run.

Pinning to the commit is what makes a push show up right away: the branch URLs on
`raw.githubusercontent.com` are cached for about five minutes, a commit URL never changes.
(The `curl … install.sh | sh` one-liner itself still comes through that cache; the files it
installs don't.)

The check fails soft: without a network, without `curl`/`wget` or with a GitHub hiccup you
simply keep running on what you already have — it never falls back to the cached branch
URL, which could hand out an older copy. It is skipped in a git checkout. With
`CCD_RAW_BASE` there is no commit to pin to; then the files are compared on every start.

| Turn off / adjust | Effect |
| ----------------- | ------ |
| `ccd --no-update` | skip the check for this run |
| `CCD_NO_UPDATE=1` | same, via the environment |
| `CCD_UPDATE_INTERVAL=86400` | check at most once per N seconds (default `0` = every start) |

### Updating Claude Code

The auto-update above keeps **`ccd` itself** current; the Claude Code version comes from the
image. To pull in a newer one:

```bash
ccd --update        # alias for --rebuild: clean rebuild, then start the session as usual
```

`claude --update` inside the container does **not** work — Claude Code is installed globally
as root in `/usr/lib/node_modules` while the session runs as `claude`, so it can't write in the
npm prefix (`Insufficient permissions to install update` when you run it by hand,
`Auto-update failed: no write permission to npm prefix` from the background updater). That is
also why the image sets `DISABLE_AUTOUPDATER=1`: in a `--rm` container an update would be
discarded at exit anyway. `ccd` therefore catches `--update` and rebuilds the image instead of
passing the flag through — use `ccd -- --update` if you really want the raw flag.

You rarely need it by hand: an image older than 10 days is rebuilt automatically (see
[Building the image](#building-the-image)).

With `CLAUDE_IMAGE` set there is no local image to rebuild, so `ccd --update` refuses and
tells you to refresh that image yourself (`docker pull …`).

## Usage

```bash
ccd                 # interactive Claude Code session in the current directory
ccd --version       # arguments are passed through to claude
ccd -p "fix the failing test"
ccd --no-clipboard  # skip the host clipboard bridge (see below)
ccd --no-m2         # skip mounting the host Maven repository (see below)
ccd --mount ~/data  # mount an extra host directory (see below)
```

`ccd` automatically:

1. Checks whether Docker is running and starts it otherwise.
2. Builds the image locally from the `Dockerfile` (only when needed — see below).
3. Mounts the current directory at `/workdir` in the container.
4. Keeps config/login in `~/.config/claude-docker` (mounted at `/home/claude/.claude`).
5. Mounts your host `~/.m2` at `/home/claude/.m2` (Maven cache + `settings.xml`).

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

### Mistral Vibe (`vibed`)

The image also contains [Mistral Vibe](https://github.com/mistralai/mistral-vibe). `vibed`
is the same script as `ccd` under a second name (the installer puts both on your `PATH`);
it starts `vibe` instead of `claude` and otherwise does exactly the same: same image, same
mounts, same flags (`--docker`, `--dind`, `--host-net`, `--mount`, `--rebuild`, …).
Everything that isn't a ccd flag is passed through to `vibe`:

```bash
vibed                          # interactive Vibe session in the current directory
vibed -p "fix the failing test"
vibed --docker                 # with access to the host Docker daemon
vibed --no-browser             # don't open sign-in pages in the host browser
```

- **Sign-in**: on the first run Vibe asks you to sign in or enter your Mistral API key, and
  saves the key in `~/.vibe/.env`. Browser sign-in opens the page in your **host** browser
  through the same bridge as [image paste](#pasting-images-clipboard-bridge) (`open` on
  macOS, `xdg-open` on Linux, PowerShell on Windows/WSL). Only `http(s)` URLs get through.
  Turn it off with `--no-browser` / `CCD_NO_BROWSER=1`.
  When `ccd` itself runs somewhere without a browser — for instance inside another
  container, or over SSH — there is nothing to open the page with. Vibe then shows the URL:
  pick **Copy URL to clipboard** (sent to your terminal as an OSC 52 escape, so it reaches the
  clipboard of the machine you're sitting at, through any number of container layers, if your
  terminal allows OSC 52 — Windows Terminal, iTerm2, kitty and WezTerm do), or use an API key
  instead.
  You can also set `MISTRAL_API_KEY` on the host; `vibed` only forwards it
  when it is set (it then takes precedence over the saved key).
- **Persistent config**: `~/.vibe` (`config.toml`, `.env`, trusted folders, session logs)
  lives in `<config dir>/vibe` on the host — `~/.config/claude-docker/vibe` by default, so
  a [profile](#multiple-accounts-profiles) has its own Vibe config too. It is mounted for
  `ccd` sessions as well, so Claude can read or adjust the Vibe config.
- **Updates**: Vibe's own update check is turned off in the image
  (`VIBE_ENABLE_UPDATE_CHECKS=false`): like Claude Code it is installed root-owned, so an
  in-container upgrade can't work. `vibed --rebuild` (or the periodic max-age rebuild)
  installs the latest version. Pin a version with
  `docker build --build-arg MISTRAL_VIBE_VERSION=3.1.0 ...`.
- **Already installed?** The auto-update brings the new image along, but only the
  installer creates the `vibed` command: run the [install command](#installation) once
  more (or `./install.sh` in your clone). Setting `CCD_AGENT=vibe ccd` works as well.

### Multiple accounts (profiles)

Point `CCD_CONFIG_DIR` at another host directory to get a separate profile, each with its
own login. Handy for keeping a personal and a work account apart:

```bash
alias ccd-work='CCD_CONFIG_DIR=~/.config/claude-docker-work ccd'
```

Plain `ccd` keeps using `~/.config/claude-docker`. Log in once per profile with `/login`;
`/status` shows which account a session is using.

A profile holds *everything* that normally lives in the config directory: settings,
`CLAUDE.md`, memory, session history and its own SSH directory (`<profile>/ssh`), so a
work profile can use a different SSH key than your personal one. A new profile starts
empty; copy over `settings.json` or `CLAUDE.md` if you want the same setup. Don't
symlink them to a path outside the profile: only the profile directory is mounted, so
such a link is dangling inside the container. The image build marker (`.image-hash`)
always stays in `~/.config/claude-docker`, so switching profiles doesn't trigger a rebuild.

### Maven repository (`~/.m2`)

`ccd` mounts your host `~/.m2` at `/home/claude/.m2`. Without it every `--rm` run starts
with an empty local repository — so Maven re-downloads all dependencies — and a corporate
`settings.xml` (mirror, repository credentials) would be missing as well. With the mount
the container uses the same artifact cache and the same settings as your host, and
anything it downloads stays behind on the host.

The directory is created if it doesn't exist yet (by `ccd`, so it belongs to you and
not to root). Point it elsewhere with `CCD_M2_DIR`, or turn it off:

```bash
ccd --no-m2
CCD_NO_M2=1 ccd                      # same effect
CCD_M2_DIR=~/work/.m2 ccd            # a different host directory
```

### Extra mounts (`--mount`)

Besides the repo (at `/workdir`) you can mount additional host directories — a second
repository, a shared data directory, a folder with reference docs:

```bash
ccd --mount ~/other-repo                   # at /mnt/other-repo
ccd --mount ~/datasets:/data               # choose the container path yourself
ccd --mount ~/secrets-config:/cfg:ro       # read-only in the container
ccd --mount ~/a --mount ~/b               # repeatable
CCD_MOUNTS="$HOME/a,$HOME/b:/data:ro" ccd  # same, via the environment (comma-separated)
```

The spec is `SRC[:DST][:ro]`:

- **`SRC`** — the host directory. A relative path resolves against where you ran `ccd`.
  It must already exist: `ccd` refuses otherwise, because letting Docker create the bind
  source would leave a root-owned directory on your host.
- **`DST`** (optional) — absolute path in the container; defaults to `/mnt/<basename of SRC>`.
- **`:ro`** (optional) — mounts the directory read-only, so the session can read it but
  never change it.

`CCD_MOUNTS` takes the same specs, comma-separated (so paths with a comma need the flag).
It is applied *before* the `--mount` flags; when both target the same container path, the
flag wins. Handy in an alias or profile:

```bash
alias ccd-proj='CCD_MOUNTS=$HOME/shared-libs:/libs:ro ccd'
```

On Git Bash, write `SRC` in the `/c/Users/...` form — in `C:/Users/...` the `:` after the
drive letter would be read as the `SRC`/`DST` separator.

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
or `docker compose`). Because Claude Code already runs *in* a container, `ccd` offers three
modes for that via a startup flag. The `docker` CLI, the daemon binaries and the compose plugin
are already in the image.

All modes are **opt-in per run**. Without a flag the container is unprivileged and has no
Docker access at all: no socket is mounted and no daemon runs, so the `docker` CLI in the
image has nothing to talk to.

| Flag | Mode | What it does |
| ---- | ---- | ------------ |
| `--docker` or `--docker=host` | **DooD** (Docker-outside-of-Docker) | Mounts the host Docker socket; testcontainers run as *siblings* on the host daemon. |
| `--docker=dind` or `--dind` | **DinD** (Docker-in-Docker) | Starts its own daemon *in* the container, fully separate from the host. |
| `--docker=vm` or `--dind=vm` | **VM** (prototype) | Starts its own daemon in a QEMU microVM *inside* the container — no `--privileged`. See [VM mode](#vm-mode---dindvm-prototype). |
| `--host-net` | network | Runs with `--network host`, so `localhost` is the host's localhost — see [Reaching host services](#reaching-host-services---host-net). |
| `--mount SRC[:DST][:ro]` | mounts | Mounts an extra host directory in the container (repeatable) — see [Extra mounts](#extra-mounts---mount). |
| `--prune` | **DinD**/**VM** + cleanup | Cleans up the DinD image store and exits (implies `--dind`; combine with `--dind=vm` for the VM's store). |
| `--rebuild` | build | Forces a clean rebuild (`--no-cache`) of the local image and cleans up old images/build cache (volumes are kept). |
| `--update` | build | Alias for `--rebuild`: the way to get a newer Claude Code. Errors out when `CLAUDE_IMAGE` pins an image (see [Updating Claude Code](#updating-claude-code)). |
| `--no-update` | update | Skips the auto-update check against GitHub for this run. |

The flag goes before the arguments for `claude`; everything else `ccd` passes through unchanged:

```bash
ccd --docker -p "run the integration tests"   # host daemon (DooD)
ccd --dind   -p "run the integration tests"   # own daemon (DinD)
ccd --dind=vm -p "run the integration tests"  # own daemon in a microVM
```

> **Note (security): DooD and DinD are not a boundary against your machine** — VM mode is
> the one that is (see below). DooD hands the
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
seccomp/apparmor) or the [sysbox](https://github.com/nestybox/sysbox) runtime on the host —
or a VM, which is what `--dind=vm` does.

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
5. **Daemon over TCP** (`DOCKER_HOST=tcp://...`, e.g. a dind sidecar at `tcp://dind:2376`):
   there is no socket to mount. `ccd` passes `DOCKER_HOST`, `DOCKER_TLS_VERIFY`/`DOCKER_TLS`
   and the client certs from `$DOCKER_CERT_PATH` (default `~/.docker`) into the container —
   the certs as env vars, because a bind mount would be resolved on the daemon's filesystem.
   The entrypoint writes them to `~/.docker` in the container. The container runs with
   `--network host`, i.e. in the *daemon's* network namespace, so published ports are on
   `localhost` and the daemon's hostname resolves as it does on the daemon.

**DinD (`--dind`)** — fully isolated from the host Docker:

1. Runs the container with `--privileged` and starts its own `dockerd` in the `entrypoint`.
2. testcontainers connect via `localhost` inside the container — no extra network config needed.
3. Pulled images are kept in a named volume `claude-dind-data` (mounted at
   `/var/lib/docker`), so a next run doesn't have to download everything again.

#### VM mode (`--dind=vm`, prototype)

`dockerd` runs in a small Alpine VM that QEMU boots *inside* the ccd container. The container
stays unprivileged; the only extra it gets is `--device /dev/kvm` when the host has it. A
`--privileged` container started by the tests is root in the *VM*, not on your machine: the
guest kernel is the boundary (comparable to Kata Containers, but nothing has to be installed
on the host).

```
host
 └─ ccd container (unprivileged, + /dev/kvm)
     ├─ claude                      DOCKER_HOST=tcp://127.0.0.1:2375
     └─ qemu microVM  (own kernel)
         └─ dockerd  ← testcontainers / compose run here
```

| | |
| --- | --- |
| Speed | with KVM (Linux) the VM boots in seconds and runs at near-native speed. Without `/dev/kvm` (macOS, Windows, or a host VM without nested virtualisation) QEMU falls back to emulation: it works, but it is slow. |
| Images | the VM's Docker data disk is a sparse file in the `claude-vm-data` volume; images survive the session. The VM's root disk is reset every session. |
| Ports | the VM's dynamic port range (`30000-30199`, override with `CCD_VM_PORTS`) is forwarded to `127.0.0.1` in the container, so testcontainers works via `localhost` without configuration (the entrypoint sets `TESTCONTAINERS_CONNECTION_MODE=docker_host` and `TESTCONTAINERS_HOST_OVERRIDE=localhost`, unless you set them yourself — testcontainers-python would otherwise guess "DinD" and dial the gateway IP). Fixed ports (`-p 8080:80`, compose) need `CCD_VM_FORWARD=8080,5432`. |
| Bind mounts | `/workdir` is shared into the VM (9p) at the same path, so `-v /workdir/...:/x` works. Other paths (`~/.m2`, `--mount` directories) are not visible in the VM — copy files in instead. |
| Shutdown | when Claude exits, the VM is powered off cleanly via the QEMU guest agent. A hard stop (`docker kill` of the ccd container) can corrupt the image store; `ccd` then reports the daemon crash and you start over with `docker volume rm claude-vm-data`. |

Tuning (environment variables, passed on by `ccd`): `CCD_VM_CPUS` (default: all),
`CCD_VM_MEMORY` (default `2G`), `CCD_VM_DISK` (data disk size on first creation, default
`64G`, sparse), `CCD_VM_PORTS`, `CCD_VM_FORWARD`, `CCD_VM_TIMEOUT` (boot timeout in seconds).

Caveats of the prototype: a forwarded port accepts the connection even when nothing listens
in the VM yet (QEMU user networking answers on the VM's behalf and then closes it), so a
"is the port open" check passes early — testcontainers' wait strategies also look inside the
container, so they are not fooled. The Docker API inside the VM is plain TCP; it is only
reachable from the ccd container and from inside the VM itself. That is also why `--dind=vm`
refuses `--host-net`: there, the container's localhost is the host's.

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

### Reaching host services (`--host-net`)

By default the container has its own network: `localhost` in there is the container
itself, so a database or API on your host's `localhost` is out of reach.

```bash
ccd --host-net
```

runs the container with `--network host`, so `localhost:5432` reaches the host's port 5432.
`--docker` on Linux and with a TCP daemon already does this; `--host-net` is for when you
want it without Docker access.

> **Note (security):** this is not root on the host, but it does weaken the sandbox.
> The container can reach *everything* that listens on the host's loopback — often
> without authentication, precisely because it's "only localhost" (dev databases, Redis,
> Jupyter, Chrome/IDE debug ports, `kubectl proxy`, a Docker API on tcp/2375). Abstract
> unix sockets live in the network namespace too, so e.g. the X11 socket becomes reachable.
> And any port Claude opens is bound to the host's real interfaces, so a dev server on
> `0.0.0.0` is visible on your LAN.

A narrower alternative, without the flag: `host.docker.internal` points to the host — on
Docker Desktop out of the box, on Linux because `ccd` adds
`--add-host=host.docker.internal:host-gateway` whenever host networking is off. On Linux
that address is the Docker bridge gateway (usually `172.17.0.1`), so the host service must
listen there or on `0.0.0.0`; one bound to `127.0.0.1` only is not reachable this way. In
exchange you choose per service what the container can see.

"The host" is the Docker daemon's network namespace. With a dind sidecar
(`DOCKER_HOST=tcp://dind:2376`) that's the dind container, not the machine you run `ccd`
on; reach services there via their compose service name instead. On macOS, Docker Desktop
only supports host networking with the feature enabled in its settings, and even then
"host" is the VM.

### Pasting images (clipboard bridge)

Ctrl+V with an image on the clipboard works in a `ccd` session, on every supported host.

That needs a bridge, because the image never travels through the terminal: Claude Code
reads the **system clipboard** itself, and inside the container it sees Linux and so shells
out to `xclip`/`wl-paste`. A container has no clipboard of its own and no route to the
host's, so without help the paste silently does nothing.

`ccd` therefore starts a small poller on the host and bind-mounts a directory at
`/run/ccd-clipboard`. In the container, an `xclip` shim writes its request into that
directory; the poller answers it with whatever the host platform actually uses:

| Host | Reads the clipboard with |
| --- | --- |
| macOS | `osascript` (`the clipboard as «class PNGf»`) |
| Linux, X11 | `xclip` — install it on the **host** (`apt install xclip`) |
| Linux, Wayland | `wl-paste` — install `wl-clipboard` on the **host** |
| Windows (Git Bash) | `powershell.exe` + `System.Windows.Forms.Clipboard` |
| WSL2 | `powershell.exe` as well — what you copy in a Windows app is on the *Windows* clipboard, which WSLg does not hand to `xclip` |

It works the other way round too: copying a screenshot out of Claude Code puts the image on
your host clipboard.

If no clipboard tool is found, `ccd` says so once at startup and simply carries on — a
headless or CI run has no clipboard to bridge. Turn the bridge off entirely with
`ccd --no-clipboard` or `CCD_NO_CLIPBOARD=1`.

Dragging an image **file** into the terminal is a separate matter: that pastes a *host*
path, which only resolves in the container when the file sits inside the mounted repo.
Copy the image to the clipboard instead, or drop it in your project first.

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

### Timezone

The image defaults to UTC; `ccd` passes your host's zone into the container as `TZ`, so
`date`, `git log`, logs and the JVM show local time. The zone comes from, in order: `TZ` on
the host, the `/etc/localtime` symlink (Linux, WSL, macOS), `/etc/timezone`, and on Git Bash
`pwsh` (PowerShell 7, which can map the Windows zone to an IANA name). Without any of those,
the current UTC offset is used as a fixed zone — correct now, but it won't follow a DST switch.
Force a zone with e.g. `TZ=Europe/Brussels ccd`.

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
| `install.sh`       | Installs `ccd` and `vibed` (via `curl \| sh` or from a clone) and puts them on your `PATH` |
| `entrypoint.sh`    | Container startup: uid/gid mapping, SSH, Docker mode, starts `claude` (or `vibe` for `vibed`) |

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
- **Ctrl+V does nothing with an image on the clipboard** — the host needs a clipboard tool
  the bridge can call. On Linux that is `xclip` (X11) or `wl-clipboard` (Wayland), *on the
  host*, not in the container; `ccd` prints a note at startup when it finds neither. Over a
  plain SSH session there is no clipboard to read at all. See
  [Pasting images](#pasting-images-clipboard-bridge).
- **Linux: permission problems on mounted directories** — `ccd` passes your host uid/gid
  (`HOST_UID`/`HOST_GID`) and the container remaps itself to them. If you run the image
  *without* `ccd`, pass those env vars yourself. With a differing uid, `~` is `chown`ed
  once at startup — that can take a moment.
