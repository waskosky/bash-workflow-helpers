set -euo pipefail

umask 077
install -d -m 0750 /root/migration/{subs,logs,tmp,files,work}

cat > /root/migration/migration.env <<'"EOF_ENV"'
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
MIGRATE_PHP_OPCACHE=1
MIGRATE_PHP_RELAY=1
MIGRATE_NGINX_GLOBALS=1
# Cron is two-phase: prepare stubs by default, apply after review.
MIGRATE_CRONS_PREPARE=1
MIGRATE_CRONS_APPLY=0

# === Plesk PHP target ===
PLESK_PHP_VER="8.2"   # must exist at /opt/plesk/php/8.2

# Optional: change Mattermost DB DSN during migrate; leave empty to keep as-is
MM_NEW_DSN=""

# Internal defaults
DEBIAN_FRONTEND=noninteractive
# Build SSH options
SSH_OPTS="-p ${SRC_SSH_PORT} -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
if [ -n "${SSH_IDENTITY_FILE:-}" ]; then SSH_OPTS="${SSH_OPTS} -i ${SSH_IDENTITY_FILE}"; fi
EOF_ENV

cat > /root/migration/migrate_services.sh <<'"EOF_MAIN"'
#!/usr/bin/env bash
set -euo pipefail

BASE="/root/migration"
ENVF="$BASE/migration.env"
LOGD="$BASE/logs"
SUBD="$BASE/subs"

if [ ! -f "$ENVF" ]; then echo "Missing $ENVF. Edit and re-run."; exit 1; fi
# shellcheck disable=SC1090
source "$ENVF"

run_sub() {
  local sub="$1"; shift || true
  local log="$LOGD/${sub##*/}.log"
  echo "==> ${sub##*/}"
  chmod +x "$sub"
  # Pass through args to sub-scripts
  "$sub" "$@" |& tee -a "$log"
  echo
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
    run_sub "$SUBD/00_prereqs_check.sh"
    [ "${MIGRATE_POSTGRES:-0}" = "1" ]      && run_sub "$SUBD/10_postgres17_migrate.sh"
    [ "${MIGRATE_MATTERMOST:-0}" = "1" ]    && run_sub "$SUBD/20_mattermost_migrate.sh"
    [ "${MIGRATE_REDIS:-0}" = "1" ]         && run_sub "$SUBD/30_redis_migrate.sh"
    [ "${MIGRATE_PHP_OPCACHE:-0}" = "1" ]   && run_sub "$SUBD/40_php_opcache_migrate.sh"
    [ "${MIGRATE_PHP_RELAY:-0}" = "1" ]     && run_sub "$SUBD/45_php_relay_install.sh"
    [ "${MIGRATE_NGINX_GLOBALS:-0}" = "1" ] && run_sub "$SUBD/50_nginx_customs_migrate.sh"
    # Cron last
    if [ "${MIGRATE_CRONS_PREPARE:-0}" = "1" ] || [ "${MIGRATE_CRONS_APPLY:-0}" = "1" ]; then
      run_sub "$SUBD/60_cron_migrate.sh"
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

cat > /root/migration/subs/00_prereqs_check.sh <<'"EOF_00"'
#!/usr/bin/env bash
set -euo pipefail
BASE="/root/migration"
# shellcheck disable=SC1090
source "$BASE/migration.env"

log() { printf "[%s] %s\n" "$(date -Iseconds)" "$*"; }

# Root check
if [ "$EUID" -ne 0 ]; then echo "Run as root."; exit 1; fi

# OS + Plesk checks
if ! command -v plesk >/dev/null 2>&1; then echo "Plesk CLI not found."; exit 1; fi
. /etc/os-release
if [ "${ID,,}" != "ubuntu" ] || [[ "${VERSION_ID}" != 24* ]]; then
  echo "This target must be Ubuntu 24.x. Detected: $PRETTY_NAME"; exit 1
fi

# Ensure dirs
install -d -m 0750 "$BASE"/{logs,tmp,files,work}

# Packages
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y rsync jq git curl gnupg build-essential autoconf pkg-config \
                   redis-server redis-tools unzip

# Plesk PHP
if [ ! -x "/opt/plesk/php/${PLESK_PHP_VER}/bin/php" ]; then
  echo "Plesk PHP ${PLESK_PHP_VER} missing. Install via:"
  echo "  plesk installer add --components php${PLESK_PHP_VER//./}"
  exit 1
fi

# SSH to source
SSH_BASE=(ssh $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}")
if ! "${SSH_BASE[@]}" 'echo ok' >/dev/null 2>&1; then
  echo "SSH to ${SRC_HOST} failed. Check migration.env"; exit 1
fi

log "Prereqs ok. Plesk: $(plesk version 2>/dev/null | head -n1)"
EOF_00

cat > /root/migration/subs/10_postgres17_migrate.sh <<'"EOF_10"'
#!/usr/bin/env bash
set -euo pipefail
BASE="/root/migration"
# shellcheck disable=SC1090
source "$BASE/migration.env"

if [ "${MIGRATE_POSTGRES:-0}" != "1" ]; then echo "PostgreSQL migrate disabled."; exit 0; fi

log() { printf "[%s] %s\n" "$(date -Iseconds)" "$*"; }
SSH_BASE=(ssh $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}")

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

# Determine source PGDATA, dump all
log "Detecting source PG data directory..."
SRC_PGDATA="$("${SSH_BASE[@]}" 'sudo -u postgres psql -tA -c "show data_directory;"' 2>/dev/null || true)"
if [ -z "$SRC_PGDATA" ]; then
  echo "Could not detect source data_directory. Proceeding with dump anyway."
fi

log "Dumping roles + databases on source..."
DUMP_GZ="$BASE/files/pg_dumpall.sql.gz"
"${SSH_BASE[@]}" 'sudo -u postgres pg_dumpall --no-role-passwords | gzip -c' >"$DUMP_GZ"

log "Restoring into local 17/main cluster..."
gunzip -c "$DUMP_GZ" | sudo -u postgres psql >/dev/null

# Save source pg_hba.conf and postgresql.conf for reference (do not overwrite automatically)
if [ -n "$SRC_PGDATA" ]; then
  scp $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}:${SRC_PGDATA}/pg_hba.conf" "$BASE/files/pg_hba.conf.source" || true
  scp $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}:${SRC_PGDATA}/postgresql.conf" "$BASE/files/postgresql.conf.source" || true
fi

systemctl restart postgresql
sleep 2
sudo -u postgres psql -tA -c "select version();" | sed -e "s/^/[PG]/"
log "PostgreSQL 17 migration done. Review $BASE/files/pg_hba.conf.source if auth rules must be mirrored."
EOF_10

cat > /root/migration/subs/20_mattermost_migrate.sh <<'"EOF_20"'
#!/usr/bin/env bash
set -euo pipefail
BASE="/root/migration"
# shellcheck disable=SC1090
source "$BASE/migration.env"

if [ "${MIGRATE_MATTERMOST:-0}" != "1" ]; then echo "Mattermost migrate disabled."; exit 0; fi

log() { printf "[%s] %s\n" "$(date -Iseconds)" "$*"; }
SSH_BASE=(ssh $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}")

DEST_MM="/opt/mattermost"
if [ ! -x "$DEST_MM/bin/mattermost" ]; then
  echo "Mattermost not installed at $DEST_MM. Install it first, then re-run."; exit 1
fi

# Find source dir
SRC_MM="$("${SSH_BASE[@]}" 'if [ -d /opt/mattermost ]; then echo /opt/mattermost; fi')"
if [ -z "$SRC_MM" ]; then echo "Source Mattermost directory not found."; exit 1; fi

log "Stopping Mattermost locally..."
systemctl stop mattermost || true

# Backup current config
if [ -f "$DEST_MM/config/config.json" ]; then
  cp -a "$DEST_MM/config/config.json" "$BASE/files/config.json.dest.bak.$(date +%s)"
fi

log "Fetching source config.json..."
scp $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}:${SRC_MM}/config/config.json" "$BASE/files/config.json.source"

# Optionally adjust DSN
if [ -n "${MM_NEW_DSN:-}" ]; then
  jq --arg dsn "$MM_NEW_DSN" '.SqlSettings.DataSource=$dsn' "$BASE/files/config.json.source" > "$BASE/files/config.json.migrated"
else
  cp -a "$BASE/files/config.json.source" "$BASE/files/config.json.migrated"
fi

install -d -m 0750 "$DEST_MM"/{data,plugins,client/plugins}

log "Syncing data and plugins from source (rsync)..."
rsync -aHAX -e "ssh $SSH_OPTS" --delete "${SRC_SSH_USER}@${SRC_HOST}:${SRC_MM}/data/" "$DEST_MM/data/"
rsync -aHAX -e "ssh $SSH_OPTS" --delete "${SRC_SSH_USER}@${SRC_HOST}:${SRC_MM}/plugins/" "$DEST_MM/plugins/"
rsync -aHAX -e "ssh $SSH_OPTS" --delete "${SRC_SSH_USER}@${SRC_HOST}:${SRC_MM}/client/plugins/" "$DEST_MM/client/plugins/"

install -m 0640 "$BASE/files/config.json.migrated" "$DEST_MM/config/config.json"
chown -R mattermost:mattermost "$DEST_MM"

log "Starting Mattermost..."
systemctl start mattermost
sleep 2
systemctl --no-pager status mattermost || true
log "Mattermost migration done."
EOF_20

cat > /root/migration/subs/30_redis_migrate.sh <<'"EOF_30"'
#!/usr/bin/env bash
set -euo pipefail
BASE="/root/migration"
# shellcheck disable=SC1090
source "$BASE/migration.env"

if [ "${MIGRATE_REDIS:-0}" != "1" ]; then echo "Redis migrate disabled."; exit 0; fi

log() { printf "[%s] %s\n" "$(date -Iseconds)" "$*"; }
SSH_BASE=(ssh $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}")

apt-get update -y
apt-get install -y redis-server redis-tools

SRC_REDIS_CONF="$("${SSH_BASE[@]}" 'test -f /etc/redis/redis.conf && echo /etc/redis/redis.conf || (test -f /etc/redis.conf && echo /etc/redis.conf)' )"
if [ -z "$SRC_REDIS_CONF" ]; then echo "Source redis.conf not found."; exit 1; fi

log "Fetching selected Redis settings from $SRC_REDIS_CONF..."
"${SSH_BASE[@]}" "sudo awk '
/^(bind|port|maxmemory|maxmemory-policy|save|appendonly|appendfsync|requirepass|rename-command|aclfile|unixsocket|timeout|tcp-backlog|databases)[[:space:]]/ {print}
/^user[[:space:]]/ {print}
' \"$SRC_REDIS_CONF\"" > "$BASE/files/redis_selected.conf"

# If an ACL file is used, copy it for reference
ACL_FILE="$(awk '\''$1=="aclfile"{print $2}'\'' "$BASE/files/redis_selected.conf" || true)"
if [ -n "$ACL_FILE" ]; then
  scp $SSH_OPTS "${SRC_SSH_USER}@${SRC_HOST}:${ACL_FILE}" "$BASE/files/redis_aclfile.source" || true
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

cat > /root/migration/subs/40_php_opcache_migrate.sh <<'"EOF_40"'
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

cat > /root/migration/subs/45_php_relay_install.sh <<'"EOF_45"'
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

cat > /root/migration/subs/50_nginx_customs_migrate.sh <<'"EOF_50"'
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

cat > /root/migration/subs/60_cron_migrate.sh <<'"EOF_60"'
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

chmod +x /root/migration/migrate_services.sh /root/migration/subs/*.sh
echo "Created. Next steps:"
echo "  1) Edit /root/migration/migration.env"
echo "  2) /root/migration/migrate_services.sh list"
echo "  3) /root/migration/migrate_services.sh run-all"
