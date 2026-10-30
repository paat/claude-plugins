# paat-plugins

Claude Code and Codex plugin marketplace for autonomous SaaS delivery loops.

This repository is organized around one north star (stated in `CLAUDE.md`): help AI
systems discover real market needs, convert those signals into production-quality SaaS
improvements, and deliver one-shot implementations with no human code review. Customer
feedback and owner validation of the live product are the only human signals, and every
decision rests on current, source-cited knowledge at low token cost. The plugins are generic and
project-agnostic, but the default audience is Estonian SaaS companies, e-residents,
small businesses, and micro-OÜs.

## Mission Model

Plugins in this marketplace usually serve one part of the loop:

- **Demand signals** — customer meetings, support email, Reddit/community research,
  live-product monitoring, abandoned funnels, and paid-search performance.
- **Conversion to work** — structured handoffs, GitHub/Plane issues, growth briefs,
  workflow specs, and maintainable research artifacts.
- **Production delivery** — one-shot implementation, browser QA, regression tests,
  tribunal review, CI/deploy monitoring, and autonomous maintenance.
- **Current knowledge** — dated, source-cited skills and data refreshed out of band (for
  example model-routing evidence), so each step of the loop acts on current facts.

Utilities that do not discover demand directly still belong here when they make that
loop safer, cheaper, or more reliable.

## Claude Code Usage

Add this marketplace to Claude Code:

```
/plugin marketplace add paat/claude-plugins
```

Install a plugin:

```
/plugin install <plugin-name>@paat-plugins
```

## Codex Usage

Add this repo as a Codex marketplace:

```bash
codex plugin marketplace add paat/claude-plugins
```

For a local checkout, run this from the repo root:

```bash
codex plugin marketplace add .
```

List available Codex plugins:

```bash
codex plugin list --marketplace paat-plugins
```

Install a plugin:

```bash
codex plugin add <plugin-name>@paat-plugins
```

When refreshing an already installed plugin, preserve paths held by active Codex
sessions with the repository wrapper:

```bash
scripts/refresh-codex-plugin.sh <plugin-name>@paat-plugins
```

The wrapper retains retired cache versions for seven days so active sessions can
continue reading their original skill locators. Retention is capped at eight old
versions; rapid refreshes can evict a younger version, and the wrapper warns when
that happens. Start a new Codex thread to use the newly installed version. Direct
`codex plugin add` replaces the old cache immediately. A read attempted while the
Codex install command itself is replacing the cache can still fail transiently;
retry it after the wrapper returns.

If an old locator is already missing, resolve only to the same plugin's current
Codex version and surface the version change:

```bash
scripts/resolve-codex-plugin-resource.sh <stale-codex-cache-path>
```

Never substitute a Claude plugin-cache path. Both helpers require Bash 4+ and
standard POSIX utilities; refresh also requires util-linux `flock`.

## Development Checks

Install the Python check dependency, then run the repository checks:

```bash
python3 -m pip install -r requirements-dev.txt
python3 scripts/check-plugin-catalog.py
python3 scripts/check-plugin-content.py
python3 scripts/test_check_plugin_content.py
python3 scripts/test_refresh_codex_plugin.py
python3 scripts/sync-codex-marketplace.py --check
```

## Updating Codex Metadata

After changing `.claude-plugin/marketplace.json` or a plugin's `.claude-plugin/plugin.json`, regenerate the Codex marketplace:

```bash
python3 scripts/sync-codex-marketplace.py
```

In Codex, invoke the `update-codex-marketplace` skill from this repo for the same workflow.

Codex-specific behavior differences are tracked in `docs/codex-plugin-behavior.md`.

## Model ID Refresh

`scripts/refresh-model-versions.sh` snapshots the model catalogs of the installed
`codex`, `grok`, and `agy` CLIs. A new pool-vendor model, newly unmappable public
name, or rank change with non-overlapping old/new CIs on a non-preliminary row
wakes a headless `claude -p` session in a throwaway worktree. It proposes
superseded pins and evidence-backed tier-order/retirement edits and opens a
`chore/model-refresh-*` PR. It never merges, and it skips runs while such a PR is
open. Other days exit before any model call. Create `~/.local/state/model-refresh/`
once, then run it daily from cron:

```
15 5 * * * bash /mnt/data/ai/claude-plugins/scripts/refresh-model-versions.sh >> "$HOME/.local/state/model-refresh/cron.log" 2>&1
```

OpenRouter, Arena WebDev/Agent (CC-BY-4.0), and Terminal-Bench 4.0 feed one dated
`evals.tsv`, joined to catalog IDs through `scripts/model-eval-aliases.tsv` (blank
IDs remain unmapped). Public data only shortlists; tier defaults change only on
local `outcomes.tsv` evidence (#676). Terminal-Bench's endpoint is undocumented
and its data licence is **UNKNOWN**. Failed/incomplete feeds preserve the whole
last good table while catalog detection continues. Pending trigger rows survive
an open PR or failed pass; repeated unchanged feeds add none. Run
`XDG_STATE_HOME=$(mktemp -d) bash scripts/refresh-model-versions.sh --feeds-only`
for an isolated live fetch/build with trigger counts and no model calls.

State, the handled catalog, and the last run log live in `~/.local/state/model-refresh/`.
It needs `curl`, `jq`, coreutils, `awk`, `sed`, `grep`, `claude`, `gh`, util-linux `flock`, and all four provider CLIs; it
fails closed when any catalog comes back empty.

The opt-in DeepSeek leg (`tribunal-review`, default `deepseek-v4-pro`) is excluded from this refresh; its pin is bumped by hand.

## Plugin Structure

Each plugin lives under `plugins/` with this structure:

```
plugins/<plugin-name>/
├── .claude-plugin/
│   └── plugin.json       # name, description, version, author, license
├── .codex-plugin/
│   └── plugin.json       # generated Codex plugin manifest
├── skills/               # SKILL.md files (optional)
├── commands/             # Command .md files (optional)
├── hooks/                # Hook definitions (optional)
└── agents/               # Agent definitions (optional)
```

## Adding a Plugin

1. Create the plugin directory under `plugins/`
2. Add a `.claude-plugin/plugin.json` with plugin metadata
3. Add skill, command, hook, or agent files as needed
4. Add an entry to `.claude-plugin/marketplace.json` in the `plugins` array
5. Run `python3 scripts/sync-codex-marketplace.py` to update Codex manifests and `.agents/plugins/marketplace.json`

Before pushing plugin changes, bump that plugin's version in both
`plugins/<plugin-name>/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`.
Enable the guard locally with:

```bash
git config core.hooksPath .githooks
```
