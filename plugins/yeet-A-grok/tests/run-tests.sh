#!/usr/bin/env bash
# Test suite for scripts/grok-delegate.sh. Runs every function named test_*
# against a stub `grok` binary; no network, no real model calls.
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$TESTS_DIR")"
SUT="$PLUGIN_DIR/scripts/grok-delegate.sh"

PASS=0
FAIL=0
CURRENT_TEST=""
FAILURES=()

fail() {
  FAIL=$((FAIL + 1))
  FAILURES+=("$CURRENT_TEST: $1")
  printf 'not ok - %s: %s\n' "$CURRENT_TEST" "$1"
}

ok() {
  PASS=$((PASS + 1))
  printf 'ok - %s\n' "$CURRENT_TEST"
}

assert_eq() { # expected actual label
  if [ "$1" != "$2" ]; then
    fail "$3: expected [$1], got [$2]"
    return 1
  fi
}

assert_contains() { # haystack needle label
  case "$1" in
    *"$2"*) return 0 ;;
    *) fail "$3: [$2] not found in [$1]"; return 1 ;;
  esac
}

assert_not_contains() { # haystack needle label
  case "$1" in
    *"$2"*) fail "$3: [$2] unexpectedly found"; return 1 ;;
    *) return 0 ;;
  esac
}

# json_get <file> <dotted.path> -> value on stdout, empty if missing
json_get() {
  python3 - "$1" "$2" <<'EOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        obj = json.load(f)
    for key in sys.argv[2].split('.'):
        if isinstance(obj, list):
            obj = obj[int(key)]
        else:
            obj = obj[key]
    if isinstance(obj, (dict, list)):
        print(json.dumps(obj))
    else:
        print(obj)
except Exception:
    pass
EOF
}

# Fresh sandbox per test: isolated tmp dir, stub grok first on PATH,
# stub env reset. Sets SANDBOX, ARGV_LOG.
sandbox() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/grok-delegate-test.XXXXXX")"
  ARGV_LOG="$SANDBOX/argv.log"
  export PATH="$TESTS_DIR/stubs:$ORIG_PATH"
  export GROK_STUB_LOG="$ARGV_LOG"
  unset GROK_STUB_STDOUT GROK_STUB_STDOUT_FILE GROK_STUB_STDERR GROK_STUB_EXIT GROK_STUB_SLEEP 2>/dev/null
  export GROK_DELEGATE_HOME="$SANDBOX/home"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_doctor_reports_ok_with_grok_on_path() {
  sandbox
  local out
  out="$("$SUT" doctor 2>&1)"
  local code=$?
  assert_eq 0 "$code" "exit code" || return
  echo "$out" > "$SANDBOX/doctor.json"
  assert_eq "ok" "$(json_get "$SANDBOX/doctor.json" status)" "status" || return
  assert_contains "$(json_get "$SANDBOX/doctor.json" grok_version)" "stub" "grok_version" || return
  ok
}

test_run_invokes_grok_headless_with_task() {
  sandbox
  local out
  out="$("$SUT" run --task "hello world" 2>"$SANDBOX/err")"
  local code=$?
  assert_eq 0 "$code" "exit code" || { cat "$SANDBOX/err"; return; }
  local argv
  argv="$(cat "$ARGV_LOG" | tr '\n' '|')"
  assert_contains "$argv" "--single|hello world|" "prompt flag" || return
  assert_contains "$argv" "--output-format|json|" "json output" || return
  assert_contains "$argv" "--permission-mode|acceptEdits|" "default mode is edit" || return
  echo "$out" > "$SANDBOX/envelope.json"
  assert_eq "ok" "$(json_get "$SANDBOX/envelope.json" status)" "envelope status" || return
  assert_eq "0" "$(json_get "$SANDBOX/envelope.json" exit_code)" "envelope exit_code" || return
  ok
}

test_run_mode_read_only_maps_to_plan() {
  sandbox
  "$SUT" run --task "t" --mode read-only >/dev/null 2>&1
  local argv
  argv="$(cat "$ARGV_LOG" | tr '\n' '|')"
  assert_contains "$argv" "--permission-mode|plan|" "read-only maps to plan" || return
  assert_not_contains "$argv" "--always-approve" "read-only never auto-approves" || return
  ok
}

test_run_mode_full_maps_to_bypass_with_always_approve() {
  sandbox
  "$SUT" run --task "t" --mode full >/dev/null 2>&1
  local argv
  argv="$(cat "$ARGV_LOG" | tr '\n' '|')"
  assert_contains "$argv" "--permission-mode|bypassPermissions|" "full maps to bypassPermissions" || return
  assert_contains "$argv" "--always-approve" "full auto-approves" || return
  ok
}

test_run_rejects_unknown_mode() {
  sandbox
  "$SUT" run --task "t" --mode yolo >/dev/null 2>"$SANDBOX/err"
  local code=$?
  assert_eq 2 "$code" "exit code" || return
  assert_contains "$(cat "$SANDBOX/err")" "invalid mode" "error names invalid mode" || return
  ok
}

test_run_task_file_uses_prompt_file() {
  sandbox
  printf 'long task from file\n' > "$SANDBOX/task.md"
  "$SUT" run --task-file "$SANDBOX/task.md" >/dev/null 2>&1 || { fail "run exited nonzero"; return; }
  local argv
  argv="$(cat "$ARGV_LOG" | tr '\n' '|')"
  assert_contains "$argv" "--prompt-file|$SANDBOX/task.md|" "prompt-file flag" || return
  assert_not_contains "$argv" "--single" "no inline prompt" || return
  ok
}

test_run_task_file_missing_is_an_error() {
  sandbox
  "$SUT" run --task-file "$SANDBOX/nope.md" >/dev/null 2>"$SANDBOX/err"
  local code=$?
  assert_eq 2 "$code" "exit code" || return
  assert_contains "$(cat "$SANDBOX/err")" "task file not found" "error message" || return
  ok
}

test_run_injects_delegation_contract_rules() {
  sandbox
  "$SUT" run --task "t" >/dev/null 2>&1 || { fail "run exited nonzero"; return; }
  local argv
  argv="$(cat "$ARGV_LOG" | tr '\n' '|')"
  assert_contains "$argv" "--rules|" "rules flag present" || return
  assert_contains "$argv" "DELEGATION CONTRACT" "contract header" || return
  assert_contains "$argv" "## Result" "result section required" || return
  assert_contains "$argv" "## Files touched" "files section required" || return
  ok
}

test_run_no_contract_omits_rules() {
  sandbox
  "$SUT" run --task "t" --no-contract >/dev/null 2>&1 || { fail "run exited nonzero"; return; }
  local argv
  argv="$(cat "$ARGV_LOG" | tr '\n' '|')"
  assert_not_contains "$argv" "--rules" "rules flag absent" || return
  ok
}

test_run_extracts_session_id_and_result() {
  sandbox
  local out
  out="$("$SUT" run --task "t" 2>/dev/null)"
  echo "$out" > "$SANDBOX/envelope.json"
  assert_eq "stub-session-1234" "$(json_get "$SANDBOX/envelope.json" session_id)" "session_id" || return
  assert_eq "stub-ok" "$(json_get "$SANDBOX/envelope.json" result)" "result text" || return
  ok
}

test_run_extracts_result_from_jsonl_stream() {
  sandbox
  printf '%s\n%s\n%s\n' \
    '{"type":"system","session_id":"jsonl-sess-99"}' \
    '{"type":"assistant","text":"working..."}' \
    '{"type":"result","result":"final answer","session_id":"jsonl-sess-99"}' \
    > "$SANDBOX/stream.jsonl"
  export GROK_STUB_STDOUT_FILE="$SANDBOX/stream.jsonl"
  local out
  out="$("$SUT" run --task "t" 2>/dev/null)"
  echo "$out" > "$SANDBOX/envelope.json"
  assert_eq "jsonl-sess-99" "$(json_get "$SANDBOX/envelope.json" session_id)" "session_id" || return
  assert_eq "final answer" "$(json_get "$SANDBOX/envelope.json" result)" "result text" || return
  ok
}

test_run_detects_auth_failure() {
  sandbox
  export GROK_STUB_STDOUT='{"type":"error","message":"Not signed in. To authenticate without a browser, run:\n  grok login --device-code"}'
  export GROK_STUB_EXIT=1
  local out
  out="$("$SUT" run --task "t" 2>/dev/null)"
  local code=$?
  assert_eq 1 "$code" "exit code" || return
  echo "$out" > "$SANDBOX/envelope.json"
  assert_eq "auth_required" "$(json_get "$SANDBOX/envelope.json" status)" "status" || return
  assert_contains "$(json_get "$SANDBOX/envelope.json" remediation)" "grok login" "remediation" || return
  ok
}

test_run_reports_error_status_on_nonzero_exit() {
  sandbox
  export GROK_STUB_STDOUT='{"type":"error","message":"model exploded"}'
  export GROK_STUB_EXIT=3
  local out
  out="$("$SUT" run --task "t" 2>/dev/null)"
  local code=$?
  assert_eq 1 "$code" "wrapper exit code" || return
  echo "$out" > "$SANDBOX/envelope.json"
  assert_eq "error" "$(json_get "$SANDBOX/envelope.json" status)" "status" || return
  assert_eq "3" "$(json_get "$SANDBOX/envelope.json" exit_code)" "grok exit code preserved" || return
  assert_contains "$(json_get "$SANDBOX/envelope.json" error)" "model exploded" "error message surfaced" || return
  ok
}

test_run_kills_grok_after_timeout() {
  sandbox
  export GROK_STUB_SLEEP=10
  local start end out code
  start=$(date +%s)
  out="$("$SUT" run --task "t" --timeout 1 2>/dev/null)"
  code=$?
  end=$(date +%s)
  if [ $((end - start)) -ge 8 ]; then
    fail "grok was not killed (took $((end - start))s)"
    return
  fi
  assert_eq 1 "$code" "wrapper exit code" || return
  echo "$out" > "$SANDBOX/envelope.json"
  assert_eq "timeout" "$(json_get "$SANDBOX/envelope.json" status)" "status" || return
  ok
}

test_run_envelope_includes_duration() {
  sandbox
  local out
  out="$("$SUT" run --task "t" 2>/dev/null)"
  echo "$out" > "$SANDBOX/envelope.json"
  local dur
  dur="$(json_get "$SANDBOX/envelope.json" duration_s)"
  if [ -z "$dur" ]; then
    fail "duration_s missing from envelope"
    return
  fi
  ok
}

test_run_passes_through_tuning_flags() {
  sandbox
  "$SUT" run --task "t" --model grok-4 --effort high --max-turns 12 \
    --cwd /tmp --worktree wt1 >/dev/null 2>&1 || { fail "run exited nonzero"; return; }
  local argv
  argv="$(cat "$ARGV_LOG" | tr '\n' '|')"
  assert_contains "$argv" "--model|grok-4|" "model" || return
  assert_contains "$argv" "--reasoning-effort|high|" "effort" || return
  assert_contains "$argv" "--max-turns|12|" "max turns" || return
  assert_contains "$argv" "--cwd|/tmp|" "cwd" || return
  assert_contains "$argv" "--worktree|wt1|" "worktree" || return
  ok
}

test_run_schema_inline_maps_to_json_schema() {
  sandbox
  "$SUT" run --task "t" --schema '{"type":"object"}' >/dev/null 2>&1 || { fail "run exited nonzero"; return; }
  local argv
  argv="$(cat "$ARGV_LOG" | tr '\n' '|')"
  assert_contains "$argv" '--json-schema|{"type":"object"}|' "inline schema" || return
  ok
}

test_run_schema_at_file_reads_contents() {
  sandbox
  printf '{"type":"array"}' > "$SANDBOX/schema.json"
  "$SUT" run --task "t" --schema "@$SANDBOX/schema.json" >/dev/null 2>&1 || { fail "run exited nonzero"; return; }
  local argv
  argv="$(cat "$ARGV_LOG" | tr '\n' '|')"
  assert_contains "$argv" '--json-schema|{"type":"array"}|' "schema from file" || return
  ok
}

test_run_forwards_extra_grok_args_after_double_dash() {
  sandbox
  "$SUT" run --task "t" -- --disable-web-search --allow "Bash(git:*)" >/dev/null 2>&1 \
    || { fail "run exited nonzero"; return; }
  local argv
  argv="$(cat "$ARGV_LOG" | tr '\n' '|')"
  assert_contains "$argv" "--disable-web-search|" "extra flag forwarded" || return
  assert_contains "$argv" "--allow|Bash(git:*)|" "extra flag with value forwarded" || return
  ok
}

test_run_label_lands_in_envelope_and_run_dir() {
  sandbox
  local out
  out="$("$SUT" run --task "t" --label review-tests 2>/dev/null)"
  echo "$out" > "$SANDBOX/envelope.json"
  assert_eq "review-tests" "$(json_get "$SANDBOX/envelope.json" label)" "label" || return
  assert_contains "$(json_get "$SANDBOX/envelope.json" run_dir)" "review-tests" "run dir named after label" || return
  ok
}

test_resume_continues_named_session() {
  sandbox
  "$SUT" resume --session abc-123 --task "keep going" >/dev/null 2>&1 \
    || { fail "resume exited nonzero"; return; }
  local argv
  argv="$(cat "$ARGV_LOG" | tr '\n' '|')"
  assert_contains "$argv" "--resume|abc-123|" "resume flag" || return
  assert_contains "$argv" "--single|keep going|" "prompt" || return
  assert_contains "$argv" "--output-format|json|" "json output" || return
  ok
}

test_resume_requires_session() {
  sandbox
  "$SUT" resume --task "t" >/dev/null 2>"$SANDBOX/err"
  assert_eq 2 "$?" "exit code" || return
  assert_contains "$(cat "$SANDBOX/err")" "--session" "error names missing flag" || return
  ok
}

test_run_reports_not_found_when_grok_missing() {
  sandbox
  export PATH="/usr/bin:/bin"
  local out
  out="$("$SUT" run --task "t" 2>/dev/null)"
  local code=$?
  assert_eq 1 "$code" "exit code" || return
  echo "$out" > "$SANDBOX/envelope.json"
  assert_eq "not_found" "$(json_get "$SANDBOX/envelope.json" status)" "status" || return
  ok
}

test_parallel_runs_all_tasks_and_aggregates() {
  sandbox
  printf 'task one\n' > "$SANDBOX/t1.md"
  printf 'task two\n' > "$SANDBOX/t2.md"
  unset GROK_STUB_LOG
  local out
  out="$("$SUT" parallel --task-file "$SANDBOX/t1.md" --task-file "$SANDBOX/t2.md" 2>/dev/null)"
  local code=$?
  assert_eq 0 "$code" "exit code" || return
  echo "$out" > "$SANDBOX/index.json"
  assert_eq "ok" "$(json_get "$SANDBOX/index.json" status)" "aggregate status" || return
  assert_eq "2" "$(json_get "$SANDBOX/index.json" counts.total)" "total count" || return
  assert_eq "2" "$(json_get "$SANDBOX/index.json" counts.ok)" "ok count" || return
  local dir1 dir2
  dir1="$(json_get "$SANDBOX/index.json" agents.0.run_dir)"
  dir2="$(json_get "$SANDBOX/index.json" agents.1.run_dir)"
  if [ -z "$dir1" ] || [ "$dir1" = "$dir2" ]; then
    fail "agent run dirs missing or colliding: [$dir1] [$dir2]"
    return
  fi
  ok
}

test_parallel_surfaces_failures() {
  sandbox
  printf 'task one\n' > "$SANDBOX/t1.md"
  printf 'task two\n' > "$SANDBOX/t2.md"
  unset GROK_STUB_LOG
  export GROK_STUB_EXIT=2
  export GROK_STUB_STDOUT='{"type":"error","message":"boom"}'
  local out
  out="$("$SUT" parallel --task-file "$SANDBOX/t1.md" --task-file "$SANDBOX/t2.md" 2>/dev/null)"
  local code=$?
  assert_eq 1 "$code" "exit code" || return
  echo "$out" > "$SANDBOX/index.json"
  assert_eq "error" "$(json_get "$SANDBOX/index.json" status)" "aggregate status" || return
  assert_eq "2" "$(json_get "$SANDBOX/index.json" counts.failed)" "failed count" || return
  ok
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

ORIG_PATH="$PATH"
TESTS=$(declare -F | awk '{print $3}' | grep '^test_')

if [ -n "${1:-}" ]; then
  TESTS="$1"
fi

for t in $TESTS; do
  CURRENT_TEST="$t"
  "$t"
done

echo
echo "passed: $PASS  failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILED: %s\n' "${FAILURES[@]}"
  exit 1
fi
exit 0
