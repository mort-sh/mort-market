#!/usr/bin/env bash
# Stop hook: when work looks complete and the identity matches, stage → AI commit → push.
#
# Gates (all must pass):
#   1. AUTO_SHIP not disabled
#   2. Not a nested/re-entrant run (AUTO_SHIP=0 already set by children)
#   3. Git identity is in the allowlist (default: mort-sh via user.name or gh login)
#   4. Worktree has changes
#   5. Completion classifier says SHIP (unless AUTO_SHIP_FORCE=1)
#
# Then:
#   git add -A
#   ai-fast /git-commit-staged  (foreground via scripts/ai-fast-fg.sh)
#   git push
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

# Drain stdin JSON (hook payload). Keep for completion checks.
HOOK_INPUT="$(cat || true)"
eval "$(
  HOOK_INPUT="$HOOK_INPUT" python3 - <<'PY'
import json, os, shlex
raw = os.environ.get("HOOK_INPUT", "")
try:
    d = json.loads(raw) if raw.strip() else {}
except Exception:
    d = {}
for key, env in (
    ("session_id", "SESSION_ID"),
    ("transcript_path", "TRANSCRIPT_PATH"),
    ("cwd", "CWD"),
):
    val = d.get(key) or ""
    print(f"{env}={shlex.quote(str(val))}")
PY
)"

if [[ -n "${CWD:-}" && -d "$CWD" ]]; then
  cd "$CWD"
elif [[ -n "${CLAUDE_PROJECT_DIR:-}" && -d "${CLAUDE_PROJECT_DIR}" ]]; then
  cd "$CLAUDE_PROJECT_DIR"
fi

log() { printf 'auto-ship: %s\n' "$*" >&2; }

# --- gates ---
if ! auto_ship_enabled; then
  log "disabled (AUTO_SHIP / auto-ship.enabled)"
  exit 0
fi

# Re-entrancy guard: nested claude from ai-fast-fg sets AUTO_SHIP=0
if [[ "${AUTO_SHIP_ACTIVE:-0}" == "1" ]]; then
  log "skip re-entrant stop"
  exit 0
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "not a git repo — skip"
  exit 0
fi

if ! auto_ship_identity_ok; then
  allowed="$(auto_ship_allowed_users)"
  git_name="$(git config --get user.name 2>/dev/null || echo '(unset)')"
  log "identity not allowed (need one of: ${allowed}; git user.name=${git_name}) — skip"
  exit 0
fi

if ! auto_ship_has_changes; then
  log "clean worktree — nothing to ship"
  exit 0
fi

# --- completion classifier ---
should_ship() {
  if [[ "${AUTO_SHIP_FORCE:-0}" == "1" ]]; then
    return 0
  fi

  # Cheap transcript heuristics before spending a model call
  local snippet=""
  if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
    snippet="$(tail -c 12000 "$TRANSCRIPT_PATH" 2>/dev/null || true)"
  fi

  # If the agent is clearly mid-question / waiting, skip without LLM
  if printf '%s' "$snippet" | rg -q '"type"\s*:\s*"assistant"' 2>/dev/null; then
    if printf '%s' "$snippet" | rg -qi \
      'AskUserQuestion|which (option|approach)|would you like|let me know|waiting for|need (your|more) (input|info)|shall I' \
      2>/dev/null; then
      # Still might be complete + a courtesy question; fall through to classifier
      :
    fi
  fi

  if ! command -v claude >/dev/null 2>&1; then
    # Without Claude we only ship when forced
    log "claude CLI missing and AUTO_SHIP_FORCE!=1 — skip completion ship"
    return 1
  fi

  local status_short
  status_short="$(git status --short 2>/dev/null | head -80)"

  local decide_prompt
  decide_prompt=$(cat <<EOF
You are a gate for an auto-commit+push hook on a coding agent Stop event.

Decide whether the agent has FINISHED the user's task and the repo is ready to ship
(feature done, bug fixed, tests/verification succeeded, nothing left the user must answer).

Answer with exactly one word on the first line: SHIP or SKIP.

SHIP when:
- Work is complete and verified (tests ran / validation passed / user asked to ship)
- Remaining files look like intentional finished work, not half-edits
- The agent is not waiting on a clarifying question

SKIP when:
- Mid-task, blocked, asking the user a question, exploring, or uncertain
- Only drive-by/WIP changes with no clear "done"
- Destructive or identity-sensitive history rewrites still in progress

Git status (short):
${status_short}

Recent transcript tail (may be JSONL, may be empty):
${snippet:-(empty)}
EOF
)

  local answer
  answer="$(
    AUTO_SHIP=0 AUTO_SHIP_ACTIVE=1 \
      claude --print --bare --no-session-persistence \
        --permission-mode bypassPermissions \
        --model haiku --effort low --fallback-model haiku \
        --no-chrome \
        "$decide_prompt" 2>/dev/null | head -5
  )" || true

  if printf '%s\n' "$answer" | head -1 | rg -qi '^[[:space:]]*SHIP\b'; then
    return 0
  fi
  log "classifier said SKIP (${answer//$'\n'/ | })"
  return 1
}

if ! should_ship; then
  exit 0
fi

# --- ship ---
export AUTO_SHIP_ACTIVE=1
export AUTO_SHIP=0

log "staging all changes"
git add -A

if git diff --cached --quiet 2>/dev/null; then
  log "nothing staged after git add -A — skip"
  exit 0
fi

log "committing via ai-fast /git-commit-staged"
if ! "${ROOT}/scripts/git-commit-staged.sh"; then
  log "commit failed"
  auto_ship_system_message "auto-ship: commit failed — left changes staged for manual recovery"
  exit 0
fi

# Push current branch
branch="$(git branch --show-current 2>/dev/null || true)"
if [[ -z "$branch" ]]; then
  log "detached HEAD — commit done, not pushing"
  auto_ship_system_message "auto-ship: committed on detached HEAD; push skipped"
  exit 0
fi

log "pushing ${branch}"
set +e
push_out="$(git push -u origin HEAD 2>&1)"
push_rc=$?
set -e

if [[ $push_rc -eq 0 ]]; then
  log "pushed ok"
  auto_ship_system_message "auto-ship: committed and pushed to origin/${branch}"
  exit 0
fi

# identity-scrub aborts with exit 2 after rewriting so the operator can re-push
if [[ $push_rc -eq 2 ]] || printf '%s' "$push_out" | rg -qi 'identity-scrub|rewrit'; then
  log "push aborted after history rewrite (likely identity-scrub) — retrying once"
  set +e
  push_out2="$(git push --force-with-lease 2>&1)"
  push_rc2=$?
  set -e
  if [[ $push_rc2 -eq 0 ]]; then
    log "force-with-lease push ok"
    auto_ship_system_message "auto-ship: committed; pushed with --force-with-lease after identity rewrite"
    exit 0
  fi
  log "retry push failed: ${push_out2}"
  auto_ship_system_message "auto-ship: committed locally but push failed after rewrite — run git push --force-with-lease"
  exit 0
fi

log "push failed (rc=${push_rc}): ${push_out}"
auto_ship_system_message "auto-ship: committed locally but push failed — run git push manually"
exit 0
