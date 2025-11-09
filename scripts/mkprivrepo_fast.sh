#!/usr/bin/env bash
set -euo pipefail

# ---- anti-hang defaults ----
export GIT_TERMINAL_PROMPT=0
export GH_PROMPT_DISABLED=1
export GH_HTTP_TIMEOUT="${GH_HTTP_TIMEOUT:-20s}"
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2}"
PUSH_TIMEOUT="${PUSH_TIMEOUT:-45s}"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-20s}"
[[ "${DEBUG:-0}" = "1" ]] && set -x

ts(){ date +'%H:%M:%S'; }
say(){ printf '[%s] %s\n' "$(ts)" "$*"; }
die(){ code=$1; shift; say "ERROR: $*"; exit "$code"; }

# ---- timeout helper ----
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="$(command -v timeout)"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="$(command -v gtimeout)"
fi
TIMEOUT_WARNED=0
run_timeout() {
  local duration="$1"; shift
  if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" "$duration" "$@"
  else
    if [[ "$TIMEOUT_WARNED" -eq 0 ]]; then
      say "WARN: Missing GNU timeout (coreutils); running without time limits. Install via 'brew install coreutils' to restore timeouts."
      TIMEOUT_WARNED=1
    fi
    "$@"
  fi
}

# ---- args ----
[[ $# -ge 2 ]] || die 1 'Usage: mkprivrepo_fast.sh "Title of repo" owner/repo|git@github.com:owner/repo.git|https://github.com/owner/repo(.git)'
TITLE="$1"; SPEC="$2"

# ---- parse owner/repo ----
if [[ "$SPEC" =~ ^git@github\.com:([^/]+/[^/]+)(\.git)?$ ]]; then
  OWNER_REPO="${BASH_REMATCH[1]}"
elif [[ "$SPEC" =~ ^https://github\.com/([^/]+/[^/]+)(\.git)?$ ]]; then
  OWNER_REPO="${BASH_REMATCH[1]}"
elif [[ "$SPEC" =~ ^[^/]+/[^/]+$ ]]; then
  OWNER_REPO="$SPEC"
else
  die 2 "Second argument must be owner/repo or a GitHub URL"
fi
OWNER="${OWNER_REPO%%/*}"
REPO="${OWNER_REPO##*/}"; REPO="${REPO%.git}"

# ---- helpers: Desktop registration ----
is_wsl(){ [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; }

uri_encode() { # encode anything not unreserved or path separators
  local s="$1" i c
  for ((i=0; i<${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9._~/:-]) printf '%s' "$c" ;;
      ' ') printf '%%20' ;;
      *)   printf '%%%02X' "'$c" ;;
    esac
  done
}

to_win_slash() { # -> C:/Users/you/path
  local p="$1"
  if command -v wslpath >/dev/null 2>&1; then p="$(wslpath -w "$p")"; fi
  if command -v cygpath >/dev/null 2>&1; then p="$(cygpath -w "$p")"; fi
  p="${p//\\//}"  # backslashes -> forward slashes
  printf '%s' "$p"
}

open_uri() {
  local uri="$1" os; os="$(uname -s 2>/dev/null || echo unknown)"
  case "$os" in
    Darwin) open "$uri" >/dev/null 2>&1 ;;
    MINGW*|MSYS*|CYGWIN*) powershell.exe -NoProfile -NonInteractive -Command "Start-Process '$uri'" >/dev/null 2>&1 ;;
    Linux)
      if is_wsl; then powershell.exe -NoProfile -NonInteractive -Command "Start-Process '$uri'" >/dev/null 2>&1
      else command -v xdg-open >/dev/null 2>&1 && xdg-open "$uri" >/dev/null 2>&1 || return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

open_in_github_desktop() {
  local dir="$1" os; os="$(uname -s 2>/dev/null || echo unknown)"
  say "Registering repo in GitHub Desktop"

  # 1) Prefer Desktop’s CLI if installed (adds repo immediately)
  if command -v github >/dev/null 2>&1; then
    if github "$dir" >/dev/null 2>&1; then
      say "GitHub Desktop CLI accepted the repo"
      return 0
    fi
  fi

  # 2) URL scheme: openLocalRepo with correct path style
  local local_target
  if [[ "$os" == Darwin ]]; then
    local_target="$(uri_encode "$dir")"
  else
    local_target="$(uri_encode "$(to_win_slash "$dir")")"
  fi
  local uri_local="x-github-client://openLocalRepo/${local_target}"

  # Try twice to handle cold start of Desktop
  for _ in 1 2; do
    if open_uri "$uri_local"; then
      sleep 1
      # No reliable programmatic confirmation available (Desktop stores list in IndexedDB)
      say "Requested Desktop to open local repo"
      return 0
    fi
    sleep 1
  done

  # 3) Fallback: open by remote URL (Desktop may match existing local clone)
  local uri_remote="x-github-client://openRepo/https://github.com/${OWNER}/${REPO}"
  if open_uri "$uri_remote"; then
    say "Requested Desktop to open by remote URL"
    return 0
  fi

  return 1
}

# ---- auth helpers ----
require_auth() {
  say "Checking GitHub auth"
  local auth_err
  auth_err="$(mktemp)"
  if ! run_timeout "$HTTP_TIMEOUT" gh api user >/dev/null 2>"$auth_err"; then
    # add read:org for org repo checks
    run_timeout "$HTTP_TIMEOUT" gh auth refresh -h github.com -s repo -s read:org -s admin:public_key >/dev/null 2>>"$auth_err" || true
  fi
  if ! run_timeout "$HTTP_TIMEOUT" gh api user >/dev/null 2>>"$auth_err"; then
    say "Login required"
    run_timeout 120s gh auth login --hostname github.com --git-protocol ssh --web || { rm -f "$auth_err"; die 10 "Login timed out or failed"; }
    if ! run_timeout "$HTTP_TIMEOUT" gh api user >/dev/null 2>>"$auth_err"; then
      rm -f "$auth_err"
      die 10 "GitHub auth check failed after login"
    fi
  fi
  rm -f "$auth_err"
}

get_gh_token() {
  local token status hosts_file

  if token="$(gh auth token 2>/dev/null)"; then
    token="$(printf '%s' "$token" | tr -d '[:space:]')"
    if [[ -n "$token" ]]; then
      printf '%s' "$token"
      return 0
    fi
  fi

  if status="$(gh auth status -t 2>/dev/null)"; then
    token="$(printf '%s\n' "$status" | awk '/Token:/ {print $2; exit}')"
    token="$(printf '%s' "${token:-}" | tr -d '[:space:]')"
    if [[ -n "$token" && "$token" != "(none)" ]]; then
      printf '%s' "$token"
      return 0
    fi
  fi

  hosts_file="${XDG_CONFIG_HOME:-$HOME/.config}/gh/hosts.yml"
  if [[ -f "$hosts_file" ]]; then
    token="$(awk -v host='github.com:' '
      BEGIN {found=0}
      $1 == host {found=1; next}
      found && /oauth_token:/ {print $2; exit}
      found && NF==0 {found=0}
    ' "$hosts_file")"
    token="$(printf '%s' "${token:-}" | tr -d '[:space:]')"
    if [[ -n "$token" && "$token" != "(none)" ]]; then
      printf '%s' "$token"
      return 0
    fi
  fi

  return 1
}


# ---- start ----
require_auth
GH_LOGIN="$(gh api user -q .login)"
GH_ID="$(gh api user -q .id)"
GH_NAME="$(gh api user -q '.name // .login')"
ADDR_ID="${GH_ID}+${GH_LOGIN}@users.noreply.github.com"
ADDR_USER="${GH_LOGIN}@users.noreply.github.com"
USE_EMAIL="$ADDR_ID"

LAUNCH_DIR="$(pwd -P)"
ROOT="${ROOT_OVERRIDE:-$LAUNCH_DIR}"
say "Using base directory $ROOT"
DEST="$ROOT/$REPO"
mkdir -p "$DEST"
cd "$DEST"

# ---- local repo ----
# Important: do not rely on `--is-inside-work-tree` here, because if we're
# inside a parent repo (e.g. $HOME as dotfiles repo), that would be true and we
# would accidentally mutate the parent repo instead of creating a new one.
# We only skip init if THIS directory is already a repo (git-dir resolves to .git).
# If this directory is not already a repo (no .git dir/file), initialize it
if [[ ! -e .git ]]; then
  say "Initializing local repo at $DEST"
  git init -q
  git symbolic-ref HEAD refs/heads/main >/dev/null 2>&1 || true
fi
git config user.name >/dev/null 2>&1 || git config user.name "$GH_NAME"
git config user.email >/dev/null 2>&1 || git config user.email "$USE_EMAIL"

HAS_COMMITS=0
if git rev-parse --verify HEAD >/dev/null 2>&1; then
  HAS_COMMITS=1
  HEAD_EMAIL="$(git log -1 --pretty=format:%ae)"
  if [[ "$HEAD_EMAIL" != "$ADDR_ID" && "$HEAD_EMAIL" != "$ADDR_USER" ]]; then
    say "Amending HEAD to use noreply email"
    git config user.email "$USE_EMAIL"
    GIT_AUTHOR_EMAIL="$USE_EMAIL" GIT_COMMITTER_EMAIL="$USE_EMAIL" git commit --amend --no-edit --reset-author >/dev/null
  fi
else
  say "No commits present; leaving working tree empty."
fi

REMOTE_PROTOCOL_DEFAULT="ssh"
if [[ -n "${REMOTE_PROTOCOL:-}" ]]; then
  REMOTE_PROTOCOL_DEFAULT="${REMOTE_PROTOCOL}"
else
  gh_proto="$(gh config get git_protocol 2>/dev/null || true)"
  if [[ "$gh_proto" =~ ^(ssh|https)$ ]]; then
    REMOTE_PROTOCOL_DEFAULT="$gh_proto"
  fi
fi
case "$REMOTE_PROTOCOL_DEFAULT" in
  https)
    REMOTE_URL="https://github.com/${OWNER}/${REPO}.git"
    ;;
  ssh|*)
    REMOTE_URL="git@github.com:${OWNER}/${REPO}.git"
    REMOTE_PROTOCOL_DEFAULT="ssh"
    ;;
esac
say "Configuring git origin using $REMOTE_PROTOCOL_DEFAULT"
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$REMOTE_URL"
else
  git remote add origin "$REMOTE_URL"
fi

# ---- ensure remote exists ----
# Optional:
#   VISIBILITY=public|private|internal  # for org repos
#   DESC="..."                          # override description; control chars removed automatically

json_escape() {  # minimal JSON escaper
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  printf '%s' "$s"
}

sanitize_desc() {  # remove ASCII control chars (incl. CR, LF, TAB)
  local in="$1"
  printf '%s' "$in" | LC_ALL=C tr -d '\000-\037\177'
}

post_github_json() { # $1=endpoint (starts with /), $2=json payload, $3=output file for the response body; echoes HTTP code
  local endpoint="$1" payload="$2" output="$3" token url code curl_max
  if ! token="$(get_gh_token)"; then
    die 15 "Unable to read GitHub auth token. Upgrade GitHub CLI or rerun 'gh auth login'."
  fi
  url="https://api.github.com$endpoint"
  curl_max="${HTTP_TIMEOUT%s}"
  code="$(
    curl -sS -o "$output" \
      -w '%{http_code}' \
      -H "Authorization: Bearer $token" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      --connect-timeout 15 --max-time "${curl_max:-30}" \
      -d "$payload" "$url"
  )" || code=0
  echo "$code"
}

create_repo_or_explain() {
  local repo_err repo_body payload code endpoint desc
  repo_err="$(mktemp)"
  repo_body="$(mktemp)"

  # Fast path: visible and exists
  if run_timeout "$HTTP_TIMEOUT" gh api -X GET "/repos/${OWNER}/${REPO}" >/dev/null 2>"$repo_err"; then
    rm -f "$repo_err" "$repo_body"
    say "Remote exists"
    return 0
  fi
  if grep -q '401' "$repo_err"; then
    say "401 on repo GET; refreshing auth"
    require_auth
  fi

  say "Creating repo ${OWNER}/${REPO}"
  desc="$(sanitize_desc "${DESC:-$TITLE}")"

  if [[ "$OWNER" == "$GH_LOGIN" ]]; then
    # User repo
    payload=$(printf '{"name":"%s","private":true,"description":"%s"}' \
      "$(json_escape "$REPO")" "$(json_escape "$desc")")
    endpoint="/user/repos"
  else
    # Org repo
    local vis="${VISIBILITY:-private}"  # public|private|internal
    payload=$(printf '{"name":"%s","visibility":"%s","description":"%s"}' \
      "$(json_escape "$REPO")" "$(json_escape "$vis")" "$(json_escape "$desc")")
    endpoint="/orgs/$OWNER/repos"
  fi

  code="$(post_github_json "$endpoint" "$payload" "$repo_body")"
  if [[ "$code" == "201" ]]; then
    rm -f "$repo_err" "$repo_body"
    return 0
  fi

  if grep -qi 'already exists' "$repo_body"; then
    rm -f "$repo_err" "$repo_body"
    say "Repo already exists. Continuing."
    return 0
  fi

  say "Create failed details (HTTP $code): $(tr '\n' ' ' < "$repo_body")"
  if [[ "$code" == "422" ]]; then
    say "Hint: control chars were removed; if policy blocks visibility, set VISIBILITY=public or internal and rerun."
  fi
  rm -f "$repo_err" "$repo_body"
  die 11 "Failed to create repo ${OWNER}/${REPO}"
}

create_repo_or_explain


# ---- push with proper exit-code handling ----
if (( HAS_COMMITS )); then
  say "Pushing to origin"
  push_once() { rm -f push.err; run_timeout "$PUSH_TIMEOUT" git push -u origin HEAD 2>push.err; }

  ok=0
  if push_once; then
    ok=1
  else
    if grep -q 'HTTP 401' push.err; then
      say "401 on push; refreshing auth"
      require_auth
      push_once && ok=1 || ok=0
    fi
  fi

  if (( ! ok )); then
    if grep -q 'GH007' push.err; then
      say "GH007 detected; switching to alternate noreply format"
      USE_EMAIL="$ADDR_USER"
      git config user.email "$USE_EMAIL"
      GIT_AUTHOR_EMAIL="$USE_EMAIL" GIT_COMMITTER_EMAIL="$USE_EMAIL" git commit --amend --no-edit --reset-author >/dev/null
      rm -f push.err
      if run_timeout "$PUSH_TIMEOUT" git push --force-with-lease -u origin HEAD 2>push.err; then
        ok=1
      else
        die 12 "Push failed after GH007 fix: $(tr '\n' ' ' < push.err)"
      fi
    else
      die 13 "Push failed: $(tr '\n' ' ' < push.err)"
    fi
  fi
  rm -f push.err
else
  say "Skipping push; repo has no commits so remote stays empty."
fi

# ---- register in GitHub Desktop ----
if open_in_github_desktop "$DEST"; then
  say "GitHub Desktop registration complete"
else
  say "GitHub Desktop not detected or registration failed; skipping GUI registration"
fi

say "Done"
echo "Local: $DEST"
echo "Remote: $REMOTE_URL"
echo "Author email used: $USE_EMAIL"
