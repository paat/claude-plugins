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

If yes, write `.github/workflows/agents-sync.yml` using this canonical template (identical to
`skills/agent-sync/references/github-actions-template.md`).

**Do NOT scaffold a runner-side `generate.sh --check` gate.** Regenerating `AGENTS.md` on the
runner re-derives a generated artifact in an environment that is, by construction, not pinned to
wherever the file was authored. Any difference in the runner's `bash`/`awk`/`sed`/locale becomes a
CI false-positive (issues #33, #92, #93). `AGENTS.md` is kept correct at authoring time by the
agent-sync PostToolUse hook (it regenerates the file in the same environment that edited the
source). CI only runs the static linter, which does not re-derive the file:

```yaml
name: agent-sync checks

on:
  pull_request:
    paths:
      - 'CLAUDE.md'
      - '.claude/**'
      - 'tools/agent-sync/sources.json'
      - '.agent-sync/sources.json'
      - 'tools/agent-sync/lint.sh'
      - '.agent-sync/lint.sh'
      - 'AGENTS.md'
      - '**/AGENTS.md'

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install jq
        run: sudo apt-get update -qq && sudo apt-get install -y jq

      - name: Lint agent-sync sources
        run: |
          if [ -f "tools/agent-sync/lint.sh" ]; then
            DIR=tools/agent-sync
          elif [ -f ".agent-sync/lint.sh" ]; then
            DIR=.agent-sync
          else
            echo "agent-sync scripts not found. Run /agent-sync:init to vendor them."
            exit 1
          fi
          bash "$DIR/lint.sh"

      # OPTIONAL drift backstop — DISABLED by default. Only enable this if your team pins the
      # toolchain so generation is deterministic across machines: a fixed runner image plus an
      # explicit `gawk` (and ideally `LC_ALL=C`). Without pinning this step false-positives when
      # the runner's shell tools differ from the author's. Uncomment to enable:
      #
      # - name: Verify AGENTS.md is in sync (pinned toolchain only)
      #   run: |
      #     sudo apt-get update -qq && sudo apt-get install -y gawk
      #     if [ -f "tools/agent-sync/generate.sh" ]; then DIR=tools/agent-sync; else DIR=.agent-sync; fi
      #     LC_ALL=C bash "$DIR/generate.sh" --check
```

### 8. Generate

Ask the user if they want to run `/agent-sync:generate` now.

> Once the plugin is installed, the agent-sync PostToolUse hook regenerates `AGENTS.md` whenever a
> tracked source (`CLAUDE.md`, `.claude/**`, `sources.json`) is edited — so the working tree stays
> in sync without a manual step. The regenerated `AGENTS.md` is also `git add`-ed alongside the
> source change by default; set `AGENT_SYNC_AUTO_STAGE=0` to opt out and manage staging yourself.
