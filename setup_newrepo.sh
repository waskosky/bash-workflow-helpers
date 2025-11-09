#!/usr/bin/env bash
set -euo pipefail

log(){ printf '[setup] %s\n' "$*"; }
err(){ printf '[setup] ERROR: %s\n' "$*" >&2; }

MIN_GH_VERSION="2.4.0"

version_lt() {
  local IFS=. a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<<"$1"
  IFS=. read -r b1 b2 b3 <<<"$2"
  a1=${a1:-0}; a2=${a2:-0}; a3=${a3:-0}
  b1=${b1:-0}; b2=${b2:-0}; b3=${b3:-0}
  if (( a1 < b1 )); then return 0; fi
  if (( a1 > b1 )); then return 1; fi
  if (( a2 < b2 )); then return 0; fi
  if (( a2 > b2 )); then return 1; fi
  if (( a3 < b3 )); then return 0; fi
  if (( a3 > b3 )); then return 1; fi
  return 1
}

ensure_min_gh_version() {
  local required="$1" raw detected
  raw="$(gh --version 2>/dev/null | head -n1 || true)"
  detected="$(printf '%s\n' "$raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  if [[ -z "$detected" ]]; then
    err "Unable to parse GitHub CLI version from: ${raw:-<empty>}"
    exit 1
  fi
  if version_lt "$detected" "$required"; then
    err "GitHub CLI $required or newer is required; detected $detected. Update via https://cli.github.com/."
    exit 1
  fi
  log "GitHub CLI version $detected satisfies minimum requirement ($required+)."
}

safe_source() {
  local file="$1" had_e=0 had_u=0 status
  [[ -f "$file" ]] || return 1
  [[ $- == *e* ]] && had_e=1
  [[ $- == *u* ]] && had_u=1
  log "Sourcing $file"
  set +e
  set +u
  # shellcheck disable=SC1090
  source "$file"
  status=$?
  (( had_u )) && set -u
  (( had_e )) && set -e
  if (( status != 0 )); then
    err "Sourcing $file exited with status $status; continuing."
  fi
  return 0
}
PATH_MARK_BEGIN="# >>> newrepo path helper >>>"
PATH_MARK_END="# <<< newrepo path helper <<<"

ensure_path_block() {
  local file="$1"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  if grep -Fq "$PATH_MARK_BEGIN" "$file"; then
    log "PATH helper already present in $file"
    return 0
  fi
  {
    printf '\n'
    printf '%s\n' "$PATH_MARK_BEGIN"
    cat <<'BLOCK'
if [[ -d "$HOME/.local/bin" ]] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  export PATH="$HOME/.local/bin:$PATH"
fi
BLOCK
    printf '%s\n' "$PATH_MARK_END"
  } >> "$file"
  log "Added PATH helper to $file"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/scripts/mkprivrepo_fast.sh"
INSTALL_DIR="${HOME}/.local/bin"
SYMLINK_PATH="$INSTALL_DIR/newrepo"

if [[ ! -f "$TARGET_SCRIPT" ]]; then
  err "Expected mkprivrepo_fast.sh at $TARGET_SCRIPT but it was not found."
  exit 1
fi

if [[ ! -x "$TARGET_SCRIPT" ]]; then
  chmod +x "$TARGET_SCRIPT"
  log "Marked $TARGET_SCRIPT as executable."
fi

if ! command -v gh >/dev/null 2>&1; then
  err "GitHub CLI (gh) is not installed. Install it from https://cli.github.com/ and rerun."
  exit 1
fi
ensure_min_gh_version "$MIN_GH_VERSION"

log "Checking GitHub CLI authentication status."
if ! gh auth status >/dev/null 2>&1; then
  log "GitHub CLI not authenticated. Launching web-based login."
  if ! gh auth login --hostname github.com --git-protocol ssh --web; then
    err "gh auth login failed or was cancelled."
    exit 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    err "GitHub CLI remains unauthenticated after login attempt."
    exit 1
  fi
else
  log "GitHub CLI already authenticated."
fi

log "Ensuring GitHub CLI is configured for Git operations."
if ! gh auth setup-git >/dev/null 2>&1; then
  err "gh auth setup-git failed; check your Git configuration."
  exit 1
fi

log "Ensuring $INSTALL_DIR exists."
mkdir -p "$INSTALL_DIR"

log "Ensuring PATH exports include $INSTALL_DIR."
ensure_path_block "$HOME/.bashrc"
if [[ -f "$HOME/.zshrc" ]]; then
  ensure_path_block "$HOME/.zshrc"
else
  log "Skipping ~/.zshrc PATH helper (file not found)."
fi

if [[ -e "$SYMLINK_PATH" && ! -L "$SYMLINK_PATH" ]]; then
  err "Cannot create symlink: $SYMLINK_PATH exists and is not a symlink."
  exit 1
fi

log "Creating symlink $SYMLINK_PATH -> $TARGET_SCRIPT"
ln -sf "$TARGET_SCRIPT" "$SYMLINK_PATH"
hash -r 2>/dev/null || true

did_source=0
if safe_source "$HOME/.bashrc"; then
  did_source=1
elif [[ -f "$HOME/.zshrc" ]] && safe_source "$HOME/.zshrc"; then
  did_source=1
fi

if (( ! did_source )); then
  log "No shell rc files sourced (none detected). Run 'source ~/.bashrc' in this shell if needed."
fi

log "Setup complete. Use newrepo \"Title of repo\" owner/repo to create a private repo quickly."
