# delegate-grok

Delegate tasks from Claude Code to the [Grok Build CLI](https://x.ai) through a
standardized headless-run API. Claude stays the orchestrator; grok becomes a
partner harness for review, research, bulk work, parallel agents, and grok-only
tooling (xAI models, grok imagine, built-in web search).

## Usage

```
/delegate-grok review all the tests
/delegate-grok [agents: 5] review all the tests
/delegate-grok [mode: full] visit the website detailed in the PLAN and pull down all the images
/delegate-grok [session: <id>] now fix the issues you found
```

Directives in the leading bracket block: `agents`, `mode` (read-only | edit |
full), `model`, `effort`, `timeout`, `max-turns`, `session`.

## How it works

Everything funnels through `scripts/grok-delegate.sh`, which wraps headless
`grok` runs and always prints exactly one JSON envelope:

```
grok-delegate.sh run --task-file brief.md --mode read-only --label review
grok-delegate.sh parallel --task-file a.md --task-file b.md --mode edit
grok-delegate.sh resume --session <id> --task "continue"
grok-delegate.sh doctor
```

The wrapper standardizes:

- **Permissions** — `read-only`/`edit`/`full` presets mapped onto grok's
  permission modes, so headless runs never hang on prompts.
- **The delegation contract** — rules appended to grok's system prompt so it
  works autonomously and reports back in a fixed shape (`## Result`,
  `## Files touched`, `## Follow-ups`).
- **Timeouts** — portable watchdog (macOS has no `timeout` binary).
- **Results** — one envelope JSON: `status` (ok | error | timeout |
  auth_required | not_found), `result`, `session_id`, `run_dir`, `exit_code`,
  `duration_s`, `remediation`.

Run artifacts (raw grok output, stderr, envelopes) land under
`~/.cache/grok-delegate/` (override with `GROK_DELEGATE_HOME`).

## Requirements

- `grok` on PATH, authenticated (`grok login`)
- `python3` (JSON envelope handling)

## Tests

```
tests/run-tests.sh
```

The suite drives the wrapper against a stub `grok` binary — no network, no
model calls.

## Roadmap

Grok Build is the first backend. The envelope/contract layer is deliberately
harness-agnostic so codex, opencode, and friends can slot in behind the same
API later.
