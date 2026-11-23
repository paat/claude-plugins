---
name: hypothesis-journaling
description: "Use for Google Ads iteration hypotheses, result logs, falsifiability checks, and cross-iteration learning distillation."
---

# Hypothesis Journaling

A good hypothesis separates an experiment from a guess; a good log separates learning from LARPing. Load `references/templates.md` when creating `hypothesis.md`, `result.md`, `hypothesis-log.md`, or `learnings.md`.

## What Makes a Hypothesis Good

- **Falsifiable**: names a specific observation that would prove it wrong (not "will improve the campaign", but "rewriting H1 from X to Y will lift CTR on commercial-intent keywords by ≥ 20%").
- **Single-variable**: if your change joins two edits with "and", split it into two iterations.
- **Predictive, not retrospective**: written BEFORE the change, never post-hoc.
- **Scoped**: names exact ad group / language / device / audience and baseline → target delta.

## Required Artifacts (`references/templates.md`)

1. **`iterations/v{N}/hypothesis.md`** (MUST exist before any `spec.md` is written — `check-single-variable.sh` blocks incomplete hypotheses): Date, Loop (`pre-launch | post-launch`), Variable class (`keywords | copy | targeting | landing-page | bidding | extensions`), Scope, Change from `v{N-1}`, Prediction, Reasoning, Evidence needed to confirm, Blast radius + revert plan.
2. **`iterations/v{N}/result.md`** (written after verification or post-launch wait gate + `/ads-metrics`): Verified date, `Hypothesis held: [YES | NO | PARTIAL]`, Evidence artifacts/metric deltas, What actually happened, Interpretation, Next move (`READY TO LAUNCH | NEXT ITERATION | REVERT + RETRY | ESCALATE`), Learning candidate.
   - **Calibration rule**: if the prediction was "+20% CTR" and actual was "+12%", mark `PARTIAL`, never `YES`. Never round up.
3. **`hypothesis-log.md`**: append-only, one factual row per iteration (`v# | Date | Loop | Var | Scope | Prediction | Result | Learning candidate`). Never rewrite past rows; feeds `/ads-distill`.

## Distilling to `learnings.md`

Run `/ads-distill` after every ≥ 5 iterations or at campaign end (`references/templates.md`):

1. **A learning requires a pattern** — one `HELD` is data; three `HELD` in the same direction is a learning.
2. **State principles, not diffs** — explain the reusable mechanism, not just what `v4` changed.
3. **Name the scope** — a principle for Estonian B2B micro-companies does not automatically hold for English e-residents.
4. **Log negative learnings** — e.g., mobile bid adjustment below -40% causes mobile exclusion.
5. **Log dead ends** — repeated failures in one direction prove that lever does not work here.

## Graduating to Project Memory

When a learning holds across ≥ 2 different campaigns for the same advertiser, propose promoting it to project memory:

- Write `$HOME/.claude/projects/<project-hash>/memory/ads_<principle>.md` with principle + scope.
- Add a pointer in `MEMORY.md` and record the graduation in `learnings.md` under `Promoted to project memory`.
- `/ads-distill` proposes candidates only — **always confirm with the user** before writing project memory.

## Anti-patterns to Refuse

- **Post-hoc hypotheses**: writing `hypothesis.md` after verification (file mtime must precede `result.md`).
- **Multi-change single hypothesis**: changing copy AND bids together — refuse and split.
- **Unmeasurable predictions**: "campaign will be better" — require a concrete observable.
- **Rationalizing failures**: "CTR dropped, so we learned something, therefore HELD" — mark `NO` honestly.
- **Generalizing too fast**: one `HELD` iteration ≠ a learning; wait for the pattern.

## Related Skills

- `iterative-campaign-design` — pre-launch hypothesis writing
- `iterative-optimization` — post-launch hypothesis writing
