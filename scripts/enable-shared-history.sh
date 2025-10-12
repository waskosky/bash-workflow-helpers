#!/usr/bin/env bash
set -euo pipefail

# Configure shared shell history so multiple sessions share live history.
# - Installs for current user (~/.bashrc and, if present, ~/.zshrc)
# - Optionally installs system-wide via sudo (all users, including root)
# The inserted config is idempotent and wrapped in clear BEGIN/END markers.

MARK_BEGIN="# >>> shared-history (managed by bash-workflow-helpers) >>>"
MARK_END="# <<< shared-history (managed by bash-workflow-helpers) <<<"

timestamp() { date +%Y%m%d-%H%M%S; }

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  cp -p "$f" "${f}.bak.$(timestamp)"
}

ensure_block_in_file() {
  local file="$1"
  local block="$2"
  mkdir -p "$(dirname "$file")"
  touch "$file"

  # If block is present, refresh it in-place; otherwise append a new one
  if grep -Fq "$MARK_BEGIN" "$file"; then
    backup_file "$file"
    local tmp_block tmp_out
    tmp_block="$(mktemp)"; tmp_out="$(mktemp)"
    printf "%s\n" "$block" >"$tmp_block"
    awk -v begin="$MARK_BEGIN" -v end="$MARK_END" -v blockfile="$tmp_block" '
      BEGIN{inblock=0}
      $0==begin {
        print begin;
        while ((getline line < blockfile) > 0) print line;
        close(blockfile);
        print end;
        inblock=1;
        next;
      }
      inblock && $0==end { inblock=0; next }
      inblock { next }
      { print }
    ' "$file" >"$tmp_out"
    mv -f "${tmp_out}" "$file"
    rm -f "$tmp_block"
    echo "+ Refreshed shared-history block in $file"
    return 0
  fi

  backup_file "$file"
  {
    echo ""
    echo "$MARK_BEGIN"
    printf "%s\n" "$block"
    echo "$MARK_END"
  } >>"$file"
  echo "+ Installed shared-history block into $file"
}

bash_block() {
  cat <<'EOF'
# Shared Bash history across sessions
if [ -n "$BASH_VERSION" ] && [[ $- == *i* ]]; then
  # Keep a big history and include timestamps
  export HISTFILE="${HISTFILE:-$HOME/.bash_history}"
  export HISTSIZE="${HISTSIZE:-500000}"
  export HISTFILESIZE="${HISTFILESIZE:-500000}"
  export HISTTIMEFORMAT="${HISTTIMEFORMAT:-%F %T }"

  # Avoid consecutive duplicates and collapse older duplicates
  export HISTCONTROL=ignoredups:erasedups

  # Append rather than overwrite; keep multi-line commands unified
  shopt -s histappend
  shopt -s cmdhist

  __shared_history_histfile_ready() {
    local histfile="$1"
    [[ -n "$histfile" ]] || return 1

    if [[ "$histfile" == */* ]]; then
      local histdir="${histfile%/*}"
      [[ -n "$histdir" ]] || histdir="/"
      if [[ ! -d "$histdir" ]]; then
        mkdir -p "$histdir" 2>/dev/null || return 1
      fi
    fi

    if [[ ! -e "$histfile" ]]; then
      touch "$histfile" 2>/dev/null || return 1
      chmod 0600 "$histfile" 2>/dev/null || :
    fi

    [[ -w "$histfile" ]] || return 1
    return 0
  }

  __shared_history_histfile_signature() {
    local file="$1"
    if [[ ! -e "$file" ]]; then
      echo "0:0:0:0"
      return
    fi

    if [[ -z "${__SHARED_HISTORY_STAT_FMT:-}" ]]; then
      if stat -Lc '%d:%i:%s:%Y' "$file" >/dev/null 2>&1; then
        __SHARED_HISTORY_STAT_FMT=gnu
      elif stat -f '%d:%i:%z:%m' "$file" >/dev/null 2>&1; then
        __SHARED_HISTORY_STAT_FMT=bsd
      else
        __SHARED_HISTORY_STAT_FMT=wc
      fi
    fi

    case "${__SHARED_HISTORY_STAT_FMT}" in
      gnu)
        stat -Lc '%d:%i:%s:%Y' "$file" 2>/dev/null || echo "0:0:0:0"
        ;;
      bsd)
        stat -f '%d:%i:%z:%m' "$file" 2>/dev/null || echo "0:0:0:0"
        ;;
      *)
        local size
        size=$(wc -c <"$file" 2>/dev/null || echo 0)
        printf '0:0:%s:0\n' "$size"
        ;;
    esac
  }

  __shared_history_sync_history() {
    local default_histfile="$HOME/.bash_history"
    local histfile="${HISTFILE:-$default_histfile}"

    if ! __shared_history_histfile_ready "$histfile"; then
      if [[ "$histfile" != "$default_histfile" ]] && __shared_history_histfile_ready "$default_histfile"; then
        histfile="$default_histfile"
        HISTFILE="$default_histfile"
        export HISTFILE
      else
        if [[ "${__SHARED_HISTORY_WARNED:-0}" -eq 0 ]]; then
          __SHARED_HISTORY_WARNED=1
          printf 'shared-history: unable to access %s (history sharing disabled)\n' "$histfile" >&2
        fi
        return
      fi
    fi

    if [[ "${__SHARED_HISTORY_FILE:-}" != "$histfile" ]]; then
      __SHARED_HISTORY_FILE="$histfile"
      __SHARED_HISTORY_DEV=""
      __SHARED_HISTORY_INO=""
      __SHARED_HISTORY_SIZE=""
      __SHARED_HISTORY_WARNED=0
    fi

    builtin history -a "$histfile" 2>/dev/null || :

    local sig dev ino size mtime reload
    sig="$(__shared_history_histfile_signature "$histfile")"
    IFS=: read -r dev ino size mtime <<<"$sig"

    reload=0
    if [[ -z "${__SHARED_HISTORY_DEV:-}" ]] || [[ -z "${__SHARED_HISTORY_INO:-}" ]]; then
      reload=1
    elif [[ "$dev:$ino" != "${__SHARED_HISTORY_DEV}:${__SHARED_HISTORY_INO}" ]]; then
      reload=1
    elif [[ -n "${__SHARED_HISTORY_SIZE:-}" && "$size" -lt "${__SHARED_HISTORY_SIZE}" ]]; then
      reload=1
    fi

    if (( reload )); then
      builtin history -c 2>/dev/null || :
      builtin history -r "$histfile" 2>/dev/null || :
    else
      builtin history -n "$histfile" 2>/dev/null || :
    fi

    __SHARED_HISTORY_DEV="$dev"
    __SHARED_HISTORY_INO="$ino"
    __SHARED_HISTORY_SIZE="$size"
  }

  # Safely attach to PROMPT_COMMAND, supporting both string and array forms
  if declare -p PROMPT_COMMAND 2>/dev/null | grep -q 'declare \-a'; then
    case " ${PROMPT_COMMAND[*]} " in
      *" __shared_history_sync_history "*) ;;
      *) PROMPT_COMMAND=(__shared_history_sync_history "${PROMPT_COMMAND[@]}");;
    esac
  else
    case ";${PROMPT_COMMAND:-};" in
      *"__shared_history_sync_history"*) ;;
      *) PROMPT_COMMAND="__shared_history_sync_history${PROMPT_COMMAND:+; ${PROMPT_COMMAND}}" ;;
    esac
  fi
fi
EOF
}

zsh_block() {
  cat <<'EOF'
# Shared Zsh history across sessions
if [ -n "$ZSH_VERSION" ]; then
  export HISTFILE="${HISTFILE:-$HOME/.zsh_history}"
  export HISTSIZE="${HISTSIZE:-500000}"
  export SAVEHIST="${SAVEHIST:-500000}"

  setopt APPEND_HISTORY           # Append rather than overwrite
  setopt INC_APPEND_HISTORY       # Write each command as it's entered
  setopt SHARE_HISTORY            # Share/merge history across sessions
  setopt HIST_IGNORE_ALL_DUPS     # Drop older duplicates
  setopt EXTENDED_HISTORY         # Timestamp + duration in history file
fi
EOF
}

install_user() {
  echo "Configuring shared history for the current user..."
  local bashrc="$HOME/.bashrc"
  ensure_block_in_file "$bashrc" "$(bash_block)"

  # Ensure login shells also load .bashrc (macOS default is login shells)
  local bash_profile="$HOME/.bash_profile"
  if [[ ! -f "$bash_profile" ]] || ! grep -Fq 'source ~/.bashrc' "$bash_profile"; then
    backup_file "$bash_profile" || true
    {
      echo ""
      echo "# Ensure interactive login shells include ~/.bashrc"
      echo "if [ -f ~/.bashrc ]; then . ~/.bashrc; fi"
    } >> "$bash_profile"
    echo "+ Ensured ~/.bash_profile sources ~/.bashrc"
  else
    echo "- ~/.bash_profile already sources ~/.bashrc"
  fi

  # If user also uses zsh, set it up too
  if [[ -f "$HOME/.zshrc" ]] || [[ "${SHELL:-}" == *"zsh"* ]]; then
    ensure_block_in_file "$HOME/.zshrc" "$(zsh_block)"
  else
    echo "- Skipping zsh: ~/.zshrc not found and shell not zsh"
  fi
}

install_systemwide() {
  echo "Configuring shared history system-wide (requires sudo)..."

  # Prefer profile.d drop-in which covers login shells (bash and zsh)
  local profiled='/etc/profile.d'
  local dropin="$profiled/shared-history.sh"

  if [[ -d "$profiled" ]]; then
    local tmp
    tmp="$(mktemp)"
    {
      echo "$MARK_BEGIN"
      bash_block
      echo ""
      zsh_block
      echo "$MARK_END"
    } > "$tmp"
    sudo mkdir -p "$profiled"
    if [[ -f "$dropin" ]]; then
      sudo cp -p "$dropin" "${dropin}.bak.$(timestamp)"
      echo "+ Refreshed $dropin"
    else
      echo "+ Installed $dropin"
    fi
    sudo tee "$dropin" >/dev/null < "$tmp"
    sudo chmod 0644 "$dropin"
    rm -f "$tmp"
  else
    # Fallback to global bashrc if profile.d doesn't exist
    local bash_global_candidates=(/etc/bash.bashrc /etc/bashrc)
    local target=""
    for f in "${bash_global_candidates[@]}"; do
      if [[ -f "$f" ]]; then target="$f"; break; fi
    done
    if [[ -n "$target" ]]; then
      local tmp tmp_awk
      tmp="$(mktemp)"; tmp_awk="$(mktemp)"
      bash_block > "$tmp"
      cat >"$tmp_awk" <<'AWK'
BEGIN{inblock=0}
$0==begin {
  print begin;
  while ((getline line < blockfile) > 0) print line;
  close(blockfile);
  print end;
  inblock=1;
  next;
}
inblock && $0==end { inblock=0; next }
inblock { next }
{ print }
AWK
      sudo bash -c '
        set -e
        file="$1"; mark_begin="$2"; mark_end="$3"; blockfile="$4"; awkscript="$5"
        if grep -Fq "$mark_begin" "$file"; then
          cp -p "$file" "${file}.bak.$(date +%Y%m%d-%H%M%S)"
          tmp_out="$(mktemp)"
          awk -v begin="$mark_begin" -v end="$mark_end" -v blockfile="$blockfile" -f "$awkscript" "$file" >"$tmp_out"
          mv -f "$tmp_out" "$file"
          echo "+ Refreshed shared-history block into $file"
        else
          cp -p "$file" "${file}.bak.$(date +%Y%m%d-%H%M%S)"
          { echo; echo "$mark_begin"; cat "$blockfile"; echo "$mark_end"; } >> "$file"
          echo "+ Installed shared-history block into $file"
        fi
      ' bash "$target" "$MARK_BEGIN" "$MARK_END" "$tmp" "$tmp_awk"
      rm -f "$tmp" "$tmp_awk"
    else
      echo "! Could not find a global Bash rc file and /etc/profile.d is missing."
      echo "  You may create /etc/profile.d/shared-history.sh manually with the snippet."
    fi
  fi

  # Also ensure root gets it in root's ~/.bashrc for interactive shells
  if sudo test -d /root; then
    local root_bashrc="/root/.bashrc"
    # Prepare a temp with just the block content (no markers; we'll add markers in-place)
    local tmp
    tmp="$(mktemp)"
    bash_block > "$tmp"
    # Append in root's .bashrc if missing
    local tmp_awk
    tmp_awk="$(mktemp)"
    cat >"$tmp_awk" <<'AWK'
BEGIN{inblock=0}
$0==begin {
  print begin;
  while ((getline line < blockfile) > 0) print line;
  close(blockfile);
  print end;
  inblock=1;
  next;
}
inblock && $0==end { inblock=0; next }
inblock { next }
{ print }
AWK
    sudo bash -c '
      set -e
      file="$1"; mark_begin="$2"; mark_end="$3"; blockfile="$4"; awkscript="$5"
      mkdir -p "$(dirname "$file")"
      touch "$file"
      if grep -Fq "$mark_begin" "$file"; then
        cp -p "$file" "${file}.bak.$(date +%Y%m%d-%H%M%S)" || true
        tmp_out="$(mktemp)"
        awk -v begin="$mark_begin" -v end="$mark_end" -v blockfile="$blockfile" -f "$awkscript" "$file" >"$tmp_out"
        mv -f "$tmp_out" "$file"
        echo "+ Refreshed shared-history block into $file"
      else
        cp -p "$file" "${file}.bak.$(date +%Y%m%d-%H%M%S)" || true
        { echo; echo "$mark_begin"; cat "$blockfile"; echo "$mark_end"; } >> "$file"
        echo "+ Installed shared-history block into $file"
      fi
    ' bash "$root_bashrc" "$MARK_BEGIN" "$MARK_END" "$tmp" "$tmp_awk"
    rm -f "$tmp" "$tmp_awk"
  fi
}

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<USAGE
Enable shared shell history across sessions.

Usage: $0 [--system]

Without flags, configures the current user. With --system, also configures
system-wide settings (requires sudo; applies to all users including root).

Re-running this script refreshes existing managed blocks in place.
USAGE
    exit 0
  fi

  install_user

  local do_system="n"
  if [[ "${1:-}" == "--system" ]]; then
    do_system="y"
  else
    read -r -p "Also apply system-wide (all users, including root) via sudo? [y/N] " do_system
  fi
  case "${do_system}" in
    y|Y|yes|YES)
      install_systemwide
      ;;
    *)
      echo "- Skipping system-wide install"
      ;;
  esac

  echo ""
  echo "Done. New shells will pick this up automatically."
  echo "To enable it immediately in current Bash session: run 'source ~/.bashrc'"
}

main "$@"
