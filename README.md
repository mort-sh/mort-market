<p align="center">
  <img src="https://raw.githubusercontent.com/mort-sh/branding/refs/heads/main/logos/SOLID/SOLID_MORT_1.png" alt="Mort sigil" width="180" />
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/mort-sh/branding/refs/heads/main/Set/1x/Asset 5.png" alt="Asset accent" width="40" />
  <img src="https://raw.githubusercontent.com/mort-sh/branding/refs/heads/main/Set/1x/Asset 7.png" alt="Asset accent" width="40" />
  <img src="https://raw.githubusercontent.com/mort-sh/branding/refs/heads/main/Set/1x/Asset 9.png" alt="Asset accent" width="40" />
</p>

<h1 align="center">mort-market</h1>

<p align="center"><strong>A curated plugin &amp; skills catalog for agentic coding harnesses.</strong></p>

<p align="center">Claude Code • plugins • skills • hooks • multi-harness delegation</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/mort-sh/branding/refs/heads/main/Icons/icon_med@0.25x.png" width="24" alt="Icon separator" />
</p>

## Immersive overview

- **Catalog, not a product** – [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json) is the registry. No build step, no dependency graph — manifests, `SKILL.md` files, and shell payloads.
- **Harness-first tooling** – plugins that sharpen Claude Code and bridge out to partner harnesses (Grok Build first; more backends on the roadmap).
- **Self-contained installs** – every plugin under [`plugins/<name>/`](plugins/) bundles what it needs. On install, Claude copies the tree to a cache; `${CLAUDE_PLUGIN_ROOT}` is the only path contract.
- **Version-gated updates** – pin `version` in both the marketplace entry and `plugin.json`. Bump it when users should notice a change.
- **Dogfooded hygiene** – this repo runs its own [`identity-scrub`](plugins/identity-scrub) hooks so history stays on an approved identity.

<p align="center">
  <img src="https://raw.githubusercontent.com/mort-sh/branding/refs/heads/main/Icons/icon_med@0.25x.png" width="24" alt="Icon separator" />
</p>

## Quick start

### Autopilot (recommended)

Register the marketplace, then install what you need:

```zsh
# From Claude Code — owner/repo clones over SSH by default
/plugin marketplace add mort-sh/mort-market

# Browse the catalog
/plugin

# Install a plugin
/plugin install identity-scrub@mort-market
/plugin install yeet-A-grok@mort-market
/reload-plugins
```

Full URL or a local checkout work the same:

```zsh
/plugin marketplace add https://github.com/mort-sh/mort-market.git
/plugin marketplace add ./mort-market
```

Pull later commits with `/plugin marketplace update mort-market`.

### Modular control

Exercise the catalog from a local clone (useful when authoring):

```zsh
claude plugin marketplace add ./ --scope local
claude plugin list --available --json          # under `available`, keyed <plugin>@mort-market
claude plugin install identity-scrub@mort-market --scope local
claude plugin marketplace remove mort-market --scope local
```

`--scope local` keeps registration in this directory; the settings blob it writes is gitignored.

<p align="center">
  <img src="https://raw.githubusercontent.com/mort-sh/branding/refs/heads/main/Icons/icon_med@0.25x.png" width="24" alt="Icon separator" />
</p>

## Plugin rack

| Plugin | Role | Notes |
| ------ | ---- | ----- |
| [`identity-scrub`](plugins/identity-scrub) | Git identity enforcement | `pre-push` rewrites unapproved authors/committers, then aborts so you re-push clean SHAs. `post-merge` warns only. |
| [`yeet-A-grok`](plugins/yeet-A-grok) | Claude → Grok Build bridge | Headless runs, parallel agent fan-out, session resume, one JSON result envelope via `scripts/grok-delegate.sh`. |

```
/plugin install identity-scrub@mort-market
/plugin install yeet-A-grok@mort-market
```

Each plugin ships its own README for install modes, config, and escape hatches.

<p align="center">
  <img src="https://raw.githubusercontent.com/mort-sh/branding/refs/heads/main/Icons/icon_med@0.25x.png" width="24" alt="Icon separator" />
</p>

## Repository atlas

| Path | Purpose |
| ---- | ------- |
| [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json) | Catalog: name, owner, plugin list, sources. |
| [`plugins/<name>/`](plugins/) | One self-contained plugin tree per entry. |
| `plugins/<name>/.claude-plugin/plugin.json` | Plugin manifest (`name`, `version`, metadata). |
| `plugins/<name>/skills/<skill>/SKILL.md` | Skill dispatch surface — `description` is the trigger. |
| `plugins/<name>/commands/` | Optional slash commands. |
| `plugins/<name>/githooks/`, `scripts/` | Payloads the skill or command installs or runs. |

```
mort-market/
├── .claude-plugin/
│   └── marketplace.json          # the catalog
└── plugins/
    ├── identity-scrub/
    │   ├── .claude-plugin/plugin.json
    │   ├── skills/identity-scrub/SKILL.md
    │   ├── githooks/             # pre-push + post-merge payload
    │   └── README.md
    └── yeet-A-grok/
        ├── .claude-plugin/plugin.json
        ├── commands/yeet-A-grok.md
        ├── skills/delegating-to-grok/
        ├── scripts/grok-delegate.sh
        └── README.md
```

**Source resolution:** each catalog entry's `source` is the full path from the repo root (`"./plugins/<name>"`). Do not use `metadata.pluginRoot` — Claude Code resolves `source` against the repo root, and root-relative paths that omit `plugins/` list fine but fail on install.

<p align="center">
  <img src="https://raw.githubusercontent.com/mort-sh/branding/refs/heads/main/Icons/icon_med@0.25x.png" width="24" alt="Icon separator" />
</p>

## System topology

```
┌──────────────────┐     marketplace add      ┌─────────────────────────┐
│  Claude Code     │ ───────────────────────▶ │  mort-market (catalog)  │
│  /plugin         │                          │  marketplace.json       │
└────────┬─────────┘                          └────────────┬────────────┘
         │ install <name>@mort-market                      │ source
         ▼                                                 ▼
┌──────────────────┐     copy to cache         ┌─────────────────────────┐
│  Plugin cache    │ ◀──────────────────────── │  plugins/<name>/        │
│  ${CLAUDE_PLUGIN │                           │  skills • hooks • bins  │
│   _ROOT}         │                           └─────────────────────────┘
└────────┬─────────┘
         │ skill / command
         ▼
┌──────────────────┐     optional bridge       ┌─────────────────────────┐
│  Workflow        │ ───────────────────────▶ │  Partner harness        │
│  (Claude owns)   │   yeet-A-grok, etc.       │  (Grok Build, …)        │
└──────────────────┘                           └─────────────────────────┘
```

<p align="center">
  <img src="https://raw.githubusercontent.com/mort-sh/branding/refs/heads/main/Icons/icon_med@0.25x.png" width="24" alt="Icon separator" />
</p>

## Forge a plugin

1. Scaffold the tree:

   ```zsh
   mkdir -p plugins/<name>/.claude-plugin plugins/<name>/skills/<skill>
   ```

2. Write `plugins/<name>/.claude-plugin/plugin.json` — `name` is required; set `version` too (users only receive updates when it changes).

3. Write `plugins/<name>/skills/<skill>/SKILL.md` with `name` and `description` frontmatter. Write the description as **trigger conditions** ("use when the user wants to…"), not a feature summary — that string is the dispatch mechanism.

4. Add a catalog entry in [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json):

   ```json
   {
     "name": "<name>",
     "source": "./plugins/<name>",
     "version": "0.1.0"
   }
   ```

5. Validate, then ship:

   ```zsh
   claude plugin validate ./plugins/<name> --strict
   ```

`--strict` turns unrecognized-field warnings into errors. Plugins may also ship agents, hooks, MCP servers, and LSP servers — see the [plugins reference](https://code.claude.com/docs/en/plugins-reference).

**Hard rule:** nothing in `plugins/<name>/` may reference paths outside that directory. Bundle dependencies inside the plugin and resolve them with `${CLAUDE_PLUGIN_ROOT}`.

Keep `version` in `plugin.json` and the marketplace entry in sync; bump both on every user-visible change.

<p align="center">
  <img src="https://raw.githubusercontent.com/mort-sh/branding/refs/heads/main/Icons/icon_med@0.25x.png" width="24" alt="Icon separator" />
</p>

## Under the hood

- **Two manifests** – marketplace catalog vs. per-plugin `plugin.json`. Easy to conflate; both matter.
- **Skill descriptions dispatch** – Claude matches task intent against skill `description` frontmatter before loading the body.
- **Versions gate delivery** – omit `version` and every commit looks like a new release; pin it and bump deliberately.
- **Listing ≠ install** – `plugin list --available` can succeed while a bad `source` still fails install. Prove installs with `claude plugin install <name>@mort-market --scope local`, then uninstall.
- **This repo's hooks** – dogfood identity-scrub from a fresh clone:

  ```zsh
  ./plugins/identity-scrub/githooks/install.sh
  ```

  Git never sets `core.hooksPath` alone. After a rewrite abort (exit 2), re-push — use `--force-with-lease` if those commits were already on the remote. Never add `Co-Authored-By` trailers; the hook rewrites identity fields, not messages.

<p align="center">
  <img src="https://raw.githubusercontent.com/mort-sh/branding/refs/heads/main/Icons/icon_med@0.25x.png" width="24" alt="Icon separator" />
</p>

## Signals & sources

| Resource | Link |
| -------- | ---- |
| Claude Code plugin marketplaces | [docs](https://code.claude.com/docs/en/plugin-marketplaces) |
| Plugins reference | [docs](https://code.claude.com/docs/en/plugins-reference) |
| identity-scrub deep dive | [`plugins/identity-scrub/README.md`](plugins/identity-scrub/README.md) |
| yeet-A-grok deep dive | [`plugins/yeet-A-grok/README.md`](plugins/yeet-A-grok/README.md) |
| Contributor guidance (this repo) | [`CLAUDE.md`](CLAUDE.md) |

<p align="center">
  <img src="https://raw.githubusercontent.com/mort-sh/branding/refs/heads/main/Icons/icon_med@0.25x.png" width="24" alt="Icon separator" />
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/mort-sh/branding/refs/heads/main/logos/CLEAR/CLEAR_MORT_1.png" alt="Mort sigil" width="72" />
</p>

<p align="center"><sub>mort-market · curated plugins for agentic harnesses · ember on obsidian</sub></p>
