---
allowed-tools: Bash, Read, Write, Glob, Grep, AskUserQuestion
description: Scaffold sources.json by scanning existing Claude Code configuration
argument-hint: "[directory]"
---

# /agent-sync:init

Initialize agent-sync for this project by scanning existing Claude Code configuration files and creating `sources.json`.

## What to do

### 1. Scan for Claude Code config files

Search the project root for these files:
- `CLAUDE.md`
- `.claude/rules/*.md`
- `.claude/settings.json`
- `.claude/hooks/*.sh`

### 2. Ask the user for project metadata

Use AskUserQuestion to collect:

**project_name**: Ask "What is the project name?" with options derived from the directory name or package.json name.

**stack**: Ask "What is the tech stack?" with options like:
- Auto-detected from package.json, *.csproj, go.mod, etc.
- Let user provide custom answer

**primary_agent**: Ask "Which AI coding tool is the primary agent?" with options:
- "Claude Code" (Recommended)
- "Codex"
- "Cursor"
- "AMP"

### 3. Group files into sections

Map discovered files to logical sections:

| File pattern | Section type | Suggested title |
|---|---|---|
| `.claude/rules/architecture*.md` | `full-body` | Architecture |
| `.claude/rules/code-style*.md` | `full-body` | Code Style |
| `.claude/rules/*.md` (other) | `full-body` | Title from filename |
| `CLAUDE.md` | `extract` | Workflow (headings: auto-detect top-level headings) |
| `.claude/settings.json` | `settings` | Claude Settings and Hooks |

### 4. Detect subdirectory candidates

If any `.claude/rules/*.md` files have prefixes suggesting subdirectories (e.g., `frontend-design.md` → `src/frontend/`), ask the user if they want a separate subdirectory AGENTS.md output.

### 5. Write sources.json

Write to `tools/agent-sync/sources.json` (preferred) or `.agent-sync/sources.json` (ask user).

Create the directory if needed.

### 6. Vendor the generator script

So the CI drift-check (and anyone without the plugin installed) can run `generate.sh`, copy it
into the repo next to `sources.json`, stamped with the plugin version. If in step 5 you wrote
`sources.json` to `.agent-sync/` instead of `tools/agent-sync/`, change `DEST_DIR` to `.agent-sync`
before running:

```bash
VER=$(jq -r .version "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json")
[ "$VER" = "null" ] && VER="unknown"
DEST_DIR=tools/agent-sync
mkdir -p "$DEST_DIR"
for s in generate.sh lint.sh; do
  awk -v v="$VER" 'NR==1{print; print "# Vendored by agent-sync v" v " — re-run /agent-sync:init to refresh."; next} {print}' \
    "${CLAUDE_PLUGIN_ROOT}/scripts/$s" > "$DEST_DIR/$s"
  chmod +x "$DEST_DIR/$s"
done
```

### 7. Offer CI template

Ask: "Do you want a GitHub Actions workflow for agent-sync checks?"

If yes, read `skills/agent-sync/references/github-actions-template.md` for the canonical workflow
YAML (and the rationale for why it lints only, not regenerates `AGENTS.md` on the runner — issues
#33, #92, #93), and write its contents to `.github/workflows/agents-sync.yml`.

### 8. Generate

Ask the user if they want to run `/agent-sync:generate` now.

> Once the plugin is installed, the agent-sync PostToolUse hook regenerates `AGENTS.md` whenever a
> tracked source (`CLAUDE.md`, `.claude/**`, `sources.json`) is edited — so the working tree stays
> in sync without a manual step. The regenerated `AGENTS.md` is also `git add`-ed alongside the
> source change by default; set `AGENT_SYNC_AUTO_STAGE=0` to opt out and manage staging yourself.
