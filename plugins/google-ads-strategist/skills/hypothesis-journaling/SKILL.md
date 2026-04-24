---
name: hypothesis-journaling
description: Use when writing any iteration hypothesis, logging an iteration result, or distilling learnings across iterations — teaches how to write falsifiable hypotheses, record outcomes without post-hoc rationalization, and distill patterns into the cross-campaign learnings file. Load when starting a new iteration, when writing result.md, or when running /ads-distill.
---

# Hypothesis Journaling

A good hypothesis is the difference between an experiment and a guess. A good log is the difference between learning and LARPing. This skill enforces both.

## What Makes a Hypothesis Good

A hypothesis is **falsifiable** — there is a specific observation that would prove it wrong. "This will improve the campaign" is not a hypothesis. "Rewriting H1 from 'AI Annual Reports' to 'E-resident Annual Report in 15 min' will lift CTR on commercial-intent keywords by ≥ 20%" is a hypothesis.

A hypothesis is **single-variable**. If your sentence contains "and" between two change descriptions, split it into two iterations.

A hypothesis is **predictive, not retrospective**. Write it BEFORE the change, not after. Post-hoc "here's what we changed and here's what happened" is reporting, not learning.

A hypothesis is **scoped**. "CTR will improve" is unscoped. "CTR on ad group `commercial-intent-ee` will improve from baseline 3.1% to ≥ 4.0%" is scoped.

## The `hypothesis.md` Template

Every iteration folder MUST contain this file before any `spec.md` is written:

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

Missing sections mean missing discipline. The single-variable hook refuses to accept a spec.md without a complete hypothesis.md.

## The `result.md` Template

After verification (pre-launch) or after the wait gate + metrics pull (post-launch), write:

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

**Calibration rule**: if the prediction was "lift CTR by ≥ 20%" and the actual was +12%, the hypothesis did NOT hold — it partially held. Do not round up. Honest calibration is how you stop being wrong.

## The `hypothesis-log.md` Ledger

Append-only. Never rewrite past entries. One line per iteration:

```markdown
# Hypothesis log — <campaign>

| v# | Date | Loop | Var | Scope | Prediction (short) | Result | Learning candidate |
|----|------|------|-----|-------|--------------------|--------|--------------------|
| v1 | 2026-04-11 | pre | copy | et/commercial | Position ≤3 for top-5 keywords | HELD | — |
| v2 | 2026-04-11 | pre | targeting | et/mobile | Mobile triggering restored | HELD | Mobile device adj -40% is floor |
| v3 | 2026-04-12 | pre | landing-page | et/* | Message-match lifts preview ad-strength to "Good" | NO | LP H1 change not sufficient — need hero copy rewrite |
| v4 | 2026-04-13 | pre | landing-page | et/* | Hero copy rewrite lifts ad-strength to "Good" | HELD | LP hero dominates ad-strength signal > H1 |
```

The log is the raw material for `/ads-distill`. Keep it pristine — no explanations, no justifications, just facts.

## Distilling to `learnings.md`

Run `/ads-distill` after every ≥ 5 iterations or at the end of a campaign. The distillation rules:

1. **A learning requires a pattern**, not a single observation. One "HELD" is data. Three "HELD" in the same direction is a learning.
2. **Learnings are stated as principles**, not as diffs. Bad: "In v4 we changed LP hero and ad strength improved." Good: "LP hero copy dominates ad-strength signal for commercial-intent Estonian keywords."
3. **Learnings name their scope**. A principle that held for Estonian B2B micro-companies does NOT automatically generalize to English e-residents. State the scope.
4. **Negative learnings matter too**. "Mobile bid adjustment below -40% causes complete mobile exclusion" is worth logging.
5. **Dead ends are worth logging**. If v3-v7 all failed in the same direction, the pattern is "this class of change doesn't work here" — log it.

The `learnings.md` template:

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

## Graduating to Project Memory

When a learning holds across ≥ 2 different campaigns for the same advertiser, promote it to auto-memory as a `project` memory:

- Write a new file in `/config/.claude/projects/<project-hash>/memory/ads_<principle>.md` with the principle and its scope
- Add an entry to `MEMORY.md` pointing to it
- Reference the graduation in `learnings.md` under "Promoted to project memory"

The `/ads-distill` command proposes graduation candidates but does not auto-write memory files. You (the agent) confirm with the user before promoting, because project memory survives across sessions and affects future work.

## Anti-patterns to Refuse

- **Post-hoc hypotheses**: writing hypothesis.md after seeing verification results. Detect this by checking file mtimes — hypothesis.md must be older than result.md.
- **Multi-change single hypothesis**: "Rewriting copy AND adjusting bids will lift CTR." Refuse and split.
- **Unmeasurable predictions**: "The campaign will be better." Refuse and ask for a specific observable.
- **Rationalizing failures**: "The hypothesis held because even though CTR went down, we learned something." No — CTR going down means the hypothesis did not hold. Write that honestly and move on.
- **Generalizing too fast**: one HELD iteration ≠ a learning. Wait for the pattern.

## Related Skills

- `iterative-campaign-design` — calls this skill for pre-launch hypothesis writing
- `iterative-optimization` — calls this skill for post-launch hypothesis writing
