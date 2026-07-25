---
name: identity-scrub
description: Install, run, or debug the identity-scrub git hooks — guarantee every commit in a repo's history carries an approved author/committer identity and rewrite the ones that don't. Use when the user wants to enforce a canonical git identity, scrub or normalize commit authors, hide a work email or old username from history, audit which identities appear in a repo, or fix a push that was aborted by the identity-scrub pre-push hook.
---

# identity-scrub

Two git hooks that keep a repository's commit history down to an approved set of
author and committer identities.

| Hook | Does | Why |
|---|---|---|
| `pre-push` | scans, rewrites, aborts the push | The gate. Last moment before anything leaves the machine. |
| `post-merge` | scans and **warns only** | Early notice. Merges are the main way foreign identities arrive. |

`post-merge` deliberately doesn't rewrite: git ignores its exit status so it
can't block the merge, and rewriting there would change every SHA on the branch
right after an ordinary `git pull`.

The payload lives at `${CLAUDE_PLUGIN_ROOT}/githooks/`.

## Install into a repository

Copy the payload in, set the identity, enable it:

```bash
cp -R "${CLAUDE_PLUGIN_ROOT}/githooks" .githooks
```

Then edit `.githooks/identity-scrub.conf` — **always ask the user for the
canonical name and email rather than guessing**, and never carry over the
values shipped in the template:

```sh
SCRUB_NAME="Their Name"                # canonical identity
SCRUB_EMAIL="them@example.com"

SCRUB_PRESERVE="                       # kept verbatim, one "Name <email>" per line
other-alias <them@example.com>
"
```

Matching is exact on the full `Name <email>` string, not on name and email
independently — `their-alias <someone@else.com>` gets rewritten. The canonical
identity is always preserved implicitly.

Finally:

```bash
./.githooks/install.sh
```

`install.sh` sets `core.hooksPath`, marks the scripts executable, and runs an
initial scan. It works from any path inside the repo, so `.githooks/` at the
root is a convention, not a requirement. Commit the directory — git never
enables hooks by itself and `.git/hooks` is untracked, so tracking the payload
is what makes it survive a clone. Each fresh clone re-runs `install.sh` once.

Per-checkout overrides, without editing the tracked file:

```bash
git config identityscrub.name "someone"
git config identityscrub.email "someone@example.com"
git config --add identityscrub.preserve "keep-me <keep@example.com>"
```

## Run it by hand

```bash
./.githooks/identity-scrub.sh scan     # report identities, flag offenders (exit 1 if any)
./.githooks/identity-scrub.sh verify   # assert only allowed identities remain (exit 1 if not)
./.githooks/identity-scrub.sh scrub    # rewrite history now
```

`scan` and `verify` are read-only and safe to run unprompted — reach for them
first when auditing. `scrub` rewrites history; see below.

## Before running `scrub`

`scrub` calls `git filter-branch` over all branches and tags. Confirm with the
user first, and check:

- **The working tree must be clean.** The script aborts rather than touching
  uncommitted work.
- **Commit SHAs change.** If the affected commits were already pushed, the
  follow-up push needs `git push --force-with-lease`, and every other clone
  must re-fetch and reset.
- **It is undoable** until the backups are dropped:

  ```bash
  git reset --hard refs/original/refs/heads/$(git branch --show-current)   # undo
  git for-each-ref --format='%(refname)' refs/original \
      | xargs -n1 git update-ref -d                                        # drop backups
  ```

- **Commits only.** Annotated tag *tagger* fields are not rewritten; tag names
  and targets are preserved.

## When a push was aborted

Exit code 2 from the hook means it rewrote history and stopped the push on
purpose — the commits git was about to send no longer exist under those SHAs.
Nothing was pushed. Re-run the push:

```bash
git push --force-with-lease
```

Plain `git push` is enough only if those commits were never pushed before.

## Escape hatches

```bash
git push --no-verify              # bypass once; history stays unscrubbed
git config --unset core.hooksPath # disable entirely
```

## CI

`scan` and `verify` both exit non-zero on a dirty history, so either works as a
CI gate. `verify` is the stricter phrasing: it asserts the end state rather
than reporting what would change.
