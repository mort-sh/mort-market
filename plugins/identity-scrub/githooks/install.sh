#!/usr/bin/env sh
#
# Enable the identity-scrub hooks in this repository.
#
#   cp -R /path/to/githooks .githooks   &&   ./.githooks/install.sh
#
# Because the payload is tracked in the repo, every clone only needs to run
# this once (git never enables hooks automatically).
#
# The payload works from anywhere inside the repo; .githooks/ at the root is a
# convention, not a requirement.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
TOP="$(git -C "$HERE" rev-parse --show-toplevel)"
cd "$TOP"

# core.hooksPath is resolved relative to the repo root, so express the payload
# location that way rather than relying on the caller's working directory.
REL="${HERE#"$TOP"/}"
[ "$REL" = "$HERE" ] && REL=".githooks"   # payload sits at the repo root itself

chmod +x "$HERE/pre-push" "$HERE/post-merge" "$HERE/identity-scrub.sh" "$HERE/install.sh"
git config core.hooksPath "$REL"

printf 'identity-scrub: core.hooksPath -> %s\n' "$(git config core.hooksPath)"
printf 'identity-scrub: running an initial scan...\n\n'

"$HERE/identity-scrub.sh" scan || true

cat <<EOF

Next steps
  1. Edit $REL/identity-scrub.conf to set the identities for this project.
  2. Commit $REL/ — git never enables hooks by itself and .git/hooks is
     untracked, so tracking it is what makes this survive a clone. Every
     fresh clone re-runs ./$REL/install.sh once.

Good to know
  * If the hook rewrites anything it aborts the push on purpose, because the
    commits git was about to send no longer exist under those SHAs. Re-run
    the push; if those commits were already on the remote, the re-run needs
    \`git push --force-with-lease\` and other clones must re-fetch.
  * Rewrites are reversible — filter-branch keeps the originals in
    refs/original/ until you delete them.
  * Bypass once with \`git push --no-verify\`; disable entirely with
    \`git config --unset core.hooksPath\`.
EOF
