# auto-ship

When a Claude Code session finishes **complete, verified work**, automatically:

1. Confirm the git identity is allowed (default: **`mort-sh`**)
2. `git add -A`
3. Commit via **`ai-fast /git-commit-staged`** (AI-generated message)
4. `git push`

This is a **Claude Code Stop hook**, not a git client hook — it fires when the
main agent is about to stop, which is the natural “feature is done” moment.

## Install

```
/plugin marketplace add mort-sh/mort-market
/plugin install auto-ship@mort-market
/reload-plugins
```

Restart the Claude Code session so hooks load.

## Identity gate

Auto-ship only runs when **one** of these matches the allowlist (default `mort-sh`):

| Source | Example |
| ------ | ------- |
| `git config user.name` | `mort-sh` |
| GitHub login via `gh api user` | `mort-sh` |

Your commit author can still be `m0rt` — the GitHub login `mort-sh` is enough.

Override the allowlist:

```bash
export AUTO_SHIP_GIT_USER="mort-sh,m0rt"
# or
git config auto-ship.user "mort-sh,m0rt"
```

## Behaviour

| Gate | Effect |
| ---- | ------ |
| `AUTO_SHIP=0` / `git config auto-ship.enabled false` | Fully off |
| Identity not in allowlist | Skip (silent) |
| Clean worktree | Skip |
| Completion classifier → `SKIP` | Skip (mid-task / waiting on user) |
| Completion classifier → `SHIP` | Stage → AI commit → push |
| `AUTO_SHIP_FORCE=1` | Skip classifier; ship whenever dirty + identity ok |

The classifier is a short haiku call over git status + transcript tail. Nested
Claude runs use `--bare` and `AUTO_SHIP=0` so they cannot re-enter the hook.

If `identity-scrub` rewrites history and aborts the first push (exit 2), auto-ship
retries once with `git push --force-with-lease`.

## Manual commit helper

Slash command (also what the hook invokes):

```
/git-commit-staged
```

Commits **already staged** files only — no `git add`, no push.

Shell equivalent (foreground `ai-fast`):

```bash
# From a checkout that has the plugin installed, or from this repo:
./plugins/auto-ship/scripts/ai-fast-fg.sh /git-commit-staged

# Or the script fallback (generates the message itself if the agent path fails):
./plugins/auto-ship/scripts/git-commit-staged.sh
```

## Disable

```bash
export AUTO_SHIP=0
# or
git config auto-ship.enabled false
```

## Layout

```
hooks/hooks.json           Stop → ship-on-stop.sh
hooks/ship-on-stop.sh      gates + add + commit + push
commands/git-commit-staged.md
scripts/ai-fast-fg.sh      foreground haiku runner (hook-safe)
scripts/git-commit-staged.sh
scripts/lib.sh
```

## Requirements

- `git`, `bash`, `python3`
- `claude` CLI on `PATH` (for classifier + AI commit message)
- `gh` optional (used to read GitHub login for the identity gate)
- `rg` optional (speeds up transcript heuristics)
