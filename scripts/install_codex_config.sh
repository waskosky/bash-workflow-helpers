#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TEMPLATE_PATH="$REPO_ROOT/codexconfig.txt"
DEST_DIR="${HOME}/.codex"
DEST_PATH="${DEST_DIR}/config.toml"
FORCE=false

usage() {
  printf 'Usage: %s [--force]\n' "$(basename "$0")"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ ! -f "$TEMPLATE_PATH" ]]; then
  printf 'Template config not found at %s\n' "$TEMPLATE_PATH" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
if [[ -e "$DEST_PATH" ]] && ! cmp -s "$TEMPLATE_PATH" "$DEST_PATH"; then
  if [[ "$FORCE" != true ]]; then
    backup_path="${DEST_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -p "$DEST_PATH" "$backup_path"
    printf 'Backed up existing Codex CLI config to %s\n' "$backup_path"
  fi
fi
cp "$TEMPLATE_PATH" "$DEST_PATH"
printf 'Installed Codex CLI config to %s\n' "$DEST_PATH"
