#!/usr/bin/env bash
set -euo pipefail

log(){ printf '[setup] %s\n' "$*"; }
err(){ printf '[setup] ERROR: %s\n' "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/scripts/mkprivrepo_fast.sh"
SYMLINK_PATH="$SCRIPT_DIR/newrepo"

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

if [[ -e "$SYMLINK_PATH" && ! -L "$SYMLINK_PATH" ]]; then
  err "Cannot create symlink: $SYMLINK_PATH exists and is not a symlink."
  exit 1
fi

log "Creating symlink $SYMLINK_PATH -> $TARGET_SCRIPT"
ln -sf "$TARGET_SCRIPT" "$SYMLINK_PATH"

log "Setup complete. Use ./newrepo \"Title of repo\" owner/repo to create a private repo quickly."
