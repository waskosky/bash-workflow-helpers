#!/usr/bin/env bash
set -euo pipefail

log() { printf '[setup] %s\n' "$*"; }
err() { printf '[setup] ERROR: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Required command '$cmd' is not installed."
}

repo_slug_from_url() {
  local url="$1"
  local normalized="$url"
  normalized="${normalized%.git}"
  if [[ "$normalized" =~ github\.com[:/]+([^/]+/[^/]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '\n'
  fi
}

install_gh() {
  if command -v gh >/dev/null 2>&1; then
    log "GitHub CLI (gh) is already installed."
    return 0
  fi

  log "GitHub CLI (gh) not found. Attempting automatic install."
  if command -v brew >/dev/null 2>&1; then
    brew install gh
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y gh
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y gh
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y gh
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -Sy --noconfirm github-cli
  else
    die "Could not auto-install gh. Install it from https://cli.github.com/ and rerun."
  fi

  command -v gh >/dev/null 2>&1 || die "gh install step finished but command is still unavailable."
  log "GitHub CLI installed."
}

ensure_gh_personal_login() {
  if gh auth status --hostname github.com >/dev/null 2>&1; then
    log "GitHub CLI is already authenticated for github.com."
  else
    cat <<'EOF'
[setup] GitHub login is required for personal account usage.
[setup] In the prompts, select:
[setup]   1) GitHub.com
[setup]   2) HTTPS
[setup]   3) Login with a web browser
EOF
    gh auth login --hostname github.com --git-protocol https --web
    gh auth status --hostname github.com >/dev/null 2>&1 || die "GitHub authentication did not complete."
    log "GitHub CLI authentication completed."
  fi

  gh auth setup-git >/dev/null 2>&1 || die "Failed to configure Git to use gh credentials."
  log "GitHub CLI git credential integration is configured."
}

ensure_nvm_and_node() {
  local nvm_dir="$HOME/.nvm"
  local nvm_script="$nvm_dir/nvm.sh"

  if [[ ! -s "$nvm_script" ]]; then
    log "Installing nvm v0.40.3."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
  else
    log "nvm is already installed."
  fi

  # shellcheck disable=SC1090
  . "$nvm_script"
  command -v nvm >/dev/null 2>&1 || die "nvm was not available after sourcing $nvm_script."

  log "Installing Node.js 24 via nvm."
  nvm install 24

  local node_version
  local npm_version
  node_version="$(node -v)"
  npm_version="$(npm -v)"
  log "node -v => $node_version (expected v24.13.1)"
  log "npm -v => $npm_version (expected 11.8.0)"
}

repo_has_tracked_changes() {
  local repo_dir="$1"
  [[ -n "$(git -C "$repo_dir" status --porcelain --untracked-files=no)" ]]
}

sync_repo() {
  local repo_url="$1"
  local repo_dir="$2"
  local expected_slug
  local origin_url
  local origin_slug

  expected_slug="$(repo_slug_from_url "$repo_url")"
  if [[ -d "$repo_dir/.git" ]]; then
    origin_url="$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)"
    [[ -n "$origin_url" ]] || die "Repo at $repo_dir has no origin remote."
    origin_slug="$(repo_slug_from_url "$origin_url")"
    if [[ -n "$expected_slug" && -n "$origin_slug" && "$expected_slug" != "$origin_slug" ]]; then
      die "$repo_dir points to $origin_url, but expected $repo_url."
    fi

    if repo_has_tracked_changes "$repo_dir"; then
      log "Skipping pull in $repo_dir because tracked local changes are present."
    else
      log "Pulling latest changes in $repo_dir"
      git -C "$repo_dir" pull --ff-only
    fi
  else
    mkdir -p "$(dirname "$repo_dir")"
    log "Cloning $repo_url into $repo_dir"
    git clone "$repo_url" "$repo_dir"
  fi
}

run_repo_script() {
  local repo_dir="$1"
  local script_name="$2"
  local script_path="$repo_dir/$script_name"

  [[ -f "$script_path" ]] || die "Expected script not found: $script_path"
  chmod +x "$script_path"
  log "Running $script_name in $repo_dir"
  (
    cd "$repo_dir"
    "./$script_name"
  )
}

main() {
  require_command git
  require_command curl

  local script_dir
  local repos_dir
  local helpers_repo_url="https://github.com/waskosky/bash-workflow-helpers"
  local helpers_repo_dir
  local current_origin

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repos_dir="${WORKFLOW_REPOS_DIR:-$(cd "$script_dir/.." && pwd)}"
  mkdir -p "$repos_dir"
  log "Using repo directory: $repos_dir"

  install_gh
  ensure_gh_personal_login
  ensure_nvm_and_node

  sync_repo "https://github.com/waskosky/codex-cli-farm" "$repos_dir/codex-cli-farm"
  run_repo_script "$repos_dir/codex-cli-farm" "setup.sh"

  helpers_repo_dir="$repos_dir/bash-workflow-helpers"
  if [[ -d "$script_dir/.git" ]]; then
    current_origin="$(git -C "$script_dir" remote get-url origin 2>/dev/null || true)"
    if [[ "$(repo_slug_from_url "$current_origin")" == "$(repo_slug_from_url "$helpers_repo_url")" ]]; then
      helpers_repo_dir="$script_dir"
    fi
  fi

  sync_repo "$helpers_repo_url" "$helpers_repo_dir"
  run_repo_script "$helpers_repo_dir" "setup_newrepo.sh"

  sync_repo "https://github.com/waskosky/bash-git-simplified" "$repos_dir/bash-git-simplified"
  run_repo_script "$repos_dir/bash-git-simplified" "install.sh"

  log "Recommended workflow setup complete."
}

main "$@"
