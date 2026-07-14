---
allowed-tools: Bash, Read, Grep
description: Independent second-model (Codex/GPT-5.6 Sol) review of a diff, plan, or file — repo-walking, read-only
argument-hint: "[<target>] [--model <id>] [--effort <level>] [--dir <repo>]"
---

Get an independent **second-model review** from the OpenAI Codex CLI (`codex exec`, GPT-5.6 Sol at `high` reasoning effort by default). Codex reads the real source tree itself to verify cross-file effects — this catches integration defects a same-model pass rationalizes past (line-anchor drift, dispatch-signature mismatches, wrong recomputed formulas, renderers hardcoding old field names). Then synthesize with your own review.

**Target:** $ARGUMENTS

## Steps

1. **Decide the review target.** If `$ARGUMENTS` names a file or plan, review that. If it is empty or says "diff"/"changes", review the working diff (`git diff` / `git diff origin/main...HEAD`). Optional `--model <id>` and `--effort <level>` override the pinned defaults; `--dir <repo>` sets the repo (default: repo root).

2. **Do your own review first** so you can compare, not just relay. Read the target and note the issues you find.

3. **Dispatch Codex (read-only, repo-walking).** It needs FS access to walk the tree, so keep the default `-s danger-full-access` but instruct it NOT to modify anything. Point it at the artifact by path (it opens files itself — don't paste large diffs). Use a generous Bash-tool timeout (≥ 600000 ms):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh" --dir <repo> [--model <id>] [--effort <level>] --timeout 600 <<'PROMPT'
   You are a senior reviewer. Review <target: the working diff / plan file <path> / file <path>>.
   You are inside the project repo and MAY open any other file to trace call sites,
   verify framework/library semantics, and check cross-file effects. This is
   READ-ONLY review — do NOT modify, stage, or commit anything.

   Report only REAL, actionable findings (skip style/naming). For each: file:line,
   severity, what is wrong, and a concrete fix. Pay special attention to:
   - line-anchor / plan-vs-source drift,
   - dispatch / function signature mismatches (arity, return type),
   - duplicated logic recomputing a value with a different (wrong) formula,
   - renderers or callers referencing renamed/old field names,
   - silent failures, unawaited async, and money-as-float in payment paths.
   End with a one-line verdict: APPROVE / NEEDS_WORK / BLOCK.
   PROMPT
   ```

   If the wrapper prints the bwrap remedy, it means Codex couldn't read the tree — confirm `--sandbox danger-full-access` (the default) and retry.

4. **Synthesize** into a unified report:

   ## Code Review: [target]
   ### Codex's Findings
   [Codex's key findings, with file:line]
   ### My Findings
   [your own independent findings]
   ### Where We Agree
   [shared findings — higher confidence]
   ### Where We Differ
   [disagreements, with your reasoning and recommendation]
   ### Recommendations
   [prioritized, combined]

5. If Codex is unavailable (not installed, persistent timeout), proceed with your own review and note that Codex was unavailable.

## Notes

- This is the high-value pre-flight: pointing Codex at a **written plan + the real source** before implementing surfaces integration defects cheaply. Run it before `/codex-implement`.
- For pasted-context, no-FS reasoning (e.g. critiquing a methodology or a snippet with no repo), use `/codex-critique` instead.
