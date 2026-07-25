---
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(git commit:*)
description: Create a git commit from already-staged files with an AI-generated message (no add, no push)
argument-hint: ""
---

# git-commit-staged

Create **one** git commit from files that are **already staged**.

## Context

- Git status: !`git status --short`
- Staged stat: !`git diff --cached --stat`
- Staged diff: !`git diff --cached`
- Recent commits: !`git log --oneline -10`

## Rules

1. **Do not** run `git add`. Only what is already staged may be committed.
2. **Do not** push, create branches, or open PRs.
3. **Do not** modify unstaged or untracked files.
4. If nothing is staged, say so briefly and stop — do not invent a commit.
5. Never add `Co-Authored-By` or similar trailers.
6. Prefer conventional-commit style when it fits; keep the subject ≤ 72 chars.
7. Focus on *why*, not a file laundry list.
8. Match the tone of recent commits when possible.

## Procedure

1. If the staged diff is empty, stop.
2. Draft a commit message from the staged diff and recent log style.
3. Commit with a HEREDOC (or equivalent) so the message is quoted safely:

```bash
git commit -m "$(cat <<'EOF'
Your commit message here.

Optional body.
EOF
)"
```

4. Run `git status` once to confirm the index is clean of those staged changes.
5. Reply with the short hash and subject only — no long narrative.
