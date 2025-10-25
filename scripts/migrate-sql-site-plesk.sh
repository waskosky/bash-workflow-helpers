#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
PLESK_AUTO_SETUP="${PLESK_AUTO_SETUP:-false}"

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [--plesk-setup] [--help]

Options:
  --plesk-setup   Run the optional Plesk Obsidian provisioning (subscription + DB records).
  -h, --help      Show this message.

Edit the variables near the top of the script to match your environment.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plesk-setup)
      PLESK_AUTO_SETUP=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

# ---------- EDIT THESE ----------
# Hosts, users, ports, and paths
OLD_HOST="old.example.com"
OLD_USER="ubuntu"
OLD_SSH_PORT=22

NEW_HOST="new.example.com"
NEW_USER="ubuntu"
NEW_SSH_PORT=22

OLD_WEB_ROOT="/var/www/site"
NEW_WEB_ROOT="/var/www/site"

# Plesk subscription + database defaults (used only when --plesk-setup is supplied)
PLESK_DOMAIN="example.com"
PLESK_OWNER="admin"
PLESK_SERVICE_PLAN="Default Domain"
PLESK_IP_ADDR="203.0.113.10"
PLESK_SYSTEM_USER="siteuser"
PLESK_SYSTEM_PASS="changeme"
PLESK_DOCROOT_REL="httpdocs" # relative to /var/www/vhosts/<domain>/
PLESK_DB_SERVER="localhost"
PLESK_DB_TYPE="mysql"

# Uploaded assets directory relative to the web root
ASSETS_DIR="public/uploads"

# MySQL on OLD
OLD_DB_HOST="127.0.0.1"
OLD_DB_USER="appuser"
OLD_DB_PASS="oldpass"

# MySQL on NEW
NEW_DB_HOST="127.0.0.1"
NEW_DB_USER="appuser"
NEW_DB_PASS="newpass"

# Databases to migrate (space-separated)
DB_LIST=(appdb analyticsdb)

# Optional replacements across text columns and config files
# If OLD_* equals NEW_*, the script skips that replacement.
OLD_URL="https://example.com"
NEW_URL="https://example.com"
OLD_PATH="${OLD_WEB_ROOT}"
NEW_PATH="${NEW_WEB_ROOT}"

# Local staging directory (must have free space for code + assets)
STAGE_DIR="${HOME}/.migrate_stage_$(date +%s)"

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

SECONDS=0
tic() { date +%s; }
toc() { local s="$1"; echo "$(( $(date +%s) - s ))s"; }

# ---------- helpers ----------
io_wrap() { if command -v ionice >/dev/null 2>&1; then echo "ionice -c2 -n7 nice -n 19"; else echo "nice -n 19"; fi; }
pv_or_cat() { if command -v pv >/dev/null 2>&1; then echo "pv -brat"; else echo "cat"; fi; }

SSH_CTL_DIR="${HOME}/.ssh/ctl-mux"
mkdir -p "${SSH_CTL_DIR}"; chmod 700 "${SSH_CTL_DIR}"

open_master() { # name user host port
  local name="$1" user="$2" host="$3" port="$4"
  INFO "Opening SSH master to ${user}@${host}:${port} (you may be prompted)."
  ssh -fN -tt \
    -o ControlMaster=auto \
    -o ControlPersist=600 \
    -o StrictHostKeyChecking=accept-new \
    -S "${SSH_CTL_DIR}/${name}" \
    -p "${port}" "${user}@${host}" || { ERR "SSH master failed for ${host}"; exit 1; }
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
INFO "BEGIN migration (password‑friendly mode)"
INFO "OLD ${OLD_USER}@${OLD_HOST}:${OLD_SSH_PORT}  NEW ${NEW_USER}@${NEW_HOST}:${NEW_SSH_PORT}"
INFO "Roots: ${OLD_WEB_ROOT} -> ${NEW_WEB_ROOT} | Assets: ${ASSETS_DIR}"
INFO "DBs: ${DB_LIST[*]}"
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
LINE

STEP "Open SSH sessions (prompts occur here)"
open_master "old" "${OLD_USER}" "${OLD_HOST}" "${OLD_SSH_PORT}"
open_master "new" "${NEW_USER}" "${NEW_HOST}" "${NEW_SSH_PORT}"

STEP "Validate required commands on OLD host"
ssh -S "${SSH_CTL_DIR}/old" -p "${OLD_SSH_PORT}" "${OLD_USER}@${OLD_HOST}" 'bash -s' <<'REMOTE'
set -euo pipefail
REQUIRED=(rsync mysqldump)
OPTIONAL=(ionice)
missing=()
for cmd in "${REQUIRED[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing+=("$cmd")
  fi
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "Missing required commands on OLD host: ${missing[*]}" >&2
  exit 1
fi
for cmd in "${OPTIONAL[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Optional command not found on OLD host: ${cmd} (migration will continue without it)"
  fi
done
echo "OLD host dependencies satisfied."
REMOTE

STEP "Preflight on NEW"
ssh -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" "mkdir -p '${NEW_WEB_ROOT}' '${NEW_WEB_ROOT}/${ASSETS_DIR}' && ls -ld '${NEW_WEB_ROOT}' '${NEW_WEB_ROOT}/${ASSETS_DIR}'"
ssh -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" "df -h '${NEW_WEB_ROOT}' 2>/dev/null || df -h /" || true

if [ "${PLESK_AUTO_SETUP}" = "true" ]; then
  STEP "Ensure Plesk subscription and DB records"
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
fi

STEP "Create local staging at ${STAGE_DIR}"
mkdir -p "${STAGE_DIR}/code" "${STAGE_DIR}/assets"

STEP "Pull code from OLD to local (excludes assets)"
START=$(tic)
rsync -azh --delete --stats --info=progress2 --human-readable \
  -e "ssh -S ${SSH_CTL_DIR}/old -p ${OLD_SSH_PORT}" \
  --exclude=".git" --exclude="node_modules" --exclude="vendor" \
  --exclude="cache" --exclude="logs" --exclude="tmp" \
  --exclude="${ASSETS_DIR}" \
  "${OLD_USER}@${OLD_HOST}:${OLD_WEB_ROOT}/" \
  "${STAGE_DIR}/code/"
INFO "Code pulled in $(toc "$START")"
du -sh "${STAGE_DIR}/code" 2>/dev/null || true

STEP "Push code from local to NEW"
START=$(tic)
rsync -azh --delete --stats --info=progress2 --human-readable \
  -e "ssh -S ${SSH_CTL_DIR}/new -p ${NEW_SSH_PORT}" \
  "${STAGE_DIR}/code/" \
  "${NEW_USER}@${NEW_HOST}:${NEW_WEB_ROOT}/"
INFO "Code pushed in $(toc "$START")"

STEP "Pull assets from OLD to local"
START=$(tic)
rsync -azh --delete --stats --info=progress2 --human-readable \
  -e "ssh -S ${SSH_CTL_DIR}/old -p ${OLD_SSH_PORT}" \
  "${OLD_USER}@${OLD_HOST}:${OLD_WEB_ROOT}/${ASSETS_DIR}/" \
  "${STAGE_DIR}/assets/"
INFO "Assets pulled in $(toc "$START")"
du -sh "${STAGE_DIR}/assets" 2>/dev/null || true

STEP "Push assets from local to NEW"
START=$(tic)
rsync -azh --delete --stats --info=progress2 --human-readable \
  -e "ssh -S ${SSH_CTL_DIR}/new -p ${NEW_SSH_PORT}" \
  "${STAGE_DIR}/assets/" \
  "${NEW_USER}@${NEW_HOST}:${NEW_WEB_ROOT}/${ASSETS_DIR}/"
INFO "Assets pushed in $(toc "$START")"

STEP "Ensure DBs exist on NEW"
for db in "${DB_LIST[@]}"; do
  ssh -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" \
    "MYSQL_PWD='${NEW_DB_PASS}' mysql -h '${NEW_DB_HOST}' -u '${NEW_DB_USER}' \
     -e \"CREATE DATABASE IF NOT EXISTS \\\`${db}\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\""
done
INFO "DBs ensured."

STEP "Migrate DBs with low I/O priority (prompts will NOT occur here)"
for db in "${DB_LIST[@]}"; do
  INFO "Migrating DB: ${db}"
  START=$(tic)
  WRAP=$(io_wrap)
  PV=$(pv_or_cat)
  ssh -S "${SSH_CTL_DIR}/old" -p "${OLD_SSH_PORT}" "${OLD_USER}@${OLD_HOST}" "bash -lc '
    set -euo pipefail
    export MYSQL_PWD=\"${OLD_DB_PASS}\"
    if command -v ionice >/dev/null 2>&1; then WRAP=\"ionice -c2 -n7 nice -n 19\"; else WRAP=\"nice -n 19\"; fi
    exec \$WRAP mysqldump -h \"${OLD_DB_HOST}\" -u \"${OLD_DB_USER}\" \
      --single-transaction --quick --routines --triggers --events \
      --default-character-set=utf8mb4 --no-tablespaces \"${db}\"
  '" | ${PV} | ssh -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" "bash -lc '
    set -euo pipefail
    export MYSQL_PWD=\"${NEW_DB_PASS}\"
    if command -v ionice >/dev/null 2>&1; then WRAP=\"ionice -c2 -n7 nice -n  19\"; else WRAP=\"nice -n 19\"; fi
    exec \$WRAP mysql -h \"${NEW_DB_HOST}\" -u \"${NEW_DB_USER}\" \"${db}\"
  '"
  INFO "DB ${db} migrated in $(toc "$START")"
done

STEP "Update NEW .env only if values differ"
ssh -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" \
  NEW_WEB_ROOT="${NEW_WEB_ROOT}" OLD_URL="${OLD_URL}" NEW_URL="${NEW_URL}" OLD_PATH="${OLD_PATH}" NEW_PATH="${NEW_PATH}" 'bash -s' <<'REMOTE'
set -euo pipefail
FILE="${NEW_WEB_ROOT}/.env"
[ -f "$FILE" ] || { echo "[$(date +%F\ %T)] No .env at $FILE. Skipping."; exit 0; }

escape_pat()  { printf '%s' "$1" | sed -e 's/[.[*^$\\\/|]/\\&/g'; }
escape_repl() { printf '%s' "$1" | sed -e 's/[&|]/\\&/g'; }
build_sed()   { [ "$1" = "$2" ] && return 1; printf '%s' "-e" "s|$(escape_pat "$1")|$(escape_repl "$2")|g"; }

SED_ARGS=()
if args=$(build_sed "$OLD_URL" "$NEW_URL");  then SED_ARGS+=($args); fi
if args=$(build_sed "$OLD_PATH" "$NEW_PATH"); then SED_ARGS+=($args); fi
if [ "${#SED_ARGS[@]}" -gt 0 ]; then
  echo "[$(date +%F\ %T)] Applying replacements to $FILE"
  sed -i.bak "${SED_ARGS[@]}" "$FILE"
  echo "[$(date +%F\ %T)] Backup written: ${FILE}.bak"
else
  echo "[$(date +%F\ %T)] No changes required in $FILE"
fi
REMOTE

STEP "Optional DB search/replace (skipped if values equal)"
db_replace() {
  local DB="$1"; local OLD_VAL="$2"; local NEW_VAL="$3"
  [ "$OLD_VAL" = "$NEW_VAL" ] && { INFO "Skip ${DB}: values identical (${OLD_VAL})"; return 0; }
  INFO "DB ${DB}: replacing '${OLD_VAL}' -> '${NEW_VAL}'"
  ssh -S "${SSH_CTL_DIR}/new" -p "${NEW_SSH_PORT}" "${NEW_USER}@${NEW_HOST}" \
    NEW_DB_PASS="${NEW_DB_PASS}" NEW_DB_HOST="${NEW_DB_HOST}" NEW_DB_USER="${NEW_DB_USER}" \
    DB="${DB}" OLD_VAL="${OLD_VAL}" NEW_VAL="${NEW_VAL}" 'bash -s' <<'REMOTE'
set -euo pipefail
export MYSQL_PWD="${NEW_DB_PASS}"
if command -v ionice >/dev/null 2>&1; then WRAP="ionice -c2 -n7 nice -n 19"; else WRAP="nice -n 19"; fi
GEN=$(mktemp)
mysql -h "${NEW_DB_HOST}" -u "${NEW_DB_USER}" -Nse "
SET @schema='${DB}';
SET @old='${OLD_VAL}';
SET @new='${NEW_VAL}';
SELECT CONCAT(
  'UPDATE `', TABLE_NAME, '` SET `', COLUMN_NAME, '`=REPLACE(`', COLUMN_NAME, '`, ''',
  REPLACE(@old, '''', ''''''), ''', ''', REPLACE(@new, '''', ''''''), ''') ',
  'WHERE `', COLUMN_NAME, '` LIKE CONCAT(''%'', REPLACE(@old, '''', ''''''), ''%'');'
)
FROM information_schema.columns
WHERE table_schema=@schema
  AND DATA_TYPE IN ('varchar','char','text','mediumtext','longtext');
" > "$GEN"
LINES=$(wc -l < "$GEN" | tr -d ' ')
echo "[$(date +%F\ %T)] Generated $LINES UPDATE statements for ${DB}"
if [ "$LINES" -gt 0 ]; then
  eval $WRAP mysql -h "${NEW_DB_HOST}" -u "${NEW_DB_USER}" "${DB}" < "$GEN"
  echo "[$(date +%F\ %T)] Replacements applied for ${DB}"
else
  echo "[$(date +%F\ %T)] Nothing to replace in ${DB}"
fi
rm -f "$GEN"
REMOTE
}
for db in "${DB_LIST[@]}"; do
  db_replace "${db}" "${OLD_URL}"  "${NEW_URL}"
  db_replace "${db}" "${OLD_PATH}" "${NEW_PATH}"
done

STEP "Summary"
INFO "Code -> ${NEW_USER}@${NEW_HOST}:${NEW_WEB_ROOT}"
INFO "Assets -> ${NEW_USER}@${NEW_HOST}:${NEW_WEB_ROOT}/${ASSETS_DIR}"
INFO "DBs migrated: ${DB_LIST[*]}"
INFO "URL replace:  $( [ "${OLD_URL}" = "${NEW_URL}" ] && echo 'skipped' || echo "${OLD_URL} -> ${NEW_URL}" )"
INFO "Path replace: $( [ "${OLD_PATH}" = "${NEW_PATH}" ] && echo 'skipped' || echo "${OLD_PATH} -> ${NEW_PATH}" )"
INFO "Plesk provisioning: $( [ "${PLESK_AUTO_SETUP}" = "true" ] && echo "enabled for ${PLESK_DOMAIN}" || echo 'disabled' )"
INFO "Structured log file: $( [ -n "${LOG_FILE}" ] && echo "${LOG_FILE}" || echo 'disabled' )"
