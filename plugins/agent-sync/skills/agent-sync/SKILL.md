---
name: agent-sync
description: "Use when the user asks about AGENTS.md generation, agent-sync configuration, sources.json format, syncing Claude Code config to other AI tools, or troubleshooting agent-sync issues. Triggers: 'agents.md', 'agent sync', 'sync agents', 'sources.json', 'generate agents', 'agents file', 'codex config', 'copilot config', 'cursor rules', 'amp config'"
---

# agent-sync

agent-sync generates AGENTS.md from Claude Code project configuration files (CLAUDE.md, .claude/rules/, settings.json, hooks). This makes your Claude Code setup available to other AI coding tools (Codex, Copilot, Cursor, AMP) that read AGENTS.md.

## Quick Start

1. **Initialize**: `/agent-sync:init` — scans your project, creates `sources.json`
2. **Generate**: `/agent-sync:generate` — builds AGENTS.md from your config
3. **Check**: `/agent-sync:check` — verifies AGENTS.md is in sync

## How It Works

The generator reads `sources.json` which maps Claude Code config files to sections in AGENTS.md:

- **full-body** sections include the entire file (frontmatter stripped, headings shifted +1)
- **extract** sections pull specific heading sections from a file
- **settings** sections render `.claude/settings.json` as readable markdown tables

Template variables (`{{project_name}}`, `{{stack}}`, `{{primary_agent}}`) are substituted in the generated header.

## Configuration

Config lives at `tools/agent-sync/sources.json` or `.agent-sync/sources.json`. See `references/sources-json-format.md` for the full schema.

## Commands

| Command | Purpose |
|---|---|
| `/agent-sync:generate` | Generate/update AGENTS.md |
| `/agent-sync:check` | Verify sync status |
| `/agent-sync:init` | Create sources.json from existing config |

## Troubleshooting

### "Heading not found" error
The extract section references a heading that doesn't exist in the source file. Check spelling and case — matching is case-insensitive but the heading text must match.

### "Missing source file" error
A file listed in `sources.json` `files` doesn't exist. Update the path or remove the entry.

### Drift detected
AGENTS.md is out of date with your Claude Code config. Run `/agent-sync:generate` to update.

### Subdirectory outputs
Add multiple entries to the `outputs` array, each with its own `path` and `sections`. Use `parent` to add a back-reference link to the root AGENTS.md.
