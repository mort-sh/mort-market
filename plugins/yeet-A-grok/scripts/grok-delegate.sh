#!/usr/bin/env bash
# grok-delegate.sh — standardized delegation API between Claude Code and the
# Grok Build CLI. Wraps headless grok invocations and always reports back a
# single JSON envelope on stdout, regardless of how the run went.
set -u

usage() {
  cat <<'EOF'
Usage: grok-delegate.sh <subcommand> [options]

Subcommands:
  doctor    Check that grok is installed and report its version.
  run       Delegate one task to grok headlessly and print a JSON result envelope.
  resume    Continue a prior grok session (--session <id-or-title>) with a new task.
  parallel  Fan tasks out to concurrent grok agents (one --task-file per agent)
            and print an aggregate index JSON.

Run options:
  --task <text> | --task-file <path>   The task (exactly one required).
  --mode read-only|edit|full           Permission preset (default: edit).
                                         read-only -> --permission-mode plan
                                         edit      -> --permission-mode acceptEdits
                                         full      -> --permission-mode bypassPermissions --always-approve
  --model <id>                         Grok model ID.
  --effort <level>                     Reasoning effort.
  --max-turns <n>                      Cap agent turns.
  --cwd <dir>                          Working directory for the run.
  --worktree <name>                    Run in a fresh git worktree.
  --schema <json | @file>              Constrain final output to a JSON Schema.
  --timeout <seconds>                  Kill the run after this long (default 900).
  --label <name>                       Human-readable run label (envelope + run dir).
  --no-contract                        Skip the delegation-contract system rules.
  -- <args...>                         Forward anything else to grok verbatim.

Every run prints one JSON envelope: status (ok|error|timeout|auth_required|not_found),
exit_code, duration_s, session_id, result, run_dir with raw output/stderr, and
remediation when the failure needs the user to act.
EOF
}

# Appended to grok's system prompt on every delegated run (unless --no-contract).
# This is the standardization layer: it makes an autonomous grok run finish in a
# shape the orchestrating agent can integrate without re-reading the transcript.
delegation_contract() {
  cat <<'EOF'
DELEGATION CONTRACT — you are running headlessly as a delegate for another AI agent (an orchestrator), not chatting with a human.

1. Work autonomously. Never ask questions, never wait for confirmation; when a detail is ambiguous, choose the most reasonable interpretation, proceed, and record the assumption.
2. Verify your own work before finishing (run the code, re-read the diff, check the artifact exists). Report what you verified, not what you intended.
3. Stay within the task's scope. Do not refactor, reformat, or "improve" anything you were not asked to touch.
4. If the task is impossible or partially completed, say so plainly — a truthful partial result is worth more than an optimistic summary.

End your final message with exactly these three sections:

## Result
2-6 sentences: what was accomplished, what was verified, any assumptions made or parts left undone.

## Files touched
One absolute path per line, each prefixed with created/modified/deleted. Write "none" if the task produced no file changes.

## Follow-ups
Concrete next actions the orchestrator should consider, one per line. Write "none" if there are none.
EOF
}

# Root for run artifacts (task files, raw output, envelopes).
delegate_home() {
  printf '%s' "${GROK_DELEGATE_HOME:-${HOME}/.cache/grok-delegate}"
}

# emit_envelope <run_dir> <status> <exit_code>
# Reads raw grok stdout from <run_dir>/output.json, writes and prints envelope.
emit_envelope() {
  local run_dir="$1" status="$2" exit_code="$3"
  RUN_DIR="$run_dir" STATUS="$status" EXIT_CODE="$exit_code" python3 <<'EOF'
import json, os

run_dir = os.environ["RUN_DIR"]
output_file = os.path.join(run_dir, "output.json")
stderr_file = os.path.join(run_dir, "stderr.log")

# Grok's json output is one object or a stream of typed objects (JSONL).
# Parse defensively: a delegate wrapper must never crash on odd output.
objects = []
try:
    with open(output_file) as f:
        raw = f.read()
    try:
        parsed = json.loads(raw)
        objects = parsed if isinstance(parsed, list) else [parsed]
    except ValueError:
        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                objects.append(json.loads(line))
            except ValueError:
                pass
except OSError:
    pass

session_id = None
result = None
error = None
for obj in objects:
    if not isinstance(obj, dict):
        continue
    for key in ("session_id", "sessionId"):
        if obj.get(key):
            session_id = obj[key]
    if obj.get("type") == "error":
        error = obj.get("message") or obj.get("error")
        continue
    for key in ("result", "response", "text", "message", "content"):
        value = obj.get(key)
        if isinstance(value, str) and value:
            result = value
            break

status = os.environ["STATUS"]
envelope = {
    "schema_version": 1,
    "status": status,
    "exit_code": int(os.environ["EXIT_CODE"]),
    "duration_s": int(os.environ.get("DURATION_S", "0")),
    "label": os.environ.get("LABEL", "task"),
    "run_dir": run_dir,
    "output_file": output_file,
    "stderr_file": stderr_file,
}
if session_id:
    envelope["session_id"] = session_id
if result is not None:
    envelope["result"] = result
if status == "not_found":
    envelope["remediation"] = (
        "grok CLI not found on PATH. The user must install Grok Build and run `grok login`."
    )
if status != "ok" and error:
    envelope["error"] = error
    if "Not signed in" in error or "not signed in" in error:
        envelope["status"] = "auth_required"
        envelope["remediation"] = (
            "Grok is not authenticated. The user must run `grok login` "
            "(or `grok login --device-code`, or set XAI_API_KEY) themselves."
        )

path = os.path.join(run_dir, "envelope.json")
with open(path, "w") as f:
    json.dump(envelope, f, indent=2)
print(json.dumps(envelope, indent=2))
EOF
}

# resume — continue a prior delegated session with a follow-up task.
# Everything except --session is forwarded to `run`.
cmd_resume() {
  local session=""
  local -a passthrough=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) session="$2"; shift 2 ;;
      *) passthrough+=("$1"); shift ;;
    esac
  done
  if [ -z "$session" ]; then
    echo "resume: --session <id-or-title> is required" >&2
    return 2
  fi
  cmd_run --resume-session "$session" ${passthrough[@]+"${passthrough[@]}"}
}

cmd_run() {
  local task="" task_file="" mode="edit" contract=1 timeout=900
  local model="" effort="" max_turns="" cwd="" worktree="" schema="" label="task" resume_session=""
  local -a extra_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) task="$2"; shift 2 ;;
      --task-file) task_file="$2"; shift 2 ;;
      --mode) mode="$2"; shift 2 ;;
      --no-contract) contract=0; shift ;;
      --timeout) timeout="$2"; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      --effort) effort="$2"; shift 2 ;;
      --max-turns) max_turns="$2"; shift 2 ;;
      --cwd) cwd="$2"; shift 2 ;;
      --worktree) worktree="$2"; shift 2 ;;
      --schema) schema="$2"; shift 2 ;;
      --label) label="$2"; shift 2 ;;
      --resume-session) resume_session="$2"; shift 2 ;;
      --) shift; extra_args=("$@"); break ;;
      *) echo "run: unknown option: $1" >&2; return 2 ;;
    esac
  done
  if [ -z "$task" ] && [ -z "$task_file" ]; then
    echo "run: --task or --task-file is required" >&2
    return 2
  fi
  if [ -n "$task_file" ] && [ ! -f "$task_file" ]; then
    echo "run: task file not found: $task_file" >&2
    return 2
  fi

  local -a mode_args
  case "$mode" in
    read-only) mode_args=(--permission-mode plan) ;;
    edit)      mode_args=(--permission-mode acceptEdits) ;;
    full)      mode_args=(--permission-mode bypassPermissions --always-approve) ;;
    *) echo "run: invalid mode: $mode (expected read-only, edit, or full)" >&2; return 2 ;;
  esac

  # Labels become path components; keep them filesystem-safe.
  label="$(printf '%s' "$label" | tr -c 'a-zA-Z0-9_.-' '-' | cut -c1-60)"
  local runs_root run_dir
  runs_root="$(delegate_home)/runs"
  mkdir -p "$runs_root"
  run_dir="$(mktemp -d "$runs_root/$(date +%Y%m%d-%H%M%S)-${label}.XXXXXX")"

  if [ -n "$schema" ]; then
    case "$schema" in
      @*)
        local schema_file="${schema#@}"
        if [ ! -f "$schema_file" ]; then
          echo "run: schema file not found: $schema_file" >&2
          return 2
        fi
        schema="$(cat "$schema_file")"
        ;;
    esac
  fi

  local -a prompt_args
  if [ -n "$task_file" ]; then
    prompt_args=(--prompt-file "$task_file")
  else
    prompt_args=(--single "$task")
  fi

  local -a contract_args=()
  if [ "$contract" -eq 1 ]; then
    contract_args=(--rules "$(delegation_contract)")
  fi

  local -a tuning_args=()
  [ -n "$model" ] && tuning_args+=(--model "$model")
  [ -n "$effort" ] && tuning_args+=(--reasoning-effort "$effort")
  [ -n "$max_turns" ] && tuning_args+=(--max-turns "$max_turns")
  [ -n "$cwd" ] && tuning_args+=(--cwd "$cwd")
  [ -n "$worktree" ] && tuning_args+=(--worktree "$worktree")
  [ -n "$schema" ] && tuning_args+=(--json-schema "$schema")
  [ -n "$resume_session" ] && tuning_args+=(--resume "$resume_session")

  local -a argv
  argv=(grok "${prompt_args[@]}" --output-format json "${mode_args[@]}"
    ${tuning_args[@]+"${tuning_args[@]}"}
    ${contract_args[@]+"${contract_args[@]}"}
    ${extra_args[@]+"${extra_args[@]}"})

  if ! command -v grok >/dev/null 2>&1; then
    : > "$run_dir/output.json"
    : > "$run_dir/stderr.log"
    DURATION_S=0 LABEL="$label" emit_envelope "$run_dir" "not_found" 127
    return 1
  fi

  # Portable timeout: run grok in the background and poll. macOS ships no
  # `timeout` binary, and a delegate that can hang forever is unusable.
  local start_ts end_ts timed_out=0
  start_ts=$(date +%s)
  "${argv[@]}" >"$run_dir/output.json" 2>"$run_dir/stderr.log" &
  local grok_pid=$!
  while kill -0 "$grok_pid" 2>/dev/null; do
    if [ $(( $(date +%s) - start_ts )) -ge "$timeout" ]; then
      timed_out=1
      kill -TERM "$grok_pid" 2>/dev/null
      sleep 2
      kill -KILL "$grok_pid" 2>/dev/null
      break
    fi
    sleep 0.2
  done
  wait "$grok_pid" 2>/dev/null
  local code=$?
  end_ts=$(date +%s)

  local status="ok"
  [ "$code" -ne 0 ] && status="error"
  [ "$timed_out" -eq 1 ] && status="timeout"
  DURATION_S=$((end_ts - start_ts)) LABEL="$label" emit_envelope "$run_dir" "$status" "$code"
  [ "$status" = "ok" ]
}

json_escape() { # string -> JSON-escaped string (no surrounding quotes)
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1])[1:-1])' "$1"
}

cmd_doctor() {
  local grok_bin
  grok_bin="$(command -v grok 2>/dev/null || true)"
  if [ -z "$grok_bin" ]; then
    printf '{"status":"not_found","message":"grok CLI not found on PATH. Install Grok Build, then run: grok login"}\n'
    return 1
  fi
  local version
  version="$(grok --version 2>/dev/null | head -n1)"
  printf '{"status":"ok","grok_bin":"%s","grok_version":"%s"}\n' \
    "$(json_escape "$grok_bin")" "$(json_escape "$version")"
}

# parallel — fan one task file per agent out to concurrent grok runs and
# aggregate their envelopes into a single index JSON.
cmd_parallel() {
  local -a task_files=()
  local -a shared=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --task-file) task_files+=("$2"); shift 2 ;;
      --no-contract) shared+=("$1"); shift ;;
      --) shift; shared+=(--); shared+=("$@"); break ;;
      *) shared+=("$1" "${2:-}"); shift 2 ;;
    esac
  done
  if [ "${#task_files[@]}" -eq 0 ]; then
    echo "parallel: at least one --task-file is required" >&2
    return 2
  fi
  local tf
  for tf in "${task_files[@]}"; do
    if [ ! -f "$tf" ]; then
      echo "parallel: task file not found: $tf" >&2
      return 2
    fi
  done

  local par_root par_dir
  par_root="$(delegate_home)/parallel"
  mkdir -p "$par_root"
  par_dir="$(mktemp -d "$par_root/$(date +%Y%m%d-%H%M%S).XXXXXX")"

  local -a pids=()
  local i=0
  for tf in "${task_files[@]}"; do
    i=$((i + 1))
    cmd_run --task-file "$tf" --label "agent-$i" ${shared[@]+"${shared[@]}"} \
      >"$par_dir/agent-$i.json" 2>"$par_dir/agent-$i.stderr" &
    pids+=($!)
  done

  local pid failed=0
  for pid in "${pids[@]}"; do
    wait "$pid" || failed=$((failed + 1))
  done

  PAR_DIR="$par_dir" python3 <<'EOF'
import glob, json, os, re

par_dir = os.environ["PAR_DIR"]
agents = []
for path in sorted(glob.glob(os.path.join(par_dir, "agent-*.json")),
                   key=lambda p: int(re.search(r"agent-(\d+)", p).group(1))):
    try:
        with open(path) as f:
            agents.append(json.load(f))
    except (OSError, ValueError):
        agents.append({"status": "error", "error": f"unreadable envelope: {path}"})

ok = sum(1 for a in agents if a.get("status") == "ok")
index = {
    "schema_version": 1,
    "status": "ok" if ok == len(agents) else "error",
    "counts": {"total": len(agents), "ok": ok, "failed": len(agents) - ok},
    "parallel_dir": par_dir,
    "agents": agents,
}
with open(os.path.join(par_dir, "index.json"), "w") as f:
    json.dump(index, f, indent=2)
print(json.dumps(index, indent=2))
EOF
  [ "$failed" -eq 0 ]
}

main() {
  local sub="${1:-}"
  shift 2>/dev/null || true
  case "$sub" in
    doctor) cmd_doctor "$@" ;;
    run) cmd_run "$@" ;;
    resume) cmd_resume "$@" ;;
    parallel) cmd_parallel "$@" ;;
    -h|--help|"") usage; [ "$sub" = "" ] && return 1 || return 0 ;;
    *) echo "unknown subcommand: $sub" >&2; usage >&2; return 1 ;;
  esac
}

main "$@"
