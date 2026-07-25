---
description: Delegate a task to Grok Build agents and integrate the results
argument-hint: "[agents: N, mode: read-only|edit|full] <task>"
---

Delegate the task below to the Grok Build CLI, then integrate the results. Use the
delegating-to-grok skill for the full playbook (task-brief quality, mode selection,
failure handling); this command is the execution procedure.

The delegation API is `${CLAUDE_PLUGIN_ROOT}/scripts/grok-delegate.sh`. Never invoke
`grok` directly — the wrapper standardizes permissions, timeouts, the delegation
contract, and always returns one JSON envelope no matter how the run went.

## 1. Parse the request

Request: $ARGUMENTS

If the request begins with a bracketed directive block like `[agents: 5]` or
`[agents: 3, mode: read-only, model: grok-4]`, extract the directives; everything
after the block is the task. Recognized directives: `agents` (parallel agent count,
default 1, cap at 8), `mode` (read-only | edit | full), `model`, `effort`,
`timeout` (seconds), `max-turns`, `session` (resume an earlier grok session).
Unknown directives: mention them and proceed without them.

If the task is empty, ask the user what to delegate — do not invent a task.

## 2. Choose the mode (when not given)

- Review, analysis, research, exploration → `read-only`
- Writing or modifying files in the repo → `edit` (the default)
- Anything needing arbitrary commands, downloads, network side effects, or
  external tooling (e.g. grok imagine) → `full`

`full` auto-approves every tool call grok makes. Use it only when the task
genuinely requires it, and say so in the summary.

## 3. Write the task brief

Write the brief to a file (via `mktemp`), never inline — briefs should be
thorough and quoting-proof. A strong brief contains: the goal, all context grok
cannot discover itself (relevant file paths, contents of any PLAN or spec the
user referenced, constraints, naming conventions), what "done" looks like, and
how grok should verify its own work. Grok performs exactly as well as its brief.

## 4. Run

Single agent:

```
${CLAUDE_PLUGIN_ROOT}/scripts/grok-delegate.sh run \
  --task-file <brief> --mode <mode> --label <short-label> [--model ... --effort ... --timeout ...]
```

`[agents: N]` with N > 1: split the task into N genuinely independent slices
(by directory, by file group, by concern — never overlapping edits to the same
files), write one brief per slice each with the shared context plus its slice,
then:

```
${CLAUDE_PLUGIN_ROOT}/scripts/grok-delegate.sh parallel \
  --task-file <brief1> --task-file <brief2> ... --mode <mode> [shared options]
```

If the task cannot be split into independent slices, run fewer agents and say why.

`[session: <id>]`: use `resume --session <id>` instead of `run`.

Runs that may exceed a few minutes: launch with `run_in_background: true` and a
generous `--timeout`, then read the envelope from the completed task's output.
Parallel edit-mode agents on this repo: prefer `--worktree` per agent to keep
concurrent edits isolated.

## 5. Integrate the envelope

Every run prints one JSON envelope (`status`, `result`, `session_id`, `run_dir`,
`exit_code`, `duration_s`, and on failure `error`/`remediation`).

- `ok` — read `result` (it ends with `## Result`, `## Files touched`,
  `## Follow-ups`). Spot-check the claims: read at least the key files it says it
  touched before reporting success. Report to the user: what grok did, what was
  verified, the session_id for follow-ups.
- `auth_required` / `not_found` — stop and relay `remediation` to the user
  verbatim. Never attempt `grok login` or credential entry yourself.
- `timeout` — report how far it got (read `output_file`), then either resume the
  session with a longer `--timeout` or narrow the task.
- `error` — read `error` and `stderr_file`, fix what is fixable (bad flag, bad
  brief), retry at most once, otherwise report the failure honestly.

Full transcripts stay in `run_dir` — cite them rather than pasting them.
