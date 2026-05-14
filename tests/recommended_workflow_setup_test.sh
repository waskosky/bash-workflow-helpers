#!/usr/bin/env bash
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

test_nvm_install_uses_xdg_config_home
printf 'ok - recommended_workflow_setup uses the nvm installer XDG_CONFIG_HOME path\n'
