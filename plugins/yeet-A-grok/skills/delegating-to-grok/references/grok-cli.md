# Grok Build CLI reference (for delegation)

Verified against grok 0.2.112. This documents the surface the delegation wrapper
builds on, plus what matters when driving grok headlessly.

## Headless invocation

One-shot agentic run, no TUI:

```
grok --single "<prompt>" --output-format json
grok --prompt-file <path> --output-format json     # long prompts, no quoting issues
```

`--single`/`-p` is "single user turn", not "single agent step" — grok still runs
its full tool-use loop, bounded by `--max-turns`. The `grok agent` subcommand is
transport plumbing (stdio / WebSocket relay / serve / leader) for SDK
integrations — not the delegation path.

`--output-format`: `plain` (default), `json`, `streaming-json`. In `json` mode
stdout carries typed JSON objects (single object or JSONL stream) with a `type`
field. Observed error shape (exit code 1):

```json
{"type":"error","message":"Not signed in. To authenticate without a browser, run:\n  grok login --device-code\n\nAlternatively, set the XAI_API_KEY environment variable or run `grok login` on a machine with a browser."}
```

Result objects carry the final text under keys like `result` and a
`session_id`; the wrapper parses all of these defensively (JSON or JSONL, last
object wins, multiple key aliases).

## Permissions in headless runs

`--permission-mode`: `default`, `acceptEdits`, `auto`, `dontAsk`,
`bypassPermissions`, `plan`. Headless runs cannot answer interactive permission
prompts, so the wrapper maps:

- `read-only` → `--permission-mode plan` (no edits or side effects)
- `edit` → `--permission-mode acceptEdits`
- `full` → `--permission-mode bypassPermissions --always-approve`

Finer control passes through after `--`: `--allow <RULE>` / `--deny <RULE>`,
`--tools <list>` / `--disallowed-tools <list>`, `--disable-web-search`,
`--no-subagents`.

## Steering flags

- `-m, --model <MODEL>` — model ID (`grok models` lists them)
- `--reasoning-effort <EFFORT>` (alias `--effort`)
- `--max-turns <N>` — hard cap on agent turns
- `--rules <RULES>` — extra rules appended to the system prompt (how the
  wrapper injects the delegation contract)
- `--system-prompt-override <PROMPT>` — full replacement; avoid for delegation,
  it discards grok's tool instructions
- `--json-schema <SCHEMA>` — constrain final output to a JSON Schema; implies
  `--output-format json`
- `--agents <JSON>` — inline subagent definitions; `--no-subagents` disables
- `--verbatim` — send the prompt exactly as given
- `--no-memory` / `--experimental-memory` — cross-session memory off/on
- `--no-plan` — disable plan mode

## Workspace and sessions

- `--cwd <CWD>` — working directory for the run
- `-w, --worktree [<name>]` — run in a fresh git worktree;
  `--worktree-ref <ref>` picks the base (defaults to current HEAD)
- `grok worktree` — manage worktrees
- `-r, --resume [<SESSION_ID_OR_TITLE>]` — resume by ID or title; `-c,
  --continue` resumes the most recent session for the cwd
- `--fork-session` — new session ID when resuming; `--restore-code` checks out
  the original session's commit
- `grok sessions list|search|delete` — session management
- `grok export` — export a session transcript as Markdown

## Auth and environment

- Auth: `grok login`, `grok login --device-code`, or `XAI_API_KEY` env var.
  "Not signed in" errors must be fixed by the user, never by the orchestrator.
- `grok doctor` — terminal/environment diagnostics; `grok inspect` — effective
  config for a directory; `grok models` — available model IDs
- `--sandbox <PROFILE>` (env `GROK_SANDBOX`) — filesystem/network sandbox
- Config: `~/.grok/config.toml`

## Grok-only tooling worth delegating for

- Web search / web fetch built in (disable with `--disable-web-search`)
- Grok imagine (image generation) — reachable when the task allows the
  relevant tools; run in `full` mode since it needs network side effects
- xAI model family via `-m`
