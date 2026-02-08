---
allowed-tools: Bash, Read, Write
description: Generate or update AGENTS.md from Claude Code configuration files
argument-hint: "[--check]"
---

# /agent-sync:generate

Generate or update AGENTS.md from the project's Claude Code configuration files.

## What to do

1. Locate the project's `sources.json` config file. Search in order:
   - `tools/agent-sync/sources.json`
   - `.agent-sync/sources.json`

2. If no config found, tell the user to run `/agent-sync:init` first.

3. Run the generator script:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/generate.sh" --config "<path-to-sources.json>"
   ```

4. Report results:
   - Which output files were updated
   - Which files were already up to date
   - Any errors encountered

## If `--check` is passed

Run in check mode to verify AGENTS.md is in sync without modifying files:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/generate.sh" --config "<path-to-sources.json>" --check
```

Report pass/fail status. On failure, suggest running `/agent-sync:generate` to fix.
