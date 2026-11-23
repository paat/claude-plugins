# Hypothesis Journaling — Artifact Templates

On-demand templates for `hypothesis.md`, `result.md`, `hypothesis-log.md`, and `learnings.md`.

## `iterations/v{N}/hypothesis.md`

Every iteration folder MUST contain this file before any `spec.md` is written (enforced by `check-single-variable.sh`):

```markdown
# Iteration v{N} hypothesis

**Date**: YYYY-MM-DD
**Loop**: [pre-launch | post-launch]
**Variable class**: [keywords | copy | targeting | landing-page | bidding | extensions]
**Scope**: [which ad group / language / device / audience this applies to]

## Change from v{N-1}
- [exact diff — a reader should be able to apply this change blindly]

## Prediction
- [observable, falsifiable outcome]
- [optional: secondary predictions — but only one primary]

## Reasoning
- [why you believe this change will produce the predicted outcome]
- [link to specific competitor observation, learning from past iteration, or principle from a skill]

## Evidence needed to confirm
- [exact artifacts that must exist for the hypothesis to be called "held"]
- For pre-launch: screenshot of Ad Preview Tool for keyword X showing position ≤ Y
- For post-launch: metric delta from /ads-metrics after N-day wait

## Blast radius
- [what could go wrong if the hypothesis is wrong]
- [revert plan if needed]
```

## `iterations/v{N}/result.md`

```markdown
# Iteration v{N} result

**Verified**: YYYY-MM-DD
**Hypothesis held**: [YES | NO | PARTIAL]

## Evidence
- [list of artifacts in verification/ with a one-line description each]
- [metric deltas for post-launch, with baseline + current + delta]

## What actually happened
- [honest description, even if it contradicts the prediction]
- [if partial: what subset of the prediction held, and why the rest did not]

## Interpretation
- [what this tells us about the underlying mechanism]
- [NOT a rationalization — if we were wrong, say we were wrong]

## Next move
- [one of: READY TO LAUNCH | NEXT ITERATION | REVERT + RETRY | ESCALATE]
- [if NEXT ITERATION: one-line seed of the next hypothesis]

## Learning candidate
- [if any, a one-line principle worth promoting to learnings.md]
- [leave blank if this was just a campaign-specific tweak]
```

## `hypothesis-log.md` (append-only ledger)

```markdown
# Hypothesis log — <campaign>

| v# | Date | Loop | Var | Scope | Prediction (short) | Result | Learning candidate |
|----|------|------|-----|-------|--------------------|--------|--------------------|
| v1 | 2026-04-11 | pre | copy | et/commercial | Position ≤3 for top-5 keywords | HELD | — |
| v2 | 2026-04-11 | pre | targeting | et/mobile | Mobile triggering restored | HELD | Mobile device adj -40% is floor |
| v3 | 2026-04-12 | pre | landing-page | et/* | Message-match lifts preview ad-strength to "Good" | NO | LP H1 change not sufficient — need hero copy rewrite |
| v4 | 2026-04-13 | pre | landing-page | et/* | Hero copy rewrite lifts ad-strength to "Good" | HELD | LP hero dominates ad-strength signal > H1 |
```

## `learnings.md`

```markdown
# Learnings — <campaign>

Last distilled: YYYY-MM-DD from vN

## What works
- [principle] — scope: [context] — evidence: [v# references]

## What does not work
- [principle] — scope: [context] — evidence: [v# references]

## Open questions
- [things we haven't tested yet that might matter]

## Promoted to project memory
- [principles that graduated — see memory file names]
```
