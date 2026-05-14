#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

require_no_pattern() {
  local file="$1"
  local pattern="$2"
  local message="$3"

  if grep -Eq "$pattern" "$ROOT_DIR/$file"; then
    fail "$message"
  fi
}

test_migration_scripts_avoid_known_bad_patterns() {
  require_no_pattern "scripts/migrate_business_stack.sh" '>/devnull' \
    "migrate_business_stack.sh must redirect to /dev/null"
  require_no_pattern "scripts/migrate_business_stack.sh" 'echo "NEW_SSH_PASS=' \
    "migrate_business_stack.sh must not persist NEW_SSH_PASS in defaults"
  require_no_pattern "scripts/migrate_business_stack.sh" '\$\{REMOTE_ARGS\[\*\]\}' \
    "migrate_business_stack.sh must shell-quote remote arguments"
  require_no_pattern "servers/create-virtualmin-site.sh" '\[\^' \
    "create-virtualmin-site.sh must use POSIX [!...] glob negation"
}

test_tar_stream_copy_has_no_stdin_overriding_heredocs() {
  command -v shellcheck >/dev/null 2>&1 || return 0

  if shellcheck "$ROOT_DIR/scripts/migrate-sql-site-plesk.sh" 2>&1 | grep -q 'SC2259'; then
    fail "migrate-sql-site-plesk.sh must not attach heredocs to piped tar/ssh commands"
  fi

  if shellcheck "$ROOT_DIR/scripts/migrate-sql-site.sh" 2>&1 | grep -q "Couldn't parse"; then
    fail "migrate-sql-site.sh must remain parseable by shellcheck"
  fi
}

test_install_codex_config_backs_up_existing_config() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  mkdir -p "$tmp_dir/home/.codex"
  printf 'custom config\n' >"$tmp_dir/home/.codex/config.toml"

  HOME="$tmp_dir/home" bash "$ROOT_DIR/scripts/install_codex_config.sh" >/dev/null

  compgen -G "$tmp_dir/home/.codex/config.toml.bak.*" >/dev/null \
    || fail "install_codex_config.sh must back up an existing config.toml"
}

test_migration_scripts_avoid_known_bad_patterns
test_tar_stream_copy_has_no_stdin_overriding_heredocs
test_install_codex_config_backs_up_existing_config
printf 'ok - static regression checks\n'
