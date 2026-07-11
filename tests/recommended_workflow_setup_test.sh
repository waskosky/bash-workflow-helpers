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

test_gh_release_platform_mapping() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  load_setup_functions "$tmp_dir/recommended_workflow_setup.lib.sh"

  [[ "$(gh_release_os Linux)" == "linux" ]] || fail "expected Linux gh release mapping"
  [[ "$(gh_release_os Darwin)" == "macOS" ]] || fail "expected macOS gh release mapping"
  [[ "$(gh_release_os MINGW64_NT-10.0)" == "windows" ]] || fail "expected Windows gh release mapping"
  [[ "$(gh_release_arch x86_64)" == "amd64" ]] || fail "expected amd64 gh release mapping"
  [[ "$(gh_release_arch aarch64)" == "arm64" ]] || fail "expected arm64 gh release mapping"
}

test_install_gh_auto_installs_without_sudo() {
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
    export HOME="$tmp_dir/home"
    export PATH="$tmp_dir/bin"
    hash -r

    install_gh_from_release() {
      printf 'called\n' >"$tmp_dir/release-installer-called"
      gh() { :; }
    }

    install_gh >/dev/null

    [[ ! -e "$tmp_dir/sudo.log" ]] || fail "install_gh must not invoke sudo package installs"
    [[ -e "$tmp_dir/release-installer-called" ]] \
      || fail "expected install_gh to invoke the release installer"
  )
}

test_coding_agent_install_sources_bashrc_and_uses_npm_global() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  mkdir -p "$tmp_dir/bin" "$tmp_dir/home"
  printf 'export BASHRC_SOURCED_FOR_TEST=yes\n' >"$tmp_dir/home/.bashrc"
  make_executable "$tmp_dir/bin/npm" '#!/usr/bin/env bash
printf "%s|%s\n" "${BASHRC_SOURCED_FOR_TEST:-no}" "$*" >"$NPM_INSTALL_RECORD"'

  (
    export HOME="$tmp_dir/home"
    export NPM_INSTALL_RECORD="$tmp_dir/npm-install-record"
    export PATH="$tmp_dir/bin:$PATH"
    load_setup_functions "$tmp_dir/recommended_workflow_setup.lib.sh"

    install_coding_agents >/dev/null
  )

  [[ "$(cat "$tmp_dir/npm-install-record")" == \
    "yes|install --global @anthropic-ai/claude-code @openai/codex" ]] \
    || fail "expected bashrc sourcing before the global coding-agent npm install"
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

    record_step() { printf '%s\n' "$1" >>"$tmp_dir/main-steps"; }
    require_command() { record_step "require_command:$1"; }
    install_gh() { record_step "install_gh"; }
    ensure_gh_personal_login() { record_step "ensure_gh_personal_login"; }
    ensure_nvm_and_node() { record_step "ensure_nvm_and_node"; }
    install_coding_agents() { record_step "install_coding_agents"; }
    sync_repo() {
      local repo_url="$1"
      local repo_dir="$2"

      record_step "sync_repo:$repo_url"
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
    [[ "$(head -n1 "$tmp_dir/main-steps")" == "install_gh" ]] \
      || fail "expected gh installation to be the first main setup step"
    [[ "$(tail -n1 "$tmp_dir/main-steps")" == "install_coding_agents" ]] \
      || fail "expected coding-agent installation to be the final main setup step"
  )
}

test_nvm_install_uses_xdg_config_home
test_gh_release_platform_mapping
test_install_gh_auto_installs_without_sudo
test_coding_agent_install_sources_bashrc_and_uses_npm_global
test_main_uses_no_sudo_bash_git_simplified_install_method
printf 'ok - recommended_workflow_setup regression checks\n'
