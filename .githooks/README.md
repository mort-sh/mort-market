# identity-scrub

A `pre-push` hook that guarantees every commit in the repository's history
carries an approved author and committer identity, and rewrites the ones that
don't.

## Behaviour

Two hooks, with different jobs:

| Hook | Does | Why |
|---|---|---|
| `pre-push` | scans, rewrites, aborts the push | The gate. Last moment before anything leaves the machine. |
| `post-merge` | scans and **warns only** | Early notice. Merges are the main way foreign identities arrive. |

`post-merge` deliberately doesn't rewrite. Git ignores a post-merge hook's exit
status so it cannot block the merge, and rewriting there would silently change
every SHA on the branch right after an ordinary `git pull` — leaving it
diverged from its remote and needing a force-push nobody asked for. It tells
you now; `pre-push` fixes it before it matters.

On `git push`, the hook scans every commit reachable from local branches and
tags and compares each author and committer identity against an allowlist:

- identity is on the allowlist → left untouched
- anything else → rewritten to the canonical `Name <email>`

If nothing needs changing, the push proceeds normally. If anything was
rewritten, the hook **aborts the push** — the commits git was about to send no
longer exist under those SHAs — and prints the command to re-run.

After any rewrite the hook re-verifies the whole history and refuses to report
success unless only allowlisted identities remain.

## Configuration

Everything project-specific lives in [`identity-scrub.conf`](identity-scrub.conf):

```sh
SCRUB_NAME="m0rt"                     # canonical identity
SCRUB_EMAIL="mort@paradox.zone"

SCRUB_PRESERVE="                      # kept verbatim, one per line
mort-sh <mort@paradox.zone>
"
```

Matching is exact on the full `Name <email>` string. The canonical identity is
always preserved implicitly, so the config above yields exactly two allowed
usernames: `mort-sh` and `m0rt`.

Note this is an allowlist on the *whole* identity, not on the name and email
independently: `mort-sh <someone@else.com>` and `Nobody <mort@paradox.zone>`
are both rewritten, because neither matches an allowed pair exactly. That is
what keeps the "only two usernames" guarantee true.

Per-checkout overrides, without editing the tracked file:

```bash
git config identityscrub.name "someone"
git config identityscrub.email "someone@example.com"
git config --add identityscrub.preserve "keep-me <keep@example.com>"
```

## Reusing this in another project

```bash
cp -r /path/to/this/repo/.githooks /path/to/other/repo/
cd /path/to/other/repo
$EDITOR .githooks/identity-scrub.conf
./.githooks/install.sh
```

`install.sh` sets `core.hooksPath` to `.githooks` and marks the scripts
executable. Since `.githooks/` is tracked, each fresh clone just re-runs
`./.githooks/install.sh`.

## Running it by hand

```bash
./.githooks/identity-scrub.sh scan     # report identities and flag offenders
./.githooks/identity-scrub.sh scrub    # rewrite history now
./.githooks/identity-scrub.sh verify   # assert only allowed identities remain
```

`scan` exits non-zero when offenders exist, `verify` exits non-zero when the
history is not clean — both are usable in CI.

## Caveats

- Rewriting changes commit SHAs. If the affected commits were already pushed,
  the follow-up push needs `git push --force-with-lease`, and any other clone
  must re-fetch.
- The rewrite requires a clean working tree; the hook aborts rather than
  touching uncommitted work.
- `git filter-branch` leaves the pre-rewrite refs under `refs/original/` as an
  undo path:

  ```bash
  git reset --hard refs/original/refs/heads/main            # undo
  git for-each-ref --format='%(refname)' refs/original \
      | xargs -n1 git update-ref -d                          # drop backups
  ```

- Identities are scrubbed on commits only. Annotated tag *tagger* fields are
  not rewritten (tag names and targets are preserved).
- To bypass once: `git push --no-verify` (the history stays unscrubbed).
