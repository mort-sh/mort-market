---
name: delegating-to-grok
description: This skill should be used when the user asks to "delegate to grok", "yeet to grok", "offload this to grok", "have grok do it", "run grok agents", "use grok imagine", invokes /yeet-A-grok, or wants a second AI coding harness to handle review, research, exploration, or bulk work in parallel with Claude. Covers writing task briefs, choosing permission modes, parallel fan-out, session resume, and integrating grok's results.
version: 0.2.0
---

# Delegating to Grok

## Purpose

Grok Build is a second autonomous coding harness. Delegating to it buys parallel
capacity (grok works while Claude works), an independent second opinion, and
access to grok-only tooling (e.g. grok imagine, xAI models). The delegation API
is one script:

```
${CLAUDE_PLUGIN_ROOT}/scripts/grok-delegate.sh <doctor|run|resume|parallel> [options]
```

Always go through the script — never invoke `grok` directly. It standardizes
headless permissions, enforces timeouts (macOS has no `timeout` binary), injects
the delegation contract, and reduces every outcome — success, crash, hang,
missing binary, missing auth — to one machine-readable JSON envelope.

Run `${CLAUDE_PLUGIN_ROOT}/scripts/grok-delegate.sh --help` for exact flags, and
consult `references/grok-cli.md` for the underlying grok CLI surface.

## What delegates well

Delegate: self-contained tasks with checkable outcomes — code review, test
audits, research and codebase exploration, bulk mechanical changes, asset
generation, web scraping/collection, second implementations to compare against.

Keep: anything needing conversation context grok cannot be given compactly,
architectural decisions the user expects Claude to own, tasks touching secrets,
and work mid-flight in Claude's own edits (two agents editing one file is a
merge conflict factory).

## The task brief is everything

Grok receives only the brief — no conversation history, no CLAUDE.md, no memory.
Write briefs to a temp file (`--task-file`), never inline. Include:

1. **Goal** — one paragraph, outcome-shaped ("all tests reviewed, findings
   listed by severity"), not process-shaped.
2. **Context grok cannot discover** — absolute repo path, relevant file paths,
   pasted contents of any PLAN/spec the user referenced, project conventions
   that matter.
3. **Constraints** — what not to touch, style rules, scope fences.
4. **Definition of done** — concrete deliverables and where to write them.
5. **Verification** — the command or check grok must run before claiming done.

The wrapper appends a delegation contract to grok's system prompt, so grok works
autonomously (never asks questions) and ends with `## Result`, `## Files touched`,
`## Follow-ups` sections the orchestrator can parse. `--no-contract` disables
this only when raw output is required (e.g. with `--schema`).

## Mode, model, and budget selection

| Situation | Flags |
|---|---|
| Review / research / exploration | `--mode read-only` |
| Editing files (default) | `--mode edit` |
| Arbitrary commands, downloads, grok imagine | `--mode full` (auto-approves everything — only when truly needed) |
| Hard problem, deep reasoning | `--effort high`, generous `--timeout` |
| Bulk mechanical work | default effort, `--max-turns` as a cost fence |
| Machine-parseable answer needed | `--schema '<json-schema>'` or `--schema @file` |
| Isolated edits / parallel editors | `--worktree <name>` per agent |

Default timeout is 900 s. Estimate generously: a real review of a large test
suite is 10–30 minutes, so raise `--timeout` and launch via background Bash
rather than letting the wrapper kill honest work.

## Parallel fan-out

`parallel` takes one `--task-file` per agent and runs them concurrently,
aggregating envelopes into one index JSON (`counts`, per-agent `agents[]`).

- Slice by independent units (directories, file groups, concerns). Overlapping
  edit scopes are forbidden; if slices must overlap, use `read-only` agents and
  apply changes centrally afterward.
- Every brief repeats the shared context — agents share nothing.
- In edit mode, give each agent its own `--worktree`.
- Cap fan-out at 8; beyond that, coordination costs exceed the parallelism win.

## Integrating results

Parse the envelope JSON (single object on stdout; also saved as
`envelope.json` in `run_dir`):

| status | Meaning and response |
|---|---|
| `ok` | Read `result`; spot-check the `## Files touched` claims before trusting them. Keep `session_id` for follow-ups. |
| `auth_required` | Grok is not signed in. Relay `remediation` to the user verbatim; never run `grok login` or handle credentials. |
| `not_found` | Grok is not installed; relay `remediation`. |
| `timeout` | Read partial progress from `output_file`; resume with a longer `--timeout` or a narrower task. |
| `error` | Read `error` + `stderr_file`; fix fixable causes, retry once, then report honestly. |

Treat grok's output as a report to verify, not ground truth: run the tests it
says pass, open the files it says it created. For follow-up work in the same
context, `resume --session <session_id> --task "..."` is far cheaper than
re-briefing from scratch.

## Additional resources

- **`references/grok-cli.md`** — the raw grok CLI surface: headless invocation,
  output formats, permission modes, sessions/worktrees, and observed JSON shapes.
