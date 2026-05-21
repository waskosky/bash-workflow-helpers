#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2317
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

make_fake_curl() {
  local bin_dir="$1"

  cat >"$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
cat <<'INSTALLER'
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${NVM_DIR:-}" ]]; then
  install_dir="$NVM_DIR"
elif [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
  install_dir="$XDG_CONFIG_HOME/nvm"
else
  install_dir="$HOME/.nvm"
fi

mkdir -p "$install_dir"
cat >"$install_dir/nvm.sh" <<'NVM'
nvm() {
  if [[ "$1" != "install" || "$2" != "24" ]]; then
    printf 'unexpected nvm args: %s\n' "$*" >&2
    return 1
  fi

  mkdir -p "$HOME/fake-node-bin"
  cat >"$HOME/fake-node-bin/node" <<'NODE'
#!/usr/bin/env bash
printf 'v24.0.0\n'
NODE
  cat >"$HOME/fake-node-bin/npm" <<'NPM'
#!/usr/bin/env bash
printf '11.0.0\n'
NPM
  chmod +x "$HOME/fake-node-bin/node" "$HOME/fake-node-bin/npm"
  export PATH="$HOME/fake-node-bin:$PATH"
}
NVM
INSTALLER
EOF
  chmod +x "$bin_dir/curl"
}

make_executable() {
  local path="$1"
  local content="$2"

  printf '%s\n' "$content" >"$path"
  chmod +x "$path"
}

load_setup_functions() {
  local setup_lib="$1"
  sed '/^main "\$@"$/d' "$ROOT_DIR/recommended_workflow_setup.sh" >"$setup_lib"
  # shellcheck disable=SC1090
  source "$setup_lib"
}

test_nvm_install_uses_xdg_config_home() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  mkdir -p "$tmp_dir/bin"
  make_fake_curl "$tmp_dir/bin"

  (
    export HOME="$tmp_dir/home"
    export XDG_CONFIG_HOME="$HOME/.config"
    unset NVM_DIR
    mkdir -p "$HOME"
    export PATH="$tmp_dir/bin:$PATH"

    load_setup_functions "$tmp_dir/recommended_workflow_setup.lib.sh"
    ensure_nvm_and_node

    [[ -s "$XDG_CONFIG_HOME/nvm/nvm.sh" ]] || fail "expected nvm under XDG_CONFIG_HOME"
    [[ ! -e "$HOME/.nvm/nvm.sh" ]] || fail "did not expect nvm under HOME/.nvm"
  )
}

test_install_gh_does_not_attempt_sudo_package_install() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  mkdir -p "$tmp_dir/bin"
  make_executable "$tmp_dir/bin/apt-get" '#!/bin/bash
exit 0'
  make_executable "$tmp_dir/bin/sudo" "#!/bin/bash
printf '%s\n' \"sudo \$*\" >> '$tmp_dir/sudo.log'
exit 89"

  (
    load_setup_functions "$tmp_dir/recommended_workflow_setup.lib.sh"
    export PATH="$tmp_dir/bin"

    set +e
    output="$(install_gh 2>&1)"
    status=$?
    set -e

    [[ ! -e "$tmp_dir/sudo.log" ]] || fail "install_gh must not invoke sudo package installs"
    [[ "$status" -ne 0 ]] || fail "expected install_gh to fail when gh is unavailable"
    [[ "$output" == *"GitHub CLI (gh) is required"* ]] \
      || fail "expected install_gh to explain the gh prerequisite"
  )
}

test_main_uses_no_sudo_bash_git_simplified_install_method() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  (
    export HOME="$tmp_dir/home"
    export WORKFLOW_REPOS_DIR="$tmp_dir/repos"
    mkdir -p "$HOME" "$WORKFLOW_REPOS_DIR"

    load_setup_functions "$tmp_dir/recommended_workflow_setup.lib.sh"

    require_command() { :; }
    install_gh() { :; }
    ensure_gh_personal_login() { :; }
    ensure_nvm_and_node() { :; }
    sync_repo() {
      local repo_url="$1"
      local repo_dir="$2"

      mkdir -p "$repo_dir"
      case "$repo_url" in
        *codex-cli-farm)
          make_executable "$repo_dir/setup.sh" '#!/usr/bin/env bash
exit 0'
          ;;
        *bash-workflow-helpers)
          make_executable "$repo_dir/setup_newrepo.sh" '#!/usr/bin/env bash
exit 0'
          ;;
        *bash-git-simplified)
          make_executable "$repo_dir/install.sh" "#!/usr/bin/env bash
set -euo pipefail
method=\"\${1:-}\"
printf '%s\n' \"\$method\" > '$tmp_dir/bash-git-simplified-method'
[[ \"\$method\" == path ]]"
          ;;
        *)
          fail "unexpected repo url: $repo_url"
          ;;
      esac
    }

    set +e
    main >"$tmp_dir/main.out" 2>&1
    status=$?
    set -e

    [[ "$status" -eq 0 ]] || fail "main should install bash-git-simplified with path method"
    [[ "$(cat "$tmp_dir/bash-git-simplified-method")" == "path" ]] \
      || fail "expected bash-git-simplified install method to be path"
  )
}

test_nvm_install_uses_xdg_config_home
test_install_gh_does_not_attempt_sudo_package_install
test_main_uses_no_sudo_bash_git_simplified_install_method
printf 'ok - recommended_workflow_setup regression checks\n'
