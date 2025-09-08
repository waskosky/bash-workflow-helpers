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
  if grep -Fq "$MARK_BEGIN" "$file"; then
    echo "- Skipping: block already present in $file"
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
if [ -n "$BASH_VERSION" ]; then
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

  # After each command: append this line, then reload from the file
  # so we immediately see other sessions' commands.
  __shared_history_sync_history() { history -a; history -c; history -r; }
  case ";${PROMPT_COMMAND:-};" in
    *"__shared_history_sync_history"*) ;;
    *) PROMPT_COMMAND="__shared_history_sync_history${PROMPT_COMMAND:+; ${PROMPT_COMMAND}}" ;;
  esac
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
    if [[ -f "$dropin" ]] && sudo grep -Fq "$MARK_BEGIN" "$dropin"; then
      echo "- Skipping: block already present in $dropin"
    else
      if [[ -f "$dropin" ]]; then
        sudo cp -p "$dropin" "${dropin}.bak.$(timestamp)"
      fi
      sudo tee "$dropin" >/dev/null < "$tmp"
      sudo chmod 0644 "$dropin"
      echo "+ Installed $dropin"
    fi
    rm -f "$tmp"
  else
    # Fallback to global bashrc if profile.d doesn't exist
    local bash_global_candidates=(/etc/bash.bashrc /etc/bashrc)
    local target=""
    for f in "${bash_global_candidates[@]}"; do
      if [[ -f "$f" ]]; then target="$f"; break; fi
    done
    if [[ -n "$target" ]]; then
      local tmp
      tmp="$(mktemp)"
      bash_block > "$tmp"
      sudo bash -c '
        set -e
        file="$1"; mark_begin="$2" mark_end="$3"
        if grep -Fq "$mark_begin" "$file"; then
          echo "- Skipping: block already present in $file"
        else
          cp -p "$file" "${file}.bak.$(date +%Y%m%d-%H%M%S)"
          { echo; echo "$mark_begin"; cat "$4"; echo "$mark_end"; } >> "$file"
          echo "+ Installed shared-history block into $file"
        fi
      ' bash "$target" "$MARK_BEGIN" "$MARK_END" "$tmp"
      rm -f "$tmp"
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
    sudo bash -c '
      set -e
      file="$1"; mark_begin="$2" mark_end="$3"; tmpfile="$4"
      mkdir -p "$(dirname "$file")"
      touch "$file"
      if grep -Fq "$mark_begin" "$file"; then
        echo "- Skipping: block already present in $file"
      else
        cp -p "$file" "${file}.bak.$(date +%Y%m%d-%H%M%S)" || true
        { echo; echo "$mark_begin"; cat "$tmpfile"; echo "$mark_end"; } >> "$file"
        echo "+ Installed shared-history block into $file"
      fi
    ' bash "$root_bashrc" "$MARK_BEGIN" "$MARK_END" "$tmp"
    rm -f "$tmp"
  fi
}

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<USAGE
Enable shared shell history across sessions.

Usage: $0 [--system]

Without flags, configures the current user. With --system, also configures
system-wide settings (requires sudo; applies to all users including root).
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

