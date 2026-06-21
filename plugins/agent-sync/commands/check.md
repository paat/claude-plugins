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

3. Run the check. **Prefer the repo's vendored generator** when present, falling back to the
   plugin-cache copy — the same precedence `/agent-sync:init` writes into CI, so this check
   validates against the identical generator CI uses (no false drift from version skew):
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
   > **Trust note:** the vendored `tools/agent-sync/generate.sh` is repo-controlled — the copy
   > `/agent-sync:init` committed and the one CI runs. Preferring it is what keeps this check
   > byte-consistent with CI. As with any repo build script, run it only on a branch you trust.

4. Run the linter (doc-drift contradictions + rules-file bloat). Use the same vendored-first
   precedence as the generator so the command matches CI:
   ```bash
   if [ -f "tools/agent-sync/lint.sh" ]; then
     LINT=tools/agent-sync/lint.sh
   elif [ -f ".agent-sync/lint.sh" ]; then
     LINT=.agent-sync/lint.sh
   else
     LINT="${CLAUDE_PLUGIN_ROOT}/scripts/lint.sh"
   fi
   bash "$LINT" --config "<path-to-sources.json>"; lint_rc=$?
   ```
   - `lint_rc=0`: no error-severity findings (warnings may still print).
   - `lint_rc=1`: at least one error-severity finding.
   - `lint_rc=2`: a **configuration error** in the `lint` block — surface it as a config problem to
     fix, distinct from drift or content findings.

5. Report results clearly. The overall result is a failure if **either** the drift check or the
   lint returns non-zero. Report drift, lint findings, and lint config errors (`rc=2`) distinctly:
   - **Drift pass, lint pass**: "AGENTS.md is in sync and lint found no issues."
   - **Drift fail**: "AGENTS.md is out of sync. Run `/agent-sync:generate` to update."
   - **Lint error findings** (`lint_rc=1`): "Lint found error-severity issues (see above). Fix them in `sources.json` or the flagged files."
   - **Lint config error** (`lint_rc=2`): "Lint configuration error — check the `lint` block in `sources.json`."
   - If both drift and lint fail, report both problems separately before stating the combined failure.
