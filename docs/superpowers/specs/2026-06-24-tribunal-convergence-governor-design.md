# Tribunal Convergence Governor + YAGNI Triage — Design

**Date:** 2026-06-24
**Status:** Approved (design); pending implementation plan
**Plugins touched:** `tribunal-review` (0.15.0 → 0.16.0), `saas-startup-team` (0.49.0 → 0.50.0)

## Problem

The tribunal loop's only stop condition was *"the Opus arbiter returns `APPROVE` with **zero findings** on the latest diff."* Because every fix changes the diff, and repo-walking reviewers (Codex, DeepSeek) can always mine one more atomicity/ordering edge on a concurrency path, **zero-findings is asymptotically unreachable** on that class of code.

Observed failure (aruannik, issue #951): an `improve/unified-emission-validity-gate` branch spiraled to **11 committed tribunal rounds**, each adding more concurrency machinery — lock → run-token → `verdict_sha256` digest → cross-process `fcntl` lock → completion marker → sidecar. Every finding was rated **HIGH**; none was reachable in production (a single user finalizing their own annual report cannot trigger a concurrent same-cid finalize). The other multi-round issue in the repo's history (#630, 6 rounds) showed the same shape.

Root-cause findings from the investigation:

- The spiral is **engine-independent** — both the Claude/Opus engine (rounds 1/4/6: tokens, double-read TOCTOU, `verdict_sha256`) and the Codex engine (rounds 8/11: `fcntl` lock, completion markers) exhibited the same *additive-defensive reflex*. Swapping engines does not fix it.
- The loop has **no round cap, no production-reachability grounding, and no severity honesty**. The arbiter's severities were inflated, so any cap keyed on severity would never trip.
- The `goal-deliver` triage gate ("use judgment on the number of rounds; file out-of-scope findings as follow-ups") was never exercised by the autonomous maintain loop.

A code-review of an earlier draft of this design (Codex) identified the decisive gap: *changing the stop condition without changing the epistemic standard for a blocking finding lets the spiral recur "with better paperwork."* That feedback produced **piece 0** below, which is the linchpin.

## Goals

1. The loop converges on the concurrency/atomicity work-class without sacrificing real defect coverage.
2. Severity is **honest and adjudicated**, so a cap keyed on critical/high actually trips.
3. When the loop stalls, the system attacks the **architecture generating the findings**, not the individual finding.
4. Genuine critical/high defects are still ground down to resolution, with a hard ceiling and human escalation as the final backstop.

## Non-Goals

- Changing which providers run in the tribunal panel, or their prompts (beyond the blocking-finding standard and reachability injection).
- Switching the implementation engine (the investigation showed engine is not the cause).
- Re-litigating already-merged #951 work; this governs future loops.

## Design

### Piece 0 — Blocking-finding standard (the linchpin)

A finding may be rated **critical** or **high** *only if it demonstrates all three*:

1. **Production-reachable path** — a concrete actor + trigger + state transition. "An interleaving exists" or "a malformed file could…" is **not** sufficient; the finding must describe how a real caller reaches the state.
2. **Material impact** — money, data-loss, legal/compliance, or user-visible correctness.
3. **Caused or exposed by *this* change** — a pre-existing, untouched code path that a repo-walking reviewer merely *found* is at most **low / follow-up**, never a blocking finding.

**Burden of proof is on the finding.** If any of the three is absent or unproven, the arbiter caps it at **medium** (informational / triage), never critical/high. The arbiter enforces this standard and has **final say** on every severity.

This is what stops "atomicity archaeology rated HIGH": even with no `reachability.md` present, a same-cid race that cannot show a reachable path fails requirement 1 and cannot block the gate.

### Piece 1 — `reachability.md` (supporting context, not the gatekeeper)

A short, committed, per-repo file stating deployment facts a diff cannot reveal: worker/process model, whether the same session/cid can be acted on concurrently, single-user-per-session assumptions, and which paths are money/data-loss-bearing vs theoretical.

- **Injected** into every reviewer **and** the arbiter the same way `AGENTS.md` already is (capped at 16 KB; absent → no injection).
- **Role:** reduce reviewer noise up front and aid the arbiter's adjudication of piece 0. It is **not** load-bearing against staleness — piece 0's burden-of-proof rule is. A stale or missing `reachability.md` does not silently suppress a real finding, because a blocking finding must *independently* demonstrate reachability.
- **Rebuttable:** the arbiter cross-checks any deployment claim a finding hinges on against the actual code/config before relying on it.
- **Freshness marker:** the file carries a `last-verified:` line (date + commit ref). The arbiter treats claims as lower-confidence when the marker is old relative to changes in the touched area.
- **Upkeep:** updating `reachability.md` is part of the tech-founder definition-of-done whenever a change touches the deployment / concurrency / session model (sits alongside the existing invariant-map DoD rule).

### Piece 2 — Stop condition

The loop **closes** when the arbiter verdict has **zero critical AND zero high** findings remaining. Medium/low findings no longer hold the gate open; they flow to YAGNI triage (piece 3).

### Piece 3 — YAGNI triage for leftover medium/low

At close, for each remaining medium/low finding:

- **File a GitHub follow-up issue only if** the finding is *both* reachable/real (per the arbiter) *and* plausibly something the team will act on.
- **Otherwise drop it**, recording a single line in the PR body: `Tribunal: N low findings dropped (YAGNI) — <one-line reason>`. No silent truncation — the drop is always traceable.

### Piece 4 — Step-back workflow (anti-spiral)

- **Rounds 1–2:** address findings directly.
- **Round 3 onward, while the gate is still open:** enter **step-back mode**. Stop adding guards. Diagnose whether the recent findings are the same *class* (the signature that the **design**, not the bug, is the problem). Then choose exactly one:
  - **Simplify / re-architect** so the whole finding class disappears (e.g., collapse a multi-step commit into a single atomic rename).
  - **Descope** — remove the contested mechanism from the diff and file a follow-up issue capturing the risk.
  - **Confirm-unreachable** — take the class to the arbiter to down-rate under piece 0 / `reachability.md`.
- **Stay in step-back mode** each subsequent stalled round; do **not** revert to guard-piling.

**Falsifiable output (anti-relabel guard):** a step-back round must produce one of:
- a **collapsed** finding class where the **net count of defensive mechanisms does not increase** (measured: locks/tokens/digests/markers/sidecars added must be ≤ removed), or
- a **descope** with the mechanism removed from the diff **and** a linked follow-up issue, or
- an **arbiter ruling** that the class fails the piece-0 bar.

"Added another guard, relabeled as re-architecture" is **invalid** — caught by the no-net-increase check.

### Piece 5 — Same-class merge (every round)

The arbiter merges same-class findings **on every round**, not only in step-back mode. N restatements/variants of one concern collapse to a single finding, so a reviewer cannot refresh the loop by rephrasing.

### Piece 6 — Grind, checkpoint, and ceiling

- **Grind:** keep looping while *any* critical/high remains. Critical/high are **never** YAGNI-dropped. A high is **cleared** when it is *fixed*, *re-rated below high by the arbiter*, or *descoped* (mechanism removed from the diff **+** follow-up filed). A descoped high is no longer "remaining" because the risky surface is gone from the change.
- **Soft checkpoint at round 10:** notify the investor — "still grinding on #<issue>, here is the standing critical/high finding" — **without** forcing a stop.
- **Hard ceiling at round 20:** if critical/high are still unresolved, **stop and escalate to the investor** with the standing finding.

With piece 0 filtering spurious highs early, round counts past ~3 should occur only for genuine hard defects worth grinding on — so the ceiling rarely binds, and when it does it binds on a real defect.

## Where it lands

| Component | Plugin | Change |
|---|---|---|
| `closing-tribunal-loop` SKILL | tribunal-review | New stop condition (piece 2), step-back sub-routine (piece 4), YAGNI triage (piece 3), grind/checkpoint/ceiling (piece 6) |
| `opus-arbiter` agent | tribunal-review | Blocking-finding standard (piece 0), same-class merge (piece 5), reachability.md adjudication + freshness handling (piece 1) |
| `tribunal-loop` SKILL | tribunal-review | Inject `reachability.md` alongside `AGENTS.md` into reviewers + arbiter (piece 1) |
| reviewer agents (codex/claude/deepseek/etc.) | tribunal-review | Prompt note: a blocking severity requires the piece-0 three-part proof |
| `reachability.md` convention | saas-startup-team | Document the file, its format + `last-verified:` marker; add to tech-founder definition-of-done |
| tech-founder agents | saas-startup-team | Execute step-back; maintain `reachability.md` on deployment/concurrency/session changes |
| `goal-deliver` command | saas-startup-team | Align triage text + round cap with this design |

Both plugin versions bumped in `.claude-plugin/plugin.json` **and** root `.claude-plugin/marketplace.json` (repo rule). Update each plugin's README/CHANGELOG as applicable.

## Testing

- `tribunal-review/tests` — extend `run-tests.sh` to cover: stop closes on zero-critical/high with mediums outstanding; a finding lacking any piece-0 leg cannot be emitted as critical/high; step-back's no-net-increase check rejects a guard-pile; same-class merge collapses variants; round-10 checkpoint fires once; round-20 ceiling escalates.
- `saas-startup-team/tests` — `reachability.md` injection path; tech-founder DoD includes reachability upkeep; goal-deliver triage/cap text matches.
- Regression anchor: a reconstructed #951-style sequence (theoretical same-cid race, no reachable path) must close by ≤ round 3 instead of spiraling.

## Open risks

- **Piece-0 enforcement depends on the arbiter following the rubric.** Mitigated by making the three-part proof a required, structured field on any critical/high finding (schema-level), not just prose guidance.
- **Reviewer incentive asymmetry** (finding one more HIGH keeps the loop alive) persists at the prompt level; piece 0 + same-class merge are the counter-pressure. Watch round-count telemetry after rollout.
