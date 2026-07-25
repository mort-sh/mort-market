#!/usr/bin/env bash
# Shared helpers for auto-ship. Source this file; do not execute.

# Comma-separated allowlist of identities that unlock auto-ship.
# Matched against git user.name and (when available) the GitHub login.
# Override with AUTO_SHIP_GIT_USER or: git config auto-ship.user "mort-sh,m0rt"
auto_ship_allowed_users() {
  local from_git from_env
  from_env="${AUTO_SHIP_GIT_USER:-}"
  from_git="$(git config --get auto-ship.user 2>/dev/null || true)"
  if [[ -n "$from_env" ]]; then
    printf '%s' "$from_env"
  elif [[ -n "$from_git" ]]; then
    printf '%s' "$from_git"
  else
    printf '%s' "mort-sh"
  fi
}

# Return 0 if current identity is allowed.
auto_ship_identity_ok() {
  local allowed git_name gh_user candidate
  allowed="$(auto_ship_allowed_users)"
  git_name="$(git config --get user.name 2>/dev/null || true)"
  gh_user=""
  if command -v gh >/dev/null 2>&1; then
    gh_user="$(gh api user --jq .login 2>/dev/null || true)"
  fi

  IFS=',' read -r -a candidates <<< "$allowed"
  for candidate in "${candidates[@]}"; do
    candidate="${candidate#"${candidate%%[![:space:]]*}"}"
    candidate="${candidate%"${candidate##*[![:space:]]}"}"
    [[ -z "$candidate" ]] && continue
    if [[ "$git_name" == "$candidate" || "$gh_user" == "$candidate" ]]; then
      return 0
    fi
  done
  return 1
}

# Return 0 when auto-ship is enabled (default on).
auto_ship_enabled() {
  local flag
  flag="${AUTO_SHIP:-}"
  if [[ -z "$flag" ]]; then
    flag="$(git config --get auto-ship.enabled 2>/dev/null || true)"
  fi
  flag="$(printf '%s' "$flag" | tr '[:upper:]' '[:lower:]')"
  case "$flag" in
    0|false|no|off) return 1 ;;
    *) return 0 ;;
  esac
}

# Return 0 when the worktree (or index) has something worth shipping.
auto_ship_has_changes() {
  # Unstaged, staged, or untracked (excluding ignored)
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 1
  fi
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    return 0
  fi
  return 1
}

# Emit a JSON systemMessage for Claude (optional UX).
auto_ship_system_message() {
  local msg="$1"
  # Escape for JSON string
  local escaped
  escaped="$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null || printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf '{"systemMessage":"%s","suppressOutput":false}\n' "$escaped"
}
