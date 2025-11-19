#!/usr/bin/env bash
set -euo pipefail

umask 077

# Run context: assume we run this orchestrator on the OLD/source server by default.
# When running on OLD, this script will copy itself to NEW and execute there with --from-new.
ORIGIN_MODE="${ORIGIN_MODE:-old}"   # old|new
NEW_HOST="${NEW_HOST:-}"
NEW_SSH_USER="${NEW_SSH_USER:-root}"
NEW_SSH_PORT="${NEW_SSH_PORT:-22}"
NEW_SSH_PASS="${NEW_SSH_PASS:-}"
SRC_HOST="${SRC_HOST:-}"
SRC_SSH_USER="${SRC_SSH_USER:-root}"
SRC_SSH_PORT="${SRC_SSH_PORT:-22}"
SSH_IDENTITY_FILE="${SSH_IDENTITY_FILE:-}"
CLI_PLESK_EXPECTED="${CLI_PLESK_EXPECTED:-}"
RMT_AUTOSTART="${RMT_AUTOSTART:-}"

# Optional persistent defaults like migrate-sql-site-plesk
SCRIPT_NAME="$(basename "$0")"
XDG_CONFIG_HOME_DEFAULT="${HOME}/.config"
BUS_CONFIG_DIR="${XDG_CONFIG_HOME:-$XDG_CONFIG_HOME_DEFAULT}/migrate-business-stack"
BUS_CONFIG_FILE="${BUS_CONFIG_FILE:-${BUS_CONFIG_DIR}/defaults.env}"

ensure_bus_config_dir() { mkdir -p "$BUS_CONFIG_DIR"; chmod 700 "$BUS_CONFIG_DIR" 2>/dev/null || true; }
load_bus_config() {
  ensure_bus_config_dir
  if [ -f "$BUS_CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$BUS_CONFIG_FILE"
  fi
}
_sh_escape() { printf %s "$1" | sed -e "s/'/'\\''/g"; }
save_bus_config() {
  ensure_bus_config_dir
  local tmp="${BUS_CONFIG_FILE}.tmp$$"
  {
    echo "# Saved by ${SCRIPT_NAME} on $(date '+%Y-%m-%d %H:%M:%S')"
    echo "NEW_HOST='$( _sh_escape "${NEW_HOST:-}")'"
    echo "NEW_SSH_USER='$( _sh_escape "${NEW_SSH_USER:-}")'"
    echo "NEW_SSH_PORT='$( _sh_escape "${NEW_SSH_PORT:-}")'"
    echo "NEW_SSH_PASS='$( _sh_escape "${NEW_SSH_PASS:-}")'"
    echo "SRC_HOST='$( _sh_escape "${SRC_HOST:-}")'"
    echo "SRC_SSH_USER='$( _sh_escape "${SRC_SSH_USER:-}")'"
    echo "SRC_SSH_PORT='$( _sh_escape "${SRC_SSH_PORT:-}")'"
    echo "SSH_IDENTITY_FILE='$( _sh_escape "${SSH_IDENTITY_FILE:-}")'"
    echo "CLI_PLESK_EXPECTED='$( _sh_escape "${CLI_PLESK_EXPECTED:-}")'"
  } >"$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$BUS_CONFIG_FILE"
}

# Load saved defaults upfront
load_bus_config

# Parse minimal flags early so we can forward correctly
FWD_ARGS=()
SAVE_DEFAULTS=false
while [[ ${1:-} == --* ]]; do
  case "$1" in
    --from-old) ORIGIN_MODE=old; shift ;;
    --from-new) ORIGIN_MODE=new; shift ;;
    --new-host) NEW_HOST="$2"; shift 2 ;;
    --new-user) NEW_SSH_USER="$2"; shift 2 ;;
    --new-port) NEW_SSH_PORT="$2"; shift 2 ;;
    --new-pass) NEW_SSH_PASS="$2"; shift 2 ;;
    --src-host) SRC_HOST="$2"; shift 2 ;;
    --src-user) SRC_SSH_USER="$2"; shift 2 ;;
    --src-port) SRC_SSH_PORT="$2"; shift 2 ;;
    --src-key|--ssh-identity|--identity-file) SSH_IDENTITY_FILE="$2"; shift 2 ;;
    --autostart) RMT_AUTOSTART="$2"; FWD_ARGS+=("$1" "$2"); shift 2 ;;
    --plesk) CLI_PLESK_EXPECTED=true; FWD_ARGS+=("$1"); shift ;;
    --no-plesk) CLI_PLESK_EXPECTED=false; FWD_ARGS+=("$1"); shift ;;
    --save-defaults) SAVE_DEFAULTS=true; shift ;;
    -h|--help)
      cat <<USAGE
Usage: $0 [--from-old|--from-new]
          [--new-host HOST] [--new-user USER] [--new-port PORT] [--new-pass PASS]
          [--src-host HOST] [--src-user USER] [--src-port PORT] [--src-key PATH]
          [--autostart list|run-all|run:<subname>]
          [--plesk|--no-plesk] [--save-defaults]

Defaults: --from-old and --no-plesk. In old mode this script copies itself to NEW and runs there.
If both --new-host and --src-host are set (or detected), autostart=run-all is applied by default.
--plesk/--no-plesk forces Plesk expectation on NEW (overrides migration.env PLESK_EXPECTED).
--autostart runs the service migrator remotely on NEW after staging (use run-all for full migration).
USAGE
      exit 0
      ;;
    *) FWD_ARGS+=("$1"); shift ;;
  esac
done

# If running on OLD, stage and exec on NEW
if [ "${ORIGIN_MODE}" = "old" ]; then
  # Minimal interactive prompts for convenience when running from a TTY
  prompt_if_empty() {
    local var="$1"; shift
    local msg="$1"; shift || true
    local secret="${1:-false}"
    if [ -z "${!var:-}" ] && [ -t 0 ]; then
      if [ "$secret" = "true" ]; then
        read -rsp "${msg}: " _val; echo
      else
        read -rp "${msg}: " _val
      fi
      printf -v "$var" '%s' "${_val}"
    fi
  }
  prompt_if_empty NEW_HOST "Enter NEW host (IP/FQDN)"
  # Try to auto-detect SRC_HOST if empty
  if [ -z "${SRC_HOST}" ]; then
    # Prefer public IP if available, then default route source IP
    SRC_HOST=$( (command -v curl >/dev/null 2>&1 && curl -fsS https://api.ipify.org) || true )
    if [ -z "${SRC_HOST}" ] && command -v dig >/dev/null 2>&1; then
      SRC_HOST=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null || true)
    fi
    if [ -z "${SRC_HOST}" ]; then
      SRC_HOST=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)
    fi
  fi
  prompt_if_empty SRC_HOST "Enter SRC host (this OLD server address reachable from NEW)"
  # Re-check NEW host
  if [ -z "${NEW_HOST}" ]; then
    echo "NEW host is required when running with --from-old. Provide --new-host <host>." >&2
    exit 1
  fi
  # Default to one-command: autostart run-all when both ends are known and not overridden
  if [ -z "${RMT_AUTOSTART:-}" ] && [ -n "${SRC_HOST}" ] && [ -n "${NEW_HOST}" ]; then
    RMT_AUTOSTART="run-all"
  fi
  # One-time password prompts (won't be stored). Use only if interactive and ssh key isn't available.
  # NEW root password (for staging and execution)
  if [ -z "${NEW_SSH_PASS:-}" ] && [ -t 0 ]; then
    # Attempt non-interactive check first to see if key-based auth works
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -p "${NEW_SSH_PORT}" -o StrictHostKeyChecking=accept-new "${NEW_SSH_USER}@${NEW_HOST}" 'echo ok' >/dev/null 2>&1; then
      read -rsp "Enter NEW (${NEW_SSH_USER}@${NEW_HOST}) password (leave blank to be prompted later): " NEW_SSH_PASS_INPUT; echo
      if [ -n "${NEW_SSH_PASS_INPUT}" ]; then NEW_SSH_PASS="${NEW_SSH_PASS_INPUT}"; fi
    fi
  fi
  # SRC root password for NEW->OLD connections (passed ephemerally during remote run)
  if [ -z "${SRC_SSH_PASS:-}" ] && [ -t 0 ]; then
    # Attempt to see if key-based auth from NEW->SRC may work by probing from OLD; if we have no identity file, prompt
    if [ -z "${SSH_IDENTITY_FILE:-}" ]; then
      read -rsp "Enter SRC (${SRC_SSH_USER}@${SRC_HOST}) password for remote pull (leave blank to be prompted on NEW): " SRC_SSH_PASS_INPUT; echo
      if [ -n "${SRC_SSH_PASS_INPUT}" ]; then SRC_SSH_PASS="${SRC_SSH_PASS_INPUT}"; fi
    fi
  fi
  if [ -z "${SRC_HOST}" ]; then
    echo "[WARN] SRC_HOST (address of this OLD/source server reachable from NEW) not set."
    echo "       Provide with --src-host <host-or-ip>."
  fi
  echo "[INFO] Detected --from-old (default). Staging on NEW: ${NEW_SSH_USER}@${NEW_HOST}:${NEW_SSH_PORT}"
  # Optionally save defaults
  if [ "$SAVE_DEFAULTS" = true ]; then save_bus_config; fi
  # Ensure target folder exists
  if [ -n "${NEW_SSH_PASS}" ] && command -v sshpass >/dev/null 2>&1; then
    sshpass -p "${NEW_SSH_PASS}" ssh -A -p "${NEW_SSH_PORT}" -o ForwardAgent=yes -o StrictHostKeyChecking=accept-new "${NEW_SSH_USER}@${NEW_HOST}" 'sudo install -d -m 0750 /root/migration'
  else
    ssh -A -p "${NEW_SSH_PORT}" -o ForwardAgent=yes -o StrictHostKeyChecking=accept-new "${NEW_SSH_USER}@${NEW_HOST}" 'sudo install -d -m 0750 /root/migration'
  fi
  # Copy this script to NEW
  THIS_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
  if [ -n "${NEW_SSH_PASS}" ] && command -v sshpass >/dev/null 2>&1; then
    sshpass -p "${NEW_SSH_PASS}" scp -P "${NEW_SSH_PORT}" -o StrictHostKeyChecking=accept-new "$THIS_PATH" "${NEW_SSH_USER}@${NEW_HOST}:/root/migration/migrate_business_stack.sh"
  else
    scp -P "${NEW_SSH_PORT}" -o StrictHostKeyChecking=accept-new "$THIS_PATH" "${NEW_SSH_USER}@${NEW_HOST}:/root/migration/migrate_business_stack.sh"
  fi
  # If a source identity key was provided, copy it to NEW for temporary use
  SRC_KEY_REMOTE=""
  if [ -n "${SSH_IDENTITY_FILE:-}" ] && [ -r "${SSH_IDENTITY_FILE}" ]; then
    SRC_KEY_REMOTE="/root/migration/src_ssh_key"
    if [ -n "${NEW_SSH_PASS}" ] && command -v sshpass >/dev/null 2>&1; then
      sshpass -p "${NEW_SSH_PASS}" scp -P "${NEW_SSH_PORT}" -o StrictHostKeyChecking=accept-new "${SSH_IDENTITY_FILE}" "${NEW_SSH_USER}@${NEW_HOST}:${SRC_KEY_REMOTE}"
    else
      scp -P "${NEW_SSH_PORT}" -o StrictHostKeyChecking=accept-new "${SSH_IDENTITY_FILE}" "${NEW_SSH_USER}@${NEW_HOST}:${SRC_KEY_REMOTE}"
    fi
    # Fix permissions on NEW and remember to clean up
    if [ -n "${NEW_SSH_PASS}" ] && command -v sshpass >/dev/null 2>&1; then
      sshpass -p "${NEW_SSH_PASS}" ssh -A -p "${NEW_SSH_PORT}" -o ForwardAgent=yes -o StrictHostKeyChecking=accept-new "${NEW_SSH_USER}@${NEW_HOST}" \
        "sudo chmod 600 ${SRC_KEY_REMOTE} && sudo chown root:root ${SRC_KEY_REMOTE}"
    else
      ssh -A -p "${NEW_SSH_PORT}" -o ForwardAgent=yes -o StrictHostKeyChecking=accept-new "${NEW_SSH_USER}@${NEW_HOST}" \
        "sudo chmod 600 ${SRC_KEY_REMOTE} && sudo chown root:root ${SRC_KEY_REMOTE}"
    fi
  fi
  # Rebuild argument list: drop any --from-old/new-host/new-user/new-port, add --from-new
  REMOTE_ARGS=(--from-new)
  for a in "${FWD_ARGS[@]}"; do
    case "$a" in
      --from-old|--from-new|--new-host|--new-user|--new-port) ;; # skip
      *) REMOTE_ARGS+=("$a") ;;
    esac
  done
  # Add overrides for SRC_* and identity if provided
  if [ -n "${SRC_HOST}" ]; then REMOTE_ARGS+=(--src-host "$SRC_HOST"); fi
  if [ -n "${SRC_SSH_USER}" ]; then REMOTE_ARGS+=(--src-user "$SRC_SSH_USER"); fi
  if [ -n "${SRC_SSH_PORT}" ]; then REMOTE_ARGS+=(--src-port "$SRC_SSH_PORT"); fi
  if [ -n "${SRC_KEY_REMOTE}" ]; then REMOTE_ARGS+=(--src-key "$SRC_KEY_REMOTE"); fi
  if [ -n "${CLI_PLESK_EXPECTED:-}" ]; then
    if [ "$CLI_PLESK_EXPECTED" = true ]; then REMOTE_ARGS+=(--plesk); else REMOTE_ARGS+=(--no-plesk); fi
  fi
  if [ -n "${RMT_AUTOSTART:-}" ]; then REMOTE_ARGS+=(--autostart "$RMT_AUTOSTART"); fi
  # Pass through any remaining non-flag arguments as well
  for a in "$@"; do REMOTE_ARGS+=("$a"); done

  # Always pre-push source assets to NEW so remote scripts can operate without NEW->OLD SSH
  echo "[INFO] Pre-pushing source assets to NEW (best effort)"
  # Ensure files dir exists on NEW
  if [ -n "${NEW_SSH_PASS}" ] && command -v sshpass >/dev/null 2>&1; then
    sshpass -p "${NEW_SSH_PASS}" ssh -A -p "${NEW_SSH_PORT}" -o ForwardAgent=yes -o StrictHostKeyChecking=accept-new "${NEW_SSH_USER}@${NEW_HOST}" 'sudo install -d -m 0750 /root/migration/files'
  else
    ssh -A -p "${NEW_SSH_PORT}" -o ForwardAgent=yes -o StrictHostKeyChecking=accept-new "${NEW_SSH_USER}@${NEW_HOST}" 'sudo install -d -m 0750 /root/migration/files'
  fi
  # Helper to copy to NEW
  _push_to_new() { # local remote
    if [ -n "${NEW_SSH_PASS}" ] && command -v sshpass >/dev/null 2>&1; then
      sshpass -p "${NEW_SSH_PASS}" scp -P "${NEW_SSH_PORT}" -o StrictHostKeyChecking=accept-new "$1" "${NEW_SSH_USER}@${NEW_HOST}:$2" 2>/dev/null || true
    else
      scp -P "${NEW_SSH_PORT}" -o StrictHostKeyChecking=accept-new "$1" "${NEW_SSH_USER}@${NEW_HOST}:$2" 2>/dev/null || true
    fi
  }
  _rsync_to_new() { # localdir remotedir
    if [ -n "${NEW_SSH_PASS}" ] && command -v sshpass >/devnull 2>&1; then
      sshpass -p "${NEW_SSH_PASS}" rsync -aHAX -e "ssh -p ${NEW_SSH_PORT} -o StrictHostKeyChecking=accept-new" "$1" "${NEW_SSH_USER}@${NEW_HOST}:$2" 2>/dev/null || true
    else
      rsync -aHAX -e "ssh -p ${NEW_SSH_PORT} -o StrictHostKeyChecking=accept-new" "$1" "${NEW_SSH_USER}@${NEW_HOST}:$2" 2>/dev/null || true
    fi
  }
  # Marker for push mode
  if [ -n "${NEW_SSH_PASS}" ] && command -v sshpass >/dev/null 2>&1; then
    sshpass -p "${NEW_SSH_PASS}" ssh -A -p "${NEW_SSH_PORT}" -o ForwardAgent=yes -o StrictHostKeyChecking=accept-new "${NEW_SSH_USER}@${NEW_HOST}" 'sudo bash -c "echo 1 > /root/migration/files/push_mode.marker"' || true
  else
    ssh -A -p "${NEW_SSH_PORT}" -o ForwardAgent=yes -o StrictHostKeyChecking=accept-new "${NEW_SSH_USER}@${NEW_HOST}" 'sudo bash -c "echo 1 > /root/migration/files/push_mode.marker"' || true
  fi

  # 1) Postgres dump and configs (if available on OLD)
  if command -v psql >/dev/null 2>&1 || sudo -u postgres psql -tA -c 'select 1' >/dev/null 2>&1; then
    echo "[INFO] Creating source PostgreSQL dump..."
    TMP_PG="/tmp/pg_dumpall.$$.sql.gz"
    sudo -u postgres pg_dumpall --no-role-passwords | gzip -c >"$TMP_PG" 2>/dev/null || true
    if [ -s "$TMP_PG" ]; then
      _push_to_new "$TMP_PG" "/root/migration/files/pg_dumpall.sql.gz"
      rm -f "$TMP_PG" || true
    fi
    SRC_PGDATA_OLD="$(sudo -u postgres psql -tA -c 'show data_directory;' 2>/dev/null || true)"
    if [ -n "$SRC_PGDATA_OLD" ]; then
      _push_to_new "$SRC_PGDATA_OLD/pg_hba.conf" "/root/migration/files/pg_hba.conf.source"
      _push_to_new "$SRC_PGDATA_OLD/postgresql.conf" "/root/migration/files/postgresql.conf.source"
    fi
  fi

  # 2) Mattermost assets (if present on OLD)
  if [ -d "/opt/mattermost" ]; then
    echo "[INFO] Pre-pushing Mattermost assets..."
    _push_to_new "/opt/mattermost/config/config.json" "/root/migration/files/config.json.source"
    # Push data and plugins directly into destination path on NEW for speed; remote script will detect and reuse
    _rsync_to_new "/opt/mattermost/" "/opt/mattermost/"
  fi

  # 3) Redis selected config (if present on OLD)
  if [ -f "/etc/redis/redis.conf" ] || [ -f "/etc/redis.conf" ]; then
    echo "[INFO] Pre-pushing Redis config..."
    SRC_REDIS_CONF_OLD="/etc/redis/redis.conf"
    [ -f "$SRC_REDIS_CONF_OLD" ] || SRC_REDIS_CONF_OLD="/etc/redis.conf"
    awk '/^(bind|port|maxmemory|maxmemory-policy|save|appendonly|appendfsync|requirepass|rename-command|aclfile|unixsocket|timeout|tcp-backlog|databases)[[:space:]]/ {print} /^user[[:space:]]/ {print}' "$SRC_REDIS_CONF_OLD" >"/tmp/redis_selected.$$.conf" 2>/dev/null || true
    if [ -s "/tmp/redis_selected.$$.conf" ]; then
      _push_to_new "/tmp/redis_selected.$$.conf" "/root/migration/files/redis_selected.conf"
      rm -f "/tmp/redis_selected.$$.conf" || true
    fi
    ACL_FILE_OLD="$(awk '$1=="aclfile"{print $2}' "$SRC_REDIS_CONF_OLD" 2>/dev/null || true)"
    if [ -n "$ACL_FILE_OLD" ] && [ -f "$ACL_FILE_OLD" ]; then
      _push_to_new "$ACL_FILE_OLD" "/root/migration/files/redis_aclfile.source"
    fi
  fi
  # Execute on NEW as root
  # Pass SRC_SSH_PASS ephemerally if provided
  if [ -n "${NEW_SSH_PASS}" ] && command -v sshpass >/dev/null 2>&1; then
    if [ -n "${SRC_SSH_PASS:-}" ]; then
      sshpass -p "${NEW_SSH_PASS}" ssh -A -t -p "${NEW_SSH_PORT}" -o ForwardAgent=yes -o StrictHostKeyChecking=accept-new "${NEW_SSH_USER}@${NEW_HOST}" \
        "SRC_SSH_PASS='$(printf %s "${SRC_SSH_PASS}" | sed -e "s/'/'\\''/g")' sudo -E bash /root/migration/migrate_business_stack.sh ${REMOTE_ARGS[*]}"
    else
      sshpass -p "${NEW_SSH_PASS}" ssh -A -t -p "${NEW_SSH_PORT}" -o ForwardAgent=yes -o StrictHostKeyChecking=accept-new "${NEW_SSH_USER}@${NEW_HOST}" \
        "sudo -E bash /root/migration/migrate_business_stack.sh ${REMOTE_ARGS[*]}"
    fi
  else
    if [ -n "${SRC_SSH_PASS:-}" ]; then
      ssh -A -t -p "${NEW_SSH_PORT}" -o ForwardAgent=yes -o StrictHostKeyChecking=accept-new "${NEW_SSH_USER}@${NEW_HOST}" \
        "SRC_SSH_PASS='$(printf %s "${SRC_SSH_PASS}" | sed -e "s/'/'\\''/g")' sudo -E bash /root/migration/migrate_business_stack.sh ${REMOTE_ARGS[*]}"
    else
      ssh -A -t -p "${NEW_SSH_PORT}" -o ForwardAgent=yes -o StrictHostKeyChecking=accept-new "${NEW_SSH_USER}@${NEW_HOST}" \
        "sudo -E bash /root/migration/migrate_business_stack.sh ${REMOTE_ARGS[*]}"
    fi
  fi
  exit $?
fi
install -d -m 0750 /root/migration/{subs,logs,tmp,files,work}

cat > /root/migration/migration.env <<'EOF_ENV'
# === REQUIRED: Source server SSH ===
SRC_HOST="old.example.com"
SRC_SSH_USER="root"
SRC_SSH_PORT=22

# Optional: SSH key path if not default
# SSH_IDENTITY_FILE="/root/.ssh/id_rsa"

# === Toggles (1=enable, 0=skip) ===
MIGRATE_POSTGRES=1
MIGRATE_MATTERMOST=1
MIGRATE_REDIS=1
MIGRATE_PHP_OPCACHE=0
MIGRATE_PHP_RELAY=0
MIGRATE_NGINX_GLOBALS=0
# Cron is two-phase: prepare stubs by default, apply after review.
MIGRATE_CRONS_PREPARE=1
MIGRATE_CRONS_APPLY=0

# === Plesk PHP target ===
PLESK_PHP_VER="8.2"   # must exist at /opt/plesk/php/8.2

# Expect a Plesk target? auto|true|false
#  - auto: require Plesk only if Plesk-related toggles are enabled
#  - true: always require Plesk
#  - false: never require Plesk (Plesk toggles default to disabled)
PLESK_EXPECTED="auto"

# Optional: change Mattermost DB DSN during migrate; leave empty to keep as-is
MM_NEW_DSN=""

# Internal defaults
DEBIAN_FRONTEND=noninteractive
# Build SSH options
SSH_OPTS="-p ${SRC_SSH_PORT} -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
if [ -n "${SSH_IDENTITY_FILE:-}" ]; then SSH_OPTS="${SSH_OPTS} -i ${SSH_IDENTITY_FILE}"; fi
EOF_ENV

# Apply CLI overrides into migration.env
if [ -n "${CLI_PLESK_EXPECTED:-}" ]; then
  sed -i -E "s/^PLESK_EXPECTED=.*/PLESK_EXPECTED=\"${CLI_PLESK_EXPECTED}\"/" /root/migration/migration.env
fi
if [ -n "${SRC_HOST:-}" ]; then
  sed -i -E "s/^SRC_HOST=.*/SRC_HOST=\"${SRC_HOST}\"/" /root/migration/migration.env
fi
if [ -n "${SRC_SSH_USER:-}" ]; then
  sed -i -E "s/^SRC_SSH_USER=.*/SRC_SSH_USER=\"${SRC_SSH_USER}\"/" /root/migration/migration.env
fi
if [ -n "${SRC_SSH_PORT:-}" ]; then
  sed -i -E "s/^SRC_SSH_PORT=.*/SRC_SSH_PORT=${SRC_SSH_PORT}/" /root/migration/migration.env
fi
if [ -n "${SSH_IDENTITY_FILE:-}" ]; then
  sed -i -E "s|^#?\s*SSH_IDENTITY_FILE=.*|SSH_IDENTITY_FILE=\"${SSH_IDENTITY_FILE}\"|" /root/migration/migration.env
fi

cat > /root/migration/migrate_services.sh <<'EOF_MAIN'
#!/usr/bin/env bash
set -euo pipefail

BASE="/root/migration"
ENVF="$BASE/migration.env"
LOGD="$BASE/logs"
SUBD="$BASE/subs"

if [ ! -f "$ENVF" ]; then echo "Missing $ENVF. Edit and re-run."; exit 1; fi
# shellcheck disable=SC1090
source "$ENVF"

# Accumulate results for a clear summary
RESULTS=()
add_result() { # label status logpath
  local label="$1" status="$2" logp="$3"
  RESULTS+=("$status|$label|$logp")
}
print_summary() {
  echo
  echo "======== Migration Summary ========"
  local fail=0 warn=0 ok=0
  for entry in "${RESULTS[@]}"; do
    IFS='|' read -r status label logp <<<"$entry"
    case "$status" in
      OK)   ok=$((ok+1));   printf "[OK]    %s (log: %s)\n"   "$label" "$logp" ;;
      FAIL) fail=$((fail+1)); printf "[FAIL]  %s (log: %s)\n" "$label" "$logp" ;;
      SKIP*) warn=$((warn+1)); printf "[SKIP]  %s - %s\n" "$label" "${status#SKIP: }" ;;
      *)    printf "[INFO]  %s - %s\n" "$label" "$status" ;;
    esac
  done
  echo "-----------------------------------"
  printf "Totals: OK=%d FAIL=%d SKIP/WARN=%d\n" "$ok" "$fail" "$warn"
  [ "$fail" -eq 0 ] || return 1
}

run_sub() {
  local sub="$1"; shift || true
  local log="$LOGD/${sub##*/}.log"
  echo "==> ${sub##*/}"
  chmod +x "$sub"
  # Pass through args to sub-scripts
  "$sub" "$@" |& tee -a "$log"
  local rc=${PIPESTATUS[0]}
  echo
  return "$rc"
}

list() {
  printf "Available sub-scripts (enabled=1):\n"
  printf "  00_prereqs_check.sh              (always)\n"
  printf "  10_postgres17_migrate.sh         MIGRATE_POSTGRES=%s\n" "${MIGRATE_POSTGRES:-0}"
  printf "  20_mattermost_migrate.sh         MIGRATE_MATTERMOST=%s\n" "${MIGRATE_MATTERMOST:-0}"
  printf "  30_redis_migrate.sh              MIGRATE_REDIS=%s\n" "${MIGRATE_REDIS:-0}"
  printf "  40_php_opcache_migrate.sh        MIGRATE_PHP_OPCACHE=%s\n" "${MIGRATE_PHP_OPCACHE:-0}"
  printf "  45_php_relay_install.sh          MIGRATE_PHP_RELAY=%s\n" "${MIGRATE_PHP_RELAY:-0}"
  printf "  50_nginx_customs_migrate.sh      MIGRATE_NGINX_GLOBALS=%s\n" "${MIGRATE_NGINX_GLOBALS:-0}"
  printf "  60_cron_migrate.sh               PREPARE=%s APPLY=%s\n" "${MIGRATE_CRONS_PREPARE:-0}" "${MIGRATE_CRONS_APPLY:-0}"
}

case "${1:-}" in
  list|"")
    list
    ;;
  run-all)
    # Always run prereqs first
    if run_sub "$SUBD/00_prereqs_check.sh"; then
      add_result "00_prereqs_check.sh" "OK" "$LOGD/00_prereqs_check.sh.log"
      # Reload environment in case prereqs adjusted toggles
      # shellcheck disable=SC1090
      source "$ENVF"
      # Postgres
      if [ "${MIGRATE_POSTGRES:-0}" = "1" ]; then
        if run_sub "$SUBD/10_postgres17_migrate.sh"; then
          add_result "10_postgres17_migrate.sh" "OK" "$LOGD/10_postgres17_migrate.sh.log"
        else
          add_result "10_postgres17_migrate.sh" "FAIL" "$LOGD/10_postgres17_migrate.sh.log"
        fi
      else
        add_result "10_postgres17_migrate.sh" "SKIP: disabled" "-"
      fi
      # Mattermost
      if [ "${MIGRATE_MATTERMOST:-0}" = "1" ]; then
        if run_sub "$SUBD/20_mattermost_migrate.sh"; then
          add_result "20_mattermost_migrate.sh" "OK" "$LOGD/20_mattermost_migrate.sh.log"
        else
          add_result "20_mattermost_migrate.sh" "FAIL" "$LOGD/20_mattermost_migrate.sh.log"
        fi
      else
        add_result "20_mattermost_migrate.sh" "SKIP: disabled" "-"
      fi
      # Redis
      if [ "${MIGRATE_REDIS:-0}" = "1" ]; then
        if run_sub "$SUBD/30_redis_migrate.sh"; then
          add_result "30_redis_migrate.sh" "OK" "$LOGD/30_redis_migrate.sh.log"
        else
          add_result "30_redis_migrate.sh" "FAIL" "$LOGD/30_redis_migrate.sh.log"
        fi
      else
        add_result "30_redis_migrate.sh" "SKIP: disabled" "-"
      fi
      # PHP opcache (Plesk)
      if [ "${MIGRATE_PHP_OPCACHE:-0}" = "1" ]; then
        if run_sub "$SUBD/40_php_opcache_migrate.sh"; then
          add_result "40_php_opcache_migrate.sh" "OK" "$LOGD/40_php_opcache_migrate.sh.log"
        else
          add_result "40_php_opcache_migrate.sh" "FAIL" "$LOGD/40_php_opcache_migrate.sh.log"
        fi
      else
        add_result "40_php_opcache_migrate.sh" "SKIP: disabled" "-"
      fi
      # PHP relay (Plesk)
      if [ "${MIGRATE_PHP_RELAY:-0}" = "1" ]; then
        if run_sub "$SUBD/45_php_relay_install.sh"; then
          add_result "45_php_relay_install.sh" "OK" "$LOGD/45_php_relay_install.sh.log"
        else
          add_result "45_php_relay_install.sh" "FAIL" "$LOGD/45_php_relay_install.sh.log"
        fi
      else
        add_result "45_php_relay_install.sh" "SKIP: disabled" "-"
      fi
      # Nginx globals (Plesk)
      if [ "${MIGRATE_NGINX_GLOBALS:-0}" = "1" ]; then
        if run_sub "$SUBD/50_nginx_customs_migrate.sh"; then
          add_result "50_nginx_customs_migrate.sh" "OK" "$LOGD/50_nginx_customs_migrate.sh.log"
        else
          add_result "50_nginx_customs_migrate.sh" "FAIL" "$LOGD/50_nginx_customs_migrate.sh.log"
        fi
      else
        add_result "50_nginx_customs_migrate.sh" "SKIP: disabled" "-"
      fi
      # Cron last
      if [ "${MIGRATE_CRONS_PREPARE:-0}" = "1" ] || [ "${MIGRATE_CRONS_APPLY:-0}" = "1" ]; then
        if run_sub "$SUBD/60_cron_migrate.sh"; then
          add_result "60_cron_migrate.sh" "OK" "$LOGD/60_cron_migrate.sh.log"
        else
          add_result "60_cron_migrate.sh" "FAIL" "$LOGD/60_cron_migrate.sh.log"
        fi
      else
        add_result "60_cron_migrate.sh" "SKIP: disabled" "-"
      fi
      print_summary
    else
      # Prereqs failed; summarize and abort
      add_result "00_prereqs_check.sh" "FAIL" "$LOGD/00_prereqs_check.sh.log"
      add_result "10_postgres17_migrate.sh" "SKIP: prereqs failed" "-"
      add_result "20_mattermost_migrate.sh" "SKIP: prereqs failed" "-"
      add_result "30_redis_migrate.sh" "SKIP: prereqs failed" "-"
      add_result "40_php_opcache_migrate.sh" "SKIP: prereqs failed" "-"
      add_result "45_php_relay_install.sh" "SKIP: prereqs failed" "-"
      add_result "50_nginx_customs_migrate.sh" "SKIP: prereqs failed" "-"
      add_result "60_cron_migrate.sh" "SKIP: prereqs failed" "-"
      print_summary || true
      exit 1
    fi
    ;;
  run)
    shift
    if [ -z "${1:-}" ]; then echo "Usage: $0 run <basename-of-subscript> [args]"; exit 1; fi
    sub="$SUBD/${1}"; shift || true
    if [ ! -x "$sub" ]; then echo "Not found: $sub"; exit 1; fi
    run_sub "$sub" "$@"
    ;;
  *)
    echo "Usage: $0 [list|run-all|run <sub> [args]]"
    exit 1
    ;;
esac
EOF_MAIN

cat > /root/migration/subs/00_prereqs_check.sh <<'EOF_00'
#!/usr/bin/env bash
set -euo pipefail
BASE="/root/migration"
# shellcheck disable=SC1090
source "$BASE/migration.env"

log() { printf "[%s] %s\n" "$(date -Iseconds)" "$*"; }

# Root check
if [ "$EUID" -ne 0 ]; then echo "Run as root."; exit 1; fi

# OS + Plesk checks (conditional, with auto-disable when Plesk missing)
PLESK_EXPECTED="${PLESK_EXPECTED:-auto}"
PLESK_PRESENT=0
if command -v plesk >/dev/null 2>&1; then PLESK_PRESENT=1; fi

USES_PLESK_TOGGLES=0
if [ "${MIGRATE_PHP_OPCACHE:-0}" = "1" ] || \
   [ "${MIGRATE_PHP_RELAY:-0}" = "1" ] || \
   [ "${MIGRATE_NGINX_GLOBALS:-0}" = "1" ]; then
  USES_PLESK_TOGGLES=1
fi

# Decide behavior based on expectation and presence
if [ "${PLESK_EXPECTED}" = "true" ] && [ "$PLESK_PRESENT" != 1 ]; then
  echo "Plesk CLI not found but PLESK_EXPECTED=true. Install Plesk on this NEW host or set PLESK_EXPECTED=false and disable Plesk-related toggles."
  exit 1
fi

if [ "${PLESK_EXPECTED}" = "false" ] || { [ "${PLESK_EXPECTED}" = "auto" ] && [ "$PLESK_PRESENT" != 1 ]; }; then
  # Auto-disable Plesk-related toggles if Plesk is not present or explicitly not expected
  if [ -f "$BASE/migration.env" ]; then
    sed -i \
      -e 's/^MIGRATE_PHP_OPCACHE=.*/MIGRATE_PHP_OPCACHE=0/' \
      -e 's/^MIGRATE_PHP_RELAY=.*/MIGRATE_PHP_RELAY=0/' \
      -e 's/^MIGRATE_NGINX_GLOBALS=.*/MIGRATE_NGINX_GLOBALS=0/' "$BASE/migration.env" || true
  fi
  # Reflect disabled toggles for this run
  MIGRATE_PHP_OPCACHE=0
  MIGRATE_PHP_RELAY=0
  MIGRATE_NGINX_GLOBALS=0
  USES_PLESK_TOGGLES=0
fi

# If Plesk is present and PLESK_EXPECTED is auto, auto-enable related toggles for convenience
if [ "$PLESK_PRESENT" = 1 ] && [ "${PLESK_EXPECTED}" = "auto" ]; then
  if [ -f "$BASE/migration.env" ]; then
    sed -i \
      -e 's/^MIGRATE_PHP_OPCACHE=.*/MIGRATE_PHP_OPCACHE=1/' \
      -e 's/^MIGRATE_PHP_RELAY=.*/MIGRATE_PHP_RELAY=1/' \
      -e 's/^MIGRATE_NGINX_GLOBALS=.*/MIGRATE_NGINX_GLOBALS=1/' "$BASE/migration.env" || true
  fi
  MIGRATE_PHP_OPCACHE=1
  MIGRATE_PHP_RELAY=1
  MIGRATE_NGINX_GLOBALS=1
  USES_PLESK_TOGGLES=1
fi

. /etc/os-release
if [ "${ID,,}" != "ubuntu" ] || [[ "${VERSION_ID}" != 24* ]]; then
  echo "This target must be Ubuntu 24.x. Detected: $PRETTY_NAME"; exit 1
fi

# If Plesk toggles remain enabled, ensure Plesk exists
if [ "$USES_PLESK_TOGGLES" = "1" ] && [ "$PLESK_PRESENT" != 1 ]; then
  echo "Plesk CLI not found but required by enabled toggles. Either install Plesk or disable MIGRATE_PHP_OPCACHE/MIGRATE_PHP_RELAY/MIGRATE_NGINX_GLOBALS."
  exit 1
fi

# Ensure dirs
install -d -m 0750 "$BASE"/{logs,tmp,files,work}

# Packages (resilient against broken third‑party repos)
export DEBIAN_FRONTEND=noninteractive

# If PGDG repo is configured but its key is missing, add it proactively
if grep -REqs 'apt\.postgresql\.org' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
  install -d -m 0755 /etc/apt/keyrings
  if [ ! -s /etc/apt/keyrings/postgresql.gpg ]; then
    log "Ensuring PGDG apt key is installed (ACCC4CF8)."
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor >/etc/apt/keyrings/postgresql.gpg || true
  fi
fi

if ! apt-get update -y; then
  log "apt-get update failed; attempting to disable broken PGDG entries and retry."
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] || continue
    if grep -qE 'apt\.postgresql\.org' "$f"; then
      cp -a "$f" "$f.bak.$(date +%s)" || true
      sed -i -E 's/^\s*deb(\s+.*apt\.postgresql\.org.*)$/# disabled-by-migrator \0/' "$f" || true
    fi
  done
  apt-get update -y || apt-get update -y || true
fi

apt-get install -y rsync jq git curl gnupg ca-certificates build-essential autoconf pkg-config \
                   redis-server redis-tools unzip sshpass

# Plesk PHP (only when Plesk is present and toggles require it or explicitly expected)
if [ "$PLESK_PRESENT" = 1 ] && { [ "$USES_PLESK_TOGGLES" = 1 ] || [ "${PLESK_EXPECTED}" = "true" ]; }; then
  if [ ! -x "/opt/plesk/php/${PLESK_PHP_VER}/bin/php" ]; then
    # Try to auto-select an already-installed Plesk PHP version
    ORIG_VER="$PLESK_PHP_VER"
    BEST_VER="$(ls -1d /opt/plesk/php/*/bin/php 2>/dev/null | awk -F'/' '{print $(NF-2)}' | sort -V | tail -n1)"
    if [ -n "$BEST_VER" ] && [ -x "/opt/plesk/php/${BEST_VER}/bin/php" ]; then
      sed -i -E "s#^PLESK_PHP_VER=.*#PLESK_PHP_VER=\"${BEST_VER}\"#" "$BASE/migration.env" || true
      PLESK_PHP_VER="$BEST_VER"
      log "Detected installed Plesk PHP ${BEST_VER}. Using it instead of ${ORIG_VER}."
    fi
  fi
  if [ ! -x "/opt/plesk/php/${PLESK_PHP_VER}/bin/php" ]; then
    log "Plesk PHP ${PLESK_PHP_VER} not found. Attempting automatic installation."
    # Try non-interactive install of requested version
    if plesk installer add --components "php${PLESK_PHP_VER//./}" -y || yes | plesk installer add --components "php${PLESK_PHP_VER//./}"; then
      log "Installed Plesk PHP ${PLESK_PHP_VER}."
    else
      echo "Failed to auto-install Plesk PHP ${PLESK_PHP_VER}. You can install manually:"
      echo "  plesk installer add --components php${PLESK_PHP_VER//./}"
      exit 1
    fi
  fi
fi

# Push-mode detection: if assets were pre-pushed by the OLD orchestrator, skip SSH validation
PUSH_MODE=0
[ -f "$BASE/files/push_mode.marker" ] && PUSH_MODE=1

# SSH to source (use sshpass if password provided via environment), unless push mode
ensure_agent_forward_keep() {
  # Preserve SSH_AUTH_SOCK over sudo for agent forwarding
  local f="/etc/sudoers.d/99-keep-ssh-agent"
  if [ ! -f "$f" ]; then
    echo 'Defaults env_keep += "SSH_AUTH_SOCK"' >/etc/sudoers.d/99-keep-ssh-agent || true
    chmod 0440 /etc/sudoers.d/99-keep-ssh-agent || true
  fi
}
ensure_agent_forward_keep

try_ssh_user() { # user
  local u="$1"
  if [ -n "${SRC_SSH_PASS:-}" ] && command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$SRC_SSH_PASS" ssh $SSH_OPTS "$u@${SRC_HOST}" 'echo ok' >/dev/null 2>&1
  else
    ssh $SSH_OPTS "$u@${SRC_HOST}" 'echo ok' >/dev/null 2>&1
  fi
}

if [ "$PUSH_MODE" != "1" ]; then
  # Validate SSH to source; if it fails for configured user, try common cloud users
  if ! try_ssh_user "${SRC_SSH_USER}"; then
    for cand in ubuntu ec2-user admin centos debian root; do
      if [ "$cand" = "${SRC_SSH_USER}" ]; then continue; fi
      if try_ssh_user "$cand"; then
        log "Auto-detected working SRC_SSH_USER=$cand"
        SRC_SSH_USER="$cand"
        sed -i -E "s/^SRC_SSH_USER=.*/SRC_SSH_USER=\"${SRC_SSH_USER}\"/" "$BASE/migration.env" || true
        break
      fi
    done
  fi

  if ! try_ssh_user "${SRC_SSH_USER}"; then
    echo "SSH to ${SRC_HOST} failed for users: ${SRC_SSH_USER}. Check migration.env or provide --src-user/--src-key."; exit 1
  fi
else
  log "Push mode active: skipping SSH-to-source validation"
fi

if [ "$PLESK_PRESENT" = 1 ]; then
  PLESK_VER=$(plesk version 2>/dev/null | head -n1 || true)
  log "Prereqs ok. Plesk: ${PLESK_VER:-present}"
else
  log "Prereqs ok. Plesk: not installed (skipped)"
fi
EOF_00

cat > /root/migration/subs/10_postgres17_migrate.sh <<'EOF_10'
#!/usr/bin/env bash
set -euo pipefail
BASE="/root/migration"
# shellcheck disable=SC1090
source "$BASE/migration.env"

if [ "${MIGRATE_POSTGRES:-0}" != "1" ]; then echo "PostgreSQL migrate disabled."; exit 0; fi

log() { printf "[%s] %s\n" "$(date -Iseconds)" "$*"; }
PUSH_MODE=0
[ -f "$BASE/files/push_mode.marker" ] && PUSH_MODE=1
if [ "$PUSH_MODE" != "1" ]; then
  if [ -n "${SRC_SSH_PASS:-}" ] && command -v sshpass >/dev/null 2>&1; then
    SSH_BASE=(sshpass -p "$SRC_SSH_PASS" ssh $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}")
  else
    SSH_BASE=(ssh $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}")
  fi
fi

log "Installing PostgreSQL 17 from PGDG..."
. /etc/os-release
CODENAME="${UBUNTU_CODENAME:-noble}"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor >/etc/apt/keyrings/postgresql.gpg
echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt ${CODENAME}-pgdg main" >/etc/apt/sources.list.d/pgdg.list
apt-get update -y
apt-get install -y postgresql-common postgresql-17 postgresql-client-17

# Fresh cluster to avoid conflicts
if systemctl is-active --quiet postgresql; then systemctl stop postgresql; fi
if pg_lsclusters | awk '\''$1==17 && $2=="main"{found=1} END{exit(!found)}'\''; then
  pg_dropcluster --stop 17 main
fi
pg_createcluster 17 main --start

log "Preparing PostgreSQL dump..."
DUMP_GZ="$BASE/files/pg_dumpall.sql.gz"
if [ -s "$DUMP_GZ" ]; then
  log "Using pre-pushed dump at $DUMP_GZ"
else
  if [ "$PUSH_MODE" = "1" ]; then
    echo "Pre-pushed dump not found and push mode active; cannot proceed."; exit 1
  fi
  # Determine source PGDATA, dump all
  log "Detecting source PG data directory..."
  SRC_PGDATA="$("${SSH_BASE[@]}" 'sudo -u postgres psql -tA -c "show data_directory;"' 2>/dev/null || true)"
  if [ -z "$SRC_PGDATA" ]; then
    echo "Could not detect source data_directory. Proceeding with dump anyway."
  fi
  log "Dumping roles + databases on source..."
  "${SSH_BASE[@]}" 'sudo -u postgres pg_dumpall --no-role-passwords | gzip -c' >"$DUMP_GZ"
fi

log "Restoring into local 17/main cluster..."
gunzip -c "$DUMP_GZ" | sudo -u postgres psql >/dev/null

# Save source pg_hba.conf and postgresql.conf for reference (do not overwrite automatically)
if [ "$PUSH_MODE" != "1" ]; then
  if [ -n "$SRC_PGDATA" ]; then
    if [ -n "${SRC_SSH_PASS:-}" ] && command -v sshpass >/dev/null 2>&1; then
      sshpass -p "$SRC_SSH_PASS" scp $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}:${SRC_PGDATA}/pg_hba.conf" "$BASE/files/pg_hba.conf.source" || true
      sshpass -p "$SRC_SSH_PASS" scp $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}:${SRC_PGDATA}/postgresql.conf" "$BASE/files/postgresql.conf.source" || true
    else
      scp $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}:${SRC_PGDATA}/pg_hba.conf" "$BASE/files/pg_hba.conf.source" || true
      scp $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}:${SRC_PGDATA}/postgresql.conf" "$BASE/files/postgresql.conf.source" || true
    fi
  fi
fi

systemctl restart postgresql
sleep 2
sudo -u postgres psql -tA -c "select version();" | sed -e "s/^/[PG]/"
log "PostgreSQL 17 migration done. Review $BASE/files/pg_hba.conf.source if auth rules must be mirrored."
EOF_10

cat > /root/migration/subs/20_mattermost_migrate.sh <<'EOF_20'
#!/usr/bin/env bash
set -euo pipefail
BASE="/root/migration"
# shellcheck disable=SC1090
source "$BASE/migration.env"

if [ "${MIGRATE_MATTERMOST:-0}" != "1" ]; then echo "Mattermost migrate disabled."; exit 0; fi

log() { printf "[%s] %s\n" "$(date -Iseconds)" "$*"; }
PUSH_MODE=0
[ -f "$BASE/files/push_mode.marker" ] && PUSH_MODE=1
if [ "$PUSH_MODE" != "1" ]; then
  if [ -n "${SRC_SSH_PASS:-}" ] && command -v sshpass >/dev/null 2>&1; then
    SSH_BASE=(sshpass -p "$SRC_SSH_PASS" ssh $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}")
  else
    SSH_BASE=(ssh $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}")
  fi
fi

DEST_MM="/opt/mattermost"
# Find source dir early for potential auto-install
if [ "$PUSH_MODE" != "1" ]; then
  SRC_MM="$("${SSH_BASE[@]}" 'if [ -d /opt/mattermost ]; then echo /opt/mattermost; fi')"
  if [ -z "$SRC_MM" ]; then echo "Source Mattermost directory not found."; exit 1; fi
else
  SRC_MM="/opt/mattermost"
fi

if [ ! -x "$DEST_MM/bin/mattermost" ]; then
  log "Mattermost not found on NEW. Attempting to copy from source..."
  install -d -m 0755 "$DEST_MM"
  if [ -n "${SRC_SSH_PASS:-}" ] && command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$SRC_SSH_PASS" rsync -aHAX -e "ssh $SSH_OPTS" "${SRC_SSH_USER}@${SRC_HOST}:${SRC_MM}/" "$DEST_MM/"
  else
    rsync -aHAX -e "ssh $SSH_OPTS" "${SRC_SSH_USER}@${SRC_HOST}:${SRC_MM}/" "$DEST_MM/"
  fi
  # Copy systemd unit if present on source
  if "${SSH_BASE[@]}" 'test -f /lib/systemd/system/mattermost.service'; then
    if [ -n "${SRC_SSH_PASS:-}" ] && command -v sshpass >/dev/null 2>&1; then
      sshpass -p "$SRC_SSH_PASS" scp $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}:/lib/systemd/system/mattermost.service" \
        "/lib/systemd/system/mattermost.service" || true
    else
      scp $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}:/lib/systemd/system/mattermost.service" \
        "/lib/systemd/system/mattermost.service" || true
    fi
    systemctl daemon-reload || true
    systemctl enable mattermost || true
  fi
  if [ ! -x "$DEST_MM/bin/mattermost" ]; then
    echo "Failed to auto-install Mattermost on NEW."; exit 1
  fi
fi

log "Stopping Mattermost locally..."
systemctl stop mattermost || true

# Backup current config
if [ -f "$DEST_MM/config/config.json" ]; then
  cp -a "$DEST_MM/config/config.json" "$BASE/files/config.json.dest.bak.$(date +%s)"
fi

if [ -s "$BASE/files/config.json.source" ]; then
  log "Using pre-pushed Mattermost config.json"
else
  log "Fetching source config.json..."
  if [ "$PUSH_MODE" = "1" ]; then
    echo "Pre-pushed config.json missing in push mode."; exit 1
  fi
  if [ -n "${SRC_SSH_PASS:-}" ] && command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$SRC_SSH_PASS" scp $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}:${SRC_MM}/config/config.json" "$BASE/files/config.json.source"
  else
    scp $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}:${SRC_MM}/config/config.json" "$BASE/files/config.json.source"
  fi
fi

# Optionally adjust DSN
if [ -n "${MM_NEW_DSN:-}" ]; then
  jq --arg dsn "$MM_NEW_DSN" '.SqlSettings.DataSource=$dsn' "$BASE/files/config.json.source" > "$BASE/files/config.json.migrated"
else
  cp -a "$BASE/files/config.json.source" "$BASE/files/config.json.migrated"
fi

install -d -m 0750 "$DEST_MM"/{data,plugins,client/plugins}

if [ -d "$DEST_MM/data" ] && [ -f "$BASE/files/push_mode.marker" ]; then
  log "Using pre-pushed Mattermost data/plugins"
else
  log "Syncing data and plugins from source (rsync)..."
  if [ "$PUSH_MODE" = "1" ]; then
    echo "Pre-pushed data missing in push mode."; exit 1
  fi
  if [ -n "${SRC_SSH_PASS:-}" ] && command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$SRC_SSH_PASS" rsync -aHAX -e "ssh $SSH_OPTS" --delete "${SRC_SSH_USER}@${SRC_HOST}:${SRC_MM}/data/" "$DEST_MM/data/"
    sshpass -p "$SRC_SSH_PASS" rsync -aHAX -e "ssh $SSH_OPTS" --delete "${SRC_SSH_USER}@${SRC_HOST}:${SRC_MM}/plugins/" "$DEST_MM/plugins/"
    sshpass -p "$SRC_SSH_PASS" rsync -aHAX -e "ssh $SSH_OPTS" --delete "${SRC_SSH_USER}@${SRC_HOST}:${SRC_MM}/client/plugins/" "$DEST_MM/client/plugins/"
  else
    rsync -aHAX -e "ssh $SSH_OPTS" --delete "${SRC_SSH_USER}@${SRC_HOST}:${SRC_MM}/data/" "$DEST_MM/data/"
    rsync -aHAX -e "ssh $SSH_OPTS" --delete "${SRC_SSH_USER}@${SRC_HOST}:${SRC_MM}/plugins/" "$DEST_MM/plugins/"
    rsync -aHAX -e "ssh $SSH_OPTS" --delete "${SRC_SSH_USER}@${SRC_HOST}:${SRC_MM}/client/plugins/" "$DEST_MM/client/plugins/"
  fi
fi

install -m 0640 "$BASE/files/config.json.migrated" "$DEST_MM/config/config.json"
chown -R mattermost:mattermost "$DEST_MM"

log "Starting Mattermost..."
systemctl start mattermost
sleep 2
systemctl --no-pager status mattermost || true
log "Mattermost migration done."
EOF_20

cat > /root/migration/subs/30_redis_migrate.sh <<'EOF_30'
#!/usr/bin/env bash
set -euo pipefail
BASE="/root/migration"
# shellcheck disable=SC1090
source "$BASE/migration.env"

if [ "${MIGRATE_REDIS:-0}" != "1" ]; then echo "Redis migrate disabled."; exit 0; fi

log() { printf "[%s] %s\n" "$(date -Iseconds)" "$*"; }
PUSH_MODE=0
[ -f "$BASE/files/push_mode.marker" ] && PUSH_MODE=1
if [ "$PUSH_MODE" != "1" ]; then
  if [ -n "${SRC_SSH_PASS:-}" ] && command -v sshpass >/dev/null 2>&1; then
    SSH_BASE=(sshpass -p "$SRC_SSH_PASS" ssh $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}")
  else
    SSH_BASE=(ssh $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}")
  fi
fi

apt-get update -y
apt-get install -y redis-server redis-tools

if [ -s "$BASE/files/redis_selected.conf" ]; then
  log "Using pre-pushed Redis selected config."
else
  if [ "$PUSH_MODE" = "1" ]; then
    echo "Pre-pushed redis_selected.conf missing in push mode."; exit 1
  fi
  SRC_REDIS_CONF="$("${SSH_BASE[@]}" 'test -f /etc/redis/redis.conf && echo /etc/redis/redis.conf || (test -f /etc/redis.conf && echo /etc/redis.conf)' )"
  if [ -z "$SRC_REDIS_CONF" ]; then echo "Source redis.conf not found."; exit 1; fi
  log "Fetching selected Redis settings from $SRC_REDIS_CONF..."
  "${SSH_BASE[@]}" "sudo awk '
/^(bind|port|maxmemory|maxmemory-policy|save|appendonly|appendfsync|requirepass|rename-command|aclfile|unixsocket|timeout|tcp-backlog|databases)[[:space:]]/ {print}
/^user[[:space:]]/ {print}
' \"$SRC_REDIS_CONF\"" > "$BASE/files/redis_selected.conf"
fi

# If an ACL file is used, copy it for reference
ACL_FILE="$(awk '\''$1=="aclfile"{print $2}'\'' "$BASE/files/redis_selected.conf" || true)"
if [ -n "$ACL_FILE" ] && [ ! -s "$BASE/files/redis_aclfile.source" ]; then
  if [ "$PUSH_MODE" = "1" ]; then
    log "ACL file referenced ($ACL_FILE) but not pre-pushed; continuing without copying."
  else
    if [ -n "${SRC_SSH_PASS:-}" ] && command -v sshpass >/dev/null 2>&1; then
      sshpass -p "$SRC_SSH_PASS" scp $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}:${ACL_FILE}" "$BASE/files/redis_aclfile.source" || true
    else
      scp $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}:${ACL_FILE}" "$BASE/files/redis_aclfile.source" || true
    fi
  fi
fi

DEST="/etc/redis/redis.conf"
cp -a "$DEST" "$DEST.bak.$(date +%s)"
{
  echo ""
  echo "# ===== BEGIN MIGRATED $(date -Iseconds) ====="
  cat "$BASE/files/redis_selected.conf"
  echo "# ===== END MIGRATED ====="
} >>"$DEST"

systemctl restart redis-server
sleep 1
redis-cli ping || true
log "Redis migration done. If you used an ACL file, review $BASE/files/redis_aclfile.source and configure accordingly."
EOF_30

cat > /root/migration/subs/40_php_opcache_migrate.sh <<'EOF_40'
#!/usr/bin/env bash
set -euo pipefail
BASE="/root/migration"
# shellcheck disable=SC1090
source "$BASE/migration.env"

if [ "${MIGRATE_PHP_OPCACHE:-0}" != "1" ]; then echo "PHP OPcache migrate disabled."; exit 0; fi

log() { printf "[%s] %s\n" "$(date -Iseconds)" "$*"; }
SSH_BASE=(ssh $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}")

log "Collecting opcache.* settings from source..."
"${SSH_BASE[@]}" 'sudo awk "
  BEGIN{IGNORECASE=1}
  /^\s*opcache\./ {print}
" /etc/php.d/*.ini /etc/php.ini /etc/php*/mods-available/opcache.ini 2>/dev/null' > "$BASE/files/opcache.source.ini" || true

# Filter out directives that are obsolete or risky to carry over
grep -E '^\s*opcache\.' "$BASE/files/opcache.source.ini" \
  | grep -Ev 'opcache\.blacklist_filename|opcache\.file_cache' \
  > "$BASE/files/opcache.filtered.ini" || true

DEST_DIR="/opt/plesk/php/${PLESK_PHP_VER}/etc/php.d"
install -d -m 0755 "$DEST_DIR"
DEST_INI="$DEST_DIR/zz-migrated-opcache.ini"

{
  echo "; Migrated from source on $(date -Iseconds)"
  if [ -s "$BASE/files/opcache.filtered.ini" ]; then
    cat "$BASE/files/opcache.filtered.ini"
  else
    # Sensible defaults if none found on source
    cat <<EOF_DEF
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=256
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=100000
opcache.validate_timestamps=1
opcache.revalidate_freq=60
opcache.jit=1255
opcache.jit_buffer_size=64M
EOF_DEF
  fi
} > "$DEST_INI"

systemctl restart "plesk-php${PLESK_PHP_VER//./}-fpm"
"/opt/plesk/php/${PLESK_PHP_VER}/bin/php" -i | grep -i "^opcache.enable" || true
log "OPcache settings written to $DEST_INI"
EOF_40

cat > /root/migration/subs/45_php_relay_install.sh <<'EOF_45'
#!/usr/bin/env bash
set -euo pipefail
BASE="/root/migration"
# shellcheck disable=SC1090
source "$BASE/migration.env"

if [ "${MIGRATE_PHP_RELAY:-0}" != "1" ]; then echo "PHP Relay install disabled."; exit 0; fi

log() { printf "[%s] %s\n" "$(date -Iseconds)" "$*"; }

apt-get update -y
apt-get install -y git build-essential autoconf pkg-config

PHP_BASE="/opt/plesk/php/${PLESK_PHP_VER}"
if [ ! -x "$PHP_BASE/bin/phpize" ]; then
  echo "phpize not found for Plesk PHP ${PLESK_PHP_VER}."; exit 1
fi

cd "$BASE/work"
if [ ! -d relay ]; then
  git clone --depth=1 https://github.com/cachewerk/relay.git
fi
cd relay
"$PHP_BASE/bin/phpize"
./configure --with-php-config="$PHP_BASE/bin/php-config"
make -j"$(nproc)"
make install

INI="$PHP_BASE/etc/php.d/zz-relay.ini"
echo -e "; Migrated\nextension=relay.so" > "$INI"

# Try to import any relay.* ini from source for reference
SSH_BASE=(ssh $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}")
"${SSH_BASE[@]}" 'sudo awk "/^relay\./{print}" /etc/php.ini /etc/php.d/*.ini 2>/dev/null' > "$BASE/files/relay.source.ini" || true
if [ -s "$BASE/files/relay.source.ini" ]; then
  echo -e "\n; ---- Source relay.* (review before enabling) ----" >> "$INI"
  cat "$BASE/files/relay.source.ini" >> "$INI"
fi

systemctl restart "plesk-php${PLESK_PHP_VER//./}-fpm"
"$PHP_BASE/bin/php" -m | grep -i "^relay$" || true
log "Relay extension built and configured for PHP ${PLESK_PHP_VER}. INI: $INI"
EOF_45

cat > /root/migration/subs/50_nginx_customs_migrate.sh <<'EOF_50'
#!/usr/bin/env bash
set -euo pipefail
BASE="/root/migration"
# shellcheck disable=SC1090
source "$BASE/migration.env"

if [ "${MIGRATE_NGINX_GLOBALS:-0}" != "1" ]; then echo "nginx customs migrate disabled."; exit 0; fi

log() { printf "[%s] %s\n" "$(date -Iseconds)" "$*"; }
SSH_BASE=(ssh $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}")

DEST_CONF_D="/etc/nginx/conf.d/migrated"
DEST_SNIPS="/etc/nginx/snippets/migrated"
install -d -m 0755 "$DEST_CONF_D" "$DEST_SNIPS" "/etc/nginx/migration/server_confs"

log "Pulling source snippets and conf.d..."
rsync -a -e "ssh $SSH_OPTS" --include="*/" --include="*.conf" --exclude="*" \
  "${SRC_SSH_USER}@${SRC_HOST}:/etc/nginx/snippets/" "$DEST_SNIPS/" || true

# Fetch conf.d, but separate files containing server{ } blocks for manual review
TMPDIR="$(mktemp -d)"
rsync -a -e "ssh $SSH_OPTS" --include="*/" --include="*.conf" --exclude="*" \
  "${SRC_SSH_USER}@${SRC_HOST}:/etc/nginx/conf.d/" "$TMPDIR/conf.d/" || true

shopt -s nullglob
for f in "$TMPDIR"/conf.d/*.conf; do
  if grep -Eq '^[[:space:]]*server[[:space:]]*\{' "$f"; then
    cp -a "$f" "/etc/nginx/migration/server_confs/"
  else
    cp -a "$f" "$DEST_CONF_D/"
  fi
done
rm -rf "$TMPDIR"

# Do not replace nginx.conf on Plesk. Only additive includes tested below.
plesk sbin nginx_ctl -t
plesk sbin nginx_ctl reload
log "Copied global include files. Any vhost server{} files were parked at /etc/nginx/migration/server_confs for manual review."
EOF_50

cat > /root/migration/subs/60_cron_migrate.sh <<'EOF_60'
#!/usr/bin/env bash
set -euo pipefail
BASE="/root/migration"
# shellcheck disable=SC1090
source "$BASE/migration.env"

log() { printf "[%s] %s\n" "$(date -Iseconds)" "$*"; }
SSH_BASE=(ssh $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}")

CR_BASE="$BASE/files/cron"
install -d -m 0750 "$CR_BASE/src" "$CR_BASE/build"

if [ "${MIGRATE_CRONS_PREPARE:-0}" = "1" ]; then
  log "Fetching crontabs and cron.d from source..."
  "${SSH_BASE[@]}" 'sudo tar -C / -czf - var/spool/cron etc/cron.d etc/cron.daily etc/cron.weekly etc/cron.hourly etc/crontab etc/anacrontab 2>/dev/null || true' > "$CR_BASE/cron_src.tgz" || true
  tar -C "$CR_BASE/src" -xzf "$CR_BASE/cron_src.tgz" || true

  # Build user map template
  SRC_USERS="$(ls -1 "$CR_BASE/src/var/spool/cron" 2>/dev/null || true)"
  MAP="$CR_BASE/cron_user_map.tsv"
  if [ ! -s "$MAP" ]; then
    : > "$MAP"
    for u in $SRC_USERS; do echo -e "${u}\troot" >> "$MAP"; done
  fi

  cat > "$CR_BASE/README.txt" <<EOF
Review cron_user_map.tsv and adjust mappings from old usernames to target usernames.
Then re-run this sub-script with MIGRATE_CRONS_APPLY=1 in migration.env to activate.
Cron lines will be created under /etc/cron.d/migrated_<user>.
EOF

  log "Prepared cron materials at $CR_BASE. Review cron_user_map.tsv before apply."
fi

if [ "${MIGRATE_CRONS_APPLY:-0}" = "1" ]; then
  MAP="$CR_BASE/cron_user_map.tsv"
  if [ ! -s "$MAP" ]; then echo "Missing $MAP"; exit 1; fi

  while IFS=$'\t' read -r OLD NEW; do
    [ -z "$OLD" ] && continue
    SRC_FILE="$CR_BASE/src/var/spool/cron/$OLD"
    [ -f "$SRC_FILE" ] || continue
    OUT="/etc/cron.d/migrated_${OLD}"
    {
      echo "SHELL=/bin/bash"
      echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      # Convert each active line to cron.d format: m h dom mon dow USER command
      awk -v U="$NEW" '
        /^\s*#/ {print; next}
        /^\s*$/ {print; next}
        /^[A-Za-z_][A-Za-z0-9_]*=/{print; next}
        {
          m=$1; h=$2; dom=$3; mon=$4; dow=$5;
          $1=$2=$3=$4=$5="";
          sub(/^[ \t]+/, "", $0);
          print m" "h" "dom" "mon" "dow" "U" " " $0
        }
      ' "$SRC_FILE"
    } > "$OUT"
    chmod 0644 "$OUT"
  done < <(grep -v '^[[:space:]]*$' "$MAP")

  systemctl reload cron || systemctl reload crond || true
  log "Cron jobs written under /etc/cron.d/migrated_* . Verify and monitor."
fi
EOF_60

chmod +x /root/migration/migrate_services.sh /root/migration/subs/*.sh

# Optional remote autostart to make running from OLD seamless
if [ -n "${RMT_AUTOSTART:-}" ]; then
  case "${RMT_AUTOSTART}" in
    list)
      /root/migration/migrate_services.sh list || true ;;
    run-all)
      /root/migration/migrate_services.sh run-all || true ;;
    run:*)
      target="${RMT_AUTOSTART#run:}"
      /root/migration/migrate_services.sh run "$target" || true ;;
    *)
      echo "Unknown --autostart value: ${RMT_AUTOSTART}. Skipping." ;;
  esac
  # Clean up any temporary source identity key
  if [ -f /root/migration/src_ssh_key ]; then
    shred -u /root/migration/src_ssh_key 2>/dev/null || rm -f /root/migration/src_ssh_key
  fi
else
  echo "Created on NEW host." 
  echo "You can run: /root/migration/migrate_services.sh run-all"
fi
