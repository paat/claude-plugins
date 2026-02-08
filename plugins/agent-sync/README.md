# agent-sync

Generate AGENTS.md from your Claude Code project configuration. Keep your `.claude/rules/`, `CLAUDE.md`, and `.claude/settings.json` as the source of truth — agent-sync assembles them into a single AGENTS.md that other AI coding tools (Codex, Copilot, Cursor, AMP) can read.

## Prerequisites

- `bash` 4+
- `jq`
- `awk`, `sed` (standard on Linux/macOS)

## Quick Start

```
/agent-sync:init        # Scan project, create sources.json
/agent-sync:generate    # Build AGENTS.md
/agent-sync:check       # Verify AGENTS.md is in sync
```

## How It Works

1. Your Claude Code config lives in `CLAUDE.md`, `.claude/rules/*.md`, `.claude/settings.json`, and `.claude/hooks/*.sh`
2. `sources.json` maps these files to sections in AGENTS.md
3. The generator reads each source, processes it (strip frontmatter, extract headings, shift heading levels), and assembles the output
4. Template variables (`{{project_name}}`, `{{stack}}`, `{{primary_agent}}`) customize the header

## Configuration

Config file: `tools/agent-sync/sources.json` or `.agent-sync/sources.json`

```jsonc
{
  "version": 2,
  "variables": {
    "project_name": "My Project",
    "stack": "Node.js + React",
    "primary_agent": "Claude Code"
  },
  "files": {
    "architecture": ".claude/rules/architecture.md",
    "codeStyle": ".claude/rules/code-style.md",
    "settings": ".claude/settings.json"
  },
  "outputs": [
    {
      "path": "AGENTS.md",
      "sections": [
        { "id": "arch", "title": "Architecture", "source": "architecture", "type": "full-body" },
        { "id": "style", "title": "Code Style", "source": "codeStyle", "type": "full-body" },
        { "id": "settings", "title": "Settings", "source": "settings", "type": "settings" }
      ]
    }
  ]
}
```

### Section Types

| Type | Description |
|---|---|
| `full-body` | Include entire file (frontmatter stripped, title removed, headings shifted +1) |
| `extract` | Pull specific heading sections. Requires `headings` array. |
| `settings` | Render `.claude/settings.json` as markdown tables (plugins, hooks, scripts) |

### Subdirectory Outputs

Generate scoped AGENTS.md files for subdirectories:

```jsonc
{
  "outputs": [
    { "path": "AGENTS.md", "sections": [...] },
    {
      "path": "src/frontend/AGENTS.md",
      "parent": "../../AGENTS.md",
      "sections": [
        { "id": "fe", "title": "Frontend", "source": "frontendDesign", "type": "full-body" }
      ]
    }
  ]
}
```

## CI Integration

Add drift detection to your CI pipeline. See `/agent-sync:init` to generate the workflow, or see `skills/agent-sync/references/github-actions-template.md`.

## Migration from Node.js Version

If you have an existing `tools/agent-sync/generate-agents.mjs`:

1. Your `sources.json` with `version: 1` works as-is (auto-converted to v2 format)
2. Add `variables` to `sources.json` if you want project name/stack in the header
3. Add a `settings` section if you want the settings summary rendered
4. Replace `node tools/agent-sync/generate-agents.mjs` with `/agent-sync:generate`

## Components

| Component | Type | Purpose |
|---|---|---|
| `/agent-sync:generate` | Command | Generate/update AGENTS.md |
| `/agent-sync:check` | Command | Verify AGENTS.md is in sync |
| `/agent-sync:init` | Command | Scaffold sources.json |
| `agent-sync` | Skill | Usage reference and troubleshooting |
| `sync-watcher` | Agent | Proactively checks sync when configs change |
| PostToolUse hook | Hook | Warns when tracked source file is edited |
