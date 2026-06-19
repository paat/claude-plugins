# tribunal-review: silent-failure / payment-idempotency review lens (issue #57)

**Date:** 2026-06-19
**Plugin:** `tribunal-review` (0.13.0 → 0.14.0)
**Issue:** #57 (P1) — add a dedicated review dimension for the highest-value quiet-bug class
(silent failures, payment idempotency).

## Problem

Tribunal reviews diffs across multiple models but has no dedicated dimension for silent
failures and payment-path traps. Reviewers may surface such bugs incidentally, but nothing
instructs them to hunt the specific patterns. These bugs are the most-cited quiet AI-introduced
bug class and are costly on the Montonio/Stripe payment paths the target projects run.

## Approach

Add **one** new dimension item to the existing hunt-list in every reviewer prompt. It maps onto
the existing category enum (`logic` / `edge-case`) — **no schema, severity-rule, or arbiter
change**. The arbiter's existing CONSENSUS-when-≥2-agree behavior already satisfies the issue's
consensus requirement.

### Canonical fragment

Anchored on the searchable phrase **"Silent failures & payment-path traps"**. The wording is
**conditional and self-limiting** to prevent attention-dilution and false-positive inflation on
unrelated diffs:

> Silent failures & payment-path traps - when the diff touches error handling, async code,
> webhooks, or money handling: swallowed exceptions / broadened catch blocks, unawaited promises
> (a removed or missing await), webhook handlers that are non-idempotent or skip signature
> verification, and money handled as float/decimal instead of integer cents. Do NOT invent
> payment concerns on diffs that have none.

Style is adapted per list: bold-em-dash form for the "What to Report" lists (Codex), and
`N. Category - examples` form for the "ANALYZE THIS DIFF FOR" lists (Gemini/DeepSeek+GLM/Qwen/Claude).

**Shell-safe fragment (no metacharacters):** the prompts are embedded in bash heredocs
(`<<PROMPT`, an *unquoted* delimiter) and double-quoted `-p "…"` strings. In both contexts the
shell still interprets `` ` ``, `$`, `$(…)`, and `\`. The fragment therefore contains **none** of
these — `await` is written plain, no backticks, no `$`, no backslashes — so it expands literally
in every site.

### Anti-dilution guards (why other dimensions stay healthy)

1. **Conditional trigger** — "when the diff touches error handling, async, webhooks, or money"
   scopes the lens so it does not fire on unrelated diffs.
2. **Explicit "do not invent"** clause, reinforced by the existing `confidence >= 0.7` and
   "no theoretical concerns without concrete evidence" rules already in every prompt.
3. **Appended, not reordered** — added as the last list item so existing dimensions keep their
   priority position; this is an addition, not a reprioritization.
4. **Within existing taxonomy** — no new category / severity / callout block; reads as one more
   bullet the model already processes.

## Sites edited (9 occurrences of the anchor)

`SKILL.md` — 5 prompt builders (5 anchor occurrences):
- Bash call 1: Codex (`## What to Report` list)
- Bash call 2: Gemini (`ANALYZE THIS DIFF FOR` list)
- Bash call 3: `review_opencode_leg` — **one** shared prompt string covering DeepSeek + GLM (one occurrence)
- Bash call 4: Qwen
- Bash call 5: Claude

`agents/*.md` — 4 standalone docs that carry a prompt (kept in sync to avoid doc-drift, cf. #55):
- `codex-reviewer.md`, `gemini-reviewer.md`, `qwen-reviewer.md`, `claude-reviewer.md`

`deepseek-reviewer.md` has **no** embedded prompt (delegates to the opencode leg) — no change.

## Version + housekeeping

- Bump `.claude-plugin/plugin.json` and root `.claude-plugin/marketplace.json` to `0.14.0`.
- Update README changelog if one exists.

## Verification

**Deterministic gate (run in this session):**
- `grep` asserts the anchor appears at exactly 9 sites (5 in `SKILL.md` + 4 agent docs).
- Re-read each edited block to confirm the fragment landed *inside* the existing prompt
  heredoc/string and did not disturb fence/quoting/backtick-safety.

**Behavioral acceptance (live-LLM, on-demand — non-deterministic, costs quota):**
An A/B over three diffs, run by hand once after implementation:
- Payment/silent-failure fixture (seeded swallowed exception + non-idempotent webhook) →
  new prompt surfaces both; arbiter marks CONSENSUS when ≥2 default legs agree.
- Neutral diff with zero payment/async/error code → other-dimension findings unchanged vs the
  old prompt; no invented payment findings (validates the guard clause).
- Diff with a planted non-payment bug (e.g. off-by-one / SQLi, no payment code) → still caught
  (validates no dilution regression).

If the neutral or planted-bug cases regress, tighten the conditional wording.

## Out of scope

- No committed test harness for this prompt-string change (one-shot grep is sufficient).
- No arbiter / schema / category changes.
- The live-LLM A/B is a judgement check, not a CI gate.
