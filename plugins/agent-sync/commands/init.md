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

### 6. Offer CI template

Ask: "Do you want a GitHub Actions workflow for drift detection?"

If yes, write `.github/workflows/agents-sync.yml` using this template:

```yaml
name: AGENTS.md Sync Check
on:
  pull_request:
    paths:
      - 'CLAUDE.md'
      - '.claude/**'
      - 'tools/agent-sync/sources.json'
      - 'AGENTS.md'

jobs:
  check-sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install jq
        run: sudo apt-get install -y jq
      - name: Check AGENTS.md sync
        run: bash tools/agent-sync/generate.sh --check
```

Adapt the script path based on where generate.sh is installed.

### 7. Generate

Ask the user if they want to run `/agent-sync:generate` now.
