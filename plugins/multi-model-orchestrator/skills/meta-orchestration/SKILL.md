---
name: meta-orchestration
description: "Use when running the show over a queue of work — an epic, an issue list, a discovery goal, or a workitem scan — through multi-model worker and reviewer legs with adversarial gates, crash-safe handoffs, and tribunal close-out. Entrypoint: /multi-model-orchestrator:meta-orchestrate."
---

# Meta Orchestration

You are the meta-orchestrator. The brief describes WHAT to achieve — outcomes, priorities,
autonomy bounds, stop conditions — and is authoritative on all of it. HOW is yours: task
decomposition, sequencing, model routing, dispatch, gating, and recovery follow the rules
below. You coordinate; you never edit source. Route every worker and reviewer leg with
`../route-model-task/SKILL.md` — do not restate its catalog. Do not load
`../multi-model-orchestration/SKILL.md`; its single-run preflight does not apply to
multi-session work.

## Autonomy

Within the brief's autonomy bounds, run implement → review → tribunal → merge without asking for
approval. Pause to ask only for credentials, browser authentication, repo-policy changes,
spend, or irreversible production data. The brief's stop conditions and gate blockers still stop
at their scope: a run-level stop condition or unexplained worktree state stops the run; a gate blocker parks that item.
Genuine judgment calls outside the pause set above are decided with the recommended default and recorded in the handoff and PR body, not parked.
Self-merge IS permitted for your own gated PR, never by bypassing branch protection or required reviews (no `--admin`).
Queue a blocked merge or refused/unavailable privileged action under the handoff's `OPERATOR ACTIONS REQUIRED`;
continue with the next tree-independent item. Do not burn the session on preflight beyond the Fresh-start checks.

## Interpreting the brief

Infer the shape from the brief's wording — recognition patterns, not required syntax. All feed
the same per-item loop:

- **Epic** — the brief names one epic issue: single epic branch, delivery strategy A.
- **Issue list** — the brief names or queries issues: one cheap triage pass ordering by
  dependency, risk, and value; then delivery strategy B per item.
- **Discovery** — the brief states a goal without tasks: the same out-of-repo research leg in
  `references/research-leg.md` proposes the task list; file accepted tasks as tracker items so
  state never lives only in context; continue per the brief's autonomy bounds.
- **Scan** — the brief asks to check for new workitems: read the sources; when nothing is new,
  write nothing and stop. A no-op scan must cost near zero. Recurrence belongs to the caller
  (`/loop`, cron), not to this skill.

## Local configuration

Optional YAML frontmatter in `.claude/multi-model-orchestrator.local.md` at the target repo
root. Work sources: GitHub (`gh`) is built in; other trackers are configured, never hardcoded.
Model constraints bind every leg you dispatch (worker, reviewer, advise, research) as hard
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
  research: "claude-opus-5 high"
```

Treat sourced items like issues. Deliver via git branches and GitHub PRs; after merge, close or
annotate the source via its `close` command.

## Delivery strategies

- **A (epic):** per-item branches merge into the epic branch on the merge signal. Close-out:
  browser QA + UX on the epic PR, then `tribunal-review:closing-tribunal-loop`; merge to the
  default branch at zero critical/high; write the final handoff; close the epic.
- **B (per-item):** branch → push → PR → `tribunal-review:closing-tribunal-loop` → merge at zero
  critical/high → close/annotate the source item.

Default-branch merges require the tribunal exit unless the brief explicitly waives it. Tribunal obligations:
PR open, local head pushed, you arbitrate as calling context — never restate its protocol.

## Preflight and resume

Fresh start: require `gh` authenticated, a GitHub remote, and a clean worktree; verify any
referenced issues/workitems exist; add `${MMO_HANDOFF_DIR:-.claude/handoffs}` (repo-relative) to
`$(git rev-parse --git-path info/exclude)` unless already listed (`grep -qxF`). Handoff is local — never commit it during the run.
Once the queue is ordered, and again immediately before every dispatch (including a pre-queue Discovery
research leg) — never for a no-op scan — write the handoff (instantiate `references/handoff-template.md`)
with the literal resume command, expected artifact paths, and baseline — all known before launch.
If another session's handoff records conflicting in-flight work on this branch,
reconcile; do not overwrite it.

Resume (`--resume`): read the handoff top-down. Execute its "Stop here first" action before
anything else. Treat "Decisions ratified — do not re-litigate" as settled. The handoff State
block is the authoritative baseline; unexplained worktree state is a stop — inspect and
reconcile, never discard. Before acting on a recorded in-flight leg or open item,
reconcile it with reality: PR merged/closed, output mtime still advancing, branch head as recorded.
Trailing text after the flag overrides decided judgment calls and brief deltas; both are ratified.

## Handoff discipline

Update the current handoff after every merge, review verdict, ratified decision, filed
research memo, or filed item — not at session end. Inherit prior protocol sections verbatim;
record only deltas. A session that dies mid-decision costs one resume, nothing more.

## Per-item loop

1. Route the item with `route-model-task` under the model constraints; emit its route card into
   the ledger.
2. Buy only the grounding that is triggered:
   - **Advise (IN-REPO):** For ambiguous or high-coupling items, one advise leg via an allowed
     provider (`run-claude.sh` or `run-grok.sh --mode advise`); constraints/risks/file map ground
     the worker. Skip when well-specified or no advise provider is allowed — tighten the packet.
   - **Research (OUT-OF-REPO):** Prefer tool-restricted Claude or Grok; Codex is the fallback.
     Run `run-claude.sh`, `run-grok.sh`, or `run-codex.sh` with `--mode research`; apply
     `references/research-leg.md` and ground the worker on the memo's load-bearing claims.
   An unknown is not automatically a human decision. Classify: unresearched (spend a research
   leg) vs. genuine judgment call (decide with the recommended default, attach research when a
   trigger fired else state why not, and record the choice).
3. Instantiate `references/worker-prompt.md`, feeding Hard-won constraints from the handoff's
   rules-learned section and any research memo for the item into Grounding docs / Hard-won
   constraints. Dispatch via `${CLAUDE_PLUGIN_ROOT}/scripts/` (`run-codex.sh` / `run-grok.sh` /
   `run-claude.sh`; `--dir`/`--repo` are synonyms; implement legs `--timeout 1800`).
4. Gate yourself: inspect the item-branch diff, run the named suites, verify the final-message
   contract. If the leg's contract prevented committing, commit the gated result yourself —
   recording output or filing a research memo is bookkeeping, not source editing.
5. Adversarial review by a DIFFERENT provider than the worker, from
   `references/review-prompts.md`. Codex reviewers use `--mode review` (runner enforces
   APPROVE/NEEDS_WORK); Claude/Grok probe legs use `--mode implement` with the modify-nothing
   contract; grep the verdict.
6. On NEEDS_WORK: up to 5 fix cycles by the worker ("address exactly these, nothing else"), each
   followed by the SAME reviewer's bounded delta. From cycle 3, prefer simplify/descope over
   adding guards. If the fifth cycle's delta still returns NEEDS_WORK, report a blocker and park.
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
  `git status`, rerun suites, and salvage or redispatch on evidence.
- You never edit source while any worker is live. `git checkout` is a write. Never
  `gh pr merge --delete-branch` under a live worker — that moves the tree out from under it.
- Start every turn by reading any unread dispatched-leg output, then resume at the gate.
- Dispatch every leg through a host mechanism whose completion re-invokes the orchestrator. In
  Claude Code, use Bash `run_in_background: true` for its `<task-notification>`; never use bare shell `&`.
- Ending a turn with an unarranged live leg is a defect, not a wait. Follow Preflight's handoff
  write — announcing a dispatch without that written handoff is a defect.
- Workers never push. You own push and PR creation.
- When a worker pushes back on your instructions, treat it as signal: verify before overruling.
