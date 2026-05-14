#!/bin/sh
set -eu

usage() {
  echo "Usage: $0 domain [ip]" >&2
  echo "  Env: VM_PASS to set the domain owner password (random if unset)" >&2
  exit 1
}

if [ $# -lt 1 ]; then
  usage
fi

domain_raw=$1
ip=${2:-127.0.0.1}

if [ "$(id -u)" -ne 0 ]; then
  echo "Must run as root (sudo) to edit /etc/hosts and use Virtualmin." >&2
  exit 1
fi

if command -v virtualmin >/dev/null 2>&1; then
  VM_BIN=$(command -v virtualmin)
elif [ -x /usr/sbin/virtualmin ]; then
  VM_BIN=/usr/sbin/virtualmin
else
  echo "virtualmin CLI not found in PATH or /usr/sbin/virtualmin" >&2
  exit 1
fi

# Normalize and validate domain/hostname
# - strip scheme/path
# - strip trailing dot
# - lowercase
# - allow only a-z0-9.-
domain=$(printf '%s' "$domain_raw" \
  | sed -e 's#^[A-Za-z][A-Za-z0-9+.-]*://##' -e 's#/.*$##' -e 's/\.$//' \
  | tr '[:upper:]' '[:lower:]')

case "$domain" in
  ""|*[!a-z0-9.-]*|.*|*.)
    echo "Invalid domain/hostname: $domain_raw" >&2
    exit 1
    ;;
  *..*)
    echo "Invalid domain/hostname (double dots): $domain_raw" >&2
    exit 1
    ;;
  -*|*-)
    echo "Invalid domain/hostname (leading/trailing hyphen): $domain_raw" >&2
    exit 1
    ;;
esac

# Add to /etc/hosts if missing
if awk -v d="$domain" '
  $0 !~ /^[[:space:]]*#/ {
    for (i=2; i<=NF; i++) {
      if ($i == d) { found=1; exit }
    }
  }
  END { exit(found ? 0 : 1) }
' /etc/hosts; then
  hosts_status="exists"
else
  if [ ! -w /etc/hosts ]; then
    echo "/etc/hosts is not writable" >&2
    exit 1
  fi
  printf "%s\t%s\n" "$ip" "$domain" >> /etc/hosts
  hosts_status="added"
fi

# Generate a username based on the domain
user_base=$(printf '%s' "$domain" \
  | tr '.-' '__' \
  | tr -cd 'a-z0-9_')

if [ -z "$user_base" ]; then
  user_base=site
fi

case "$user_base" in
  [a-z_]* ) : ;;
  * ) user_base="u$user_base" ;;
esac

maxlen=32
user=$(printf '%s' "$user_base" | cut -c1-$maxlen)

if id -u "$user" >/dev/null 2>&1; then
  suffix=1
  while :; do
    suffix=$((suffix + 1))
    avail=$((maxlen - ${#suffix}))
    base_trim=$(printf '%s' "$user_base" | cut -c1-$avail)
    candidate="${base_trim}${suffix}"
    if ! id -u "$candidate" >/dev/null 2>&1; then
      user="$candidate"
      break
    fi
  done
fi

# Get/Generate password
if [ -n "${VM_PASS:-}" ]; then
  pass=$VM_PASS
else
  if command -v openssl >/dev/null 2>&1; then
    pass=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)
  else
    pass=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
  fi
fi

# Skip creation if domain already exists
if "$VM_BIN" list-domains --name-only --domain "$domain" 2>/dev/null | grep -Fxq "$domain"; then
  echo "Virtualmin domain already exists: $domain"
  echo "Hosts entry: $hosts_status ($ip $domain)"
  exit 0
fi

features=$($VM_BIN list-features --name-only 2>/dev/null || true)
if [ -z "$features" ]; then
  # Fall back to common features if list-features is unavailable
  features="web webmin dns mail mysql ssl logrotate"
fi

has_feature() {
  printf '%s\n' "$features" | tr ' ' '\n' | grep -Fxq "$1"
}

set -- create-domain \
  --domain "$domain" \
  --user "$user" \
  --pass "$pass" \
  --unix \
  --dir \
  --limits-from-plan

if has_feature web; then set -- "$@" --web; fi
if has_feature webmin; then set -- "$@" --webmin; fi
if has_feature dns; then set -- "$@" --dns; fi
if has_feature mail; then set -- "$@" --mail; fi
if has_feature ssl; then set -- "$@" --ssl; fi
if has_feature logrotate; then set -- "$@" --logrotate; fi
if has_feature mysql; then set -- "$@" --mysql; fi

"$VM_BIN" "$@"

cat <<SUMMARY
Virtualmin domain created.
  Domain:   $domain
  User:     $user
  Password: $pass
  Hosts:    $hosts_status ($ip $domain)
SUMMARY
