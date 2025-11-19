# bash-workflow-helpers

Small, pragmatic Bash helpers to speed up day‑to‑day developer workflows.

What you get:

- Shared shell history across terminals and sessions (Bash and Zsh).
- A fast path to create/connect a GitHub repo locally (`newrepo`).

These scripts are idempotent, make backups before editing your shell rc files, and are safe to re‑run.

## Contents

- `scripts/enable-shared-history.sh`: Enable live, shared history for Bash and Zsh so every terminal sees the latest commands.
- `scripts/mkprivrepo_fast.sh`: Create or connect to a GitHub repo quickly, handle auth, push, and register in GitHub Desktop.
- `setup_newrepo.sh`: One‑time setup to install the `newrepo` convenience command and ensure `gh` is ready.

## Quickstart

1) Install the `newrepo` helper and verify GitHub CLI auth:

```
./setup_newrepo.sh
```

This will:

- Ensure `gh` is installed and authenticated for Git operations.
- Add `~/.local/bin` to your `PATH` if needed.
- Symlink `~/.local/bin/newrepo` → `scripts/mkprivrepo_fast.sh`.

2) Create or connect a repo in seconds:

```
newrepo "My Project Title" owner/repo
```

You can pass `owner/repo`, `git@github.com:owner/repo(.git)`, or `https://github.com/owner/repo(.git)`.

## Scripts

### enable-shared-history.sh

Enables robust, shared history across concurrent shells so every terminal sees the latest commands.

Features:

- Works for Bash (and Zsh when `~/.zshrc` exists or Zsh is your shell).
- Appends/refreshes a clearly marked config block in your rc files; makes timestamped backups.
- Uses Bash’s `history -a`/`-n` and Zsh’s `SHARE_HISTORY` for live merging without clearing in‑memory history.
- Optional system‑wide install (via sudo) using `/etc/profile.d` or global bashrc fallback.

Usage:

```
# Current user only
./scripts/enable-shared-history.sh

# Also configure system‑wide (all users, including root)
./scripts/enable-shared-history.sh --system
```

Removal: open your `~/.bashrc` or `~/.zshrc` and delete the block between:

```
# >>> shared-history (managed by bash-workflow-helpers) >>>
# <<< shared-history (managed by bash-workflow-helpers) <<<
```

### mkprivrepo_fast.sh (aka `newrepo`)

Creates (or connects to) a GitHub repository and wires your local repo to it quickly.

What it does:

- Verifies GitHub CLI auth; refreshes scopes if needed and supports web login.
- Creates the repo under your user or an org (default visibility private; override with `VISIBILITY=public|internal`).
- Configures your local Git identity to GitHub’s noreply address (avoids GH007 policy blocks) and amends if needed.
- Seeds new repos with a timestamped placeholder `README.md` so there is always initial content.
- Pushes existing commits to `origin` on `main` (skips push if no commits).
- Optionally registers the local repo in GitHub Desktop (macOS, Windows, WSL, Linux with `xdg-open`).
- Uses conservative timeouts to avoid hanging on network issues.

Usage examples:

```
# After running ./setup_newrepo.sh you can use the shortcut name
newrepo "My Project Title" owner/repo

# Or call the script directly
scripts/mkprivrepo_fast.sh "My Project Title" owner/repo

# Using different repo spec formats
newrepo "Title" my-org/my-repo
newrepo "Title" git@github.com:my-org/my-repo.git
newrepo "Title" https://github.com/my-org/my-repo

# Override visibility for org repos
VISIBILITY=public newrepo "Website" my-org/site

# Provide a custom description
DESC="Cool project" newrepo "Cool project" my-user/cool
```

Environment knobs:

- `VISIBILITY`: `public` | `private` | `internal` (org repos; default `private`).
- `DESC`: description string; control characters are stripped.
- `ROOT_OVERRIDE`: directory to place the local clone (default: current working dir).
- `PUSH_TIMEOUT`, `HTTP_TIMEOUT`: tune network timeouts (e.g., `45s`, `20s`).

### setup_newrepo.sh

One‑time helper that:

- Ensures `gh` is installed and authenticated; runs `gh auth setup-git`.
- Creates `~/.local/bin/newrepo` symlink to `scripts/mkprivrepo_fast.sh`.
- Adds `~/.local/bin` to your `PATH` in Bash/Zsh if missing.

Usage:

```
./setup_newrepo.sh
```

Afterwards, run `newrepo "Title" owner/repo` from any directory.

## Requirements

- Bash 4+ and standard Unix tools (`awk`, `sed`, `curl`).
- `git` and the GitHub CLI (`gh`).
- Optional: GitHub Desktop for repo registration.
- OS: Linux, macOS, and WSL are supported; Windows via Git Bash may also work for `newrepo`.

## Notes & troubleshooting

- If `gh` isn’t logged in, scripts will prompt for web login.
- If corporate policy blocks certain visibilities, set `VISIBILITY` accordingly.
- Shared history changes are idempotent and wrapped in markers with backups; re‑running is safe.
- To apply shared history immediately in your current Bash session, run: `source ~/.bashrc`.
