# agent-sync

Generate AGENTS.md from your Claude Code project configuration. Keep your `.claude/rules/`, `CLAUDE.md`, and `.claude/settings.json` as the source of truth — agent-sync assembles them into a single AGENTS.md that other AI coding tools (Codex, Copilot, Cursor, AMP) can read.

## Installation

Add this marketplace, then install the plugin at the scope you want:

- **Install for you** (user scope) — available in all your projects:
  `/plugin install agent-sync@paat-plugins`
- **Install for all collaborators on this repository** (project scope) — committed to the repo and
  shared with your team via `.claude/settings.json`.
- **Install for you, in this repo only** (local scope) — just you, just this repository, via
  `.claude/settings.local.json`.

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

## Linting

`/agent-sync:check` also runs `lint.sh` against your `sources.json` config after the drift check.
Three checks are available (all optional, configured in the `lint` block of `sources.json`):

- **Contradictions** — flags exclusive technology pairs co-occurring in the same doc (e.g. `Supabase` + `Postgres`).
- **Line budget** — warns when a rules file exceeds a raw-line-count threshold.
- **Soft preferences** — flags line-leading `prefer`/`prefers`/`prefer to`/`preferred` directives that should be rewritten as hard rules.

If no `lint` block is present, `lint.sh` exits 0 silently (fully backward compatible). See
`skills/agent-sync/references/sources-json-format.md` for the full `lint` block reference.

## Staying in sync

`AGENTS.md` is generated, so agent-sync keeps it correct **at authoring time** rather than
re-deriving it later in an unpinned environment:

- **PostToolUse hook** — whenever you edit a tracked source (`CLAUDE.md`, `.claude/**`,
  `sources.json`), the hook regenerates `AGENTS.md` in the same environment that made the change,
  so the working tree never drifts. Set `AGENT_SYNC_AUTO_STAGE=1` to also `git add` the regenerated
  file alongside your source change (off by default — staging stays under your control).
- **CI** — `/agent-sync:init` scaffolds `.github/workflows/agents-sync.yml` that runs `lint.sh`
  only. It deliberately does **not** regenerate `AGENTS.md` on the runner: re-deriving a generated
  artifact in an environment that isn't pinned to where it was authored produces false drift when
  the runner's `bash`/`awk`/`sed` differ (issues #33, #92). An optional, commented drift backstop
  is included for teams that pin their toolchain. See
  `skills/agent-sync/references/github-actions-template.md`.

## Migration from Node.js Version

If you have an existing `tools/agent-sync/generate-agents.mjs`:

1. Your `sources.json` with `version: 1` works as-is (auto-converted to v2 format)
2. Add `variables` to `sources.json` if you want project name/stack in the header
3. Add a `settings` section if you want the settings summary rendered
4. Replace `node tools/agent-sync/generate-agents.mjs` with `/agent-sync:generate` (and run
   `/agent-sync:init` once to vendor the bash `generate.sh` for CI)

## Components

| Component | Type | Purpose |
|---|---|---|
| `/agent-sync:generate` | Command | Generate/update AGENTS.md |
| `/agent-sync:check` | Command | Verify AGENTS.md is in sync |
| `/agent-sync:init` | Command | Scaffold sources.json |
| `agent-sync` | Skill | Usage reference and troubleshooting |
| `sync-watcher` | Agent | Proactively checks sync when configs change |
| PostToolUse hook | Hook | Regenerates AGENTS.md when a tracked source file is edited (opt-in auto-stage) |
| `lint.sh` | Script | Lint config for stack contradictions, rules-file bloat, and soft directives |
