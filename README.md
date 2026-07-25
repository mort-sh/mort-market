# mort-market

A [Claude Code plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces).

## Use it

```
/plugin marketplace add mort-sh/mort-market
```

Then browse and install:

```
/plugin
/plugin install identity-scrub@mort-market
/reload-plugins
```

`owner/repo` shorthand clones over SSH by default. The full URL works too, and
so does a local path if you have the repo checked out:

```
/plugin marketplace add https://github.com/mort-sh/mort-market.git
/plugin marketplace add ./mort-market
```

Pull in later updates with `/plugin marketplace update mort-market`.

## Plugins

| Plugin | What it does |
|---|---|
| [`identity-scrub`](plugins/identity-scrub) | Git hooks that guarantee every commit in a repo's history carries an approved author and committer identity, rewriting the ones that don't. |

## Layout

```
.claude-plugin/
└── marketplace.json          the catalog — name, owner, plugin list
plugins/
└── identity-scrub/
    ├── .claude-plugin/
    │   └── plugin.json       the plugin manifest
    ├── skills/
    │   └── identity-scrub/
    │       └── SKILL.md      what Claude invokes
    ├── githooks/             payload the skill installs into a target repo
    └── README.md
```

`metadata.pluginRoot` in `marketplace.json` is set to `./plugins`, so each
entry's `source` is written relative to that (`"./identity-scrub"`).

## Add a plugin

1. `mkdir -p plugins/<name>/.claude-plugin plugins/<name>/skills/<skill>`
2. Write `plugins/<name>/.claude-plugin/plugin.json` — `name` is the only
   required field, but set `version` too: users only get updates when it
   changes, and omitting it makes every commit a new version.
3. Write `plugins/<name>/skills/<skill>/SKILL.md` with `name` and `description`
   frontmatter. The description is what decides whether Claude reaches for it,
   so write it as trigger conditions, not a summary.
4. Add an entry to `.claude-plugin/marketplace.json` with `"source": "./<name>"`.
5. Validate and push:

   ```bash
   claude plugin validate ./plugins/<name> --strict
   ```

Plugins are copied to a cache on install, so nothing may reference paths
outside its own directory — bundle what it needs and reach it through
`${CLAUDE_PLUGIN_ROOT}`.

Plugins can also ship agents, hooks, MCP servers, and LSP servers; see the
[plugins reference](https://code.claude.com/docs/en/plugins-reference).

## This repo's own hooks

`mort-market` dogfoods `identity-scrub`. Enable it in a fresh clone with:

```bash
./plugins/identity-scrub/githooks/install.sh
```

Git never enables hooks by itself, so this is a per-clone step.
