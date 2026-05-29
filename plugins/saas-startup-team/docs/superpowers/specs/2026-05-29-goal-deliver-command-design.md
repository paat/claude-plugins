# `/goal-deliver` — Autonomous Multi-Chunk Goal Orchestrator

**Date:** 2026-05-29
**Plugin:** saas-startup-team
**Status:** Approved design — ready for implementation plan

## Overview

`/goal-deliver` takes a set of tasks (GitHub issues, a milestone, a markdown
spec file, or a free-text feature list), autonomously plans and chunks the
work, **reviews its own plan** (no human gate), then executes each chunk by
invoking the `/improve` flow → closing tribunal loop → merge to main,
respecting a dependency graph between chunks. After the final merge it monitors
the GitHub Actions deploy run and auto-fixes failures. All plan and progress
state persists to `.startup/goals/<slug>/` so a long run resumes after
interruption.

The command is fully autonomous: there is **no human in the loop**. The only
human-facing output is the final report. The human approval gate that a
human-in-the-loop design would use is replaced by an autonomous two-pass plan
review (business founder drafts → tech founder reviews/finalizes).

The name is `goal-deliver` (not `goal`) deliberately, to avoid any collision
with a built-in `/goal` command. The hyphenated form is a distinct,
exact-match-safe invocation.

## Input Resolution

The command auto-detects the input form from its arguments:

| Form | Example | Handling |
|---|---|---|
| GitHub issues | `/goal-deliver #12 #15 #20` | `gh issue view <n>` for each; carry issue numbers through for closing on merge |
| Milestone | `/goal-deliver --milestone v2` | `gh issue list --milestone v2 --state open` → issue set |
| Markdown spec file | `/goal-deliver docs/roadmap.md` | argument is an existing file path → read file as the spec |
| Free text | `/goal-deliver add dark mode, fix mobile nav` | fallback when no `#`, no `--milestone`, no existing path → natural-language spec |

Detection order: `--milestone` flag first; then if the single argument is an
existing file path → file mode; then if arguments contain `#<digits>` tokens →
issues mode; otherwise → free-text mode.

All forms normalize into one **task spec**: a list of work items, each with a
source reference (issue number where applicable) so issues can be closed when
their chunk merges.

## Pre-Flight (Hard Gates)

All gates must pass before any work begins. Same spirit as `/improve` —
`/goal-deliver` is a post-completion command.

1. **tribunal-review installed.** The `tribunal-review:tribunal-loop` skill must
   be resolvable. If not, fail with an install hint. This is a **hard
   dependency** — the tribunal gate is non-negotiable per chunk.
2. **`.startup/` exists** and `.startup/go-live/solution-signoff.md` exists. If
   not, instruct the investor to run `/startup` first (the build loop must have
   completed). `/goal-deliver` is for post-completion delivery of new work, like
   `/improve`.
3. **`docs/architecture/architecture.md` exists** (tech founder needs stack and
   service URLs).
4. **Working tree clean** (`git status --porcelain` empty).
5. **On the default branch** (chunks branch off main and merge back to main).
   If not on default, instruct the investor to switch.
6. **`gh` authenticated** and the repo has a remote (issue fetch, PR, merge,
   and run-watch all require it).

## Plan + Autonomous Review

This replaces the human approval gate with a two-pass autonomous review.

### Pass 1 — Business founder drafts the plan

Dispatch the business founder (`business-founder-maintain` identity) to:

- Read the normalized task spec.
- Read `docs/business/brief.md`, `docs/architecture/architecture.md`, relevant
  `docs/research/`, and `docs/legal/`.
- **Push back** on anything that conflicts with legal compliance, undermines
  business strategy, or risks sales/conversion — citing specific docs (same
  push-back contract as `/improve`). If the business founder rejects part of the
  spec, that work item is dropped from the plan with a recorded reason.
- Decompose the remaining work into **PR-sized chunks** (the `/improve` sweet
  spot: a coherent unit producing one PR, ~15–30 min of agent work each).
- Define a **dependency graph**: each chunk lists the chunk IDs it `depends_on`.
- Write the draft to the goal state file (see State File) and a human-readable
  `plan.md`.

### Pass 2 — Tech founder reviews and finalizes

Dispatch the tech founder (`tech-founder-maintain` identity) to:

- Read the draft plan and `docs/architecture/architecture.md`.
- Review for **feasibility** (is each chunk implementable as scoped?) and
  **dependency correctness** (are the `depends_on` edges right? any missing
  edges that would cause merge conflicts or broken builds?).
- Adjust chunk boundaries and dependency edges as needed and finalize.

The finalized plan is written to `plan.json`. This two-pass cross-discipline
review **is** the autonomous gate; execution begins immediately after it, with
no human confirmation.

## State File — `.startup/goals/<slug>/plan.json`

`<slug>` is derived from the goal (issue list, milestone name, file name, or a
slug of the free-text spec). The directory also holds the human-readable
`plan.md`.

```jsonc
{
  "goal_slug": "...",
  "created": "<ISO timestamp>",
  "source": { "type": "issues|milestone|file|freetext", "refs": [12, 15, 20] },
  "chunks": [
    {
      "id": "C1",
      "title": "...",
      "description": "...",          // self-contained brief passed to /improve
      "issue_refs": [12],            // GH issues this chunk closes on merge
      "depends_on": [],              // chunk IDs that must be merged first
      "status": "pending",           // pending|in-progress|merged|blocked|skipped
      "pr_url": null,
      "branch": null,
      "tribunal_rounds": 0,
      "filed_issues": [],            // GH issues filed for out-of-scope findings
      "skip_reason": null            // set when blocked or skipped
    }
  ],
  "deploy": { "status": "pending", "run_id": null }  // pending|monitoring|green|failed
}
```

State is persisted (write-temp-then-rename, matching the existing `.startup/`
pattern) after every status transition so the run is resumable. Re-running
`/goal-deliver` with the same goal detects the existing state file and resumes
from the first non-`merged` chunk.

## Per-Chunk Loop

Process chunks in **topological order**. A chunk is eligible only when every
chunk in its `depends_on` has `status == "merged"`.

For each eligible chunk:

1. Mark `in-progress`, persist.
2. **Invoke the `/improve` flow** with the chunk's `description` as the
   improvement instruction, in new-branch mode off main. This runs the existing
   business → tech → business-QA cycle and opens a PR on `improve/<chunk-slug>`.
   Record `branch` and `pr_url`.
3. **Closing tribunal loop** on the PR branch (per the
   `tribunal-review:closing-tribunal-loop` skill):
   - Run `tribunal-review:tribunal-loop`. If the arbiter returns `APPROVE` with
     0 findings → the gate is closed, go to step 4.
   - Otherwise triage each finding:
     - **Critical / service-breaking** → fix in this PR (dispatch tech founder),
       push, increment `tribunal_rounds`, re-run tribunal.
     - **Non-critical AND out-of-scope / pre-existing** → file a GitHub issue
       using the closing-tribunal-loop follow-up template, cross-link to the PR,
       append to `filed_issues`, and do **not** block on it.
     - **False positive** → reject (verified against the cited code).
   - Repeat until `APPROVE`-0 **or** `tribunal_rounds` reaches the retry cap
     (default **5**).
4. **Gate closed (APPROVE-0):** squash-merge the PR to main, close the chunk's
   `issue_refs`, delete the branch, mark the chunk `merged`, persist. Return to
   main.
5. **Retry cap hit with unresolved critical findings:** mark the chunk
   `blocked` with a `skip_reason`, leave its PR open as a draft, then mark every
   chunk that transitively `depends_on` this one as `skipped` (block dependents).
   Continue with the remaining independent chunks.
6. Continue until no eligible chunks remain.

### Finding-severity policy (summary)

- Critical / service-breaking → **fix ASAP in the PR**.
- Non-critical, out-of-scope, or pre-existing → **file a GH issue**, don't block.
- When a chunk genuinely can't pass the gate → **block dependents, continue
  independents**.

## Deploy Monitoring

Runs after the last eligible chunk has been processed and at least one chunk
merged to main.

1. Identify the GitHub Actions run triggered by the final merge to main
   (`gh run list` filtered to the merge commit / main branch; `gh run watch`).
   Record `deploy.run_id`, set `deploy.status = "monitoring"`.
2. Watch until the run concludes.
3. **On success:** set `deploy.status = "green"`.
4. **On failure:** read the failing job logs, dispatch the tech founder to fix
   on a `deploy-fix/<slug>` branch → open PR → run the closing tribunal loop →
   merge → re-monitor the new run. Repeat until green or a deploy retry cap
   (default 3) is hit. If the cap is hit, set `deploy.status = "failed"` and
   record it for the final report.

## Final Report

A single English status summary to the investor:

- Chunks **merged** (with PR links).
- Chunks **blocked** / **skipped** (with reasons and draft-PR links).
- GitHub issues **filed** for out-of-scope tribunal findings (with links).
- **Deploy status** (green / failed, with run link).

## Reuse Mechanics

The investor chose "invoke `/improve` per chunk" for maximum reuse. Slash
commands cannot be called as a tool from inside another command, so mechanically
this means: the `/goal-deliver` orchestrator **follows the documented `/improve`
flow** (`${CLAUDE_PLUGIN_ROOT}/commands/improve.md`) for each chunk, keeping
`/improve` as the single source of truth for the build cycle. If logic drift
between the two becomes a problem later, extract the shared build cycle into a
skill that both `/improve` and `/goal-deliver` invoke. The by-reference approach
is chosen now to keep scope contained.

## Autonomy Mechanics

- Each chunk's `/improve` + tribunal work is synchronous. For any genuinely
  long-running background wait (e.g. `gh run watch`), use the `ScheduleWakeup`
  poll pattern documented in `/startup` (≤270 s delay to stay inside the
  prompt-cache window) so the orchestrator yields control correctly instead of
  thrashing the Stop hook.
- Reset `active_role` in `.startup/state.json` before dispatching subagents (same
  guard as `/improve`) so the `enforce-delegation` hook does not block this flow.
- No human gate anywhere except the final report. A critical-but-unfixable chunk
  blocks its dependents and the run continues with independent work.

## Communication

Inherits the team language rules:

- Business founder speaks **Estonian** to the investor.
- Tech founder speaks **English** to the investor.
- The orchestrator (team lead) speaks **English** for status updates and the
  final report.

## Versioning

Bump `saas-startup-team` version in **both** `.claude-plugin/plugin.json` and
the root `.claude-plugin/marketplace.json` before pushing (repo rule).

## Out of Scope

- Human approval checkpoints (explicitly excluded — fully autonomous).
- Extracting a shared build-cycle skill (deferred; by-reference reuse for now).
- Non-GitHub-Actions deploy pipelines (deploy monitoring targets GH Actions;
  project-specific deploy commands from the architecture doc are a possible
  future extension).
- Parallel chunk execution (chunks run sequentially in topological order; the
  dependency graph governs eligibility, not concurrency).
