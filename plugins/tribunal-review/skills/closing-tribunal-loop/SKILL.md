---
name: closing-tribunal-loop
description: "Use after tribunal-loop returns NEEDS_WORK or BLOCK to triage findings, fix or file follow-ups, and revalidate the changed diff."
---

# Closing the Tribunal Loop

## Overview

`tribunal-loop` is one round of review. **Closing the loop is iterative**: after any code change, the diff has changed and findings can change with it — new bugs introduced by the fix, old findings invalidated, false positives clarified. The loop closes when the arbiter returns a verdict with **zero critical and zero high findings** on the latest diff (medium/low go to YAGNI triage). Every code change re-opens the diff, so re-run after any fix.

**Core principle:** Tribunal is a quality gate, not a checklist. The gate stays closed until the diff itself stops generating critical/high findings — including findings caused by your own fixes.

## Frozen Delivery Contract

Before triage, freeze the original task outcome, acceptance checks, preserved invariants,
and exclusions using only explicit user, issue, PR, or plan text. Never invent missing
acceptance criteria, invariants, or exclusions. Findings may prove that the current diff violates that contract.
They do not redefine the task. Expand the current PR only for a verified defect caused or exposed
by the diff whose fix is required by the frozen acceptance checks or removes a material
regression. Do not expand investigation for adjacent concerns beyond evidence already present.
File a follow-up only when that evidence is sufficient; otherwise record or drop the concern.

## When to Use

- Just ran `tribunal-loop` and the arbiter verdict is `NEEDS_WORK` or `BLOCK`
- Made a code change in response to a tribunal finding (any change → re-run required)
- About to mark the PR ready / merge / hand off, but haven't re-run tribunal since the last commit

**Don't use when:**
- Tribunal verdict is `APPROVE` with zero critical/high findings on the current diff
- Reading findings only (no code change planned)
- The PR is documentation-only or you're not running tribunal at all

## The Loop

```dot
digraph close_tribunal {
    "tribunal verdict" [shape=doublecircle];
    "Zero critical & high?" [shape=diamond];
    "Per-finding triage" [shape=box];
    "Apply fixes + tests" [shape=box];
    "Push" [shape=box];
    "Re-run tribunal-loop" [shape=box];
    "DONE — ready to merge / hand off" [shape=doublecircle];

    "tribunal verdict" -> "Zero critical & high?";
    "Zero critical & high?" -> "DONE — ready to merge / hand off" [label="yes (arbiter verdict)"];
    "Zero critical & high?" -> "Per-finding triage" [label="no"];
    "Per-finding triage" -> "Apply fixes + tests";
    "Apply fixes + tests" -> "Push";
    "Push" -> "Re-run tribunal-loop";
    "Re-run tribunal-loop" -> "Zero critical & high?";
}
```

The loop only exits when the calling context's verdict has **zero critical and zero high findings** on the current diff (medium/low go to YAGNI triage). The panel runs in parallel (by default Codex, DeepSeek, and Claude; Gemini, GLM, Qwen, and Grok opt-in) precisely because any single reviewer can miss things — so a verdict built on the latest diff is the only verdict that counts.

## Per-Finding Triage

You triage the **arbiter's findings** (`T-001`, `T-002`, …), each already deduplicated and tagged with a `consensus` type (`CONSENSUS` or `SINGLE_PROVIDER`, per the `tribunal-loop` output contract) and supporting `providers`. For every finding, decide one of three outcomes:

| Outcome | When |
|---|---|
| **Fix in this PR** | Verified bug caused/exposed by this diff and required by the frozen acceptance checks or to remove a material regression |
| **File follow-up issue** | Verified, plausibly actionable bug that is pre-existing or explicitly out of PR scope |
| **Reject** | False positive (verified against actual code) |

Verify each finding by reading the cited line and reasoning about it (or running a 30-second repro). Don't trust the consensus label or confidence number on its own — a `CONSENSUS` finding can be a shared false positive, and a `SINGLE` finding (one reviewer) can be a real bug. Verification is cheap; trusting blindly is expensive.

Use the smallest causal fix consistent with the existing architecture. Validate the
reproduced finding and the original acceptance checks; do not start a broader audit or
add generalized machinery for hypothetical variants.

**One commit per finding (or per cluster of related findings)** with the finding ID in the commit message body — `tribunal T-001`, `tribunal T-004 / T-005`. This makes the loop trail readable in `git log`.

## Stop Condition

The loop **closes** when the arbiter's verdict has **zero `critical` and
zero `high` findings** remaining on the latest diff. Medium/low findings do
NOT hold the gate open — they go to YAGNI triage below.

A `high` finding is **cleared** when it is one of:
- **fixed**, or
- **re-rated below high by the arbiter** (e.g. it failed the 3b-0 blocking
  standard), or
- **descoped** — the contested mechanism is *removed from the diff* AND the
  risk is captured in a filed follow-up issue. A descoped high is no longer
  "remaining" because the risky surface is gone from the change.

### YAGNI triage (leftover medium/low at close)

For each remaining medium/low finding:
- **File a follow-up issue ONLY IF** it is both reachable/real (per the
  arbiter) AND plausibly something the team will act on.
- **Otherwise drop it**, recording one line in the PR body:
  `Tribunal: N low findings dropped (YAGNI) — <one-line reason>`.
  Never silently truncate — every drop is traceable.

### Retry, checkpoint, ceiling

- **Retry:** keep looping while ANY critical/high remains. Critical/high are
  never YAGNI-dropped.
- **Round 3 — checkpoint:** surface a progress note to the caller
  ("still blocked on #<issue>; standing finding: <title>") WITHOUT stopping.
- **Round 5 — hard ceiling:** if critical/high are still unresolved, STOP and
  escalate to the caller with the standing finding.

## Step-back workflow (anti-spiral)

- **Rounds 1–2:** address findings directly.
- **Round 3 onward, while the gate is open:** enter **step-back mode**. Stop
  adding guards. Diagnose whether the recent findings are the same *class*
  (the signature that the DESIGN, not the bug, is the problem). Then choose
  exactly one:
  - **Simplify within the original acceptance criteria and existing architecture** so
    the whole class disappears (e.g. collapse a multi-step commit into a single atomic
    rename). If that requires a broader redesign, descope or escalate instead.
  - **Descope** — remove the contested mechanism from the diff and file a
    follow-up issue capturing the risk.
  - **Confirm-unreachable** — take the class to the arbiter to down-rate under
    3b-0 / reachability.md.
- Stay in step-back mode each subsequent stalled round; do NOT revert to
  guard-piling.

**Falsifiable output (anti-relabel guard).** A step-back round MUST produce one
of: (a) a collapsed class where the net count of defensive mechanisms
(locks/tokens/digests/markers/sidecars) does NOT increase — added ≤ removed; or
(b) a descope with the mechanism removed from the diff AND a linked follow-up
issue; or (c) an arbiter ruling that the class fails 3b-0. "Added another guard,
relabeled as re-architecture" is INVALID and is caught by the no-net-increase
check.

## Follow-Up Issue Template

When triage decides "file follow-up" rather than "fix in this PR", file a real GitHub issue (or comment on a pre-existing one if cited). Use this body template — dense, actionable, lets the next person fix without re-deriving the context:

```markdown
## Context

Brief note on which PR surfaced this and why it's deferred (e.g., out of
original issue scope, requires separate design decision, blocked on X).

## Current behaviour

File:line citation + 2-3 lines of code or behaviour description.

## Failure scenario

Concrete repro: a specific input that triggers the bug, expected vs
actual output. Use a table when contrasting pre- vs post-state.

## Fix sketch

The smallest change that closes the bug. One paragraph or short code
block. Include any acceptance test that should pin the fix.

## Severity

Low / Medium / High / Critical, with one sentence on customer impact
and triggering preconditions ("only bites returning customers who…").

## Discovered by

Tribunal review of PR #N, finding T-XXX (consensus type, confidence).
```

The template exists because tribunal findings have **structured context** (severity, consensus type, supporting providers, confidence, file/line, description, suggestion) that's lost if you just paste a one-line "fix this later". Preserve the structure so the next session can act on the issue without re-running tribunal.

**Cross-link both directions** when you file: the PR commit message references the issue (`tracked at #N`) AND the issue references the PR (`Discovered by tribunal review of PR #N`).

## Common Mistakes

- **Stopping after round 1** because all original findings were addressed. The fixes are themselves a new diff — they can have their own bugs.
- **Bundling out-of-scope fixes into the PR** to "reduce churn". Bloats the diff, expands review surface, makes rollback messier. File a separate issue and a separate PR.
- **Filing follow-up issues with one-line bodies** ("fix the cart_total typing bug"). When the next session picks it up, they have to re-derive context. The template makes the next fix mechanical.
- **Declaring done on a stale verdict** — re-running tribunal after a fix but acting on the previous round's verdict, or skipping the re-run entirely. Only the arbiter verdict on the current HEAD counts.

## Related

- `tribunal-loop` — single round of multi-provider review (this skill is what to do *after* it returns)
- `superpowers:receiving-code-review` — verification-not-performative-agreement applies to tribunal findings too
