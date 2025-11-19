#!/usr/bin/env bash
set -euo pipefail

umask 077

# Import a previously created business migration package on the NEW server.
# This script does NOT contact the OLD server; it only consumes the package.

SCRIPT_NAME="$(basename "$0")"
PACKAGE="${PACKAGE:-}"
WORK_ROOT="/root/migration"
EXTRACT_DIR="$WORK_ROOT/pkg"
LOG_DIR="$WORK_ROOT/logs"

PLESK_EXPECTED="${PLESK_EXPECTED:-auto}"  # auto|true|false
PLESK_PHP_VER="${PLESK_PHP_VER:-8.4}"

usage() {
  cat <<USAGE
Usage: $SCRIPT_NAME --package /path/to/business_pkg.tgz [--plesk auto|true|false] [--php 8.4]

Runs entirely on NEW, using only the provided package (no SSH to OLD).
USAGE
}

while [[ ${1:-} == --* ]]; do
  case "$1" in
    --package) PACKAGE="$2"; shift 2 ;;
    --plesk) PLESK_EXPECTED="$2"; shift 2 ;;
    --php) PLESK_PHP_VER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; usage; exit 1 ;;
  esac
done

if [ -z "$PACKAGE" ]; then echo "--package is required" >&2; usage; exit 1; fi
[ -f "$PACKAGE" ] || { echo "Package not found: $PACKAGE" >&2; exit 1; }

log() { printf '[%s] %s\n' "$(date -Iseconds)" "$*"; }

ensure_pgdg_repo() {
  local codename="${UBUNTU_CODENAME:-noble}"
  local keyring="/etc/apt/keyrings/postgresql.gpg"
  local sources="/etc/apt/sources.list.d/pgdg.list"
  install -d -m 0755 /etc/apt/keyrings
  local tmpkey
  tmpkey="$(mktemp)"
  if ! curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor >"$tmpkey"; then
    rm -f "$tmpkey"
    return 1
  fi
  install -m 0644 "$tmpkey" "$keyring"
  rm -f "$tmpkey"
  install -m 0644 /dev/null "$sources"
  cat >"$sources" <<EOF
deb [signed-by=$keyring] https://apt.postgresql.org/pub/repos/apt ${codename}-pgdg main
EOF
}

# Prepare dirs
install -d -m 0750 "$WORK_ROOT" "$EXTRACT_DIR" "$LOG_DIR"

# Detect OS
. /etc/os-release
if [ "${ID,,}" != "ubuntu" ] || [[ "${VERSION_ID}" != 24* ]]; then
  echo "This target must be Ubuntu 24.x. Detected: $PRETTY_NAME" >&2
  exit 1
fi

# Install base packages, fixing PGDG if needed
export DEBIAN_FRONTEND=noninteractive
ensure_pgdg_repo || log "WARNING: Could not refresh PGDG signing key (will retry during PostgreSQL restore)."
apt-get update -y || true
apt-get install -y rsync jq git curl gnupg ca-certificates build-essential autoconf pkg-config \
                   redis-server redis-tools unzip sshpass || true

# Extract package
log "Extracting package to $EXTRACT_DIR"
tar -C "$EXTRACT_DIR" -xzf "$PACKAGE"

# Plesk detection
PLESK_PRESENT=0
if command -v plesk >/dev/null 2>&1; then PLESK_PRESENT=1; fi

# Decide Plesk toggles (auto-enable if Plesk is present and package contains opcache hints)
MIGRATE_PHP_OPCACHE=0
if [ "$PLESK_EXPECTED" = "true" ] || { [ "$PLESK_EXPECTED" = "auto" ] && [ "$PLESK_PRESENT" = 1 ] && [ -s "$EXTRACT_DIR/plesk/opcache.filtered.ini" ]; }; then
  MIGRATE_PHP_OPCACHE=1
fi

# Helper: run and capture log per step
STEP_N=0
RESULTS=()
add_result(){ RESULTS+=("$1|$2|$3"); }
print_summary(){
  echo
  echo "======== Import Summary ========"
  local ok=0 fail=0 skip=0
  for e in "${RESULTS[@]}"; do
    IFS='|' read -r label status logp <<<"$e"
    case "$status" in
      OK) ok=$((ok+1)); printf "[OK]   %s (log: %s)\n" "$label" "$logp" ;;
      FAIL) fail=$((fail+1)); printf "[FAIL] %s (log: %s)\n" "$label" "$logp" ;;
      SKIP*) skip=$((skip+1)); printf "[SKIP] %s - %s\n" "$label" "${status#SKIP: }" ;;
      *) printf "[INFO] %s - %s\n" "$label" "$status" ;;
    esac
  done
  echo "--------------------------------"
  printf "Totals: OK=%d FAIL=%d SKIP=%d\n" "$ok" "$fail" "$skip"
  [ "$fail" -eq 0 ] || return 1
}

run_step() { # label command...
  local label="$1"; shift
  local logf="$LOG_DIR/${label}.log"
  STEP_N=$((STEP_N+1))
  echo; echo "==> ${label}"; echo
  if "$@" |& tee -a "$logf"; then
    add_result "$label" OK "$logf"
    return 0
  else
    add_result "$label" FAIL "$logf"
    return 1
  fi
}

# 1) Prereqs and Plesk PHP (if needed)
step_prereqs() {
  # If Plesk is present and opcache migration enabled, ensure a Plesk PHP exists
  if [ "$MIGRATE_PHP_OPCACHE" = 1 ]; then
    if [ ! -x "/opt/plesk/php/${PLESK_PHP_VER}/bin/php" ]; then
      # Try to use an installed one
      BEST_VER="$(ls -1d /opt/plesk/php/*/bin/php 2>/dev/null | awk -F'/' '{print $(NF-2)}' | sort -V | tail -n1)"
      if [ -n "$BEST_VER" ] && [ -x "/opt/plesk/php/${BEST_VER}/bin/php" ]; then
        PLESK_PHP_VER="$BEST_VER"
        log "Using installed Plesk PHP ${BEST_VER}"
      else
        log "Installing Plesk PHP ${PLESK_PHP_VER}"
        plesk installer add --components "php${PLESK_PHP_VER//./}" -y || true
      fi
    fi
  fi
  echo OK
}

# 2) PostgreSQL restore (if package contains it)
step_postgres() {
  if [ ! -s "$EXTRACT_DIR/pg/pg_dumpall.sql.gz" ]; then echo "SKIP"; return 0; fi
  . /etc/os-release
  ensure_pgdg_repo
  apt-get update -y
  apt-get install -y postgresql-common postgresql-17 postgresql-client-17
  if systemctl is-active --quiet postgresql; then systemctl stop postgresql; fi
  if pg_lsclusters | awk '$1==17 && $2=="main"{found=1} END{exit(!found)}'; then
    pg_dropcluster --stop 17 main
  fi
  pg_createcluster 17 main --start
  gunzip -c "$EXTRACT_DIR/pg/pg_dumpall.sql.gz" | sudo -u postgres psql >/dev/null
  [ -f "$EXTRACT_DIR/pg/pg_hba.conf.source" ] && cp -a "$EXTRACT_DIR/pg/pg_hba.conf.source" "$WORK_ROOT/files/pg_hba.conf.source" || true
  [ -f "$EXTRACT_DIR/pg/postgresql.conf.source" ] && cp -a "$EXTRACT_DIR/pg/postgresql.conf.source" "$WORK_ROOT/files/postgresql.conf.source" || true
  systemctl restart postgresql
  sleep 2
  sudo -u postgres psql -tA -c 'select version();' | sed -e 's/^/[PG]/'
}

# 3) Mattermost import and start (if package contains it)
step_mattermost() {
  if [ ! -d "$EXTRACT_DIR/mm" ]; then echo "SKIP"; return 0; fi
  DEST_MM="/opt/mattermost"
  id -u mattermost >/dev/null 2>&1 || useradd --system --user-group --home-dir "$DEST_MM" --shell /usr/sbin/nologin mattermost || true
  install -d -m 0755 "$DEST_MM"
  rsync -a "$EXTRACT_DIR/mm/" "$DEST_MM/"
  if [ -f "$EXTRACT_DIR/mm/mattermost.service" ]; then
    cp -a "$EXTRACT_DIR/mm/mattermost.service" /lib/systemd/system/mattermost.service
    systemctl daemon-reload || true
    systemctl enable mattermost || true
  fi
  chown -R mattermost:mattermost "$DEST_MM"
  # Ensure config exists
  if [ -f "$DEST_MM/config/config.json" ]; then
    systemctl restart mattermost || systemctl start mattermost || true
    sleep 2
    systemctl --no-pager status mattermost || true
  fi
  echo OK
}

# 4) Redis config
step_redis() {
  if [ ! -s "$EXTRACT_DIR/redis/redis_selected.conf" ]; then echo "SKIP"; return 0; fi
  DEST="/etc/redis/redis.conf"
  [ -f "$DEST" ] || DEST="/etc/redis.conf"
  [ -f "$DEST" ] || { echo "SKIP"; return 0; }
  cp -a "$DEST" "$DEST.bak.$(date +%s)"
  # If we have an ACL file, drop it in a sane location and update directive
  ACL_DST=""
  if [ -s "$EXTRACT_DIR/redis/redis_aclfile.source" ]; then
    ACL_DST="/etc/redis/migrated_aclfile.acl"
    cp -a "$EXTRACT_DIR/redis/redis_aclfile.source" "$ACL_DST"
    sed -i -E "/^\s*aclfile\s+/d" "$EXTRACT_DIR/redis/redis_selected.conf" || true
    echo "aclfile $ACL_DST" >> "$EXTRACT_DIR/redis/redis_selected.conf"
  fi
  {
    echo
    echo "# ===== BEGIN MIGRATED $(date -Iseconds) ====="
    cat "$EXTRACT_DIR/redis/redis_selected.conf"
    echo "# ===== END MIGRATED ====="
  } >>"$DEST"
  systemctl restart redis-server || systemctl restart redis || true
  sleep 1
  redis-cli ping || true
  echo OK
}

# 5) Plesk OPcache config
step_opcache() {
  if [ "$MIGRATE_PHP_OPCACHE" != 1 ]; then echo "SKIP: disabled"; return 0; fi
  if [ ! -s "$EXTRACT_DIR/plesk/opcache.filtered.ini" ]; then echo "SKIP: no opcache config"; return 0; fi
  PHP_BASE="/opt/plesk/php/${PLESK_PHP_VER}"
  if [ ! -x "$PHP_BASE/bin/php" ]; then echo "SKIP: php ${PLESK_PHP_VER} missing"; return 0; fi
  DEST_DIR="$PHP_BASE/etc/php.d"
  install -d -m 0755 "$DEST_DIR"
  cp -a "$EXTRACT_DIR/plesk/opcache.filtered.ini" "$DEST_DIR/zz-migrated-opcache.ini"
  systemctl restart "plesk-php${PLESK_PHP_VER//./}-fpm" || true
  "$PHP_BASE/bin/php" -i | grep -i '^opcache.enable' || true
  echo OK
}

# Run steps with logging
run_step 00_prereqs step_prereqs || true
run_step 10_postgres step_postgres || true
run_step 20_mattermost step_mattermost || true
run_step 30_redis step_redis || true
run_step 40_opcache step_opcache || true

print_summary || exit 1
