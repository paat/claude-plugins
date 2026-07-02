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

3. Resolve and run the generator script using the vendored-first precedence in
   `skills/agent-sync/references/generator-selection.md` (read it for the exact snippet and the
   trust note on running repo-vendored scripts).

4. Report results:
   - Which output files were updated
   - Which files were already up to date
   - Any errors encountered

## If `--check` is passed

Run the same generator selection as step 3, appending `--check` to the final command instead of
writing files. Report pass/fail status. On failure, suggest running `/agent-sync:generate` to fix.
