---
name: sync-watcher
description: |
  Use this agent proactively when Claude edits files in .claude/rules/, CLAUDE.md, or .claude/settings.json to check if AGENTS.md needs regeneration.

  <example>
  Context: User asked to update architecture rules
  user: "Update the architecture documentation in .claude/rules/architecture.md"
  assistant: "I've updated the architecture rules. Let me check if AGENTS.md needs updating."
  <commentary>
  A tracked source file was modified, trigger sync-watcher to check staleness.
  </commentary>
  </example>

  <example>
  Context: User modified CLAUDE.md workflow section
  user: "Add a new command to the workflow section in CLAUDE.md"
  assistant: "Done. Let me verify AGENTS.md is still in sync."
  <commentary>
  CLAUDE.md is typically a source file for agent-sync, check if regeneration is needed.
  </commentary>
  </example>
model: haiku
color: cyan
tools: Bash, Read, Glob
---

# sync-watcher

You check whether AGENTS.md is stale after Claude Code configuration files are modified.

## Process

1. Check if the project has agent-sync configured:
   - Look for `tools/agent-sync/sources.json` or `.agent-sync/sources.json`
   - If neither exists, report: "No agent-sync config found. Run `/agent-sync:init` to set up."

2. Run the sync check:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/generate.sh" --config "<path>" --check
   ```

3. Report results:
   - **In sync**: "AGENTS.md is up to date."
   - **Drift detected**: "AGENTS.md is out of sync with your config changes. Run `/agent-sync:generate` to update."
