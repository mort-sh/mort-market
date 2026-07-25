#!/usr/bin/env bash
#
# identity-scrub — normalize commit author/committer identities across history.
#
# Preserves an explicit allowlist of identities and rewrites every other
# identity (author *and* committer) to a single canonical name/email.
#
# Reusable: copy this whole directory into any repo (conventionally as
# .githooks/), edit identity-scrub.conf, run its install.sh.
#
# Usage:
#   identity-scrub.sh scan       list identities in history and flag offenders
#   identity-scrub.sh scrub      rewrite history so only allowed identities remain
#   identity-scrub.sh verify     fail unless history contains only allowed identities
#   identity-scrub.sh pre-push   hook entrypoint: scan -> scrub if needed -> verify
#
# Exit codes: 0 clean/ok, 1 verification or precondition failure,
#             2 history was rewritten (push aborted, re-run the push).
#
# Notes:
#   * Commit .githooks/ to the repo. Git never enables hooks on its own and
#     .git/hooks is untracked, so tracking this directory is what makes the
#     setup survive a clone — each clone runs ./.githooks/install.sh once.
#   * A rewrite changes commit SHAs. If the affected commits were already
#     pushed, the follow-up push must be `git push --force-with-lease`, and
#     every other clone has to re-fetch and reset.
#   * The rewrite is undoable: filter-branch keeps the pre-rewrite refs under
#     refs/original/. Every scrub prints the exact reset and cleanup commands.
#   * Scrubbing needs a clean working tree; this script aborts rather than
#     touching uncommitted work.
#   * Commits only — annotated tag *tagger* fields are not rewritten, though
#     tag names and targets are preserved.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------- output ----

c_red=''; c_yellow=''; c_green=''; c_dim=''; c_off=''
if [ -t 2 ]; then
    c_red=$'\033[31m'; c_yellow=$'\033[33m'; c_green=$'\033[32m'
    c_dim=$'\033[2m'; c_off=$'\033[0m'
fi

info() { printf '%s\n' "identity-scrub: $*" >&2; }
warn() { printf '%s\n' "${c_yellow}identity-scrub: $*${c_off}" >&2; }
err()  { printf '%s\n' "${c_red}identity-scrub: $*${c_off}" >&2; }
ok()   { printf '%s\n' "${c_green}identity-scrub: $*${c_off}" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------- config ----

load_config() {
    local config="${SCRUB_CONFIG:-$HERE/identity-scrub.conf}"
    [ -r "$config" ] || die "config not found: $config"
    # shellcheck disable=SC1090
    . "$config"

    # git config overrides, so a shared checkout can deviate without an edit.
    local v
    v="$(git config --get identityscrub.name || true)"
    [ -n "$v" ] && SCRUB_NAME="$v"
    v="$(git config --get identityscrub.email || true)"
    [ -n "$v" ] && SCRUB_EMAIL="$v"
    v="$(git config --get-all identityscrub.preserve || true)"
    [ -n "$v" ] && SCRUB_PRESERVE="$v"

    [ -n "${SCRUB_NAME:-}" ]  || die "SCRUB_NAME is not set in $config"
    [ -n "${SCRUB_EMAIL:-}" ] || die "SCRUB_EMAIL is not set in $config"
}

# Full allowlist: canonical identity plus every preserved identity.
allowed_identities() {
    {
        printf '%s <%s>\n' "$SCRUB_NAME" "$SCRUB_EMAIL"
        printf '%s\n' "${SCRUB_PRESERVE:-}"
    } | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | sort -u
}

# ---------------------------------------------------------------- history ---

has_commits() { git rev-parse --verify -q HEAD >/dev/null 2>&1; }

# This script's path relative to the repo root — main() has already cd'd there,
# so messages can quote a command the reader can paste back verbatim regardless
# of where the payload was installed.
self_path() { printf '%s\n' "${HERE#"$PWD"/}/$(basename "${BASH_SOURCE[0]}")"; }

# Every distinct "Name <email>" appearing as author or committer on any commit
# reachable from a local branch or tag.
history_identities() {
    git log --branches --tags --format='%an <%ae>%n%cn <%ce>' | sort -u
}

# Identities in history that are not on the allowlist.
offending_identities() {
    comm -23 <(history_identities) <(allowed_identities)
}

# Printed after any rewrite: filter-branch keeps the pre-rewrite refs, so the
# operation is always reversible until the backups are deleted.
undo_hint() {
    printf '%s\n' \
        "${c_dim}  undo the rewrite:  git reset --hard refs/original/refs/heads/\$(git branch --show-current)" \
        "  drop the backups:  git for-each-ref --format='%(refname)' refs/original | xargs -n1 git update-ref -d${c_off}" >&2
}

require_clean_worktree() {
    git diff --quiet --ignore-submodules HEAD -- 2>/dev/null \
        || die "working tree has uncommitted changes; commit or stash before rewriting history"
    [ -z "$(git ls-files --others --exclude-standard --directory --no-empty-directory)" ] \
        || warn "untracked files present (they are not affected by the rewrite)"
}

# ------------------------------------------------------------- commands -----

cmd_scan() {
    has_commits || { info "no commits yet — nothing to scan"; return 0; }

    info "allowed identities:"
    allowed_identities | sed "s/^/  ${c_green}✓${c_off} /" >&2

    local offenders
    offenders="$(offending_identities)"
    if [ -z "$offenders" ]; then
        ok "history is clean — all identities are allowed"
        return 0
    fi

    warn "identities that will be rewritten to \"$SCRUB_NAME <$SCRUB_EMAIL>\":"

    local slots id count
    slots="$(git log --branches --tags --format='%an <%ae>%n%cn <%ce>')"
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        count="$(printf '%s\n' "$slots" | grep -cxF "$id")"
        printf '  %s✗%s %s %s(%s author/committer slot(s))%s\n' \
            "$c_red" "$c_off" "$id" "$c_dim" "$count" "$c_off" >&2
    done <<< "$offenders"
    return 1
}

cmd_scrub() {
    has_commits || { info "no commits yet — nothing to scrub"; return 0; }

    if [ -z "$(offending_identities)" ]; then
        info "nothing to rewrite"
        return 0
    fi

    require_clean_worktree

    # Exported for the filter-branch subshell below.
    SCRUB_ALLOWED="$(allowed_identities)"
    export SCRUB_ALLOWED SCRUB_NAME SCRUB_EMAIL

    info "rewriting history (a backup of every original ref is kept in refs/original/)"

    FILTER_BRANCH_SQUELCH_WARNING=1 \
    git filter-branch --force --env-filter '
        _author="$GIT_AUTHOR_NAME <$GIT_AUTHOR_EMAIL>"
        if ! printf "%s\n" "$SCRUB_ALLOWED" | grep -qxF "$_author"; then
            GIT_AUTHOR_NAME="$SCRUB_NAME"
            GIT_AUTHOR_EMAIL="$SCRUB_EMAIL"
            export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL
        fi
        _committer="$GIT_COMMITTER_NAME <$GIT_COMMITTER_EMAIL>"
        if ! printf "%s\n" "$SCRUB_ALLOWED" | grep -qxF "$_committer"; then
            GIT_COMMITTER_NAME="$SCRUB_NAME"
            GIT_COMMITTER_EMAIL="$SCRUB_EMAIL"
            export GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
        fi
    ' --tag-name-filter cat -- --branches --tags >&2 \
        || die "git filter-branch failed; history was not changed"

    ok "history rewritten"
    undo_hint
    warn "commit SHAs changed — an already-pushed branch now needs \`git push --force-with-lease\`"
}

cmd_verify() {
    has_commits || { info "no commits yet — nothing to verify"; return 0; }

    local offenders
    offenders="$(offending_identities)"
    if [ -n "$offenders" ]; then
        err "verification FAILED — disallowed identities remain in history:"
        printf '%s\n' "$offenders" | sed "s/^/  ${c_red}✗${c_off} /" >&2
        return 1
    fi

    local found n
    found="$(history_identities)"
    n="$(printf '%s\n' "$found" | wc -l | tr -d ' ')"
    ok "verification passed — $n unique identity/identities in the entire history:"
    printf '%s\n' "$found" | sed "s/^/  ${c_green}✓${c_off} /" >&2

    # Names only, which is what the "unique usernames" guarantee is about.
    local names
    names="$(git log --branches --tags --format='%an%n%cn' | sort -u)"
    info "unique usernames: $(printf '%s' "$names" | paste -sd', ' -)"
    return 0
}

# Early warning after a merge pulls in someone else's commits — the main way
# foreign identities enter a repo. This deliberately does NOT rewrite: git
# ignores a post-merge exit status, so it cannot block anything, and rewriting
# here would silently diverge the branch from its remote and force a
# force-push moments after an ordinary `git pull`. pre-push stays the gate;
# this just means you hear about it now instead of at push time.
cmd_post_merge() {
    has_commits || return 0
    [ -z "$(offending_identities)" ] && return 0

    cmd_scan || true
    cat >&2 <<EOF

${c_yellow}The merge brought in identities that are not on the allowlist.${c_off}
Nothing has been changed — post-merge hooks cannot block or safely rewrite.
Your next push will rewrite them automatically, or do it now with:

    ./$(self_path) scrub

EOF
    return 0
}

cmd_pre_push() {
    # Consume the ref list git feeds on stdin; we act on full history, not a range.
    cat >/dev/null 2>&1 || true

    has_commits || return 0

    if [ -z "$(offending_identities)" ]; then
        cmd_verify || return 1
        info "identities clean — push allowed"
        return 0
    fi

    cmd_scan || true
    cmd_scrub || return 1
    cmd_verify || return 1

    cat >&2 <<EOF

${c_yellow}Push aborted on purpose.${c_off}

History was rewritten, so the commits git was about to send are stale.
Nothing was pushed. Re-run your push to send the scrubbed commits:

    git push --force-with-lease

(Plain \`git push\` is enough only if these commits were never pushed before.)
Anyone else holding a clone must re-fetch and reset.

EOF
    undo_hint
    return 2
}

# ------------------------------------------------------------------ main ----

main() {
    git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
    cd "$(git rev-parse --show-toplevel)" || die "cannot cd to repository root"
    load_config

    case "${1:-scan}" in
        scan)       cmd_scan ;;
        scrub)      cmd_scrub ;;
        verify)     cmd_verify ;;
        pre-push)   shift; cmd_pre_push "$@" ;;
        post-merge) shift; cmd_post_merge "$@" ;;
        -h|--help|help)
            # The file's own header comment block is the help text.
            awk 'NR>2 { if (!/^#/) exit; sub(/^# ?/, ""); print }' \
                "${BASH_SOURCE[0]}" >&2 ;;
        *) die "unknown command: $1 (try: scan | scrub | verify | pre-push)" ;;
    esac
}

main "$@"
