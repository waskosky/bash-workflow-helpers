#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
PLESK_AUTO_SETUP="${PLESK_AUTO_SETUP:-false}"

# Persistent config (saved defaults)
XDG_CONFIG_HOME_DEFAULT="${HOME}/.config"
CONFIG_DIR="${XDG_CONFIG_HOME:-$XDG_CONFIG_HOME_DEFAULT}/migrate-sql-site-plesk"
CONFIG_FILE="${CONFIG_FILE:-${CONFIG_DIR}/defaults.env}"

ensure_config_dir() { mkdir -p "${CONFIG_DIR}"; chmod 700 "${CONFIG_DIR}" 2>/dev/null || true; }
load_config() {
  ensure_config_dir
  if [ -f "${CONFIG_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${CONFIG_FILE}"
  fi
}
_sh_escape() { printf %s "$1" | sed -e "s/'/'\\''/g"; }
save_config() {
  ensure_config_dir
  tmp="${CONFIG_FILE}.tmp$$"
  {
    echo "# Saved by ${SCRIPT_NAME} on $(date '+%Y-%m-%d %H:%M:%S')"
    # Core hosts/users/ports
    echo "OLD_HOST='$(
      _sh_escape "${OLD_HOST:-}")'"
    echo "OLD_USER='$( _sh_escape "${OLD_USER:-}")'"
    echo "OLD_SSH_PORT='$( _sh_escape "${OLD_SSH_PORT:-}")'"
    echo "OLD_SSH_KEY_PATH='$( _sh_escape "${OLD_SSH_KEY_PATH:-}")'"
    echo "OLD_SSH_PASSWORD='$( _sh_escape "${OLD_SSH_PASSWORD:-}")'"
    echo "OLD_WEB_ROOT='$( _sh_escape "${OLD_WEB_ROOT:-}")'"

    echo "NEW_HOST='$( _sh_escape "${NEW_HOST:-}")'"
    echo "NEW_USER='$( _sh_escape "${NEW_USER:-}")'"
    echo "NEW_SSH_PORT='$( _sh_escape "${NEW_SSH_PORT:-}")'"
    echo "NEW_SSH_KEY_PATH='$( _sh_escape "${NEW_SSH_KEY_PATH:-}")'"
    echo "NEW_SSH_PASSWORD='$( _sh_escape "${NEW_SSH_PASSWORD:-}")'"
    echo "NEW_WEB_ROOT='$( _sh_escape "${NEW_WEB_ROOT:-}")'"

    # DB connection
    echo "OLD_DB_HOST='$( _sh_escape "${OLD_DB_HOST:-}")'"
    echo "OLD_DB_USER='$( _sh_escape "${OLD_DB_USER:-}")'"
    echo "OLD_DB_PASS='$( _sh_escape "${OLD_DB_PASS:-}")'"
    echo "NEW_DB_HOST='$( _sh_escape "${NEW_DB_HOST:-}")'"
    echo "NEW_DB_USER='$( _sh_escape "${NEW_DB_USER:-}")'"
    echo "NEW_DB_PASS='$( _sh_escape "${NEW_DB_PASS:-}")'"

    # Plesk
    echo "PLESK_DOMAIN='$( _sh_escape "${PLESK_DOMAIN:-}")'"
    echo "PLESK_OWNER='$( _sh_escape "${PLESK_OWNER:-}")'"
    echo "PLESK_SERVICE_PLAN='$( _sh_escape "${PLESK_SERVICE_PLAN:-}")'"
    echo "PLESK_IP_ADDR='$( _sh_escape "${PLESK_IP_ADDR:-}")'"
    echo "PLESK_SYSTEM_USER='$( _sh_escape "${PLESK_SYSTEM_USER:-}")'"
    echo "PLESK_SYSTEM_PASS='$( _sh_escape "${PLESK_SYSTEM_PASS:-}")'"
    echo "PLESK_DOCROOT_REL='$( _sh_escape "${PLESK_DOCROOT_REL:-}")'"
    echo "PLESK_DB_SERVER='$( _sh_escape "${PLESK_DB_SERVER:-}")'"
    echo "PLESK_DB_TYPE='$( _sh_escape "${PLESK_DB_TYPE:-}")'"
    echo "PLESK_VHOSTS_ROOT='$( _sh_escape "${PLESK_VHOSTS_ROOT:-}")'"

    # Misc
    echo "ASSETS_DIR='$( _sh_escape "${ASSETS_DIR:-}")'"
    echo "OLD_URL='$( _sh_escape "${OLD_URL:-}")'"
    echo "NEW_URL='$( _sh_escape "${NEW_URL:-}")'"
    echo "OLD_PATH='$( _sh_escape "${OLD_PATH:-}")'"
    echo "NEW_PATH='$( _sh_escape "${NEW_PATH:-}")'"
    echo "RSYNC_NEW_USER='$( _sh_escape "${RSYNC_NEW_USER:-}")'"
    echo "RSYNC_EXCLUDES='$( _sh_escape "${RSYNC_EXCLUDES:-}")'"
    echo "DB_COMPRESS='$( _sh_escape "${DB_COMPRESS:-}")'"
    echo "MODE='$( _sh_escape "${MODE:-}")'"
    echo "MAINTENANCE='$( _sh_escape "${MAINTENANCE:-}")'"
    # DB list as a single string
    echo "DB_LIST='$( _sh_escape "${DB_LIST[*]:-}")'"
  } >"${tmp}"
  chmod 600 "${tmp}" 2>/dev/null || true
  mv -f "${tmp}" "${CONFIG_FILE}"
}

# Behavior toggles and advanced options (overridable via env or flags)
MODE="${MODE:-auto}"                 # auto|wordpress|generic
SKIP_CODE="${SKIP_CODE:-false}"
SKIP_ASSETS="${SKIP_ASSETS:-false}"
SKIP_DB="${SKIP_DB:-false}"
DRY_RUN="${DRY_RUN:-false}"
DB_COMPRESS="${DB_COMPRESS:-auto}"   # auto|lz4|gzip|none
MAINTENANCE="${MAINTENANCE:-prompt}" # prompt|true|false
WPCLI_ENSURE="${WPCLI_ENSURE:-true}" # ensure wp-cli availability on NEW when mode=wordpress
WP_SEARCH_REPLACE="${WP_SEARCH_REPLACE:-auto}" # auto|true|false
# Where this script is running from: auto|old
ORIGIN_MODE="${ORIGIN_MODE:-auto}"
# Transfer strategy: direct (default), stage (local staging), stream (tar over SSH; no delete)
TRANSFER_MODE="${TRANSFER_MODE:-direct}"
RSYNC_NEW_USER="${RSYNC_NEW_USER:-}" # override NEW_USER used for rsync/upload
RSYNC_EXCLUDES="${RSYNC_EXCLUDES:-.git node_modules vendor cache logs tmp}"
START_STEP="${START_STEP:-1}"
DB_EXCLUDE_TABLES=(${DB_EXCLUDE_TABLES:-})

# Extra client options for huge dumps/imports
MYSQLDUMP_OPTS_DEFAULT=(--single-transaction --quick --routines --triggers --events --no-tablespaces --default-character-set=utf8mb4 --column-statistics=0)
MYSQLDUMP_OPTS_EXTRA=(${MYSQLDUMP_OPTS_EXTRA:-})
MYSQL_IMPORT_OPTS_DEFAULT=(--max_allowed_packet=1G --net_buffer_length=1048576)
MYSQL_IMPORT_OPTS_EXTRA=(${MYSQL_IMPORT_OPTS_EXTRA:-})

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Common options:
  --plesk-setup                 Auto-provision Plesk subscription + DB metadata on NEW.
  --mode <auto|wordpress|generic>
                                Special handling for WordPress (auto detects wp-config.php).
  --skip-code                   Skip code rsync steps.
  --skip-assets                 Skip assets rsync steps.
  --skip-db                     Skip database migration.
  --only-db                     Shortcut for --skip-code --skip-assets
  --db-compress <auto|lz4|gzip|none>
                                Compress DB stream (auto prefers lz4, then gzip).
  --maintenance                 Put source WordPress in maintenance during DB dump.
  --no-maintenance              Do not use maintenance even for WordPress.
  --rsync-new-user <user>       Use this user for rsync to NEW (defaults to NEW_USER).
  --no-wp-cli                   Do not auto-install wp-cli on NEW.
  --no-search-replace           Skip WordPress search-replace (serialized safe).
  --transfer-mode <direct|stage|stream>
                                Transfer strategy. direct (default) = rsync runs on NEW pulling from OLD,
                                stage = local staging on this machine,
                                stream = tar over SSH via local, no delete.
  --from-old                    Force run-from-OLD mode (script is running on the OLD server).
  --start-step <N>              Start at STEP number N (skips earlier steps). See logs for step numbers.
  --exclude-table <db.tbl|tbl>  Repeatable. Exclude table(s) from dump (prefix with DB or omit to apply per-DB).
  --old-user <user>             SSH username for OLD host (overrides OLD_USER).
  --new-user <user>             SSH username for NEW host (overrides NEW_USER).
  --old-pass <password>         SSH password for OLD host (overrides OLD_SSH_PASSWORD).
  --new-pass <password>         SSH password for NEW host (overrides NEW_SSH_PASSWORD).
  --dry-run                     Print actions without making changes.
  -h, --help                    Show this message.

Defaults persist to: ${CONFIG_FILE}
You can also edit variables near the top or set env vars to match your environment.
EOF
}

# Load saved defaults before parsing flags so flags override them
load_config

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plesk-setup) PLESK_AUTO_SETUP=true; shift ;;
    --mode) MODE="$2"; shift 2 ;;
    --skip-code) SKIP_CODE=true; shift ;;
    --skip-assets) SKIP_ASSETS=true; shift ;;
    --skip-db) SKIP_DB=true; shift ;;
    --only-db) SKIP_CODE=true; SKIP_ASSETS=true; shift ;;
    --db-compress) DB_COMPRESS="$2"; shift 2 ;;
    --maintenance) MAINTENANCE=true; shift ;;
    --no-maintenance) MAINTENANCE=false; shift ;;
    --rsync-new-user) RSYNC_NEW_USER="$2"; shift 2 ;;
    --no-wp-cli) WPCLI_ENSURE=false; shift ;;
    --no-search-replace) WP_SEARCH_REPLACE=false; shift ;;
    --transfer-mode) TRANSFER_MODE="$2"; shift 2 ;;
    --from-old) ORIGIN_MODE="old"; shift ;;
    --start-step) START_STEP="$2"; shift 2 ;;
    --exclude-table)
      DB_EXCLUDE_TABLES+=("$2"); shift 2 ;;
    --old-user) OLD_USER="$2"; shift 2 ;;
    --new-user) NEW_USER="$2"; shift 2 ;;
    --old-pass) OLD_SSH_PASSWORD="$2"; shift 2 ;;
    --new-pass) NEW_SSH_PASSWORD="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *) break ;;
  esac
done

# ---------- EDIT THESE ----------
# Hosts, users, ports, and paths
OLD_HOST="${OLD_HOST:-old.example.com}"
OLD_USER="${OLD_USER:-ubuntu}"
OLD_SSH_PORT=${OLD_SSH_PORT:-22}

NEW_HOST="${NEW_HOST:-new.example.com}"
NEW_USER="${NEW_USER:-ubuntu}"
NEW_SSH_PORT=${NEW_SSH_PORT:-22}

OLD_WEB_ROOT="${OLD_WEB_ROOT:-/var/www/site}"
NEW_WEB_ROOT="${NEW_WEB_ROOT:-}" # leave empty to auto-detect from Plesk subscription docroot

# SSH authentication (leave blank to be prompted or use ssh-agent defaults)
OLD_SSH_KEY_PATH="${OLD_SSH_KEY_PATH:-}"
OLD_SSH_PASSWORD="${OLD_SSH_PASSWORD:-}"
NEW_SSH_KEY_PATH="${NEW_SSH_KEY_PATH:-}"
NEW_SSH_PASSWORD="${NEW_SSH_PASSWORD:-}"

# Plesk subscription + database defaults (used only when --plesk-setup is supplied)
PLESK_DOMAIN="${PLESK_DOMAIN:-example.com}"
PLESK_OWNER="${PLESK_OWNER:-admin}"
PLESK_SERVICE_PLAN="${PLESK_SERVICE_PLAN:-Default Domain}"
PLESK_IP_ADDR="${PLESK_IP_ADDR:-203.0.113.10}"
PLESK_SYSTEM_USER="${PLESK_SYSTEM_USER:-siteuser}"
PLESK_SYSTEM_PASS="${PLESK_SYSTEM_PASS:-changeme}"
PLESK_DOCROOT_REL="${PLESK_DOCROOT_REL:-httpdocs}" # relative to /var/www/vhosts/<domain>/
PLESK_DB_SERVER="${PLESK_DB_SERVER:-localhost}"
PLESK_DB_TYPE="${PLESK_DB_TYPE:-mysql}"
PLESK_VHOSTS_ROOT="${PLESK_VHOSTS_ROOT:-/var/www/vhosts}" # fallback base path if docroot detection needs it

# Uploaded assets directory relative to the web root (auto-changed for WordPress)
ASSETS_DIR="${ASSETS_DIR:-public/uploads}"

# MySQL on OLD
OLD_DB_HOST="${OLD_DB_HOST:-127.0.0.1}"
OLD_DB_USER="${OLD_DB_USER:-appuser}"
OLD_DB_PASS="${OLD_DB_PASS:-oldpass}"

# MySQL on NEW
NEW_DB_HOST="${NEW_DB_HOST:-127.0.0.1}"
NEW_DB_USER="${NEW_DB_USER:-appuser}"
NEW_DB_PASS="${NEW_DB_PASS:-newpass}"

# Databases to migrate (space-separated)
DB_LIST=(${DB_LIST:-appdb analyticsdb})

# Optional replacements across text columns and config files
# If OLD_* equals NEW_*, the script skips that replacement.
OLD_URL="${OLD_URL:-https://example.com}"
NEW_URL="${NEW_URL:-https://example.com}"
OLD_PATH="${OLD_PATH:-${OLD_WEB_ROOT}}"
NEW_PATH="${NEW_PATH:-${NEW_WEB_ROOT}}"

# Local staging directory (used only when TRANSFER_MODE=stage)
STAGE_DIR="${STAGE_DIR:-${HOME}/.migrate_stage_$(date +%s)}"

# Structured log destination (set to empty string to disable)
LOG_FILE="${LOG_FILE:-${HOME}/migrate-sql-site-plesk-$(date +%Y%m%d-%H%M%S).jsonl}"
# ---------- END EDITS ----------

# ---------- logging ----------
if [ -n "${LOG_FILE}" ]; then
  mkdir -p "$(dirname "${LOG_FILE}")"
  : > "${LOG_FILE}"
fi

TS() { date '+%Y-%m-%d %H:%M:%S'; }
LINE() { printf '%*s\n' "$(tput cols 2>/dev/null || echo 80)" '' | tr ' ' '='; }
json_escape() {
  local str="$1"
  str="${str//\\/\\\\}"
  str="${str//\"/\\\"}"
  str="${str//$'\n'/\\n}"
  str="${str//$'\r'/\\r}"
  str="${str//$'\t'/\\t}"
  printf '%s' "$str"
}
log_structured() {
  [ -z "${LOG_FILE}" ] && return 0
  local level="$1"; shift
  local message="$1"; shift
  local meta="${1:-}"
  local ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local payload="{\"ts\":\"${ts}\",\"level\":\"${level}\",\"message\":\"$(json_escape "$message")\""
  if [ -n "$meta" ]; then
    payload="${payload},\"meta\":${meta}"
  fi
  printf '%s}\n' "$payload" >> "${LOG_FILE}"
}

STEP_N=0
STEP() {
  STEP_N=$((STEP_N+1))
  local msg="STEP ${STEP_N}: $*"
  echo; LINE; echo "[$(TS)] ${msg}"; LINE;
  log_structured "STEP" "$msg" "{\"step\":${STEP_N}}"
}
INFO() { echo "[$(TS)] $*"; log_structured "INFO" "$*"; }
WARN() { echo "[$(TS)] WARN: $*" >&2; log_structured "WARN" "$*"; }
ERR()  { echo "[$(TS)] ERROR: $*" >&2; log_structured "ERROR" "$*"; }

run() {
  if [ "${DRY_RUN}" = "true" ]; then
    INFO "DRY-RUN: $*"
    return 0
  fi
  eval "$@"
}

# ---------- interactive configuration ----------
require_tty_for_prompt() {
  if [ ! -t 0 ]; then
    ERR "Interactive input required to set ${1}. Edit the script or export ${1} before running non-interactively."
    exit 1
  fi
}

prompt_var() {
  local var="$1"; shift
  local prompt="$1"; shift || true
  local current="${!var:-}"
  require_tty_for_prompt "${var}"
  read -rp "${prompt} [${current}]: " value || true
  [ -z "${value}" ] && value="${current}"
  printf -v "${var}" '%s' "${value}"
}

prompt_secret() {
  local var="$1"; shift
  local prompt="$1"; shift || true
  local current="${!var:-}"
  require_tty_for_prompt "${var}"
  local shown
  shown=$( [ -n "$current" ] && echo saved || echo empty )
  read -rsp "${prompt} [${shown}]: " value || true; echo
  [ -z "${value}" ] && value="${current}"
  printf -v "${var}" '%s' "${value}"
}

prompt_db_list() {
  local prompt="$1"
  local default_str
  default_str="${DB_LIST[*]:-}"
  require_tty_for_prompt "DB_LIST"
  read -rp "${prompt} [${default_str}]: " value || true
  value="${value:-${default_str}}"
  read -ra DB_LIST <<< "$value"
}

prompt_if_default() {
  local var="$1" default="$2" prompt="$3" secret="${4:-false}"
  local current="${!var}"
  if [ "${current}" != "${default}" ]; then
    return
  fi
  require_tty_for_prompt "${var}"
  while true; do
    local value confirm
    if [ "${secret}" = "true" ]; then
      read -rsp "${prompt}: " value; echo
    else
      read -rp "${prompt} [${default}]: " value
    fi
    if [ -z "${value}" ]; then
      value="${current}"
    fi
    if [ "${value}" = "${default}" ]; then
      read -rp "Value for ${var} is still default. Use it anyway? [y/N]: " confirm
      if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        continue
      fi
    fi
    printf -v "${var}" '%s' "${value}"
    break
  done
}

prompt_if_empty() {
  local var="$1" prompt="$2" secret="${3:-false}" default_val="${4:-}"
  local current="${!var:-}"
  [ -n "${current}" ] && return
  require_tty_for_prompt "${var}"
  while true; do
    local value
    if [ "${secret}" = "true" ]; then
      read -rsp "${prompt}${default_val:+ [${default_val}]}: " value; echo
    else
      read -rp "${prompt}${default_val:+ [${default_val}]}: " value
    fi
    value="${value:-${default_val}}"
    if [ -z "${value}" ]; then
      WARN "${var} cannot be empty."
      continue
    fi
    printf -v "${var}" '%s' "${value}"
    break
  done
}

prompt_db_list_if_default() {
  local default="$1" prompt="$2"
  local current="${DB_LIST[*]}"
  current="${current#"${current%%[![:space:]]*}"}"
  current="${current%"${current##*[![:space:]]}"}"
  [ -z "${current}" ] && current="${default}"
  if [ "${current}" != "${default}" ]; then
    return
  fi
  require_tty_for_prompt "DB_LIST"
  while true; do
    local value confirm
    read -rp "${prompt} [${default}]: " value
    if [ -z "${value}" ]; then
      value="${current}"
    fi
    if [ "${value}" = "${default}" ]; then
      read -rp "Use default database list '${default}'? [y/N]: " confirm
      if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        continue
      fi
    fi
    read -ra DB_LIST <<< "${value}"
    break
  done
}

prompt_ssh_auth() {
  local prefix="$1"
  local host_var="${prefix}_HOST"
  local user_var="${prefix}_USER"
  local key_var="${prefix}_SSH_KEY_PATH"
  local pass_var="${prefix}_SSH_PASSWORD"
  local current_key="${!key_var:-}"
  local current_pass="${!pass_var:-}"

  if [ -n "${current_key}" ] || [ -n "${current_pass}" ]; then
    return
  fi
  require_tty_for_prompt "${prefix}_SSH_AUTH"

  local default_choice="d"
  local prompt="SSH auth for ${!user_var}@${!host_var} - [k]ey file, [p]assword, [d]efault/agent"
  while true; do
    local choice value
    read -rp "${prompt} [${default_choice}]: " choice
    choice="${choice:-${default_choice}}"
    case "${choice}" in
      [Kk])
        read -rp "SSH key path for ${prefix} host [${HOME}/.ssh/id_rsa]: " value
        value="${value:-${HOME}/.ssh/id_rsa}"
        if [ ! -f "${value}" ]; then
          WARN "Key file '${value}' not found. Try again."
          continue
        fi
        printf -v "${key_var}" '%s' "${value}"
        printf -v "${pass_var}" '%s' ""
        break
        ;;
      [Pp])
        read -rsp "SSH password for ${prefix} host (${!user_var}@${!host_var}): " value; echo
        if [ -z "${value}" ]; then
          WARN "Password cannot be empty."
          continue
        fi
        printf -v "${pass_var}" '%s' "${value}"
        printf -v "${key_var}" '%s' ""
        break
        ;;
      [Dd])
        printf -v "${key_var}" '%s' ""
        printf -v "${pass_var}" '%s' ""
        break
        ;;
      *)
        WARN "Invalid choice '${choice}'. Enter k, p, or d."
        ;;
    esac
  done
}

describe_ssh_auth() {
  local prefix="$1"
  local key_var="${prefix}_SSH_KEY_PATH"
  local pass_var="${prefix}_SSH_PASSWORD"
  if [ -n "${!pass_var:-}" ]; then
    echo "password"
  elif [ -n "${!key_var:-}" ]; then
    echo "key: ${!key_var}"
  else
    echo "agent/default"
  fi
}

# ---------- gather config ----------
if [ -t 0 ]; then
  prompt_var OLD_HOST "Source host (OLD_HOST)"
  prompt_var OLD_USER "Source SSH user (OLD_USER)"
  prompt_var OLD_SSH_PORT "Source SSH port (OLD_SSH_PORT)"
  prompt_var NEW_HOST "Destination host (NEW_HOST)"
  prompt_var NEW_USER "Destination SSH user (NEW_USER)"
  prompt_var NEW_SSH_PORT "Destination SSH port (NEW_SSH_PORT)"
  prompt_var OLD_WEB_ROOT "Source web root absolute path (OLD_WEB_ROOT)"
  prompt_var PLESK_DOMAIN "Plesk domain name (PLESK_DOMAIN)"
  prompt_var PLESK_IP_ADDR "IPv4 address for subscription (PLESK_IP_ADDR)"
  prompt_var PLESK_SYSTEM_USER "System user for subscription (PLESK_SYSTEM_USER)"
  prompt_secret PLESK_SYSTEM_PASS "System user password (PLESK_SYSTEM_PASS)"
  prompt_var OLD_DB_HOST "Source MySQL host (OLD_DB_HOST)"
  prompt_var OLD_DB_USER "Source MySQL user (OLD_DB_USER)"
  prompt_secret OLD_DB_PASS "Source MySQL password (OLD_DB_PASS)"
  prompt_var NEW_DB_HOST "Destination MySQL host (NEW_DB_HOST)"
  prompt_var NEW_DB_USER "Destination MySQL user (NEW_DB_USER)"
  prompt_secret NEW_DB_PASS "Destination MySQL password (NEW_DB_PASS)"
  prompt_db_list "Databases to migrate (space-separated)"
  prompt_var ASSETS_DIR "Assets directory relative to web root (ASSETS_DIR)"
  prompt_var OLD_URL "Old site URL (OLD_URL)"
  prompt_var NEW_URL "New site URL (NEW_URL)"
  prompt_ssh_auth "OLD"
  prompt_ssh_auth "NEW"
  # Save all to persistent defaults
  save_config
fi

# If not using Plesk auto-setup and NEW_WEB_ROOT is empty, prompt for it now
if [ "${PLESK_AUTO_SETUP}" != "true" ] && [ -z "${NEW_WEB_ROOT}" ]; then
  prompt_if_empty "NEW_WEB_ROOT" "Destination web root absolute path (NEW_WEB_ROOT)" false "/var/www/vhosts/${PLESK_DOMAIN}/httpdocs"
  # Save updated NEW_WEB_ROOT as well
  if [ -t 0 ]; then save_config; fi
fi

SECONDS=0
tic() { date +%s; }
toc() { local s="$1"; echo "$(( $(date +%s) - s ))s"; }

# ---------- helpers ----------
io_wrap() { if command -v ionice >/dev/null 2>&1; then echo "ionice -c2 -n7 nice -n 19"; else echo "nice -n 19"; fi; }
pv_or_cat() { if command -v pv >/dev/null 2>&1; then echo "pv -brat"; else echo "cat"; fi; }

SSH_CTL_DIR="${HOME}/.ssh/ctl-mux"
mkdir -p "${SSH_CTL_DIR}"; chmod 700 "${SSH_CTL_DIR}"

# Detect whether we're running on the OLD host
RUN_FROM="other"
if [ "${ORIGIN_MODE}" = "old" ]; then
  RUN_FROM="old"
else
  # auto-detect: compare OLD_HOST addresses with local addresses
  if command -v ip >/dev/null 2>&1 && command -v getent >/dev/null 2>&1; then
    mapfile -t _local_ips < <(ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1)
    mapfile -t _old_ips < <(getent ahosts "${OLD_HOST}" | awk '{print $1}' | sort -u)
    for li in "${_local_ips[@]}" 127.0.0.1; do
      for oi in "${_old_ips[@]}" ::1; do
        if [ -n "$li" ] && [ -n "$oi" ] && [ "$li" = "$oi" ]; then RUN_FROM="old"; break 2; fi
      done
    done
  fi
fi

# If still unknown and interactive, ask the user
if [ "${RUN_FROM}" != "old" ] && [ "${ORIGIN_MODE}" = "auto" ] && [ -t 0 ]; then
  read -rp "Are you running this script on the OLD source server? [Y/n]: " _yn
  _yn=${_yn:-y}
  if [[ "${_yn}" =~ ^[Yy]$ ]]; then RUN_FROM="old"; fi
fi

# ---------- transfer helpers ----------
rsync_direct_pull_from_old_to_new_code() {
  # Runs rsync ON NEW host, pulling code (excludes assets) from OLD into NEW_WEB_ROOT
  INFO "Running direct rsync on NEW pulling code from OLD (excludes assets)."
  # Pre-escape password for remote if provided
  local pass_esc=""
  if [ -n "${OLD_SSH_PASSWORD:-}" ]; then
    pass_esc=$(printf "%s" "${OLD_SSH_PASSWORD}" | sed -e "s/'/'\\''/g")
  fi
  ssh -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" 'bash -s' <<REMOTE
set -euo pipefail
PASS_ESC='${pass_esc}'
RSYNC_DRY="${RSYNC_DRY}"
ASSETS_DIR="${ASSETS_DIR}"
OLD_USER="${OLD_USER}"; OLD_HOST="${OLD_HOST}"; OLD_WEB_ROOT="${OLD_WEB_ROOT%/}"; OLD_SSH_PORT="${OLD_SSH_PORT}"
NEW_WEB_ROOT="${NEW_WEB_ROOT%/}"
RSYNC_EXCLUDES_LIST="${RSYNC_EXCLUDES}"
if ! command -v rsync >/dev/null 2>&1; then
  echo "rsync missing on NEW host" >&2
  exit 1
fi
EXCLUDES=()
for x in ${RSYNC_EXCLUDES_LIST:-}; do EXCLUDES+=(--exclude="$x"); done
EXCLUDES+=(--exclude="${ASSETS_DIR}")
SSHPASS_PRE=""
if [ -n "${PASS_ESC}" ]; then
  if command -v sshpass >/dev/null 2>&1; then
    SSHPASS_PRE="sshpass -p '${PASS_ESC}' "
  else
    echo "OLD_SSH_PASSWORD set but sshpass missing on NEW" >&2
    exit 1
  fi
fi
eval ${SSHPASS_PRE} rsync -azh \
  ${RSYNC_DRY} --delete --stats --info=progress2 --human-readable \
  -e "ssh -p ${OLD_SSH_PORT}" \
  "\${EXCLUDES[@]}" \
  "${OLD_USER}@${OLD_HOST}:${OLD_WEB_ROOT}/" \
  "${NEW_WEB_ROOT}/"
REMOTE
}

rsync_direct_pull_from_old_to_new_assets() {
  INFO "Running direct rsync on NEW pulling assets from OLD."
  local pass_esc=""
  if [ -n "${OLD_SSH_PASSWORD:-}" ]; then
      pass_esc=$(printf "%s" "${OLD_SSH_PASSWORD}" | sed -e "s/'/'\\''/g")
  fi
  ssh -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" 'bash -s' <<REMOTE
set -euo pipefail
PASS_ESC='${pass_esc}'
RSYNC_DRY="${RSYNC_DRY}"; ASSETS_DIR="${ASSETS_DIR%/}"; NEW_WEB_ROOT="${NEW_WEB_ROOT%/}"
OLD_USER="${OLD_USER}"; OLD_HOST="${OLD_HOST}"; OLD_WEB_ROOT="${OLD_WEB_ROOT%/}"; OLD_SSH_PORT="${OLD_SSH_PORT}"
if ! command -v rsync >/dev/null 2>&1; then
  echo "rsync missing on NEW host" >&2
  exit 1
fi
SSHPASS_PRE=""
if [ -n "${PASS_ESC}" ]; then
  if command -v sshpass >/dev/null 2>&1; then
    SSHPASS_PRE="sshpass -p '${PASS_ESC}' "
  else
    echo "OLD_SSH_PASSWORD set but sshpass missing on NEW" >&2
    exit 1
  fi
fi
mkdir -p "${NEW_WEB_ROOT}/${ASSETS_DIR}"
eval ${SSHPASS_PRE} rsync -azh \
  ${RSYNC_DRY} --delete --stats --info=progress2 --human-readable \
  -e "ssh -p ${OLD_SSH_PORT}" \
  "${OLD_USER}@${OLD_HOST}:${OLD_WEB_ROOT}/${ASSETS_DIR}/" \
  "${NEW_WEB_ROOT}/${ASSETS_DIR}/"
REMOTE
}

# When running on OLD, push directly to NEW (no staging)
rsync_push_code_from_old_to_new() {
  INFO "Pushing code from OLD to NEW via rsync (delete)."
  EXCLUDES=()
  for x in ${RSYNC_EXCLUDES}; do EXCLUDES+=(--exclude="$x"); done
  EXCLUDES+=(--exclude="${ASSETS_DIR}")
  rsync -azh ${RSYNC_DRY} --delete --stats --info=progress2 --human-readable \
    "${EXCLUDES[@]}" \
    -e "ssh -S ${SSH_CTL_DIR}/new -p ${NEW_SSH_PORT}" \
    "${OLD_WEB_ROOT%/}/" \
    "${RSYNC_USER_NEW_EFFECTIVE}@${NEW_HOST}:${NEW_WEB_ROOT%/}/"
}

rsync_push_assets_from_old_to_new() {
  INFO "Pushing assets from OLD to NEW via rsync (delete)."
  rsync -azh ${RSYNC_DRY} --delete --stats --info=progress2 --human-readable \
    -e "ssh -S ${SSH_CTL_DIR}/new -p ${NEW_SSH_PORT}" \
    "${OLD_WEB_ROOT%/}/${ASSETS_DIR%/}/" \
    "${RSYNC_USER_NEW_EFFECTIVE}@${NEW_HOST}:${NEW_WEB_ROOT%/}/${ASSETS_DIR%/}/"
}

tar_stream_copy() {
  # tar from OLD to NEW via stream. Args: SRC_DIR DEST_DIR [EXCLUDE_PATTERNS...]
  local src_dir="$1"; shift
  local dest_dir="$1"; shift
  local tar_excludes=("$@")
  INFO "Streaming tar from OLD:${src_dir} to NEW:${dest_dir} (no delete)."
  local EXCL
  EXCL="${tar_excludes[*]}"
  local PV
  PV=$(pv_or_cat)
  if [ "${RUN_FROM}" = "old" ]; then
    # Local tar on OLD → ssh NEW
    local exargs=()
    for pat in ${EXCL}; do [ -n "$pat" ] && exargs+=(--exclude="$pat"); done
    tar -C "${src_dir%/}" -cpf - "${exargs[@]}" . \
      | ${PV} \
      | ssh -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" \
          DEST="${dest_dir%/}" 'bash -s' <<'REMOTE2'
set -euo pipefail
mkdir -p "$DEST"
tar -C "$DEST" -xpf -
REMOTE2
  else
    # Remote tar on OLD → ssh NEW
  ssh -S "${SSH_CTL_DIR}/old" -p "${OLD_SSH_PORT}" "${OLD_USER}@${OLD_HOST}" 'bash -s' <<REMOTE | \
  ${PV} | \
  ssh -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" 'bash -s' <<REMOTE2
set -euo pipefail
SRC="${src_dir%/}"; EXCL_LIST="${EXCL}"
declare -a exargs=()
for pat in ${EXCL_LIST:-}; do [ -n "\$pat" ] && exargs+=(--exclude="\$pat"); done
tar -C "\$SRC" -cpf - "\${exargs[@]}" .
REMOTE
set -euo pipefail
DEST="${dest_dir%/}"
mkdir -p "\$DEST"
tar -C "\$DEST" -xpf -
REMOTE2
  fi
}

open_master() { # name user host port
  local name="$1" user="$2" host="$3" port="$4"
  local prefix="${name^^}"
  local key_var="${prefix}_SSH_KEY_PATH"
  local pass_var="${prefix}_SSH_PASSWORD"
  local identity="${!key_var:-}"
  local password="${!pass_var:-}"

  INFO "Opening SSH master to ${user}@${host}:${port} (you may be prompted)."
  local ssh_base=(ssh -fN
    -o ControlMaster=auto
    -o ControlPersist=600
    -o StrictHostKeyChecking=accept-new
    -S "${SSH_CTL_DIR}/${name}"
    -p "${port}")
  # When doing direct rsync from NEW -> OLD, enable agent forwarding to NEW
  if [ "${name}" = "new" ] && [ "${TRANSFER_MODE}" = "direct" ]; then
    ssh_base+=(-A -o ForwardAgent=yes)
  fi
  if [ -n "${identity}" ]; then
    ssh_base+=(-i "${identity}")
  fi
  if [ -n "${password}" ] && command -v sshpass >/dev/null 2>&1; then
    sshpass -p "${password}" "${ssh_base[@]}" "${user}@${host}" || { ERR "SSH master failed for ${host}"; exit 1; }
  else
    if [ -n "${password}" ] && ! command -v sshpass >/dev/null 2>&1; then
      WARN "sshpass not found; ${prefix} host will prompt for password interactively."
    fi
    "${ssh_base[@]}" "${user}@${host}" || { ERR "SSH master failed for ${host}"; exit 1; }
  fi
  ssh -S "${SSH_CTL_DIR}/${name}" -O check -p "${port}" "${user}@${host}" >/dev/null
  INFO "SSH master ready for ${user}@${host}:${port}."
}

close_master() { # name user host port
  local name="$1" user="$2" host="$3" port="$4"
  ssh -S "${SSH_CTL_DIR}/${name}" -O exit -p "${port}" "${user}@${host}" >/dev/null 2>&1 || true
}

cleanup() {
  STEP "Cleanup"
  INFO "Closing SSH masters."
  close_master "old" "${OLD_USER}" "${OLD_HOST}" "${OLD_SSH_PORT}"
  close_master "new" "${NEW_USER}" "${NEW_HOST}" "${NEW_SSH_PORT}"
  if [ -d "${STAGE_DIR}" ]; then
    INFO "Removing staging dir ${STAGE_DIR}"
    rm -rf "${STAGE_DIR}"
  fi
  INFO "Done. Total elapsed: ${SECONDS}s"
}
trap cleanup EXIT

# ---------- start ----------
LINE
INFO "BEGIN migration (resilient mode)"
INFO "OLD ${OLD_USER}@${OLD_HOST}:${OLD_SSH_PORT}  NEW ${NEW_USER}@${NEW_HOST}:${NEW_SSH_PORT}"
INFO "Roots: ${OLD_WEB_ROOT} -> ${NEW_WEB_ROOT:-'(auto)'} | Assets: ${ASSETS_DIR}"
INFO "DBs: ${DB_LIST[*]}"
INFO "SSH auth: OLD=$(describe_ssh_auth OLD), NEW=$(describe_ssh_auth NEW)"
if [ "${PLESK_AUTO_SETUP}" = "true" ]; then
  INFO "Plesk: enabled for ${PLESK_DOMAIN} (plan: ${PLESK_SERVICE_PLAN}, owner: ${PLESK_OWNER})"
else
  INFO "Plesk: disabled (pass --plesk-setup to auto-provision subscription + DB metadata)"
fi
if [ -n "${LOG_FILE}" ]; then
  INFO "Structured log -> ${LOG_FILE}"
else
  INFO "Structured log -> disabled (set LOG_FILE env var to enable)"
fi
INFO "Run context: $( [ "${RUN_FROM}" = "old" ] && echo 'running on OLD' || echo 'running elsewhere' )"
LINE

# Resolve effective rsync user for NEW
RSYNC_USER_NEW_EFFECTIVE="${RSYNC_NEW_USER:-${NEW_USER}}"
INFO "Options: mode=${MODE}, transfer_mode=${TRANSFER_MODE}, skip_code=${SKIP_CODE}, skip_assets=${SKIP_ASSETS}, skip_db=${SKIP_DB}, db_compress=${DB_COMPRESS}, maintenance=${MAINTENANCE}, dry_run=${DRY_RUN}"
if [ "${RSYNC_USER_NEW_EFFECTIVE}" != "${NEW_USER}" ]; then
  INFO "Using rsync NEW user override: ${RSYNC_USER_NEW_EFFECTIVE}"
fi

# Configure rsync dry-run flag
RSYNC_DRY=""
if [ "${DRY_RUN}" = "true" ]; then RSYNC_DRY="--dry-run"; fi

STEP "Open SSH sessions (prompts occur here)"
[ "${RUN_FROM}" = "old" ] || open_master "old" "${OLD_USER}" "${OLD_HOST}" "${OLD_SSH_PORT}"
open_master "new" "${NEW_USER}" "${NEW_HOST}" "${NEW_SSH_PORT}"

STEP "Validate required commands on OLD host"
if [ "${START_STEP:-1}" -gt "${STEP_N}" ]; then
  INFO "Skipping step ${STEP_N} due to --start-step=${START_STEP}"
elif [ "${RUN_FROM}" = "old" ]; then
  REQUIRED=(rsync mysqldump)
  OPTIONAL=(ionice)
  need_install=()
  if ! command -v rsync >/dev/null 2>&1; then need_install+=(rsync); fi
  if ! command -v mysqldump >/dev/null 2>&1; then need_install+=(default-mysql-client); fi
  if [ "${#need_install[@]}" -gt 0 ] && [ "$(id -u)" = "0" ] && command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || apt-get update || true
    apt-get install -y "${need_install[@]}" || true
  fi
  missing=()
  for cmd in "${REQUIRED[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    ERR "Missing required commands on OLD (local): ${missing[*]}"
    if [ "$(id -u)" != "0" ]; then
      WARN "Tip: run as root on Debian/Ubuntu to auto-install."
    fi
    exit 1
  fi
  for cmd in "${OPTIONAL[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      WARN "Optional command not found on OLD (local): ${cmd}"
    fi
  done
  INFO "OLD host dependencies satisfied (local)."
else
  ssh -S "${SSH_CTL_DIR}/old" -p "${OLD_SSH_PORT}" "${OLD_USER}@${OLD_HOST}" 'bash -s' <<'REMOTE'
set -euo pipefail
need_install=()
if ! command -v rsync >/dev/null 2>&1; then need_install+=(rsync); fi
if ! command -v mysqldump >/dev/null 2>&1; then need_install+=(default-mysql-client); fi
if [ "${#need_install[@]}" -gt 0 ] && [ "$(id -u)" = "0" ] && command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y || apt-get update || true
  apt-get install -y "${need_install[@]}" || true
fi
missing=()
for cmd in rsync mysqldump; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "Missing required commands on OLD host: ${missing[*]}" >&2
  if [ "$(id -u)" != "0" ]; then
    echo "Tip: run as root on Debian/Ubuntu to auto-install." >&2
  fi
  exit 1
fi
echo "OLD host dependencies satisfied."
REMOTE
fi

STEP "Validate required commands on NEW host"
if [ "${START_STEP:-1}" -gt "${STEP_N}" ]; then
  INFO "Skipping step ${STEP_N} due to --start-step=${START_STEP}"
else
  ssh -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" \
  OLD_SSH_PASSWORD="${OLD_SSH_PASSWORD:-}" TRANSFER_MODE="${TRANSFER_MODE}" 'bash -s' <<'REMOTE'
set -euo pipefail
need_install=()
if ! command -v rsync >/dev/null 2>&1; then need_install+=(rsync); fi
if ! command -v mysql >/dev/null 2>&1; then need_install+=(default-mysql-client); fi
if [ -n "${OLD_SSH_PASSWORD:-}" ] && [ "${TRANSFER_MODE:-}" = "direct" ]; then
  if ! command -v sshpass >/dev/null 2>&1; then need_install+=(sshpass); fi
fi
if [ "${#need_install[@]}" -gt 0 ] && [ "$(id -u)" = "0" ] && command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y || apt-get update || true
  apt-get install -y "${need_install[@]}" || true
fi
missing=()
command -v rsync >/dev/null 2>&1 || missing+=(rsync)
command -v mysql >/dev/null 2>&1 || missing+=(mysql-client)
if [ -n "${OLD_SSH_PASSWORD:-}" ] && [ "${TRANSFER_MODE:-}" = "direct" ] && ! command -v sshpass >/dev/null 2>&1; then missing+=(sshpass); fi
if [ "${#missing[@]}" -gt 0 ]; then
  echo "Missing required commands on NEW host: ${missing[*]}" >&2
  if [ "$(id -u)" != "0" ]; then
    echo "Tip: run as root on Debian/Ubuntu to auto-install." >&2
  fi
  exit 1
fi
echo "NEW host dependencies satisfied."
REMOTE
fi

STEP "Validate MySQL connectivity (OLD and NEW)"
if [ "${START_STEP:-1}" -gt "${STEP_N}" ]; then
  INFO "Skipping step ${STEP_N} due to --start-step=${START_STEP}"
elif [ "${RUN_FROM}" = "old" ]; then
  export MYSQL_PWD="${OLD_DB_PASS}"
  mysql -h "${OLD_DB_HOST}" -u "${OLD_DB_USER}" -e "SELECT VERSION() AS old_version;" >/dev/null
  INFO "OLD MySQL connectivity OK."
else
  ssh -S "${SSH_CTL_DIR}/old" -p "${OLD_SSH_PORT}" "${OLD_USER}@${OLD_HOST}" \
    OLD_DB_HOST="${OLD_DB_HOST}" OLD_DB_USER="${OLD_DB_USER}" OLD_DB_PASS="${OLD_DB_PASS}" 'bash -s' <<'REMOTE'
set -euo pipefail
export MYSQL_PWD="${OLD_DB_PASS}"
mysql -h "${OLD_DB_HOST}" -u "${OLD_DB_USER}" -e "SELECT VERSION() AS old_version;" >/dev/null
echo "OLD MySQL connectivity OK."
REMOTE
fi
ssh -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" \
  NEW_DB_HOST="${NEW_DB_HOST}" NEW_DB_USER="${NEW_DB_USER}" NEW_DB_PASS="${NEW_DB_PASS}" 'bash -s' <<'REMOTE'
set -euo pipefail
export MYSQL_PWD="${NEW_DB_PASS}"
mysql -h "${NEW_DB_HOST}" -u "${NEW_DB_USER}" -e "SELECT VERSION() AS new_version;" >/dev/null
echo "NEW MySQL connectivity OK."
REMOTE

if [ "${PLESK_AUTO_SETUP}" = "true" ]; then
  STEP "Ensure Plesk subscription and DB records"
  if [ "${START_STEP:-1}" -le "${STEP_N}" ]; then
  DB_LIST_CSV="$(IFS=$' '; echo "${DB_LIST[*]}")"
  ssh -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" \
    PLESK_DOMAIN="${PLESK_DOMAIN}" \
    PLESK_OWNER="${PLESK_OWNER}" \
    PLESK_SERVICE_PLAN="${PLESK_SERVICE_PLAN}" \
    PLESK_IP_ADDR="${PLESK_IP_ADDR}" \
    PLESK_SYSTEM_USER="${PLESK_SYSTEM_USER}" \
    PLESK_SYSTEM_PASS="${PLESK_SYSTEM_PASS}" \
    PLESK_DOCROOT_REL="${PLESK_DOCROOT_REL}" \
    PLESK_DB_SERVER="${PLESK_DB_SERVER}" \
    PLESK_DB_TYPE="${PLESK_DB_TYPE}" \
    NEW_DB_USER="${NEW_DB_USER}" \
    NEW_DB_PASS="${NEW_DB_PASS}" \
    DB_LIST_CSV="${DB_LIST_CSV}" 'bash -s' <<'REMOTE'
set -euo pipefail
log() { echo "[$(date +%F\ %T)] $*"; }
if ! command -v plesk >/dev/null 2>&1; then
  log "Plesk CLI is not available on this host. Install plesk or remove --plesk-setup."
  exit 1
fi
read -ra DB_ARRAY <<< "${DB_LIST_CSV}"
if plesk bin subscription --info "${PLESK_DOMAIN}" >/dev/null 2>&1; then
  log "Subscription ${PLESK_DOMAIN} already exists."
else
  log "Creating subscription ${PLESK_DOMAIN} (owner: ${PLESK_OWNER}, plan: ${PLESK_SERVICE_PLAN})"
  plesk bin subscription --create "${PLESK_DOMAIN}" \
    -owner "${PLESK_OWNER}" \
    -service-plan "${PLESK_SERVICE_PLAN}" \
    -ip "${PLESK_IP_ADDR}" \
    -login "${PLESK_SYSTEM_USER}" \
    -passwd "${PLESK_SYSTEM_PASS}" \
    -www-root "${PLESK_DOCROOT_REL}"
fi
for db in "${DB_ARRAY[@]}"; do
  [ -z "$db" ] && continue
  if plesk bin database --info "$db" >/dev/null 2>&1; then
    log "Database record ${db} already exists in Plesk."
    continue
  fi
  log "Creating Plesk DB record ${db}"
  plesk bin database --create "$db" \
    -domain "${PLESK_DOMAIN}" \
    -type "${PLESK_DB_TYPE}" \
    -server "${PLESK_DB_SERVER}" \
    -db-user "${NEW_DB_USER}" \
    -passwd "${NEW_DB_PASS}"
done
REMOTE
  else
    INFO "Skipping step ${STEP_N} due to --start-step=${START_STEP}"
  fi
fi

STEP "Resolve NEW web root path"
if [ "${START_STEP:-1}" -gt "${STEP_N}" ]; then
  INFO "Skipping step ${STEP_N} due to --start-step=${START_STEP}"
elif [ -n "${NEW_WEB_ROOT}" ]; then
  INFO "Using configured NEW_WEB_ROOT=${NEW_WEB_ROOT}"
else
  if [ "${PLESK_AUTO_SETUP}" != "true" ]; then
    ERR "NEW_WEB_ROOT is empty and --plesk-setup was not used. Set NEW_WEB_ROOT manually."
    exit 1
  fi
  NEW_WEB_ROOT="$(ssh -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" \
    PLESK_DOMAIN="${PLESK_DOMAIN}" \
    PLESK_VHOSTS_ROOT="${PLESK_VHOSTS_ROOT}" 'bash -s' <<'REMOTE'
set -euo pipefail
if ! command -v plesk >/dev/null 2>&1; then
  echo "" && exit 0
fi
docroot=$(plesk bin subscription --info "${PLESK_DOMAIN}" \
  | awk -F': ' '/Document root/ {print $2; exit}')
if [ -n "$docroot" ]; then
  printf '%s\n' "$docroot"
  exit 0
fi
wwwroot=$(plesk bin subscription --info "${PLESK_DOMAIN}" \
  | awk -F': ' '/WWW root/ {print $2; exit}')
if [ -n "$wwwroot" ] && [ -n "${PLESK_VHOSTS_ROOT}" ]; then
  printf '%s/%s/%s\n' "${PLESK_VHOSTS_ROOT%/}" "${PLESK_DOMAIN}" "${wwwroot}"
fi
REMOTE
)"
  NEW_WEB_ROOT="$(echo -n "${NEW_WEB_ROOT}" | tr -d '\r')"
  if [ -z "${NEW_WEB_ROOT}" ]; then
    ERR "Failed to auto-detect NEW_WEB_ROOT from Plesk. Set it manually."
    exit 1
  fi
  INFO "Auto-detected NEW_WEB_ROOT=${NEW_WEB_ROOT}"
fi

STEP "Detect mode and adapt defaults"
if [ "${START_STEP:-1}" -gt "${STEP_N}" ]; then
  INFO "Skipping step ${STEP_N} due to --start-step=${START_STEP}"
else
detect_mode_wordpress_old() {
  if [ "${RUN_FROM}" = "old" ]; then
    test -f "${OLD_WEB_ROOT%/}/wp-config.php"
  else
    ssh -S "${SSH_CTL_DIR}/old" -p "${OLD_SSH_PORT}" "${OLD_USER}@${OLD_HOST}" "test -f '${OLD_WEB_ROOT%/}/wp-config.php'"
  fi
}
if [ "${MODE}" = "auto" ]; then
  if detect_mode_wordpress_old; then MODE="wordpress"; else MODE="generic"; fi
fi
INFO "Detected/selected mode: ${MODE}"
if [ "${MODE}" = "wordpress" ]; then
  if [ "${ASSETS_DIR}" = "public/uploads" ]; then
    ASSETS_DIR="wp-content/uploads"
    INFO "Assets dir set for WordPress: ${ASSETS_DIR}"
  fi
fi
fi

STEP "Preflight on NEW"
if [ "${START_STEP:-1}" -gt "${STEP_N}" ]; then
  INFO "Skipping step ${STEP_N} due to --start-step=${START_STEP}"
else
  ssh -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" "mkdir -p '${NEW_WEB_ROOT}' '${NEW_WEB_ROOT}/${ASSETS_DIR}' && ls -ld '${NEW_WEB_ROOT}' '${NEW_WEB_ROOT}/${ASSETS_DIR}'"
  ssh -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" "df -h '${NEW_WEB_ROOT}' 2>/dev/null || df -h /" || true
fi

if [ "${TRANSFER_MODE}" = "stage" ]; then
  STEP "Create local staging at ${STAGE_DIR}"
  mkdir -p "${STAGE_DIR}/code" "${STAGE_DIR}/assets"
else
  INFO "TRANSFER_MODE=${TRANSFER_MODE}; skipping local staging."
fi

if [ "${SKIP_CODE}" = "true" ]; then
  INFO "Skipping code transfer as requested."
else
  case "${TRANSFER_MODE}" in
    stage)
      STEP "Pull code from OLD to local (excludes assets)"
      if [ "${START_STEP:-1}" -gt "${STEP_N}" ]; then
        INFO "Skipping step ${STEP_N} due to --start-step=${START_STEP}"
      else
      START=$(tic)
      EXCLUDES=()
      for x in ${RSYNC_EXCLUDES}; do EXCLUDES+=(--exclude="$x"); done
      rsync -azh ${RSYNC_DRY} --delete --stats --info=progress2 --human-readable \
        -e "ssh -S ${SSH_CTL_DIR}/old -p ${OLD_SSH_PORT}" \
        "${EXCLUDES[@]}" \
        --exclude="${ASSETS_DIR}" \
        "${OLD_USER}@${OLD_HOST}:${OLD_WEB_ROOT%/}/" \
        "${STAGE_DIR}/code/"
      INFO "Code pulled in $(toc "$START")"
      du -sh "${STAGE_DIR}/code" 2>/dev/null || true

      STEP "Push code from local to NEW"
      if [ "${START_STEP:-1}" -gt "${STEP_N}" ]; then
        INFO "Skipping step ${STEP_N} due to --start-step=${START_STEP}"
      else
      START=$(tic)
      rsync -azh ${RSYNC_DRY} --delete --stats --info=progress2 --human-readable \
        -e "ssh -S ${SSH_CTL_DIR}/new -p ${NEW_SSH_PORT}" \
        "${STAGE_DIR}/code/" \
        "${RSYNC_USER_NEW_EFFECTIVE}@${NEW_HOST}:${NEW_WEB_ROOT%/}/"
      INFO "Code pushed in $(toc "$START")"
      fi
      fi
      ;;
    direct)
      STEP "Direct rsync code OLD → NEW"
      if [ "${START_STEP:-1}" -gt "${STEP_N}" ]; then
        INFO "Skipping step ${STEP_N} due to --start-step=${START_STEP}"
      else
      START=$(tic)
      if [ "${RUN_FROM}" = "old" ]; then
        rsync_push_code_from_old_to_new
      else
        if ! rsync_direct_pull_from_old_to_new_code; then
          WARN "Direct rsync failed or not available; falling back to stream mode for code (no delete)."
          tar_stream_copy "${OLD_WEB_ROOT}" "${NEW_WEB_ROOT}" ${RSYNC_EXCLUDES} "${ASSETS_DIR}"
        fi
      fi
      INFO "Code synced in $(toc "$START")"
      fi
      ;;
    stream)
      STEP "Stream code OLD → NEW via tar (no delete)"
      if [ "${START_STEP:-1}" -gt "${STEP_N}" ]; then
        INFO "Skipping step ${STEP_N} due to --start-step=${START_STEP}"
      else
      START=$(tic)
      tar_stream_copy "${OLD_WEB_ROOT}" "${NEW_WEB_ROOT}" ${RSYNC_EXCLUDES} "${ASSETS_DIR}"
      INFO "Code streamed in $(toc "$START")"
      fi
      ;;
    *)
      ERR "Unknown TRANSFER_MODE='${TRANSFER_MODE}'. Use stage|direct|stream."
      exit 1
      ;;
  esac
fi

if [ "${SKIP_ASSETS}" = "true" ]; then
  INFO "Skipping assets transfer as requested."
else
  case "${TRANSFER_MODE}" in
    stage)
      STEP "Pull assets from OLD to local"
      if [ "${START_STEP:-1}" -gt "${STEP_N}" ]; then
        INFO "Skipping step ${STEP_N} due to --start-step=${START_STEP}"
      else
      START=$(tic)
      rsync -azh ${RSYNC_DRY} --delete --stats --info=progress2 --human-readable \
        -e "ssh -S ${SSH_CTL_DIR}/old -p ${OLD_SSH_PORT}" \
        "${OLD_USER}@${OLD_HOST}:${OLD_WEB_ROOT%/}/${ASSETS_DIR%/}/" \
        "${STAGE_DIR}/assets/"
      INFO "Assets pulled in $(toc "$START")"
      du -sh "${STAGE_DIR}/assets" 2>/dev/null || true

      STEP "Push assets from local to NEW"
      if [ "${START_STEP:-1}" -gt "${STEP_N}" ]; then
        INFO "Skipping step ${STEP_N} due to --start-step=${START_STEP}"
      else
      START=$(tic)
      rsync -azh ${RSYNC_DRY} --delete --stats --info=progress2 --human-readable \
        -e "ssh -S ${SSH_CTL_DIR}/new -p ${NEW_SSH_PORT}" \
        "${STAGE_DIR}/assets/" \
        "${RSYNC_USER_NEW_EFFECTIVE}@${NEW_HOST}:${NEW_WEB_ROOT%/}/${ASSETS_DIR%/}/"
      INFO "Assets pushed in $(toc "$START")"
      fi
      fi
      ;;
    direct)
      STEP "Direct rsync assets OLD → NEW"
      if [ "${START_STEP:-1}" -gt "${STEP_N}" ]; then
        INFO "Skipping step ${STEP_N} due to --start-step=${START_STEP}"
      else
      START=$(tic)
      if [ "${RUN_FROM}" = "old" ]; then
        rsync_push_assets_from_old_to_new
      else
        if ! rsync_direct_pull_from_old_to_new_assets; then
          WARN "Direct rsync failed or not available; falling back to stream mode for assets (no delete)."
          tar_stream_copy "${OLD_WEB_ROOT%/}/${ASSETS_DIR%/}" "${NEW_WEB_ROOT%/}/${ASSETS_DIR%/}"
        fi
      fi
      INFO "Assets synced in $(toc "$START")"
      fi
      ;;
    stream)
      STEP "Stream assets OLD → NEW via tar (no delete)"
      if [ "${START_STEP:-1}" -gt "${STEP_N}" ]; then
        INFO "Skipping step ${STEP_N} due to --start-step=${START_STEP}"
      else
      START=$(tic)
      tar_stream_copy "${OLD_WEB_ROOT%/}/${ASSETS_DIR%/}" "${NEW_WEB_ROOT%/}/${ASSETS_DIR%/}"
      INFO "Assets streamed in $(toc "$START")"
      fi
      ;;
  esac
fi

# Fix ownership and permissions on NEW for Plesk
STEP "Fix ownership and permissions on NEW (Plesk)"
if [ "${START_STEP:-1}" -gt "${STEP_N}" ]; then
  INFO "Skipping step ${STEP_N} due to --start-step=${START_STEP}"
else
ssh -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" \
  NEW_WEB_ROOT="${NEW_WEB_ROOT}" PLESK_SYSTEM_USER="${PLESK_SYSTEM_USER}" 'bash -s' <<'REMOTE'
set -euo pipefail
if [ "$(id -u)" = "0" ]; then
  if command -v plesk >/dev/null 2>&1; then
    chown -R "${PLESK_SYSTEM_USER}:psacln" "${NEW_WEB_ROOT%/}" || true
    find "${NEW_WEB_ROOT%/}" -type d -exec chmod 755 {} + || true
    find "${NEW_WEB_ROOT%/}" -type f -exec chmod 644 {} + || true
    echo "[$(date +%F\ %T)] Ownership/perms normalized for Plesk user ${PLESK_SYSTEM_USER}."
  else
    echo "[$(date +%F\ %T)] Plesk not detected; skip ownership/perms normalization."
  fi
else
  echo "[$(date +%F\ %T)] Not root on NEW; skip ownership/perms normalization."
fi
REMOTE
fi

if [ "${SKIP_DB}" = "true" ]; then
  INFO "Skipping DB migration as requested."
elif [ "${DRY_RUN}" = "true" ]; then
  INFO "DRY-RUN is ON: skipping DB migration preview."
else
STEP "Ensure DBs exist on NEW"
if [ "${START_STEP:-1}" -gt "${STEP_N}" ]; then
  INFO "Skipping step ${STEP_N} due to --start-step=${START_STEP}"
else
for db in "${DB_LIST[@]}"; do
  ssh -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" \
    "MYSQL_PWD='${NEW_DB_PASS}' mysql -h '${NEW_DB_HOST}' -u '${NEW_DB_USER}' \
     -e \"CREATE DATABASE IF NOT EXISTS \\\`${db}\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\""
done
INFO "DBs ensured."
fi

STEP "Migrate DBs with low I/O priority (compressed stream)"
if [ "${START_STEP:-1}" -gt "${STEP_N}" ]; then
  INFO "Skipping step ${STEP_N} due to --start-step=${START_STEP}"
else
  for db in "${DB_LIST[@]}"; do
    # Build ignore-table list for this DB
    TABLES_TO_IGNORE=""
    if [ ${#DB_EXCLUDE_TABLES[@]} -gt 0 ]; then
      for t in "${DB_EXCLUDE_TABLES[@]}"; do
        case "$t" in
          *.*) TABLES_TO_IGNORE+=" $t" ;;
          *)   TABLES_TO_IGNORE+=" ${db}.$t" ;;
        esac
      done
    fi
    INFO "Migrating DB: ${db}"
    START=$(tic)
    PV=$(pv_or_cat)
    COMP_CHOICE=none
    # Detect compression pair
    if [ "${DB_COMPRESS}" = "auto" ]; then
      if { [ "${RUN_FROM}" = "old" ] && command -v lz4 >/dev/null 2>&1; } \
         && ssh -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" command -v lz4 >/dev/null 2>&1 \
         || { [ "${RUN_FROM}" != "old" ] && ssh -S "${SSH_CTL_DIR}/old" -p "${OLD_SSH_PORT}" "${OLD_USER}@${OLD_HOST}" command -v lz4 >/dev/null 2>&1 \
              && ssh -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" command -v lz4 >/dev/null 2>&1; }; then
        COMP_CHOICE=lz4
      elif { [ "${RUN_FROM}" = "old" ] && (command -v pigz >/dev/null 2>&1 || command -v gzip >/dev/null 2>&1); } \
           && ssh -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" bash -lc 'command -v pigz >/dev/null 2>&1 || command -v gzip >/dev/null 2>&1' \
           || { [ "${RUN_FROM}" != "old" ] && ssh -S "${SSH_CTL_DIR}/old" -p "${OLD_SSH_PORT}" "${OLD_USER}@${OLD_HOST}" bash -lc 'command -v pigz >/dev/null 2>&1 || command -v gzip >/dev/null 2>&1' \
                && ssh -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" bash -lc 'command -v pigz >/dev/null 2>&1 || command -v gzip >/dev/null 2>&1'; }; then
        COMP_CHOICE=gzip
      else
        COMP_CHOICE=none
      fi
    else
      COMP_CHOICE="${DB_COMPRESS}"
    fi
    INFO "DB ${db}: compression=${COMP_CHOICE}"

    # Maintenance for WordPress if requested
    if [ "${MODE}" = "wordpress" ]; then
      if [ "${MAINTENANCE}" = "prompt" ]; then
        require_tty_for_prompt "MAINTENANCE"
        read -rp "Enable temporary WordPress maintenance on OLD during dump? [y/N]: " _ans
        if [[ "${_ans}" =~ ^[Yy]$ ]]; then MAINTENANCE=true; else MAINTENANCE=false; fi
      fi
      if [ "${MAINTENANCE}" = "true" ]; then
        INFO "Enabling maintenance mode on OLD (WordPress)"
        if [ "${RUN_FROM}" = "old" ]; then
          set -euo pipefail
          root="${OLD_WEB_ROOT%/}"
          if [ -f "$root/wp-config.php" ]; then
            echo "<?php \$upgrading = time();" > "$root/.maintenance"
          fi
        else
          ssh -S "${SSH_CTL_DIR}/old" -p "${OLD_SSH_PORT}" "${OLD_USER}@${OLD_HOST}" "bash -lc '
            set -euo pipefail
            root=\"${OLD_WEB_ROOT%/}\"
            if [ -f \"$root/wp-config.php\" ]; then
              echo \"<?php \$upgrading = time();\" > \"$root/.maintenance\"
            fi
          '"
        fi
      fi
    fi

    # Dump -> compress -> import pipeline
    if [ "${RUN_FROM}" = "old" ]; then
      export MYSQL_PWD="${OLD_DB_PASS}"
      if command -v ionice >/dev/null 2>&1; then WRAP="ionice -c2 -n7 nice -n 19"; else WRAP="nice -n 19"; fi
      if command -v mariadb-dump >/dev/null 2>&1; then DUMP="mariadb-dump"; else DUMP="mysqldump"; fi
      BASE_OPTS=(--single-transaction --quick --routines --triggers --events --no-tablespaces --default-character-set=utf8mb4)
      BASE_OPTS+=(--max-allowed-packet=1073741824)
      if "$DUMP" --help 2>/dev/null | grep -q -- "--column-statistics"; then BASE_OPTS+=(--column-statistics=0); fi
      EXTRA_OPTS=( ${MYSQLDUMP_OPTS_EXTRA[*]} )
      IGNORE_ARGS=()
      for it in ${TABLES_TO_IGNORE}; do IGNORE_ARGS+=(--ignore-table="$it"); done
      eval $WRAP "$DUMP" -h "${OLD_DB_HOST}" -u "${OLD_DB_USER}" "${BASE_OPTS[@]}" "${EXTRA_OPTS[@]}" "${IGNORE_ARGS[@]}" "${db}"
    else
      ssh -T -S "${SSH_CTL_DIR}/old" -p "${OLD_SSH_PORT}" "${OLD_USER}@${OLD_HOST}" \
        TABLES_TO_IGNORE="${TABLES_TO_IGNORE}" 'bash -lc '
set -euo pipefail
export MYSQL_PWD="${OLD_DB_PASS}"
if command -v ionice >/dev/null 2>&1; then WRAP="ionice -c2 -n7 nice -n 19"; else WRAP="nice -n 19"; fi
if command -v mariadb-dump >/dev/null 2>&1; then DUMP="mariadb-dump"; else DUMP="mysqldump"; fi
BASE_OPTS=(--single-transaction --quick --routines --triggers --events --no-tablespaces --default-character-set=utf8mb4)
BASE_OPTS+=(--max-allowed-packet=1073741824)
if "$DUMP" --help 2>/dev/null | grep -q -- "--column-statistics"; then BASE_OPTS+=(--column-statistics=0); fi
EXTRA_OPTS=( ${MYSQLDUMP_OPTS_EXTRA[*]} )
IGNORE_ARGS=()
for it in ${TABLES_TO_IGNORE}; do IGNORE_ARGS+=(--ignore-table="$it"); done
exec $WRAP "$DUMP" -h "${OLD_DB_HOST}" -u "${OLD_DB_USER}" "${BASE_OPTS[@]}" "${EXTRA_OPTS[@]}" "${IGNORE_ARGS[@]}" "${db}"
'
    fi \
    | ${PV} \
    | {
        case "${COMP_CHOICE}" in
          lz4)  lz4 -c 2>/dev/null || cat ;; \
          gzip) if command -v pigz >/dev/null 2>&1; then pigz -1; else gzip -1; fi ;; \
          none) cat ;; \
        esac
      } \
    | ssh -T -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" "bash -lc '
        set -euo pipefail
        export MYSQL_PWD=\"${NEW_DB_PASS}\"
        if command -v ionice >/dev/null 2>&1; then WRAP=\"ionice -c2 -n7 nice -n 19\"; else WRAP=\"nice -n 19\"; fi
        case \"${COMP_CHOICE}\" in
          lz4)  IN=\"lz4 -d\" ;;
          gzip) IN=\"gzip -d\" ;;
          none) IN=\"cat\" ;;
        esac
        eval \$IN | \$WRAP mysql -h \"${NEW_DB_HOST}\" -u \"${NEW_DB_USER}\" ${MYSQL_IMPORT_OPTS_DEFAULT[*]} ${MYSQL_IMPORT_OPTS_EXTRA[*]} \"${db}\"
      '"

    if [ "${MODE}" = "wordpress" ] && [ "${MAINTENANCE}" = "true" ]; then
      INFO "Disabling maintenance mode on OLD"
      if [ "${RUN_FROM}" = "old" ]; then
        rm -f "${OLD_WEB_ROOT%/}/.maintenance" || true
      else
        ssh -S "${SSH_CTL_DIR}/old" -p "${OLD_SSH_PORT}" "${OLD_USER}@${OLD_HOST}" "bash -lc 'rm -f \"${OLD_WEB_ROOT%/}/.maintenance\"'" || true
      fi
    fi
    INFO "DB ${db} migrated in $(toc "$START")"
  done
fi
fi

STEP "Update config on NEW (WordPress wp-config.php or generic .env)"
if [ "${START_STEP:-1}" -gt "${STEP_N}" ]; then
  INFO "Skipping step ${STEP_N} due to --start-step=${START_STEP}"
elif [ "${MODE}" = "wordpress" ]; then
  # Check for wp-config.php; DB constants update intentionally skipped to avoid quoting issues on diverse configs
  ssh -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" \
    NEW_WEB_ROOT="${NEW_WEB_ROOT}" 'bash -s' <<'REMOTE'
set -euo pipefail
CONF="${NEW_WEB_ROOT%/}/wp-config.php"
if [ -f "$CONF" ]; then
  DBNAME=$(awk -F"'" '/DB_NAME/{print $4; exit}' "$CONF" 2>/dev/null || true)
  echo "[$(date +%F\ %T)] wp-config.php present; DB_NAME='${DBNAME:-unknown}'. Skipping inline constant edits."
else
  echo "[$(date +%F\ %T)] wp-config.php not found; skipping DB config update"
fi
REMOTE
else
  # generic .env replacements skipped to simplify; perform app-level configuration manually if needed
  INFO "Skipping .env replacements on NEW to avoid over-matching."
fi

# Generic SQL replacements disabled by default to avoid risk on serialized data.

STEP "Summary"
INFO "Code -> ${NEW_USER}@${NEW_HOST}:${NEW_WEB_ROOT}"
INFO "Assets -> ${NEW_USER}@${NEW_HOST}:${NEW_WEB_ROOT}/${ASSETS_DIR}"
INFO "DBs migrated: ${DB_LIST[*]}"
INFO "URL replace:  $( [ "${OLD_URL}" = "${NEW_URL}" ] && echo 'skipped' || echo "${OLD_URL} -> ${NEW_URL}" )"
INFO "Path replace: $( [ "${OLD_PATH}" = "${NEW_PATH}" ] && echo 'skipped' || echo "${OLD_PATH} -> ${NEW_PATH}" )"
INFO "Plesk provisioning: $( [ "${PLESK_AUTO_SETUP}" = "true" ] && echo "enabled for ${PLESK_DOMAIN}" || echo 'disabled' )"
INFO "Structured log file: $( [ -n "${LOG_FILE}" ] && echo "${LOG_FILE}" || echo 'disabled' )"
