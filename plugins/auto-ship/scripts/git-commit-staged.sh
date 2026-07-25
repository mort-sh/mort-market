#!/usr/bin/env bash
# Commit already-staged changes with an AI-generated message.
# Does not run git add. Does not push.
# Prefer invoking via:  ai-fast-fg.sh /git-commit-staged
# This script is the reliable, non-agent fallback.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "git-commit-staged: not a git repository" >&2
  exit 1
fi

if git diff --cached --quiet 2>/dev/null; then
  echo "git-commit-staged: nothing staged" >&2
  exit 1
fi

# Prefer the slash-command path (Claude agent with the command prompt).
if [[ "${GIT_COMMIT_STAGED_FORCE_SCRIPT:-0}" != "1" ]] && command -v claude >/dev/null 2>&1; then
  if "${ROOT}/scripts/ai-fast-fg.sh" "/git-commit-staged"; then
    # Confirm a commit landed
    if ! git diff --cached --quiet 2>/dev/null; then
      echo "git-commit-staged: agent returned ok but index still staged; falling back to script commit" >&2
    else
      exit 0
    fi
  else
    echo "git-commit-staged: /git-commit-staged agent path failed; falling back to script commit" >&2
  fi
fi

# --- script fallback: haiku message + git commit ---
stat="$(git diff --cached --stat)"
diff="$(git diff --cached)"
log="$(git log --oneline -8 2>/dev/null || true)"

prompt=$(cat <<EOF
Write a single git commit message for the STAGED changes below.

Rules:
- Output ONLY the commit message text (no quotes, no markdown fences, no preamble).
- Prefer conventional commits (feat/fix/docs/refactor/chore/test/perf/ci) when it fits.
- Subject line ≤ 72 chars; optional body after a blank line if needed.
- Focus on why, not a file list.
- Never add Co-Authored-By trailers.
- Match the tone of recent commits if shown.

Recent commits:
${log:-"(none)"}

Staged stat:
${stat}

Staged diff:
${diff}
EOF
)

msg=""
if command -v claude >/dev/null 2>&1; then
  msg="$(
    claude --print --bare --no-session-persistence \
      --permission-mode bypassPermissions \
      --model haiku --effort low --fallback-model haiku \
      --no-chrome \
      "$prompt" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
  )" || true
fi

# Last-resort message if Claude is unavailable
if [[ -z "$msg" ]]; then
  msg="chore: ship staged changes"
fi

# Strip accidental fences
msg="$(printf '%s\n' "$msg" | sed -e '/^```/d')"

# HEREDOC avoids shell-escaping issues in the message body
git commit -m "$(printf '%s\n' "$msg")"
echo "git-commit-staged: committed"
