#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TEMPLATE_PATH="$REPO_ROOT/codexconfig.txt"
DEST_DIR="${HOME}/.codex"
DEST_PATH="${DEST_DIR}/config.toml"

if [[ ! -f "$TEMPLATE_PATH" ]]; then
  printf 'Template config not found at %s\n' "$TEMPLATE_PATH" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
cp "$TEMPLATE_PATH" "$DEST_PATH"
printf 'Installed Codex CLI config to %s\n' "$DEST_PATH"
