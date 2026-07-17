---
name: multi-model-orchestration
description: "Use when a user asks to implement through Codex subagents with task-appropriate reasoning effort and independent Opus plus GPT-5.6 Sol review."
---

# Multi-Model Orchestration

Deliver one software change through a thin controller, fresh bounded workers, deterministic
gates, and independent final reviewers. Read `references/routing.md` before assigning models or
efforts. Read `references/research-2026-07.md` only when explaining or revisiting the policy.

## Controller contract

- Preserve the user's requested models and explicit effort levels.
- Keep implementation workers fresh and context packets self-contained. Do not pass the full
  conversation when a task ledger entry is sufficient.
- One worker owns one bounded task. Start sequentially; parallel writes are allowed only for
  disjoint files with no shared build/generated state.
- Start from a clean worktree and record `BASE_SHA`. Never mix pre-existing changes into the run.
- Every task packet names acceptance, allowed files, the exact test, dependencies, model, effort,
  and why that route pays for itself.
- Source changes require deterministic evidence. Reviewer prose is advisory until verified.
- Stop early when the requested state already exists. Stop a failing task after one targeted
  correction rather than recursively spawning agents.

## Routing sequence

1. Classify the work using `references/routing.md`: intent/UX/architecture advice, bounded
   implementation, investigation/debugging, mechanical verification, or final review.
2. Choose the cheapest sufficient effort. Escalate because of observed ambiguity, coupling,
   risk, or a failed lower-effort attempt with new evidence—not because the task sounds important.
3. When the user requires Codex implementation, Opus may produce constraints and a file map, but
   a Codex worker owns every source edit.
4. Default implementation workers to GPT-5.6 Sol. Keep task packets narrow enough that a worker
   does not need to rediscover the project.
5. Use `scripts/run-codex.sh` for each Codex leg and `scripts/run-opus.sh` for a fresh Opus advice
   or review leg. Both runners pin model and effort explicitly.

## Implementation gates

After each worker:

1. Compare changed paths with its allow-list.
2. Inspect the actual diff for acceptance, regressions, duplication, and speculative spread.
3. Run the named targeted test.
4. Record PASS/FAIL and the effective model/effort in the ledger.
5. Continue only when dependencies are satisfied.

After all workers, run the complete directly affected test set and inspect the whole diff from
`BASE_SHA`. A diff over the review budget must be split or explicitly narrowed before review.

## Final reviewers

Opus and Sol review independently and do not see each other's findings. Run them concurrently
when possible.

- Opus: architecture, user intent, UX/copy, environment/build assumptions, minimality, and
  cross-module integration. Default `opus` at `xhigh` for the final pass.
- Sol: repo-walking correctness, data flow, edge cases, tests, and contradictions. Default `high`;
  honor explicit `xhigh`, `max`, or `ultra` exactly.
- Ultra requires a bounded prompt: one pass, at most 10 findings, realistic reachable failures,
  severity threshold, and a hard stop after the verdict. Its automatic delegation is not a
  license for recursive review/fix loops.

The controller verifies file/line claims and reachable failures. Fix confirmed blocking findings
only, rerun deterministic checks, then allow one affected-scope recheck. If reviewers disagree,
prefer code and test evidence; report unresolved disagreement instead of forcing consensus.

## Result

Return a compact ledger with task routes, tests, review verdicts, accepted and rejected findings,
and remaining blockers. Do not restate the diff.
