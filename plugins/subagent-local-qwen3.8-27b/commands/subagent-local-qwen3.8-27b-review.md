---
allowed-tools: Bash, Read, Grep
description: Independent read-only review via local llama.cpp Qwen3.8-27B (Qwen Code CLI, approval-mode plan)
argument-hint: "[<target>] [--model <id>] [--dir <repo>]"
---

Get an independent **read-only review** from local **Qwen3.8-27B** via the Qwen Code CLI (`--approval-mode plan`). The worker may open files to verify findings but must not modify, stage, or commit. Then synthesize with your own review.

**Target:** $ARGUMENTS

## Steps

1. **Decide the review target.** If `$ARGUMENTS` names a file or plan, review that. If it is empty or says "diff"/"changes", review the working diff (`git diff` / `git diff origin/main...HEAD`). Optional `--model <id>` overrides the served coding alias; `--dir <repo>` sets the repo (default: repo root).

2. **Do your own review first** so you can compare, not just relay. Apply the same target, evidence, causation, and adjacency limits as the dispatched review below.

3. **Dispatch the local reviewer (read-only).** Point it at the artifact by path (it opens files itself — don't paste large diffs). Use a generous Bash-tool timeout (≥ 600000 ms):

   For a diff / commit / branch target, pass `--diff <base>` — `--diff HEAD~1` for a
   commit, `--diff 'origin/main...HEAD'` for a branch (three-dot: merge-base, so
   commits that landed on main meanwhile are not counted as changes). The wrapper writes that diff into the repo and points the
   worker at it: **approval-mode plan has no shell**, so the worker cannot run git
   itself and will otherwise review only the files as they now stand and miss
   regressions.

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/subagent-local-qwen3.8-27b-run.sh" --dir <repo> [--model <id>] [--diff <base>] --approval-mode plan --timeout 600 <<'PROMPT'
   You are a senior reviewer. Review <target: the working diff / plan file <path> / file <path>>.
   You are inside the project repo and MAY open any other file to trace call sites,
   verify framework/library semantics, and check cross-file effects. This is
   READ-ONLY review — do NOT modify, stage, or commit anything.

   Judge each changed line in the diff against the line it replaced; do not review
   only the files as they now stand, and do not dismiss a changed line as pre-existing.

   Report only REAL, actionable findings (skip style/naming). For each: file:line,
   severity, what is wrong, and a concrete fix. Pay special attention to:
   - behavior changed by the diff itself: off-by-one, inverted condition, dropped
     commit/flush, widened scope,
   - line-anchor / plan-vs-source drift,
   - dispatch / function signature mismatches (arity, return type),
   - duplicated logic recomputing a value with a different (wrong) formula,
   - renderers or callers referencing renamed/old field names,
   - silent failures, unawaited async, and money-as-float in payment paths.
   Open only files needed to verify a candidate finding; do not audit the tree.
   Report a finding only when it is caused or exposed by the target and supported
   by a reproduced runtime path, failing build/test, or directly verifiable contract
   or plan-source mismatch. Omit speculative, low-probability, stylistic, and adjacent
   concerns; for diff or plan reviews, also omit unrelated pre-existing issues. Stop
   after checking the target and its directly affected paths.
   End with a one-line verdict: APPROVE / NEEDS_WORK / BLOCK.
   PROMPT
   ```

   The wrapper appends `references/review-contract.md` via `--append-system-prompt` and keeps the Qwen Code built-in system prompt.

4. **Synthesize** into a unified report:

   ## Code Review: [target]
   ### Local Qwen3.8-27B Findings
   [key findings, with file:line]
   ### My Findings
   [your own independent findings]
   ### Where We Agree
   [shared findings — higher confidence]
   ### Where We Differ
   [disagreements, with your reasoning and recommendation]
   ### Recommendations
   [prioritized, combined]

5. If the local worker is unavailable (CLI missing, llama.cpp down/busy/wrong-model, persistent timeout), proceed with your own review and note that the local Qwen worker was unavailable.

## Notes

- Read-only is enforced by `--approval-mode plan` plus the review contract — not by a process sandbox.
- Bound model is **Qwen3.8-27B**. For high-stakes security review prefer Codex/Grok.
