---
allowed-tools: Bash, Read
description: Verify AGENTS.md is in sync with Claude Code configuration files
---

# /agent-sync:check

Verify that AGENTS.md is up to date with the project's Claude Code configuration.

## What to do

1. Locate the project's `sources.json` config file. Search in order:
   - `tools/agent-sync/sources.json`
   - `.agent-sync/sources.json`

2. If no config found, tell the user to run `/agent-sync:init` first.

3. Run the check:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/generate.sh" --config "<path-to-sources.json>" --check
   ```

4. Report results clearly:
   - **Pass**: "AGENTS.md is in sync with your Claude Code configuration."
   - **Fail**: "AGENTS.md is out of sync. Run `/agent-sync:generate` to update."
