---
name: multi-model-orchestration
description: "Use when a user asks to implement through Claude Code, Codex, or Grok Build workers with task-appropriate model and reasoning selection plus independent review."
---

# Multi-Model Orchestration

Deliver one software change through a thin controller, fresh bounded workers, deterministic
gates, and independent final reviewers. Read `../route-model-task/SKILL.md` and its routing
reference before assigning models or efforts. Read `references/research-2026-07.md` only when
explaining the community evidence behind the original policy.

## Controller contract

- Apply provider/model allowlists and denylists before routing. Preserve compatible explicit model
  and effort choices; never silently substitute a forbidden provider.
- Use only Claude Fable 5, Opus 5, Sonnet 5, Haiku 4.5; GPT-5.6 Sol, Terra, Luna; and Grok 4.5.
- Run every CLI leg in YOLO mode inside the development-container boundary: Codex bypasses
  approvals and sandboxing, Claude skips permissions, and Grok uses sandbox `none` with
  `bypassPermissions`. Keep reviewer mutation control in prompts and tool allowlists.
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

1. Use `route-model-task` to classify intent/UX/architecture advice, bounded implementation,
   investigation/debugging, mechanical verification, or final review and emit route cards.
2. Choose the cheapest sufficient supported effort. Escalate because of observed ambiguity,
   coupling, risk, or a failed lower-effort attempt with new evidence—not task importance.
3. When the user restricts implementation to one provider, every source edit belongs to that
   provider. Other allowed providers may advise or review only.
4. Keep task packets narrow enough that a worker does not need to rediscover the project.
5. Dispatch with `scripts/run-claude.sh`, `scripts/run-codex.sh`, or `scripts/run-grok.sh` as named
   by the route card. Every runner pins a current model; supported efforts are pinned explicitly.

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

Use one provider different from the implementer for ordinary nontrivial work. Use two complementary
allowed reviewers only when risk or conflicting evidence makes the extra pass pay for itself. A
provider restriction may require a fresh same-provider reviewer; preserve the restriction.

- Claude Opus 5: architecture, user intent, UX/copy, environment/build assumptions, visual
  judgment, minimality, and cross-module integration. Start at `high`.
- GPT-5.6 Sol: repo-walking correctness, data flow, edge cases, tests, contradictions, and security.
  Start at `high`; honor compatible explicit `xhigh`, `max`, or `ultra`.
- Grok 4.5: fast independent reproduction and a decorrelated code-review lens. Start at `medium`
  and use `high` for difficult review; it does not support higher efforts.
- Ultra requires a bounded prompt: one pass, at most 10 findings, realistic reachable failures,
  a severity threshold, and a hard stop after the verdict. Never create recursive review/fix loops.

The controller verifies file/line claims and reachable failures. Fix confirmed blocking findings
only, rerun deterministic checks, then allow one affected-scope recheck. If reviewers disagree,
prefer code and test evidence; report unresolved disagreement instead of forcing consensus.

## Result

Return a compact ledger with task routes, tests, review verdicts, accepted and rejected findings,
and remaining blockers. Do not restate the diff.
