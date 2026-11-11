#!/bin/sh
# Installer for 'ccd' (Claude Code in Docker).
#
#   Remote (no clone needed):
#     curl -fsSL https://raw.githubusercontent.com/ridiekel/symmetrical-enigma/main/install.sh | sh
#
#   From a clone (dev mode): ./install.sh
#
# POSIX sh on purpose, so '| sh' works as well as '| bash'.
set -eu

CMD_NAME="ccd"

# Which repo/branch we install from (override for a fork or a test branch).
REPO="${CCD_REPO:-ridiekel/symmetrical-enigma}"
BRANCH="${CCD_BRANCH:-main}"
# Escape hatch: install from another host (mirror, GitLab raw, a local dir via file://).
# Without it we download from the commit the branch points at, not from the branch itself:
# raw.githubusercontent.com caches branch URLs for ~5 minutes (see resolve_sha below).
RAW_BASE="${CCD_RAW_BASE:-}"

# Files ccd needs at runtime: itself plus the build files for the local image.
FILES="ccd Dockerfile entrypoint.sh"

# Where the files land in remote mode, and where the command goes on PATH.
CCD_HOME="${CCD_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ccd}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

# ---------------------------------------------------------------------------
# Local (clone) or remote (curl | sh)?
# ---------------------------------------------------------------------------
# When piped, $0 is 'sh'/'bash' and there is no directory with sources next to us.
resolve_dir() {
  _self="$0"
  # Follow symlinks, so './install.sh' also works via a link.
  if command -v readlink >/dev/null 2>&1; then
    while [ -L "$_self" ]; do
      _dir="$(cd -P "$(dirname "$_self")" 2>/dev/null && pwd)" || break
      _self="$(readlink "$_self")"
      case "$_self" in /*) ;; *) _self="$_dir/$_self" ;; esac
    done
  fi
  case "$_self" in
    */*) _dir="$(dirname "$_self")" ;;
    *)   if [ -f "./$_self" ]; then _dir="."; else return 1; fi ;;
  esac
  (cd -P "$_dir" 2>/dev/null && pwd) || return 1
}

SRC_DIR="$(resolve_dir || true)"
if [ -n "${SRC_DIR:-}" ] && [ -f "$SRC_DIR/ccd" ] && [ -f "$SRC_DIR/Dockerfile" ]; then
  MODE="local"
else
  MODE="remote"
  SRC_DIR="$CCD_HOME"
fi

# ---------------------------------------------------------------------------
# Remote mode: fetch the files into $CCD_HOME
# ---------------------------------------------------------------------------
fetch() {
  # $1 = url, $2 = target file
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 5 --max-time 60 "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --timeout=60 -O "$2" "$1"
  else
    echo "Neither curl nor wget found — cannot download." >&2
    exit 1
  fi
}

# The commit sha $BRANCH points at — same lookup as ccd's auto-update: 'git ls-remote'
# (uncached), with GitHub's API as the fallback.
resolve_sha() {
  _sha=""
  if command -v git >/dev/null 2>&1; then
    _sha="$(GIT_TERMINAL_PROMPT=0 git ls-remote "https://github.com/$REPO.git" "refs/heads/$BRANCH" 2>/dev/null \
            | awk 'NR == 1 { print $1 }')"
  fi
  if [ -z "$_sha" ] && command -v curl >/dev/null 2>&1; then
    _sha="$(curl -fsSL --connect-timeout 5 --max-time 15 -H 'Accept: application/vnd.github.sha' \
            "https://api.github.com/repos/$REPO/commits/$BRANCH" 2>/dev/null || true)"
  fi
  case "$_sha" in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  [ "${#_sha}" -eq 40 ] || return 1
  echo "$_sha"
}

if [ "$MODE" = "remote" ]; then
  command -v bash >/dev/null 2>&1 || echo "Warning: 'bash' not found — 'ccd' itself needs bash." >&2

  SHA=""
  if [ -z "$RAW_BASE" ]; then
    if SHA="$(resolve_sha)"; then
      RAW_BASE="https://raw.githubusercontent.com/$REPO/$SHA"
    else
      # Still installable, just possibly up to ~5 minutes behind; the first ccd start
      # then catches up via its own (sha-based) update check.
      echo "Warning: could not look up the latest commit — installing from the branch." >&2
      RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"
    fi
  fi

  echo "Installing $CMD_NAME from $REPO@$BRANCH${SHA:+ ($(echo "$SHA" | cut -c1-7))} into $CCD_HOME ..."
  mkdir -p "$CCD_HOME"

  # Download everything to a temp dir first, so a failed download never leaves
  # a half-updated installation behind.
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT INT TERM
  for f in $FILES; do
    echo "  - $f"
    fetch "$RAW_BASE/$f" "$TMP/$f"
    [ -s "$TMP/$f" ] || { echo "Empty download: $f" >&2; exit 1; }
  done
  for f in $FILES; do
    mv -f "$TMP/$f" "$CCD_HOME/$f"
  done

  # ccd reads this back for its own auto-update, so a fork keeps updating from the fork.
  printf 'repo=%s\nbranch=%s\n' "$REPO" "$BRANCH" > "$CCD_HOME/.ccd-source"
  [ -n "${CCD_RAW_BASE:-}" ] && printf 'raw_base=%s\n' "$CCD_RAW_BASE" >> "$CCD_HOME/.ccd-source"
  # The commit we installed, so ccd's first update check doesn't download it all again.
  # Without a sha (branch fallback) we remove a stale one, so that check does compare.
  if [ -n "$SHA" ]; then echo "$SHA" > "$CCD_HOME/.ccd-sha"; else rm -f "$CCD_HOME/.ccd-sha"; fi
fi

SRC_SCRIPT="$SRC_DIR/$CMD_NAME"
if [ ! -f "$SRC_SCRIPT" ]; then
  echo "Cannot find '$CMD_NAME' in $SRC_DIR." >&2
  exit 1
fi
chmod +x "$SRC_SCRIPT"

# ---------------------------------------------------------------------------
# Put the commands on PATH (symlinks, so updates are picked up automatically)
# ---------------------------------------------------------------------------
# Two names for the same script: 'ccd' starts Claude Code, 'vibed' starts Mistral Vibe in
# the same image. ccd tells them apart by the name it was invoked by.
mkdir -p "$BIN_DIR"

# Already installed? Repointing a symlink is harmless — the old target (your clone, say)
# keeps all its files. A *real* file there is someone's own copy/script, so we move that
# aside instead of silently throwing it away.
SHIM_MARKER="# ccd-shim (generated by install.sh)"

# $1 = command name, $2 = agent (claude|vibe)
install_link() {
  LINK="$BIN_DIR/$1"

  if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
    if grep -qF "$SHIM_MARKER" "$LINK" 2>/dev/null; then
      rm -f "$LINK"          # our own wrapper from an earlier install — no backup needed
    else
      BACKUP="$LINK.backup-$(date +%Y%m%d%H%M%S)"
      mv "$LINK" "$BACKUP"
      echo "Existing file moved aside: $BACKUP"
    fi
  elif [ -L "$LINK" ]; then
    OLD_TARGET="$(readlink "$LINK" 2>/dev/null || true)"
    if [ -n "$OLD_TARGET" ] && [ "$OLD_TARGET" != "$SRC_SCRIPT" ]; then
      echo "Replacing the existing link (pointed to $OLD_TARGET — that copy stays untouched)"
    fi
  fi

  # Git Bash/MSYS silently *copies* instead of linking unless winsymlinks is enabled, and a
  # copy would leave 'ccd' without its Dockerfile/entrypoint.sh. Fall back to a one-line
  # wrapper: because it exec's the real path, $0 inside ccd still points at $SRC_DIR, so the
  # build files are found and the auto-update keeps updating the installation, not the copy.
  # That same exec loses the name we were called by, so the wrapper passes the agent along.
  ln -sf "$SRC_SCRIPT" "$LINK" 2>/dev/null || true
  if [ -L "$LINK" ]; then
    echo "Symlink: $LINK -> $SRC_SCRIPT"
  else
    rm -f "$LINK"
    cat > "$LINK" <<EOF
#!/usr/bin/env bash
$SHIM_MARKER
CCD_AGENT=$2 exec "$SRC_SCRIPT" "\$@"
EOF
    chmod +x "$LINK"
    echo "Wrapper: $LINK -> $SRC_SCRIPT (this platform has no symlinks)"
  fi
}

install_link ccd claude
install_link vibed vibe

if [ "$MODE" = "local" ]; then
  echo "(local mode: linked to your working copy — auto-update stays off for a git checkout)"
fi

# Is BIN_DIR already in PATH? Then we're done.
case ":${PATH}:" in
  *":${BIN_DIR}:"*)
    echo "$BIN_DIR is already in PATH. Done — use '$CMD_NAME' (Claude Code) or 'vibed' (Mistral Vibe)."
    exit 0
    ;;
esac

MARKER="# added by ccd install.sh"

append_once() {
  # $1 = file, $2 = line to append
  file="$1"; line="$2"
  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || touch "$file"
  if grep -qF "$MARKER" "$file" 2>/dev/null; then
    echo "PATH line was already in $file"
  else
    printf '\n%s\n%s\n' "$MARKER" "$line" >> "$file"
    echo "PATH added to $file"
  fi
}

OS="$(uname -s)"
IS_WINDOWS=0
case "$OS" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
esac
POSIX_LINE="export PATH=\"$BIN_DIR:\$PATH\""

case "$(basename "${SHELL:-sh}")" in
  zsh)
    RC="$HOME/.zshrc"
    append_once "$RC" "$POSIX_LINE"
    ;;
  bash)
    # macOS Terminal starts login shells (.bash_profile); Linux uses .bashrc
    if [ "$IS_WINDOWS" = "1" ]; then
      # Git Bash starts login shells and stops at the first of .bash_profile /
      # .bash_login / .profile, so a lone .bashrc may never be read.
      if   [ -f "$HOME/.bash_profile" ]; then RC="$HOME/.bash_profile"
      elif [ -f "$HOME/.bash_login" ];   then RC="$HOME/.bash_login"
      elif [ -f "$HOME/.bashrc" ];       then RC="$HOME/.bashrc"
      else                                    RC="$HOME/.bash_profile"
      fi
    elif [ "$OS" = "Darwin" ]; then
      RC="$HOME/.bash_profile"
    elif [ -f "$HOME/.bashrc" ]; then
      RC="$HOME/.bashrc"
    else
      RC="$HOME/.profile"
    fi
    append_once "$RC" "$POSIX_LINE"
    ;;
  fish)
    RC="$HOME/.config/fish/config.fish"
    append_once "$RC" "fish_add_path \"$BIN_DIR\""
    ;;
  *)
    RC="$HOME/.profile"
    append_once "$RC" "$POSIX_LINE"
    ;;
esac

echo
echo "Done. Open a new shell or run:  source \"$RC\""
echo "After that '$CMD_NAME' (Claude Code) and 'vibed' (Mistral Vibe) work everywhere."
