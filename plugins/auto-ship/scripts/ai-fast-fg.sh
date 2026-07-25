#!/usr/bin/env bash
# Foreground equivalent of the user's `ai-fast` zsh helper (haiku + --print).
# The interactive `ai-fast` function backgrounds runs; hooks need to wait.
#
# Usage: ai-fast-fg.sh [--workdir DIR] <prompt...>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AUTO_SHIP=0
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-1}"

workdir="${PWD}"
if [[ "${1:-}" == "--workdir" ]]; then
  workdir="${2:?--workdir requires a path}"
  shift 2
fi

if [[ $# -lt 1 ]]; then
  echo "usage: ai-fast-fg.sh [--workdir DIR] <prompt...>" >&2
  exit 2
fi

prompt="$*"

settings_args=()
if [[ -f "${HOME}/.zsh/aliases/claude-agent-settings.json" ]]; then
  settings_args+=(--settings "${HOME}/.zsh/aliases/claude-agent-settings.json" --setting-sources local,project)
fi

# --bare skips hooks so nested commits cannot re-enter ship-on-stop.
# --plugin-dir loads this plugin so /git-commit-staged resolves.
args=(
  --print
  --bare
  --no-session-persistence
  --permission-mode bypassPermissions
  --no-chrome
  --fallback-model haiku
  --model haiku
  --effort low
  --plugin-dir "${ROOT}"
)
args+=("${settings_args[@]}")

(
  cd "$workdir"
  claude "${args[@]}" "$prompt"
)
