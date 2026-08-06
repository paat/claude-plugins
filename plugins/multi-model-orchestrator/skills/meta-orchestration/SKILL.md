---
name: meta-orchestration
description: "Use when running the show over a queue of work — an epic, an issue list, a discovery goal, or a workitem scan — through multi-model worker and reviewer legs with adversarial gates, crash-safe handoffs, and tribunal close-out. Entrypoint: /multi-model-orchestrator:meta-orchestrate."
---

# Meta Orchestration

You are the meta-orchestrator. The brief describes WHAT to achieve — outcomes, priorities,
autonomy bounds, stop conditions — and is authoritative on all of it. HOW is yours: task
decomposition, sequencing, model routing, dispatch, gating, and recovery follow the rules
below, and the human never has to specify mechanics. You coordinate; you never edit source. Route every worker and reviewer leg with
`../route-model-task/SKILL.md` — do not restate its catalog. Do not load
`../multi-model-orchestration/SKILL.md`; its single-run preflight does not apply to
multi-session work.

## Interpreting the brief

Infer the shape from the brief's wording — these are recognition patterns, not syntax the human
must use. All feed the same per-item loop:

- **Epic** — the brief names one epic issue: single epic branch, delivery strategy A.
- **Issue list** — the brief names or queries issues: one cheap triage pass ordering by
  dependency, risk, and value; then delivery strategy B per item.
- **Discovery** — the brief states a goal without tasks: research legs propose the task list;
  file accepted tasks as tracker items so state never lives only in context; continue per the
  brief's autonomy bounds.
- **Scan** — the brief asks to check for new workitems: read the sources; when nothing is new,
  write nothing and stop. A no-op scan must cost near zero. Recurrence belongs to the caller
  (`/loop`, cron), not to this skill.

## Local configuration

Optional YAML frontmatter in `.claude/multi-model-orchestrator.local.md` at the target repo
root. Work sources: GitHub (`gh`) is built in; other trackers are configured, never hardcoded.
Model constraints bind every leg you dispatch (worker, reviewer, advise) as hard
`route-model-task` restrictions — the brief may tighten them, never widen them. They do NOT
apply to the tribunal panel, which owns its own provider configuration.

```yaml
sources:
  - name: plane
    list: "<shell command printing open workitem ids and titles>"
    show: "<shell command printing one workitem body; id appended>"   # optional
    close: "<shell command closing or commenting a workitem; id appended>"  # optional
models:
  allow: [gpt-5.6-terra, grok-4.5, claude-sonnet-5]  # optional leg allowlist
  deny: [claude-fable-5]                             # optional leg denylist
  worker: "gpt-5.6-terra high"                       # optional per-role pins
  reviewer: "grok-4.5 high"
  advise: "claude-opus-5 high"
```

Treat sourced items exactly like issues. Code always delivers through git branches and GitHub
PRs; after merge, close or annotate the source workitem via its `close` command.

## Delivery strategies

- **A (epic):** per-item branches merge into the epic branch on the merge signal. Close-out:
  browser QA + UX pass on the epic PR, then `tribunal-review:closing-tribunal-loop`; merge to
  the default branch at zero critical/high; write the final handoff; close the epic.
- **B (per-item):** branch per item → push → PR → `tribunal-review:closing-tribunal-loop` on
  that PR → merge at zero critical/high → close/annotate the source item.

Merges to the default branch require the tribunal exit unless the brief explicitly waives it.
Your obligations to the tribunal skill are only: the PR is open, the local head is pushed, and
you arbitrate as calling context — never restate its protocol.

## Preflight and resume

Fresh start: require `gh` authenticated, a GitHub remote, and a clean worktree; verify any
referenced issues/workitems exist. Write the first handoff (instantiate
`references/handoff-template.md`) as soon as real work starts — never for a no-op scan.

Resume (`--resume`): read the handoff top-down. Execute its "Stop here first" action before
anything else. Treat "Decisions ratified — do not re-litigate" as settled. The handoff State
block is the authoritative baseline; worktree state it does not explain is a stop condition —
inspect and reconcile, never discard. Trailing text after the flag is pre-answered decisions
and brief deltas; both are ratified.

## Handoff discipline

Update the current handoff after every merge, review verdict, ratified decision, or filed item —
not at session end. Commit it on the working branch. Inherit the prior handoff's protocol
sections verbatim and record only deltas. A session that dies mid-decision costs one resume,
nothing more.

## Per-item loop

1. Route the item with `route-model-task` under the model constraints; emit its route card into
   the ledger.
2. When the item is ambiguous or high-coupling, buy grounding first: one advise leg
   (`run-claude.sh --mode advise`); its output becomes grounding for the worker prompt.
   Skip this for well-specified items.
3. Instantiate `references/worker-prompt.md`, feeding Hard-won constraints from the handoff's
   rules-learned section. Dispatch via the runner the card names:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/run-codex.sh" --mode implement --dir "$REPO_ROOT" \
     --model "$ROUTED_MODEL" --effort "$ROUTED_EFFORT" --timeout 1800 <<'PROMPT'
   <instantiated worker prompt>
   PROMPT
   ```

   (`run-grok.sh` / `run-claude.sh` take `--repo` instead of `--dir`; same contract.)
4. Gate the result yourself: inspect the diff on the item branch, run the named suites, verify
   the final-message contract was honored.
5. Adversarial review by a DIFFERENT provider than the worker, from
   `references/review-prompts.md`. Codex reviewer legs use `--mode review` (the runner enforces
   the APPROVE/NEEDS_WORK verdict); Claude/Grok legs that must execute probes use
   `--mode implement` with the template's modify-nothing contract, and you grep the verdict.
6. On NEEDS_WORK: one fix cycle by the worker ("address exactly these, nothing else"), then the
   bounded delta re-review by the SAME reviewer. A second NEEDS_WORK is a blocker to report,
   not a loop to continue.
7. Merge or open the PR only on the reviewer's literal line
   `READY TO MERGE — nothing further coming.` — a report is not a merge signal. Absent that
   line, ask the reviewer leg to confirm or state what is still coming.
8. Critical findings are fixed in-run. Non-critical findings and in-scope discoveries are filed
   as tracker items (queued or explicitly marked not-blocking). Record the outcome in the
   handoff before dispatching the next item.

## Reliability rules

- Before dispatching the next worker, confirm the previous worker's transcript/output mtime has
  stopped advancing. A process-list snapshot is not a liveness check.
- Worker exit 124 (timeout) often lands AFTER the work completed: never discard on 124 — check
  `git status`, rerun the suites yourself, and salvage or redispatch on evidence.
- You never edit source while any worker is live. `git checkout` is a write. Never
  `gh pr merge --delete-branch` under a live worker — you will move the tree out from under it.
- Poll long-running legs on a ~30-minute cadence; no tight loops.
- Workers never push. You own push and PR creation.
- When a worker pushes back on your instructions, treat it as signal: verify before overruling.
