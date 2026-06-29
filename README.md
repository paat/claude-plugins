# paat-plugins

Claude Code and Codex plugin marketplace for development workflows and productivity.

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

## Updating Codex Metadata

After changing `.claude-plugin/marketplace.json` or a plugin's `.claude-plugin/plugin.json`, regenerate the Codex marketplace:

```bash
python3 scripts/sync-codex-marketplace.py
```

In Codex, invoke the `update-codex-marketplace` skill from this repo for the same workflow.

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
