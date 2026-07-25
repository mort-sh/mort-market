# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A [Claude Code plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces) — a catalog, not an application. There is no build, no test runner, and no dependency manifest. The "source" is JSON manifests, `SKILL.md` files, and shell payloads.

Two levels, easy to conflate:

- `.claude-plugin/marketplace.json` — the catalog. Lists plugins and where to fetch each one.
- `plugins/<name>/.claude-plugin/plugin.json` — one plugin's own manifest.

`metadata.pluginRoot` is `./plugins`, so each catalog entry's `source` is written relative to that (`"./identity-scrub"`, not `"./plugins/identity-scrub"`).

## Verify changes

```bash
claude plugin validate ./plugins/<name> --strict
```

`--strict` promotes unrecognized-field warnings to errors; unrecognized fields otherwise load fine at runtime, so without it a typo'd key passes silently.

To exercise the whole catalog end to end — this is the only way to confirm `marketplace.json` parses *and* every `source` resolves:

```bash
claude plugin marketplace add ./ --scope local
claude plugin list --available --json
claude plugin marketplace remove mort-market --scope local
```

`--scope local` confines the registration to this directory. Remove it afterward; the JSON blob it leaves in `.claude/settings.local.json` is gitignored. Note `list --available --json` returns `{installed, available}` — the marketplace's plugins are under `available`, keyed `<plugin>@mort-market`.

## Constraints that shape the layout

**Plugins are copied to a cache on install.** Nothing in `plugins/<name>/` may reference a path outside its own directory — `../shared/` won't exist on a user's machine. Bundle what a plugin needs inside it and reach it via `${CLAUDE_PLUGIN_ROOT}`, which resolves in skill and agent *content* as well as in hook/MCP/LSP config.

This is why `identity-scrub`'s git hooks live at `plugins/identity-scrub/githooks/` rather than at the repo root. The repo installs its own hooks from that path — one copy, no drift.

**Versions gate updates.** A plugin pinned to a `version` string only reaches users when that string changes; omit it and every commit counts as a new version. `version` in `plugin.json` wins over the marketplace entry, but both are set here — keep them in sync and bump on every user-visible change.

**Skill descriptions are the dispatch mechanism.** The `description` frontmatter is what Claude matches against a task to decide whether to load the skill. Write it as trigger conditions ("use when the user wants to…"), not as a summary of contents.

## Git hooks in this repo

`core.hooksPath` is per-clone local config that git never sets on its own. In a fresh clone:

```bash
./plugins/identity-scrub/githooks/install.sh
```

The pre-push hook rewrites any commit identity outside the allowlist in `githooks/identity-scrub.conf`, then **aborts the push on purpose** (exit 2) because the commits git was about to send no longer exist under those SHAs. That is not a failure — re-run the push, with `--force-with-lease` if those commits were already on the remote.

Never add `Co-Authored-By` trailers. The hook rewrites author and committer fields but does not touch commit messages, so a trailer would survive and produce a co-author badge on GitHub.

## Adding a plugin

1. `plugins/<name>/.claude-plugin/plugin.json` — `name` is the only required field; set `version` too.
2. `plugins/<name>/skills/<skill>/SKILL.md` with `name` and `description` frontmatter.
3. An entry in `.claude-plugin/marketplace.json` with `"source": "./<name>"`.
4. Validate, then commit and push — the user wants changes to this repo pushed automatically.

Plugins can also ship agents, hooks, MCP servers, and LSP servers; see the [plugins reference](https://code.claude.com/docs/en/plugins-reference).
