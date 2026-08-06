---
name: epic-orchestration
description: "Use when driving a multi-issue GitHub epic through multi-model worker and reviewer legs with adversarial gates, crash-safe handoff files, and tribunal close-out. Entrypoint: /multi-model-orchestrator:epic-orchestrate."
---

# Epic Orchestration

You are the meta-orchestrator for ONE GitHub epic. You coordinate; you never edit source. All
epic work lands on a single epic branch; issues/PRs live on GitHub (other trackers are out of
scope). Workers and reviewers are CLI legs dispatched through this plugin's runner scripts;
route their model and effort with `../route-model-task/SKILL.md` — do not restate its catalog.
Do not load `../multi-model-orchestration/SKILL.md`; its single-run preflight does not apply to
a multi-session epic.

## Preflight and resume

Fresh start: require `gh` authenticated, a GitHub remote, the epic issue, and a clean worktree.
Create the epic branch from the default branch, then write the first handoff immediately
(instantiate `references/handoff-template.md`).

Resume (`--resume`): read the handoff top-down. Execute its "Stop here first" action before
anything else. Treat "Decisions ratified — do not re-litigate" as settled. The handoff State
block is the authoritative baseline; worktree state it does not explain is a stop condition —
inspect and reconcile, never discard. The human may pre-answer open decisions inline below the
handoff path; those answers are ratified decisions.

## Handoff discipline

Update the current handoff after every merge, review verdict, ratified decision, or filed issue —
not at session end. Commit it on the epic branch. Inherit the prior handoff's protocol sections
verbatim and record only deltas. A session that dies mid-decision costs one resume, nothing more.

## Per-issue loop

1. Route the issue with `route-model-task`; emit its route card into the epic ledger.
2. Instantiate `references/worker-prompt.md`, feeding Hard-won constraints from the handoff's
   rules-learned section. Dispatch via the runner the card names:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/run-codex.sh" --mode implement --dir "$REPO_ROOT" \
     --model "$ROUTED_MODEL" --effort "$ROUTED_EFFORT" --timeout 1800 <<'PROMPT'
   <instantiated worker prompt>
   PROMPT
   ```

   (`run-grok.sh` / `run-claude.sh` take `--repo` instead of `--dir`; same contract.)
3. Gate the result yourself: inspect the diff on the issue branch, run the named suites, verify
   the final-message contract was honored.
4. Adversarial review by a DIFFERENT provider than the worker, from
   `references/review-prompts.md`. Codex reviewer legs use `--mode review` (the runner enforces
   the APPROVE/NEEDS_WORK verdict); Claude/Grok legs that must execute probes use
   `--mode implement` with the template's modify-nothing contract, and you grep the verdict.
5. On NEEDS_WORK: one fix cycle by the worker ("address exactly these, nothing else"), then the
   bounded delta re-review by the SAME reviewer. A second NEEDS_WORK is a blocker to report,
   not a loop to continue.
6. Merge the issue branch into the epic branch only on the reviewer's literal line
   `READY TO MERGE — nothing further coming.` — a report is not a merge signal. Absent that
   line, ask the reviewer leg to confirm or state what is still coming.
7. Critical findings are fixed in-run. Non-critical findings and in-scope discoveries are filed
   as issues (queued on the epic or explicitly marked not-blocking). Record the outcome in the
   handoff before dispatching the next issue.

## Reliability rules

- Before dispatching the next worker, confirm the previous worker's transcript/output mtime has
  stopped advancing. A process-list snapshot is not a liveness check.
- Worker exit 124 (timeout) often lands AFTER the work completed: never discard on 124 — check
  `git status`, rerun the suites yourself, and salvage or redispatch on evidence.
- You never edit source while any worker is live. `git checkout` is a write. Never
  `gh pr merge --delete-branch` under a live worker — you will move the tree out from under it.
- Poll long-running legs on a ~30-minute cadence; no tight loops.
- Workers never push. You own push and PR creation for the epic branch.
- When a worker pushes back on your instructions, treat it as signal: verify before overruling.

## Close-out

1. Push the epic branch and open (or update) the epic PR against the default branch.
2. Browser QA and a UX pass against the epic PR's built state; file or fix what they surface.
3. Chain `tribunal-review:closing-tribunal-loop` on the epic PR — it owns its own preflight,
   rounds, and PR comments; your obligations are only: the PR is open, the local head is pushed,
   and you arbitrate as calling context.
4. Merge to the default branch only after that loop exits with zero critical and zero high.
5. Write the final handoff recording the merge evidence, then close the epic issue.
