# paat-plugins

Claude Code and Codex plugin marketplace for autonomous SaaS delivery loops.

This repository is organized around one mission: help AI systems discover real market
needs, convert those signals into production-quality SaaS improvements, and deliver
one-shot implementations with minimal human intervention. The plugins are generic and
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

## Development Checks

Install the Python check dependency, then run the repository checks:

```bash
python3 -m pip install -r requirements-dev.txt
python3 scripts/check-plugin-catalog.py
python3 scripts/check-plugin-content.py
python3 scripts/test_check_plugin_content.py
python3 scripts/sync-codex-marketplace.py --check
```

## Updating Codex Metadata

After changing `.claude-plugin/marketplace.json` or a plugin's `.claude-plugin/plugin.json`, regenerate the Codex marketplace:

```bash
python3 scripts/sync-codex-marketplace.py
```

In Codex, invoke the `update-codex-marketplace` skill from this repo for the same workflow.

Codex-specific behavior differences are tracked in `docs/codex-plugin-behavior.md`.

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
