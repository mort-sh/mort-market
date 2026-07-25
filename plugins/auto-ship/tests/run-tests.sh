#!/usr/bin/env bash
# Offline unit tests for auto-ship gates (no network, no claude required).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

PASS=0
FAIL=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "ok - $name"
    PASS=$((PASS + 1))
  else
    echo "not ok - $name (expected='$expected' actual='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

assert_rc() {
  local name="$1" expected_rc="$2"
  shift 2
  set +e
  "$@" >/dev/null 2>&1
  local rc=$?
  set -e
  assert_eq "$name" "$expected_rc" "$rc"
}

# --- identity allowlist ---
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/auto-ship-test.XXXXXX")"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

# Shadow `gh` so GitHub login cannot leak through from the host environment.
mkdir -p "$tmpdir/bin"
cat >"$tmpdir/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Stub: simulate unauthenticated / unavailable gh
exit 1
EOF
chmod +x "$tmpdir/bin/gh"
export PATH="$tmpdir/bin:$PATH"

git init -q "$tmpdir/repo"
cd "$tmpdir/repo"
git config user.name "someone-else"
git config user.email "x@example.com"

# Default allowlist is mort-sh — someone-else must fail (gh stubbed out)
assert_rc "identity rejects other user.name" 1 auto_ship_identity_ok

git config user.name "mort-sh"
assert_rc "identity accepts user.name=mort-sh" 0 auto_ship_identity_ok

git config user.name "other"
export AUTO_SHIP_GIT_USER="other,mort-sh"
assert_rc "identity accepts AUTO_SHIP_GIT_USER override" 0 auto_ship_identity_ok
unset AUTO_SHIP_GIT_USER

git config auto-ship.user "via-config"
git config user.name "via-config"
assert_rc "identity accepts git config auto-ship.user" 0 auto_ship_identity_ok
git config --unset auto-ship.user
git config user.name "mort-sh"

# With a working gh stub that returns mort-sh, user.name can be anything
cat >"$tmpdir/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "user" ]]; then
  echo "mort-sh"
  exit 0
fi
exit 1
EOF
git config user.name "not-the-allowlist"
assert_rc "identity accepts gh login=mort-sh" 0 auto_ship_identity_ok
# Restore failing gh for the rest of the suite
cat >"$tmpdir/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
git config user.name "mort-sh"

# --- enabled flag ---
unset AUTO_SHIP
assert_rc "enabled by default" 0 auto_ship_enabled
export AUTO_SHIP=0
assert_rc "disabled by AUTO_SHIP=0" 1 auto_ship_enabled
export AUTO_SHIP=false
assert_rc "disabled by AUTO_SHIP=false" 1 auto_ship_enabled
unset AUTO_SHIP
git config auto-ship.enabled false
assert_rc "disabled by git config" 1 auto_ship_enabled
git config --unset auto-ship.enabled

# --- dirty tree ---
assert_rc "clean tree has no changes" 1 auto_ship_has_changes
echo hi > file.txt
assert_rc "untracked counts as changes" 0 auto_ship_has_changes
git add file.txt
assert_rc "staged counts as changes" 0 auto_ship_has_changes
# commit so we can test post-commit clean
git commit -q -m "init"
assert_rc "clean after commit" 1 auto_ship_has_changes
echo more >> file.txt
assert_rc "modified counts as changes" 0 auto_ship_has_changes

# --- ship-on-stop dry gates (no push/commit of real agent) ---
# Wrong identity → exit 0 skip
git config user.name "not-allowed"
export AUTO_SHIP_GIT_USER="mort-sh"
export AUTO_SHIP_FORCE=1
set +e
printf '%s' '{"cwd":"'"$tmpdir/repo"'","session_id":"t","transcript_path":""}' \
  | bash "${ROOT}/hooks/ship-on-stop.sh" >/tmp/auto-ship-out.txt 2>/tmp/auto-ship-err.txt
rc=$?
set -e
assert_eq "ship-on-stop skips wrong identity (rc 0)" "0" "$rc"
if rg -q 'identity not allowed' /tmp/auto-ship-err.txt; then
  echo "ok - ship-on-stop logs identity skip"
  PASS=$((PASS + 1))
else
  echo "not ok - ship-on-stop logs identity skip"
  FAIL=$((FAIL + 1))
fi

# Clean tree + allowed identity → skip
git checkout -- file.txt 2>/dev/null || git restore file.txt 2>/dev/null || true
# ensure clean
git reset --hard -q HEAD
git clean -fdq
git config user.name "mort-sh"
set +e
printf '%s' '{"cwd":"'"$tmpdir/repo"'","session_id":"t","transcript_path":""}' \
  | bash "${ROOT}/hooks/ship-on-stop.sh" >/tmp/auto-ship-out2.txt 2>/tmp/auto-ship-err2.txt
rc=$?
set -e
assert_eq "ship-on-stop skips clean tree (rc 0)" "0" "$rc"
if rg -q 'clean worktree' /tmp/auto-ship-err2.txt; then
  echo "ok - ship-on-stop logs clean skip"
  PASS=$((PASS + 1))
else
  echo "not ok - ship-on-stop logs clean skip"
  FAIL=$((FAIL + 1))
fi

# Disabled
export AUTO_SHIP=0
set +e
printf '%s' '{"cwd":"'"$tmpdir/repo"'"}' \
  | bash "${ROOT}/hooks/ship-on-stop.sh" 2>/tmp/auto-ship-err3.txt
rc=$?
set -e
assert_eq "ship-on-stop respects AUTO_SHIP=0" "0" "$rc"
if rg -q 'disabled' /tmp/auto-ship-err3.txt; then
  echo "ok - ship-on-stop logs disabled"
  PASS=$((PASS + 1))
else
  echo "not ok - ship-on-stop logs disabled"
  FAIL=$((FAIL + 1))
fi

echo
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
