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

ensure_writable_dir() {
  local dir="$1"
  mkdir -p "$dir" || die "Could not create repo directory: $dir"
  [[ -w "$dir" ]] || die "Repo directory is not writable: $dir. Set WORKFLOW_REPOS_DIR to a writable path and rerun."
}

resolve_repos_dir() {
  local script_dir="$1"
  local helpers_repo_url="$2"
  local current_dir
  local current_origin

  if [[ -n "${WORKFLOW_REPOS_DIR:-}" ]]; then
    printf '%s\n' "$WORKFLOW_REPOS_DIR"
    return 0
  fi

  if [[ -d "$script_dir/.git" ]]; then
    current_origin="$(git -C "$script_dir" remote get-url origin 2>/dev/null || true)"
    if [[ "$(repo_slug_from_url "$current_origin")" == "$(repo_slug_from_url "$helpers_repo_url")" ]]; then
      (cd "$script_dir/.." && pwd)
      return 0
    fi
  fi

  current_dir="$(pwd)"
  if [[ "$current_dir" == "/" || ! -w "$current_dir" ]]; then
    printf '%s\n' "$HOME"
  else
    printf '%s\n' "$current_dir"
  fi
}

install_gh() {
  local install_dir="${GH_INSTALL_DIR:-$HOME/.local/bin}"

  prepend_to_path "$install_dir"
  if command -v gh >/dev/null 2>&1; then
    log "GitHub CLI (gh) is already installed."
    return 0
  fi

  log "GitHub CLI (gh) not found. Attempting automatic installation."
  if command -v brew >/dev/null 2>&1; then
    log "Installing gh with Homebrew."
    if brew install gh; then
      hash -r 2>/dev/null || true
    else
      log "Homebrew could not install gh; falling back to the official release binary."
    fi
  fi

  if ! command -v gh >/dev/null 2>&1; then
    install_gh_from_release "$install_dir"
    prepend_to_path "$install_dir"
    hash -r 2>/dev/null || true
  fi

  command -v gh >/dev/null 2>&1 || die "gh install step finished but command is still unavailable."
  log "GitHub CLI installed."
}

prepend_to_path() {
  local dir="$1"
  if [[ ":$PATH:" != *":$dir:"* ]]; then
    export PATH="$dir:$PATH"
  fi
}

gh_release_os() {
  case "$1" in
    Linux*) printf 'linux\n' ;;
    Darwin*) printf 'macOS\n' ;;
    MINGW*|MSYS*|CYGWIN*) printf 'windows\n' ;;
    *) return 1 ;;
  esac
}

gh_release_arch() {
  case "$1" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    i386|i486|i586|i686) printf '386\n' ;;
    armv6l|armv7l) printf 'armv6\n' ;;
    *) return 1 ;;
  esac
}

verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual

  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$file")"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$file")"
  else
    die "Cannot verify the gh download: sha256sum or shasum is required."
  fi
  actual="${actual%%[[:space:]]*}"

  [[ "$actual" == "$expected" ]] || die "Checksum verification failed for $(basename "$file")."
}

install_gh_from_release() {
  local install_dir="$1"
  local os
  local arch
  local version="${GH_CLI_VERSION:-}"
  local latest_url
  local archive_ext
  local asset_base
  local asset_name
  local download_base
  local tmp_dir

  require_command curl
  require_command uname

  os="$(gh_release_os "$(uname -s)")" \
    || die "Automatic gh installation is not supported on $(uname -s)."
  arch="$(gh_release_arch "$(uname -m)")" \
    || die "Automatic gh installation is not supported on architecture $(uname -m)."

  case "$os:$arch" in
    macOS:amd64|macOS:arm64|linux:amd64|linux:arm64|linux:386|linux:armv6|windows:amd64|windows:arm64|windows:386) ;;
    *) die "No official gh release binary is available for $os/$arch." ;;
  esac

  if [[ -z "$version" ]]; then
    latest_url="$(curl -fLsS -o /dev/null -w '%{url_effective}' \
      https://github.com/cli/cli/releases/latest)"
    version="${latest_url##*/}"
  fi
  version="${version#v}"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] \
    || die "Could not determine the latest gh version from GitHub."

  if [[ "$os" == "linux" ]]; then
    archive_ext="tar.gz"
  else
    archive_ext="zip"
  fi
  asset_base="gh_${version}_${os}_${arch}"
  asset_name="${asset_base}.${archive_ext}"
  download_base="https://github.com/cli/cli/releases/download/v${version}"
  tmp_dir="$(mktemp -d)"

  (
    local checksum
    local expected_checksum=""
    local checksum_asset
    local source_binary
    local target_binary="gh"

    trap 'rm -rf "$tmp_dir"' EXIT
    log "Downloading gh $version for $os/$arch."
    curl -fLsS --retry 3 --retry-delay 1 \
      "$download_base/$asset_name" -o "$tmp_dir/$asset_name"
    curl -fLsS --retry 3 --retry-delay 1 \
      "$download_base/gh_${version}_checksums.txt" -o "$tmp_dir/checksums.txt"

    while read -r checksum checksum_asset; do
      if [[ "$checksum_asset" == "$asset_name" ]]; then
        expected_checksum="$checksum"
        break
      fi
    done <"$tmp_dir/checksums.txt"
    [[ "$expected_checksum" =~ ^[0-9a-fA-F]{64}$ ]] \
      || die "Could not find a checksum for $asset_name."
    verify_sha256 "$tmp_dir/$asset_name" "$expected_checksum"

    if [[ "$archive_ext" == "tar.gz" ]]; then
      require_command tar
      tar -xzf "$tmp_dir/$asset_name" -C "$tmp_dir"
      source_binary="$tmp_dir/$asset_base/bin/gh"
    else
      require_command unzip
      unzip -q "$tmp_dir/$asset_name" -d "$tmp_dir"
      if [[ "$os" == "windows" ]]; then
        source_binary="$tmp_dir/$asset_base/bin/gh.exe"
        target_binary="gh.exe"
      else
        source_binary="$tmp_dir/$asset_base/bin/gh"
      fi
    fi

    [[ -f "$source_binary" ]] || die "The downloaded gh archive did not contain the expected binary."
    mkdir -p "$install_dir"
    cp "$source_binary" "$install_dir/$target_binary"
    chmod +x "$install_dir/$target_binary"
  )
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

resolve_nvm_dir() {
  if [[ -n "${NVM_DIR:-}" ]]; then
    printf '%s\n' "$NVM_DIR"
  elif [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    printf '%s\n' "$XDG_CONFIG_HOME/nvm"
  else
    printf '%s\n' "$HOME/.nvm"
  fi
}

ensure_nvm_and_node() {
  local nvm_dir
  nvm_dir="$(resolve_nvm_dir)"
  local nvm_script="$nvm_dir/nvm.sh"
  export NVM_DIR="$nvm_dir"

  if [[ ! -s "$nvm_script" ]]; then
    log "Installing nvm v0.40.3 to $nvm_dir."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
  else
    log "nvm is already installed at $nvm_dir."
  fi

  [[ -s "$nvm_script" ]] || die "Expected nvm to be installed at $nvm_script, but it was not found."
  # shellcheck disable=SC1090
  . "$nvm_script"
  command -v nvm >/dev/null 2>&1 || die "nvm was not available after sourcing $nvm_script."

  log "Installing Node.js 24 via nvm."
  nvm install 24

  local node_version
  local npm_version
  node_version="$(node -v)"
  npm_version="$(npm -v)"
  [[ "$node_version" == v24.* ]] || die "Expected Node.js 24.x after nvm install, got $node_version."
  [[ -n "$npm_version" ]] || die "npm was not available after installing Node.js 24."
  log "node -v => $node_version"
  log "npm -v => $npm_version"
}

source_bashrc() {
  local bashrc="$HOME/.bashrc"
  local had_errexit=0
  local had_nounset=0
  local status

  if [[ ! -f "$bashrc" ]]; then
    log "$bashrc does not exist; continuing with the current environment."
    return 0
  fi

  [[ $- == *e* ]] && had_errexit=1
  [[ $- == *u* ]] && had_nounset=1
  log "Sourcing $bashrc before installing coding agents."
  set +e
  set +u
  # shellcheck disable=SC1090
  source "$bashrc"
  status=$?
  (( had_nounset )) && set -u
  (( had_errexit )) && set -e

  if (( status != 0 )); then
    err "Sourcing $bashrc exited with status $status; continuing with the current environment."
  fi
}

install_coding_agents() {
  source_bashrc
  require_command npm

  log "Installing Claude Code and Codex globally with npm."
  npm install --global @anthropic-ai/claude-code @openai/codex
  log "Claude Code and Codex are installed."
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
  shift 2
  local script_path="$repo_dir/$script_name"

  [[ -f "$script_path" ]] || die "Expected script not found: $script_path"
  chmod +x "$script_path"
  log "Running $script_name in $repo_dir"
  (
    cd "$repo_dir"
    "./$script_name" "$@"
  )
}

main() {
  install_gh
  require_command git
  require_command curl

  local script_dir
  local repos_dir
  local helpers_repo_url="https://github.com/waskosky/bash-workflow-helpers"
  local helpers_repo_dir
  local current_origin

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repos_dir="$(resolve_repos_dir "$script_dir" "$helpers_repo_url")"
  ensure_writable_dir "$repos_dir"
  log "Using repo directory: $repos_dir"

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
  run_repo_script "$repos_dir/bash-git-simplified" "install.sh" "path"

  install_coding_agents
  log "Recommended workflow setup complete."
}

main "$@"
