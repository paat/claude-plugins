---
name: agent-sync
description: "Use for AGENTS.md generation, agent-sync config, sources.json, and syncing assistant instructions across AI tools."
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

## Staying in sync

`AGENTS.md` is generated, so it is kept correct **at authoring time**, not by re-deriving it later
in an unpinned environment:

- The **PostToolUse hook** regenerates `AGENTS.md` whenever a tracked source (`CLAUDE.md`,
  `.claude/**`, `sources.json`) is edited — in the same environment that made the edit, so the
  working tree never drifts. It also `git add`s the regenerated file by default; set
  `AGENT_SYNC_AUTO_STAGE=0` to opt out.
- **CI** runs `lint.sh` only and does **not** regenerate `AGENTS.md` on the runner — regenerating a
  derived artifact in an environment that isn't pinned to where it was authored causes false drift
  when shell-tool flavors differ (issues #33, #92). A pinned, opt-in backstop is documented in
  `references/github-actions-template.md`.

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
AGENTS.md is out of date with your Claude Code config. Run `/agent-sync:generate` to update. With
the plugin installed the PostToolUse hook normally regenerates it for you on each source edit; you
only see drift if the file was edited without the hook (e.g. on another machine, or with the plugin
uninstalled).

### Subdirectory outputs
Add multiple entries to the `outputs` array, each with its own `path` and `sections`. Use `parent` to add a back-reference link to the root AGENTS.md.
