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

3. Run the generator script. **Prefer the repo's vendored copy** when present, falling back to
   the plugin-cache copy — this is the exact precedence `/agent-sync:init` writes into CI, so the
   skill, the vendored copy, and CI all run the *same* generator and output never disagrees with
   the repo's own `--check`:
   ```bash
   if [ -f "tools/agent-sync/generate.sh" ]; then
     GEN=tools/agent-sync/generate.sh
   elif [ -f ".agent-sync/generate.sh" ]; then
     GEN=.agent-sync/generate.sh
   else
     GEN="${CLAUDE_PLUGIN_ROOT}/scripts/generate.sh"
   fi
   bash "$GEN" --config "<path-to-sources.json>"
   ```
   > **Trust note:** the vendored `tools/agent-sync/generate.sh` is repo-controlled — it is the
   > copy `/agent-sync:init` committed and the same one CI executes, so preferring it is what keeps
   > the skill, the vendored copy, and CI byte-consistent. As with any repo build script, run this
   > only on a branch you trust; on an untrusted branch the vendored copy could be modified.

4. Report results:
   - Which output files were updated
   - Which files were already up to date
   - Any errors encountered

## If `--check` is passed

Run in check mode to verify AGENTS.md is in sync without modifying files (same vendored-first
generator selection as step 3, with `--check` appended):

```bash
if [ -f "tools/agent-sync/generate.sh" ]; then
  GEN=tools/agent-sync/generate.sh
elif [ -f ".agent-sync/generate.sh" ]; then
  GEN=.agent-sync/generate.sh
else
  GEN="${CLAUDE_PLUGIN_ROOT}/scripts/generate.sh"
fi
bash "$GEN" --config "<path-to-sources.json>" --check
```

Report pass/fail status. On failure, suggest running `/agent-sync:generate` to fix.
