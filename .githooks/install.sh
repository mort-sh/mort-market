#!/usr/bin/env sh
#
# Enable the identity-scrub pre-push hook in this repository.
#
#   cp -r /path/to/.githooks .   &&   ./.githooks/install.sh
#
# Because .githooks/ is tracked in the repo, every clone only needs to run
# this once (git never enables hooks automatically).

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$(git -C "$HERE" rev-parse --show-toplevel)"

REL="$(git rev-parse --show-prefix)$(basename "$HERE")"

chmod +x "$HERE/pre-push" "$HERE/identity-scrub.sh" "$HERE/install.sh"
git config core.hooksPath "${REL:-.githooks}"

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
