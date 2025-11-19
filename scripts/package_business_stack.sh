#!/usr/bin/env bash
set -euo pipefail

umask 077

# Package everything needed from the OLD/source server into a single tar.gz,
# suitable for importing on the NEW server without any NEW->OLD SSH.

SCRIPT_NAME="$(basename "$0")"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-$PWD/business_migration_${TIMESTAMP}.tar.gz}"

# Optional push/run on NEW (upload and execute importer)
NEW_HOST="${NEW_HOST:-}"
NEW_USER="${NEW_USER:-root}"
NEW_PORT="${NEW_PORT:-22}"
NEW_PASS="${NEW_PASS:-}"
REMOTE_PATH="${REMOTE_PATH:-/root/migration/business_package_${TIMESTAMP}.tar.gz}"
IMPORTER_REMOTE="${IMPORTER_REMOTE:-/root/migration/import_business_stack.sh}"
AUTO_RUN="${AUTO_RUN:-false}"
# Importer flags
IM_PLESK="${IM_PLESK:-}"
IM_PHP_VER="${IM_PHP_VER:-}"

usage() {
  cat <<USAGE
Usage: $SCRIPT_NAME [--out FILE] [--push NEW_HOST] [--new-user USER] [--new-port PORT] [--new-pass PASS] [--remote-path PATH] [--run] [--plesk auto|true|false] [--php 8.4]

Creates an air-gapped migration package tar.gz from the current (OLD) server.
Optional: uploads the package + importer to NEW and runs the importer.

Defaults:
  --out            $OUT
  --new-user       $NEW_USER
  --new-port       $NEW_PORT
  --remote-path    $REMOTE_PATH

Examples:
  $SCRIPT_NAME --out ./business_pkg.tgz
  $SCRIPT_NAME --push 203.0.113.10 --run
  $SCRIPT_NAME --push 203.0.113.10 --new-pass 'PASSWORD' --run
  $SCRIPT_NAME --push 203.0.113.10 --run --plesk auto --php 8.4
USAGE
}

SAVE_DEFAULTS=false
while [[ ${1:-} == --* ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --push) NEW_HOST="$2"; shift 2 ;;
    --new-user) NEW_USER="$2"; shift 2 ;;
    --new-port) NEW_PORT="$2"; shift 2 ;;
    --new-pass) NEW_PASS="$2"; shift 2 ;;
    --remote-path) REMOTE_PATH="$2"; shift 2 ;;
    --run) AUTO_RUN=true; shift ;;
    --plesk) IM_PLESK="$2"; shift 2 ;;
    --php) IM_PHP_VER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; usage; exit 1 ;;
  esac
done

if [ "$(id -u)" != 0 ]; then
  echo "Please run as root (required to read service configs, db dumps)." >&2
  exit 1
fi

# Work area
STAGE="$(mktemp -d /tmp/business_pkg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE"/{pg,mm,redis,cron,plesk,meta}

log() { printf '[%s] %s\n' "$(date -Iseconds)" "$*"; }

# 1) PostgreSQL: dump roles + databases + capture conf
if id -u postgres >/dev/null 2>&1; then
  log "Dumping PostgreSQL roles + databases (pg_dumpall)..."
  if sudo -u postgres pg_dumpall --no-role-passwords | gzip -c >"$STAGE/pg/pg_dumpall.sql.gz"; then
    sudo -u postgres psql -tA -c 'show data_directory;' 2>/dev/null \
      | xargs -I{} sh -c 'test -f {}/pg_hba.conf && cp -a {}/pg_hba.conf '"$STAGE/pg/pg_hba.conf.source"' || true; \
                           test -f {}/postgresql.conf && cp -a {}/postgresql.conf '"$STAGE/pg/postgresql.conf.source"' || true' || true
  else
    log "WARN: pg_dumpall failed; skipping Postgres content"
    rm -f "$STAGE/pg/pg_dumpall.sql.gz" || true
  fi
else
  log "PostgreSQL not detected; skipping PG dump"
fi

# 2) Mattermost: copy essential tree
if [ -d /opt/mattermost ]; then
  log "Packaging Mattermost (bin, config, data, plugins)..."
  mkdir -p "$STAGE/mm"
  # Copy binaries and config
  rsync -a --delete --prune-empty-dirs \
        --include='bin/***' --include='config/***' \
        --include='data/***' --include='plugins/***' --include='client/plugins/***' \
        --exclude='*' /opt/mattermost/ "$STAGE/mm/"
  # Systemd unit if present
  if [ -f /lib/systemd/system/mattermost.service ]; then
    cp -a /lib/systemd/system/mattermost.service "$STAGE/mm/mattermost.service"
  fi
else
  log "Mattermost not found; skipping"
fi

# 3) Redis: selected directives + ACL file
if [ -f /etc/redis/redis.conf ] || [ -f /etc/redis.conf ]; then
  SRC_REDIS_CONF="/etc/redis/redis.conf"
  [ -f "$SRC_REDIS_CONF" ] || SRC_REDIS_CONF="/etc/redis.conf"
  log "Capturing selected Redis directives from $SRC_REDIS_CONF"
  awk '/^(bind|port|maxmemory|maxmemory-policy|save|appendonly|appendfsync|requirepass|rename-command|aclfile|unixsocket|timeout|tcp-backlog|databases)[[:space:]]/ {print} /^user[[:space:]]/ {print}' \
    "$SRC_REDIS_CONF" > "$STAGE/redis/redis_selected.conf" || true
  ACL_FILE="$(awk '$1=="aclfile"{print $2}' "$STAGE/redis/redis_selected.conf" 2>/dev/null || true)"
  if [ -n "$ACL_FILE" ] && [ -f "$ACL_FILE" ]; then
    cp -a "$ACL_FILE" "$STAGE/redis/redis_aclfile.source"
  fi
else
  log "Redis config not found; skipping"
fi

# 4) PHP OPcache: harvest opcache.* hints (generic, not Plesk specific)
log "Harvesting PHP OPcache directives (if any)"
{ awk 'BEGIN{IGNORECASE=1} /^\s*opcache\./ {print}' /etc/php.d/*.ini 2>/dev/null; } > "$STAGE/plesk/opcache.source.ini" || true
{ awk 'BEGIN{IGNORECASE=1} /^\s*opcache\./ {print}' /etc/php.ini 2>/dev/null; } >> "$STAGE/plesk/opcache.source.ini" || true
{ awk 'BEGIN{IGNORECASE=1} /^\s*opcache\./ {print}' /etc/php*/mods-available/opcache.ini 2>/dev/null; } >> "$STAGE/plesk/opcache.source.ini" || true
if [ -s "$STAGE/plesk/opcache.source.ini" ]; then
  grep -E '^\s*opcache\.' "$STAGE/plesk/opcache.source.ini" \
    | grep -Ev 'opcache\.blacklist_filename|opcache\.file_cache' \
    > "$STAGE/plesk/opcache.filtered.ini" || true
fi

# 5) Cron: package system and user crons
log "Packaging cron jobs"
mkdir -p "$STAGE/cron/system" "$STAGE/cron/users"
[ -f /etc/crontab ] && cp -a /etc/crontab "$STAGE/cron/system/crontab" || true
[ -d /etc/cron.d ] && rsync -a /etc/cron.d/ "$STAGE/cron/system/cron.d/" || true
if [ -d /var/spool/cron/crontabs ]; then
  rsync -a /var/spool/cron/crontabs/ "$STAGE/cron/users/" || true
elif [ -d /var/spool/cron ]; then
  rsync -a /var/spool/cron/ "$STAGE/cron/users/" || true
fi

# 6) Manifest
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname || echo unknown)"
OS_PRETTY="$(. /etc/os-release; echo "$PRETTY_NAME")"
cat > "$STAGE/meta/manifest.json" <<JSON
{
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source_host": "${HOSTNAME_FQDN}",
  "source_os": "${OS_PRETTY}",
  "includes": {
    "postgres": $( [ -s "$STAGE/pg/pg_dumpall.sql.gz" ] && echo true || echo false ),
    "mattermost": $( [ -d "$STAGE/mm" ] && echo true || echo false ),
    "redis": $( [ -s "$STAGE/redis/redis_selected.conf" ] && echo true || echo false ),
    "opcache": $( [ -s "$STAGE/plesk/opcache.filtered.ini" ] && echo true || echo false ),
    "cron": $( [ -d "$STAGE/cron" ] && echo true || echo false )
  }
}
JSON

# 7) Build tarball
log "Creating package: $OUT"
mkdir -p "$(dirname "$OUT")"
tar -C "$STAGE" -czf "$OUT" .
log "Package ready: $OUT (size: $(du -h "$OUT" | awk '{print $1}'))"

# If a target NEW host is provided, default to auto-run to satisfy one-command UX
if [ -n "$NEW_HOST" ] && [ "$AUTO_RUN" = false ]; then AUTO_RUN=true; fi

# 8) Optional push/run on NEW
if [ -n "$NEW_HOST" ]; then
  # If running interactively and no password or key is set up, offer a one-time NEW password prompt
  if [ -z "$NEW_PASS" ] && [ -t 0 ]; then
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -p "$NEW_PORT" -o StrictHostKeyChecking=accept-new "$NEW_USER@$NEW_HOST" 'echo ok' >/dev/null 2>&1; then
      read -rsp "Enter NEW ($NEW_USER@$NEW_HOST) password (leave blank to be prompted by ssh/scp): " NEW_PASS_INPUT; echo
      [ -n "$NEW_PASS_INPUT" ] && NEW_PASS="$NEW_PASS_INPUT"
    fi
  fi
  log "Uploading package to NEW: $NEW_USER@$NEW_HOST:$REMOTE_PATH"
  if [ -n "$NEW_PASS" ] && command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$NEW_PASS" ssh -p "$NEW_PORT" -o StrictHostKeyChecking=accept-new "$NEW_USER@$NEW_HOST" 'sudo install -d -m 0750 /root/migration'
    sshpass -p "$NEW_PASS" scp -P "$NEW_PORT" -o StrictHostKeyChecking=accept-new "$OUT" "$NEW_USER@$NEW_HOST:$REMOTE_PATH"
  else
    ssh -p "$NEW_PORT" -o StrictHostKeyChecking=accept-new "$NEW_USER@$NEW_HOST" 'sudo install -d -m 0750 /root/migration'
    scp -P "$NEW_PORT" -o StrictHostKeyChecking=accept-new "$OUT" "$NEW_USER@$NEW_HOST:$REMOTE_PATH"
  fi

  # Upload importer script next to the package
  THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
  IMPORTER_LOCAL="$THIS_DIR/import_business_stack.sh"
  if [ ! -f "$IMPORTER_LOCAL" ]; then
    echo "Importer script not found: $IMPORTER_LOCAL" >&2
    exit 1
  fi
  log "Uploading importer to $IMPORTER_REMOTE"
  if [ -n "$NEW_PASS" ] && command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$NEW_PASS" scp -P "$NEW_PORT" -o StrictHostKeyChecking=accept-new "$IMPORTER_LOCAL" "$NEW_USER@$NEW_HOST:$IMPORTER_REMOTE"
  else
    scp -P "$NEW_PORT" -o StrictHostKeyChecking=accept-new "$IMPORTER_LOCAL" "$NEW_USER@$NEW_HOST:$IMPORTER_REMOTE"
  fi
  if [ "$AUTO_RUN" = true ]; then
    log "Executing importer on NEW"
    # Build importer flags
    IM_FLAGS=(--package "$REMOTE_PATH")
    [ -n "$IM_PLESK" ] && IM_FLAGS+=(--plesk "$IM_PLESK")
    [ -n "$IM_PHP_VER" ] && IM_FLAGS+=(--php "$IM_PHP_VER")
    if [ -n "$NEW_PASS" ] && command -v sshpass >/dev/null 2>&1; then
      sshpass -p "$NEW_PASS" ssh -t -p "$NEW_PORT" -o StrictHostKeyChecking=accept-new "$NEW_USER@$NEW_HOST" \
        "sudo bash '$IMPORTER_REMOTE' ${IM_FLAGS[*]}"
    else
      ssh -t -p "$NEW_PORT" -o StrictHostKeyChecking=accept-new "$NEW_USER@$NEW_HOST" \
        "sudo bash '$IMPORTER_REMOTE' ${IM_FLAGS[*]}"
    fi
  else
    log "Importer uploaded. To run on NEW: sudo bash '$IMPORTER_REMOTE' --package '$REMOTE_PATH'"
  fi
fi
