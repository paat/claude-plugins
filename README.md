# paat-plugins

Claude Code plugin marketplace for development workflows and productivity.

## Usage

Add this marketplace to Claude Code:

```
/plugin marketplace add paat/claude-plugins
```

Install a plugin:

```
/plugin install <plugin-name>@paat-plugins
```

## Plugin Structure

Each plugin lives under `plugins/` with this structure:

```
plugins/<plugin-name>/
├── .claude-plugin/
│   └── plugin.json       # name, description, version, author, license
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
